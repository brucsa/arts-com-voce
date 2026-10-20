-- =====================================================================
-- Arts com Você · Integração Pedidos Diretos → Caixa · Passo 2 de 2
-- (proposta da Fase A2 na R63, aplicada aos Pedidos Diretos Essencial)
--
-- Pré-requisitos: P1-a e P1-b instalados; sql/09_caixa_origens_pedidos.sql
-- já rodado; conferência sql/manutencao/pedidos_diretos_caixa_preinstalacao.sql
-- feita e aprovada pela Bruna.
--
-- O que muda:
--   · cada recebimento ativo vira uma ENTRADA no Caixa (origem RECEBIMENTO),
--     com a data do recebimento;
--   · cada devolução ativa vira uma SAÍDA no Caixa (origem REEMBOLSO), com a
--     data da devolução;
--   · o estorno de um recebimento ou de uma devolução estorna o movimento no
--     Caixa, com a data do estorno (R45);
--   · lançamento e movimento são gravados juntos: entram os dois ou nenhum;
--   · cada lançamento tem no máximo um movimento (o banco não aceita outro);
--   · código de envio: repetir o mesmo envio não cria um segundo lançamento;
--   · a conferência do pedido passa a conferir também o Caixa;
--   · MIGRAÇÃO: os recebimentos e devoluções ativos já registrados entram no
--     Caixa uma única vez, com as datas reais (lançamentos estornados antes
--     da integração não geram nada: o dinheiro não entrou).
--
-- O que NÃO muda:
--   · as regras financeiras dos pedidos (C1, F1, F2, F3), os valores e os
--     lançamentos existentes — nenhum lançamento é alterado;
--   · gastos, pagamentos de gastos, aportes, retiradas e os movimentos
--     existentes do Caixa;
--   · Shopee, Catálogo, Estoque e Joca (sem comissão).
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/pedidos_diretos_caixa_verificacao.sql,
--   sql/pedidos_diretos_verificacao.sql, sql/pedidos_diretos_pagamentos_verificacao.sql
--   e sql/02_verificacao.sql.
-- Tudo ou nada: se qualquer passo falhar, nada é criado nem lançado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.movimentos_caixa') is not null
     and exists (select 1 from pg_attribute where attrelid = 'public.movimentos_caixa'::regclass
                   and attname in ('recebimento_id', 'devolucao_id') and not attisdropped) then
    raise exception 'A integração com o Caixa já está instalada. Nada foi alterado.';
  end if;
  if to_regclass('public.recebimentos_venda') is null or to_regclass('public.devolucoes_venda') is null
     or to_regprocedure('public.registrar_recebimento(uuid, date, numeric, text, text, boolean)') is null
     or to_regprocedure('public.registrar_devolucao(uuid, date, numeric, text, text)') is null then
    raise exception 'O P1-b (pagamentos e devoluções) não está instalado na versão esperada. Nada foi alterado.';
  end if;
  if (select count(*) from pg_enum where enumtypid = 'public.origem_caixa'::regtype
        and enumlabel in ('RECEBIMENTO', 'REEMBOLSO')) <> 2 then
    raise exception 'Rode antes sql/09_caixa_origens_pedidos.sql (origens RECEBIMENTO e REEMBOLSO). Nada foi alterado.';
  end if;
  if exists (select 1 from pg_attribute where attrelid = 'public.movimentos_caixa'::regclass
               and attname in ('recebimento_id', 'devolucao_id') and not attisdropped) then
    raise exception 'A integração com o Caixa já está instalada. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
               and proname in ('migrar_pedidos_para_caixa', 'tg_movimentos_caixa_conferir_pedido', 'numero_pedido_texto')) then
    raise exception 'Já existe função da integração com o Caixa. Nada foi alterado.';
  end if;
  if exists (select 1 from public.movimentos_caixa where origem in ('RECEBIMENTO', 'REEMBOLSO')) then
    raise exception 'Já existem movimentos de recebimento ou reembolso no Caixa. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Ligação do Caixa com os lançamentos dos pedidos
--    Cada recebimento ou devolução tem no máximo UM movimento (unique).
-- ---------------------------------------------------------------------
alter table public.movimentos_caixa
  add column recebimento_id uuid unique references public.recebimentos_venda (id) on delete restrict,
  add column devolucao_id   uuid unique references public.devolucoes_venda (id) on delete restrict,
  add constraint movimentos_caixa_origem_pedido check (
    (origem = 'RECEBIMENTO') = (recebimento_id is not null)
    and (origem = 'REEMBOLSO') = (devolucao_id is not null));

comment on column public.movimentos_caixa.recebimento_id is
  'Recebimento de Pedido Direto que gerou esta entrada (origem RECEBIMENTO). Um por recebimento.';
comment on column public.movimentos_caixa.devolucao_id is
  'Devolução de Pedido Direto que gerou esta saída (origem REEMBOLSO). Uma por devolução.';

-- Código de envio: o mesmo envio repetido (por exemplo, depois de uma falha
-- de conexão) devolve o lançamento já gravado em vez de criar outro.
alter table public.recebimentos_venda add column chave_envio uuid unique;
alter table public.devolucoes_venda   add column chave_envio uuid unique;


-- ---------------------------------------------------------------------
-- 2. Funções internas
-- ---------------------------------------------------------------------
create or replace function public.numero_pedido_texto(p_numero integer)
returns text
language sql
immutable
as $$
  select '#' || lpad(p_numero::text, greatest(4, length(p_numero::text)), '0')
$$;

-- Conferência do pedido: itens (P6), subtotal, resumo financeiro e Caixa.
--   · recebimento/devolução ATIVO: exatamente um movimento, com a mesma data
--     e o mesmo valor, não estornado;
--   · ESTORNADO: ou não tem movimento (estornado antes da integração), ou o
--     movimento dele está estornado no Caixa.
create or replace function public.conferir_pedido(p_venda_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda  public.vendas;
  v_itens  integer;
  v_soma   numeric(12,2);
  v_rec    numeric(12,2);
  v_dev    numeric(12,2);
begin
  select * into v_venda from public.vendas where id = p_venda_id;
  if not found then
    return;
  end if;

  select count(*), coalesce(sum(valor_item), 0) into v_itens, v_soma
    from public.itens_venda where venda_id = p_venda_id;

  if v_itens = 0 then
    raise exception 'O pedido precisa ter pelo menos um item (do catálogo ou personalizado). Nada foi gravado.';
  end if;
  if v_venda.subtotal <> v_soma then
    raise exception 'Conferência do pedido %: o subtotal não bate com a soma dos itens. Nada foi gravado.',
      public.numero_pedido_texto(v_venda.numero);
  end if;

  select coalesce(sum(valor), 0) into v_rec
    from public.recebimentos_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  select coalesce(sum(valor), 0) into v_dev
    from public.devolucoes_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  if v_venda.valor_recebido <> v_rec or v_venda.valor_devolvido <> v_dev then
    raise exception 'Conferência do pedido %: o recebido ou o devolvido não bate com os lançamentos ativos. Nada foi gravado.',
      public.numero_pedido_texto(v_venda.numero);
  end if;

  -- Caixa: recebimentos
  if exists (
    select 1 from public.recebimentos_venda r
     where r.venda_id = p_venda_id
       and ((r.situacao = 'ATIVO' and not exists (
              select 1 from public.movimentos_caixa m
               where m.recebimento_id = r.id and m.origem = 'RECEBIMENTO' and m.tipo = 'ENTRADA'
                 and m.valor = r.valor and m.data = r.data
                 and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id)))
         or (r.situacao = 'ESTORNADO' and exists (
              select 1 from public.movimentos_caixa m
               where m.recebimento_id = r.id
                 and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id))))
  ) then
    raise exception 'Conferência do pedido %: um recebimento não bate com o Caixa. Nada foi gravado.',
      public.numero_pedido_texto(v_venda.numero);
  end if;

  -- Caixa: devoluções
  if exists (
    select 1 from public.devolucoes_venda d
     where d.venda_id = p_venda_id
       and ((d.situacao = 'ATIVO' and not exists (
              select 1 from public.movimentos_caixa m
               where m.devolucao_id = d.id and m.origem = 'REEMBOLSO' and m.tipo = 'SAIDA'
                 and m.valor = d.valor and m.data = d.data
                 and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id)))
         or (d.situacao = 'ESTORNADO' and exists (
              select 1 from public.movimentos_caixa m
               where m.devolucao_id = d.id
                 and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id))))
  ) then
    raise exception 'Conferência do pedido %: uma devolução não bate com o Caixa. Nada foi gravado.',
      public.numero_pedido_texto(v_venda.numero);
  end if;
end;
$$;

-- Conferência também quando o próprio Caixa recebe um movimento ligado a um
-- pedido (no fim da gravação). "security definer" pelo mesmo motivo dos
-- outros gatilhos de conferência.
create or replace function public.tg_movimentos_caixa_conferir_pedido()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mov    public.movimentos_caixa := new;
  v_venda  uuid;
begin
  if v_mov.origem = 'ESTORNO' then
    select * into v_mov from public.movimentos_caixa where id = new.movimento_estornado_id;
  end if;
  if v_mov.recebimento_id is not null then
    select venda_id into v_venda from public.recebimentos_venda where id = v_mov.recebimento_id;
  elsif v_mov.devolucao_id is not null then
    select venda_id into v_venda from public.devolucoes_venda where id = v_mov.devolucao_id;
  end if;
  if v_venda is not null then
    perform public.conferir_pedido(v_venda);
  end if;
  return null;
end;
$$;

create constraint trigger trg_movimentos_caixa_conferir_pedido
  after insert or update on public.movimentos_caixa
  deferrable initially deferred
  for each row execute function public.tg_movimentos_caixa_conferir_pedido();


-- ---------------------------------------------------------------------
-- 3. Funções financeiras dos pedidos, agora com o Caixa
--    (regras e mensagens iguais às do P1-b; acréscimos: o movimento no
--    Caixa e o código de envio)
-- ---------------------------------------------------------------------
drop function public.registrar_recebimento(uuid, date, numeric, text, text, boolean);
drop function public.registrar_devolucao(uuid, date, numeric, text, text);

-- Recebimento confirmado (R83) → entrada no Caixa com a data do recebimento.
create or replace function public.registrar_recebimento(
  p_venda_id         uuid,
  p_data             date,
  p_valor            numeric,
  p_forma_pagamento  text,
  p_observacao       text,
  p_confirmado       boolean,
  p_chave            uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda  public.vendas;
  v_obs    text := nullif(trim(coalesce(p_observacao, '')), '');
  v_id     uuid;
  v_outro  uuid;
begin
  perform public.exigir_admin();

  if p_confirmado is not true then
    raise exception 'Confirme que o dinheiro foi recebido. Só pagamentos confirmados são registrados.';
  end if;

  select * into v_venda from public.vendas where id = p_venda_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;

  -- Mesmo envio repetido: devolve o recebimento já gravado.
  if p_chave is not null then
    select id, venda_id into v_id, v_outro from public.recebimentos_venda where chave_envio = p_chave;
    if v_id is not null then
      if v_outro <> p_venda_id then raise exception 'Código de envio já usado em outro pedido.'; end if;
      return v_id;
    end if;
  end if;

  if v_venda.status_pedido = 'CANCELADO' then
    raise exception 'Pedido cancelado não recebe novos pagamentos.';
  end if;
  if v_venda.total = 0 then
    raise exception 'Este pedido não tem cobrança (total R$ 0,00) e não recebe pagamentos.';
  end if;

  if p_valor is null or p_valor <= 0 then raise exception 'Informe um valor maior que zero.'; end if;
  if p_valor <> round(p_valor, 2) then raise exception 'O valor aceita até 2 casas decimais.'; end if;
  if p_valor > v_venda.saldo then
    raise exception 'O valor (R$ %) passa do saldo a receber (R$ %).',
      replace(to_char(p_valor, 'FM9999999990.00'), '.', ','), replace(to_char(v_venda.saldo, 'FM9999999990.00'), '.', ',');
  end if;

  if p_data is null then raise exception 'Informe a data do recebimento.'; end if;
  if p_data < v_venda.data then raise exception 'A data do recebimento não pode ser anterior à data do pedido.'; end if;
  if p_data > public.hoje() then raise exception 'A data do recebimento não pode ser futura.'; end if;

  if p_forma_pagamento is null
     or p_forma_pagamento not in (select unnest(enum_range(null::public.forma_pagamento))::text) then
    raise exception 'Escolha a forma de pagamento.';
  end if;
  if length(coalesce(v_obs, '')) > 500 then raise exception 'A observação pode ter até 500 caracteres.'; end if;

  insert into public.recebimentos_venda (venda_id, data, valor, forma_pagamento, observacao, confirmado_por, chave_envio)
  values (p_venda_id, p_data, p_valor, p_forma_pagamento::public.forma_pagamento, v_obs, auth.uid(), p_chave)
  returning id into v_id;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, recebimento_id)
  values (p_data, 'ENTRADA', 'RECEBIMENTO', p_valor,
          'Recebimento do pedido ' || public.numero_pedido_texto(v_venda.numero), v_id);

  perform public.recalcular_pedido(p_venda_id);
  perform public.conferir_pedido(p_venda_id);
  return v_id;
end;
$$;

-- Devolução ao cliente (R83) → saída do Caixa com a data da devolução.
create or replace function public.registrar_devolucao(
  p_venda_id         uuid,
  p_data             date,
  p_valor            numeric,
  p_forma_pagamento  text,
  p_motivo           text,
  p_chave            uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda    public.vendas;
  v_liquido  numeric;
  v_motivo   text := trim(coalesce(p_motivo, ''));
  v_id       uuid;
  v_outro    uuid;
begin
  perform public.exigir_admin();

  select * into v_venda from public.vendas where id = p_venda_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;

  if p_chave is not null then
    select id, venda_id into v_id, v_outro from public.devolucoes_venda where chave_envio = p_chave;
    if v_id is not null then
      if v_outro <> p_venda_id then raise exception 'Código de envio já usado em outro pedido.'; end if;
      return v_id;
    end if;
  end if;

  v_liquido := v_venda.valor_recebido - v_venda.valor_devolvido;

  if p_valor is null or p_valor <= 0 then raise exception 'Informe um valor maior que zero.'; end if;
  if p_valor <> round(p_valor, 2) then raise exception 'O valor aceita até 2 casas decimais.'; end if;
  if v_liquido <= 0 then raise exception 'Não há valor recebido para devolver neste pedido.'; end if;
  if p_valor > v_liquido then
    raise exception 'A devolução (R$ %) passa do valor líquido recebido (R$ %).',
      replace(to_char(p_valor, 'FM9999999990.00'), '.', ','), replace(to_char(v_liquido, 'FM9999999990.00'), '.', ',');
  end if;

  if p_data is null then raise exception 'Informe a data da devolução.'; end if;
  if p_data < v_venda.data then raise exception 'A data da devolução não pode ser anterior à data do pedido.'; end if;
  if p_data > public.hoje() then raise exception 'A data da devolução não pode ser futura.'; end if;

  if p_forma_pagamento is null
     or p_forma_pagamento not in (select unnest(enum_range(null::public.forma_pagamento))::text) then
    raise exception 'Escolha a forma da devolução.';
  end if;
  if length(v_motivo) = 0 then raise exception 'Informe o motivo da devolução.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  insert into public.devolucoes_venda (venda_id, data, valor, forma_pagamento, motivo, chave_envio)
  values (p_venda_id, p_data, p_valor, p_forma_pagamento::public.forma_pagamento, v_motivo, p_chave)
  returning id into v_id;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, devolucao_id, obs)
  values (p_data, 'SAIDA', 'REEMBOLSO', p_valor,
          'Devolução do pedido ' || public.numero_pedido_texto(v_venda.numero), v_id, v_motivo);

  perform public.recalcular_pedido(p_venda_id);
  perform public.conferir_pedido(p_venda_id);
  return v_id;
end;
$$;

-- Estorno de recebimento lançado por engano → estorno do movimento no Caixa
-- (saída), com a data de hoje (R45). Regras do P1-b iguais.
create or replace function public.estornar_recebimento(p_recebimento_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda_id  uuid;
  v_venda     public.vendas;
  v_rec       public.recebimentos_venda;
  v_mov       public.movimentos_caixa;
  v_motivo    text := trim(coalesce(p_motivo, ''));
begin
  perform public.exigir_admin();

  if length(v_motivo) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  select venda_id into v_venda_id from public.recebimentos_venda where id = p_recebimento_id;
  if v_venda_id is null then raise exception 'Recebimento não encontrado.'; end if;
  select * into v_venda from public.vendas where id = v_venda_id for update;
  select * into v_rec from public.recebimentos_venda where id = p_recebimento_id for update;

  if v_rec.situacao = 'ESTORNADO' then raise exception 'Este recebimento já foi estornado.'; end if;
  if v_venda.valor_recebido - v_rec.valor < v_venda.valor_devolvido then
    raise exception 'Estornar este recebimento deixaria as devoluções (R$ %) maiores que o recebido (R$ %). Estorne antes a devolução correspondente, se ela também foi lançada por engano.',
      replace(to_char(v_venda.valor_devolvido, 'FM9999999990.00'), '.', ','),
      replace(to_char(v_venda.valor_recebido - v_rec.valor, 'FM9999999990.00'), '.', ',');
  end if;

  select * into v_mov from public.movimentos_caixa where recebimento_id = p_recebimento_id for update;
  if not found then
    raise exception 'O recebimento não foi encontrado no Caixa. Nada foi alterado; fale com o suporte.';
  end if;

  update public.recebimentos_venda
     set situacao = 'ESTORNADO', estornado_em = now(), motivo_estorno = v_motivo
   where id = p_recebimento_id;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, movimento_estornado_id, obs)
  values (public.hoje(), 'SAIDA', 'ESTORNO', v_mov.valor, 'Estorno: ' || v_mov.descricao, v_mov.id, v_motivo);

  perform public.recalcular_pedido(v_venda_id);
  perform public.conferir_pedido(v_venda_id);
end;
$$;

-- Estorno de devolução registrada por engano (F3) → estorno do movimento no
-- Caixa (entrada), com a data de hoje (R45). Regras do P1-b iguais.
create or replace function public.estornar_devolucao(p_devolucao_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda_id  uuid;
  v_venda     public.vendas;
  v_dev       public.devolucoes_venda;
  v_mov       public.movimentos_caixa;
  v_motivo    text := trim(coalesce(p_motivo, ''));
  v_liquido   numeric;
begin
  perform public.exigir_admin();

  if length(v_motivo) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  select venda_id into v_venda_id from public.devolucoes_venda where id = p_devolucao_id;
  if v_venda_id is null then raise exception 'Devolução não encontrada.'; end if;
  select * into v_venda from public.vendas where id = v_venda_id for update;
  select * into v_dev from public.devolucoes_venda where id = p_devolucao_id for update;

  if v_dev.situacao = 'ESTORNADO' then raise exception 'Esta devolução já foi estornada.'; end if;
  v_liquido := v_venda.valor_recebido - v_venda.valor_devolvido + v_dev.valor;
  if v_venda.status_pedido <> 'CANCELADO' and v_liquido > v_venda.total then
    raise exception 'Estornar esta devolução deixaria o valor líquido recebido (R$ %) acima do total do pedido (R$ %).',
      replace(to_char(v_liquido, 'FM9999999990.00'), '.', ','), replace(to_char(v_venda.total, 'FM9999999990.00'), '.', ',');
  end if;

  select * into v_mov from public.movimentos_caixa where devolucao_id = p_devolucao_id for update;
  if not found then
    raise exception 'A devolução não foi encontrada no Caixa. Nada foi alterado; fale com o suporte.';
  end if;

  update public.devolucoes_venda
     set situacao = 'ESTORNADO', estornado_em = now(), motivo_estorno = v_motivo
   where id = p_devolucao_id;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, movimento_estornado_id, obs)
  values (public.hoje(), 'ENTRADA', 'ESTORNO', v_mov.valor, 'Estorno: ' || v_mov.descricao, v_mov.id, v_motivo);

  perform public.recalcular_pedido(v_venda_id);
  perform public.conferir_pedido(v_venda_id);
end;
$$;

-- Caixa: estornar um aporte, uma retirada ou um pagamento de gasto continua
-- igual. Movimentos que vêm de um pedido só são estornados pelo pedido.
create or replace function public.estornar_movimento(p_movimento_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mov public.movimentos_caixa;
begin
  perform public.exigir_admin();
  if p_motivo is null or length(trim(p_motivo)) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  select * into v_mov from public.movimentos_caixa where id = p_movimento_id for update;
  if not found then raise exception 'Movimento não encontrado.'; end if;
  if v_mov.origem = 'PAGAMENTO_GASTO' then
    perform public.estornar_pagamento_interno(v_mov.pagamento_id, trim(p_motivo), public.hoje());
    return;
  end if;
  if v_mov.origem in ('RECEBIMENTO', 'REEMBOLSO') then
    raise exception 'Este movimento vem de um Pedido Direto. Para corrigir, estorne o lançamento no próprio pedido (Pedidos › Diretos).';
  end if;
  if v_mov.origem not in ('APORTE', 'RETIRADA') then raise exception 'Este movimento não pode ser estornado.'; end if;
  if exists (select 1 from public.movimentos_caixa where movimento_estornado_id = p_movimento_id) then
    raise exception 'Este movimento já foi estornado.';
  end if;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, movimento_estornado_id, obs)
  values (public.hoje(),
          case when v_mov.tipo = 'ENTRADA' then 'SAIDA'::public.tipo_movimento else 'ENTRADA'::public.tipo_movimento end,
          'ESTORNO', v_mov.valor, 'Estorno: ' || v_mov.descricao, v_mov.id, trim(p_motivo));
end;
$$;


-- ---------------------------------------------------------------------
-- 4. Migração dos lançamentos já registrados (uma única vez; idempotente)
--    · só lançamentos ATIVOS que ainda não têm movimento;
--    · com as datas reais dos lançamentos;
--    · rodar de novo não cria nada (unique + "ainda não tem movimento").
-- ---------------------------------------------------------------------
create or replace function public.migrar_pedidos_para_caixa()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec  integer;
  v_dev  integer;
  v_v    uuid;
begin
  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, recebimento_id)
  select r.data, 'ENTRADA', 'RECEBIMENTO', r.valor,
         'Recebimento do pedido ' || public.numero_pedido_texto(v.numero), r.id
    from public.recebimentos_venda r
    join public.vendas v on v.id = r.venda_id
   where r.situacao = 'ATIVO'
     and not exists (select 1 from public.movimentos_caixa m where m.recebimento_id = r.id)
   order by r.data, r.confirmado_em;
  get diagnostics v_rec = row_count;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, devolucao_id, obs)
  select d.data, 'SAIDA', 'REEMBOLSO', d.valor,
         'Devolução do pedido ' || public.numero_pedido_texto(v.numero), d.id, d.motivo
    from public.devolucoes_venda d
    join public.vendas v on v.id = d.venda_id
   where d.situacao = 'ATIVO'
     and not exists (select 1 from public.movimentos_caixa m where m.devolucao_id = d.id)
   order by d.data, d.created_at;
  get diagnostics v_dev = row_count;

  -- Confere todos os pedidos com lançamentos
  for v_v in select distinct venda_id from public.recebimentos_venda
             union select distinct venda_id from public.devolucoes_venda loop
    perform public.conferir_pedido(v_v);
  end loop;

  return jsonb_build_object('recebimentos_lancados', v_rec, 'devolucoes_lancadas', v_dev);
end;
$$;

do $$
declare
  v_resultado jsonb;
begin
  v_resultado := public.migrar_pedidos_para_caixa();
  raise notice 'Migração para o Caixa: %', v_resultado;
end;
$$;


-- ---------------------------------------------------------------------
-- 5. Permissões
-- ---------------------------------------------------------------------
revoke all on function public.numero_pedido_texto(integer) from public, anon, authenticated;
revoke all on function public.tg_movimentos_caixa_conferir_pedido() from public, anon, authenticated;
revoke all on function public.migrar_pedidos_para_caixa() from public, anon, authenticated;
revoke all on function public.conferir_pedido(uuid) from public, anon, authenticated;

revoke all on function public.registrar_recebimento(uuid, date, numeric, text, text, boolean, uuid) from public, anon;
revoke all on function public.registrar_devolucao(uuid, date, numeric, text, text, uuid) from public, anon;
revoke all on function public.estornar_recebimento(uuid, text) from public, anon;
revoke all on function public.estornar_devolucao(uuid, text) from public, anon;
revoke all on function public.estornar_movimento(uuid, text) from public, anon;
grant execute on function public.registrar_recebimento(uuid, date, numeric, text, text, boolean, uuid) to authenticated;
grant execute on function public.registrar_devolucao(uuid, date, numeric, text, text, uuid) to authenticated;
grant execute on function public.estornar_recebimento(uuid, text) to authenticated;
grant execute on function public.estornar_devolucao(uuid, text) to authenticated;
grant execute on function public.estornar_movimento(uuid, text) to authenticated;

commit;
