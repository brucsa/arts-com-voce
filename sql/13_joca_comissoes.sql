-- =====================================================================
-- Arts com Você · Área do Joca nos Pedidos Diretos · Passo 2 de 2
-- Especificação v1.7, R89–R92 (decisões J1–J8); R76 atualizada.
--
-- Antes: rode sql/12_caixa_origem_joca.sql sozinho (origem PAGAMENTO_JOCA).
--
-- O que este arquivo faz (só acréscimos, mais uma função trocada):
--   · comissao_joca_pedido: o percentual congelado de cada pedido, o vigente
--     na data do pedido (R89, R2);
--   · comissoes_joca: o histórico da comissão de cada pedido (comissão
--     inicial, ajustes, cancelamento); nada é apagado (R90);
--   · pagamentos_joca: pagamentos ao Joca, que saem do Caixa com a origem
--     PAGAMENTO_JOCA e só se corrigem por estorno (R91);
--   · conferência automática no fim de cada gravação: a comissão de cada
--     pedido acompanha o pedido (itens, desconto, devolução, cancelamento);
--     cada pagamento ativo tem a sua saída no Caixa;
--   · funções do Joca: joca_resumo() e joca_extrato(), as únicas que ele
--     usa, só com os valores dele (R92, R26);
--   · estornar_movimento passa a recusar o pagamento ao Joca (o estorno é
--     feito na área do Joca);
--   · MIGRAÇÃO: os pedidos já registrados recebem a comissão uma única vez,
--     com o percentual da data de cada um (J3).
--
-- O que NÃO muda:
--   · pedidos, itens, recebimentos, devoluções e os movimentos do Caixa que
--     já existem (nenhum é alterado);
--   · as funções dos pedidos e do Caixa (só estornar_movimento ganha uma
--     recusa a mais);
--   · Catálogo, Estoque, Shopee e Configurações.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/joca_verificacao.sql e as verificações gerais.
-- Tudo ou nada: se qualquer passo falhar, nada é criado nem lançado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.comissoes_joca') is not null or to_regclass('public.pagamentos_joca') is not null
     or to_regclass('public.comissao_joca_pedido') is not null then
    raise exception 'A área do Joca já está instalada. Nada foi alterado.';
  end if;
  if not exists (select 1 from pg_attribute where attrelid = to_regclass('public.movimentos_caixa')
                    and attname = 'recebimento_id' and not attisdropped)
     or to_regprocedure('public.registrar_recebimento(uuid, date, numeric, text, text, boolean, uuid)') is null then
    raise exception 'A integração Pedidos Diretos → Caixa (sql/10) não está instalada. Nada foi alterado.';
  end if;
  if not exists (select 1 from pg_enum where enumtypid = 'public.origem_caixa'::regtype and enumlabel = 'PAGAMENTO_JOCA') then
    raise exception 'Rode antes sql/12_caixa_origem_joca.sql (origem PAGAMENTO_JOCA). Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
               and proname in ('percentual_joca_em', 'sincronizar_comissao_joca', 'tg_vendas_comissao_joca',
                               'joca_totais', 'registrar_pagamento_joca', 'estornar_pagamento_joca',
                               'conferir_pagamento_joca', 'tg_pagamentos_joca_conferir', 'tg_movimentos_caixa_conferir_joca',
                               'tg_comissoes_joca_protege', 'tg_pagamentos_joca_protege',
                               'joca_resumo', 'joca_extrato', 'migrar_comissoes_joca')) then
    raise exception 'Já existe função da área do Joca. Nada foi alterado.';
  end if;
  if exists (select 1 from public.movimentos_caixa where origem = 'PAGAMENTO_JOCA') then
    raise exception 'Já existem movimentos de pagamento ao Joca no Caixa. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------
create type public.tipo_comissao_joca as enum ('COMISSAO', 'AJUSTE', 'CANCELAMENTO');

-- Percentual congelado de cada pedido: o vigente na data do pedido (R89, R2).
create table public.comissao_joca_pedido (
  id               uuid primary key default gen_random_uuid(),
  venda_id         uuid not null unique references public.vendas (id) on delete restrict,
  data_referencia  date not null,
  percentual       numeric(5,2) not null check (percentual >= 0 and percentual <= 100),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

comment on table public.comissao_joca_pedido is
  'Percentual do Joca congelado em cada Pedido Direto (R89): o vigente na data do pedido. Mudar o percentual em Configurações não altera pedidos já registrados.';

-- Histórico da comissão (R90): só inclusões. A comissão atual do pedido é a soma.
create table public.comissoes_joca (
  id              uuid primary key default gen_random_uuid(),
  seq             bigint generated always as identity unique,
  venda_id        uuid not null references public.vendas (id) on delete restrict,
  data            date not null,
  tipo            public.tipo_comissao_joca not null,
  valor           numeric(12,2) not null check (valor <> 0),       -- diferença (±)
  comissao_apos   numeric(12,2) not null,                          -- comissão do pedido depois deste registro
  base            numeric(12,2) not null,                          -- produtos − desconto
  percentual      numeric(5,2) not null,
  total           numeric(12,2) not null,
  devolvido       numeric(12,2) not null,
  obs             text not null,
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid()
);

create index idx_comissoes_joca_venda on public.comissoes_joca (venda_id, seq);

comment on table public.comissoes_joca is
  'Comissão do Joca nos Pedidos Diretos (R89–R90): comissão inicial, ajustes e cancelamento. Nada é alterado nem apagado.';

-- Pagamentos ao Joca (R91): saem do Caixa; correção só por estorno.
create table public.pagamentos_joca (
  id               uuid primary key default gen_random_uuid(),
  data             date not null,
  valor            numeric(12,2) not null check (valor > 0),
  forma_pagamento  public.forma_pagamento not null,
  obs              text check (obs is null or length(obs) <= 500),
  situacao         public.situacao_lancamento_pedido not null default 'ATIVO',
  estornado_em     timestamptz,
  motivo_estorno   text check (motivo_estorno is null or length(motivo_estorno) <= 500),
  chave_envio      uuid unique,
  created_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),
  updated_at       timestamptz not null default now(),
  constraint pagamentos_joca_estorno_completo check (
    (situacao = 'ESTORNADO') = (estornado_em is not null and coalesce(length(trim(motivo_estorno)), 0) > 0))
);

create index idx_pagamentos_joca_data on public.pagamentos_joca (data, created_at);

comment on table public.pagamentos_joca is
  'Pagamentos ao Joca (R91). Limitados ao Disponível; cada um tem a sua saída no Caixa (PAGAMENTO_JOCA). Correção só por estorno.';

-- Caixa: cada pagamento ao Joca tem no máximo um movimento.
alter table public.movimentos_caixa
  add column pagamento_joca_id uuid unique references public.pagamentos_joca (id) on delete restrict,
  add constraint movimentos_caixa_origem_joca check ((origem = 'PAGAMENTO_JOCA') = (pagamento_joca_id is not null));

comment on column public.movimentos_caixa.pagamento_joca_id is
  'Pagamento ao Joca que gerou esta saída (origem PAGAMENTO_JOCA). Um por pagamento.';


-- ---------------------------------------------------------------------
-- 2. updated_at, auditoria e proteções
-- ---------------------------------------------------------------------
create trigger trg_comissao_joca_pedido_updated_at before update on public.comissao_joca_pedido
  for each row execute function public.tg_updated_at();
create trigger trg_pagamentos_joca_updated_at before update on public.pagamentos_joca
  for each row execute function public.tg_updated_at();

create trigger trg_comissao_joca_pedido_auditoria after insert or update or delete on public.comissao_joca_pedido
  for each row execute function public.tg_auditoria();
create trigger trg_comissoes_joca_auditoria after insert or update or delete on public.comissoes_joca
  for each row execute function public.tg_auditoria();
create trigger trg_pagamentos_joca_auditoria after insert or update or delete on public.pagamentos_joca
  for each row execute function public.tg_auditoria();

-- Histórico da comissão: só inclusões.
create or replace function public.tg_comissoes_joca_protege()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_table_name = 'comissao_joca_pedido' then
    raise exception 'O percentual do pedido não pode ser apagado.';
  end if;
  raise exception 'O histórico da comissão do Joca não pode ser alterado nem apagado. As correções entram como ajustes.';
end;
$$;

create trigger trg_comissoes_joca_protege before update or delete on public.comissoes_joca
  for each row execute function public.tg_comissoes_joca_protege();
create trigger trg_comissao_joca_pedido_protege before delete on public.comissao_joca_pedido
  for each row execute function public.tg_comissoes_joca_protege();

-- Pagamentos: nunca apagados; só ATIVO → ESTORNADO.
create or replace function public.tg_pagamentos_joca_protege()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_livres text[] := array['situacao', 'estornado_em', 'motivo_estorno', 'updated_at'];
begin
  if tg_op = 'DELETE' then
    raise exception 'Pagamentos ao Joca não podem ser excluídos. Para corrigir, estorne o pagamento.';
  end if;
  if old.situacao = 'ESTORNADO' then
    raise exception 'Este pagamento já foi estornado.';
  end if;
  if new.situacao <> 'ESTORNADO' or (to_jsonb(new) - v_livres) is distinct from (to_jsonb(old) - v_livres) then
    raise exception 'Pagamento ao Joca não pode ser editado. Para corrigir, estorne e registre de novo.';
  end if;
  return new;
end;
$$;

create trigger trg_pagamentos_joca_protege before update or delete on public.pagamentos_joca
  for each row execute function public.tg_pagamentos_joca_protege();


-- ---------------------------------------------------------------------
-- 3. Comissão de cada pedido (R89, R90)
-- ---------------------------------------------------------------------

-- Percentual vigente numa data (R2): uma mudança feita no dia D vale para
-- pedidos a partir do dia D. Sem mudança registrada depois da data, vale o
-- percentual atual.
create or replace function public.percentual_joca_em(p_data date)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select h.valor_anterior::numeric
       from public.configuracoes_hist h
      where h.campo = 'comissao_joca_pct'
        and (h.quando at time zone 'America/Sao_Paulo')::date > p_data
      order by h.quando, h.id
      limit 1),
    (select c.comissao_joca_pct from public.configuracoes c limit 1),
    10)
$$;

-- Deixa a comissão gravada do pedido igual à esperada. Se for diferente,
-- grava a diferença como um registro novo (nada é alterado nem apagado).
--   comissão = percentual × (subtotal − desconto) × (total − devolvido) ÷ total
--   pedido cancelado ou de total zero → 0.
create or replace function public.sincronizar_comissao_joca(p_venda_id uuid, p_obs_inicial text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda     public.vendas;
  v_pct       public.comissao_joca_pedido;
  v_ultimo    public.comissoes_joca;
  v_base      numeric(12,2);
  v_esperada  numeric(12,2);
  v_atual     numeric(12,2);
  v_tipo      public.tipo_comissao_joca;
  v_obs       text;
  v_data      date;
begin
  select * into v_venda from public.vendas where id = p_venda_id;
  if not found then return; end if;

  -- Percentual congelado: o da data do pedido. Se a data do pedido mudar
  -- (edição permitida enquanto ele não foi entregue), vale o da nova data.
  select * into v_pct from public.comissao_joca_pedido where venda_id = p_venda_id;
  if not found then
    insert into public.comissao_joca_pedido (venda_id, data_referencia, percentual)
    values (p_venda_id, v_venda.data, public.percentual_joca_em(v_venda.data))
    returning * into v_pct;
  elsif v_pct.data_referencia <> v_venda.data then
    update public.comissao_joca_pedido
       set data_referencia = v_venda.data, percentual = public.percentual_joca_em(v_venda.data)
     where id = v_pct.id
    returning * into v_pct;
  end if;

  v_base := v_venda.subtotal - v_venda.desconto;
  if v_venda.status_pedido = 'CANCELADO' or v_venda.total <= 0 then
    v_esperada := 0;
  else
    v_esperada := round(v_pct.percentual / 100 * v_base
                        * greatest(v_venda.total - v_venda.valor_devolvido, 0) / v_venda.total, 2);
  end if;

  select coalesce(sum(valor), 0) into v_atual from public.comissoes_joca where venda_id = p_venda_id;
  if v_esperada = v_atual then return; end if;

  select * into v_ultimo from public.comissoes_joca where venda_id = p_venda_id order by seq desc limit 1;
  if v_ultimo.id is null then
    v_tipo := 'COMISSAO'; v_data := v_venda.data;
    v_obs := coalesce(p_obs_inicial, 'Comissão do pedido');
  elsif v_venda.status_pedido = 'CANCELADO' then
    v_tipo := 'CANCELAMENTO'; v_data := public.hoje(); v_obs := 'Pedido cancelado';
  else
    v_tipo := 'AJUSTE'; v_data := public.hoje();
    v_obs := case
      when v_venda.valor_devolvido > v_ultimo.devolvido then 'Devolução ao cliente'
      when v_venda.valor_devolvido < v_ultimo.devolvido then 'Devolução estornada'
      else 'Pedido editado' end;
  end if;

  insert into public.comissoes_joca (venda_id, data, tipo, valor, comissao_apos, base, percentual, total, devolvido, obs)
  values (p_venda_id, v_data, v_tipo, v_esperada - v_atual, v_esperada, v_base, v_pct.percentual,
          v_venda.total, v_venda.valor_devolvido, v_obs);
end;
$$;

-- No fim de cada gravação de um pedido (itens, desconto, recebimento,
-- devolução, status), a comissão é acertada.
create or replace function public.tg_vendas_comissao_joca()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.sincronizar_comissao_joca(new.id);
  return null;
end;
$$;

create constraint trigger trg_vendas_comissao_joca
  after insert or update on public.vendas
  deferrable initially deferred
  for each row execute function public.tg_vendas_comissao_joca();


-- ---------------------------------------------------------------------
-- 4. Consultas da Admin (respeitam o acesso de quem consulta)
-- ---------------------------------------------------------------------
-- Situação de cada pedido (R90, R91): A receber até o pedido estar todo
-- recebido; depois Disponível. Os pagamentos quitam primeiro as comissões
-- disponíveis mais antigas (pela data do pedido).
create view public.vw_joca_pedidos with (security_invoker = true) as
with c as (
  select v.id as venda_id, v.numero, v.data, v.status_pedido, v.status_financeiro, cl.nome as cliente,
         p.percentual, (v.subtotal - v.desconto) as base, v.total, v.valor_devolvido,
         coalesce(s.soma, 0)::numeric(12,2) as comissao, coalesce(s.registros, 0) as registros
    from public.vendas v
    join public.clientes cl on cl.id = v.cliente_id
    left join public.comissao_joca_pedido p on p.venda_id = v.id
    left join (select venda_id, sum(valor) as soma, count(*) as registros
                 from public.comissoes_joca group by venda_id) s on s.venda_id = v.id
),
pago as (
  select coalesce(sum(valor), 0) as total from public.pagamentos_joca where situacao = 'ATIVO'
),
disp as (
  select venda_id, sum(comissao) over (order by data, numero rows between unbounded preceding and current row) as acumulado
    from c where status_financeiro = 'RECEBIDO' and comissao > 0
)
select c.*,
       case
         when c.status_pedido = 'CANCELADO' then 'CANCELADO'
         when c.comissao <= 0 then 'SEM_COMISSAO'
         when c.status_financeiro <> 'RECEBIDO' then 'A_RECEBER'
         when d.acumulado <= pago.total then 'PAGA'
         when d.acumulado - c.comissao < pago.total then 'PAGA_EM_PARTE'
         else 'DISPONIVEL'
       end as situacao
  from c
  cross join pago
  left join disp d on d.venda_id = c.venda_id;

-- Totais (R92): A receber, Disponível (pode ficar negativo, R90) e Pago.
-- Interna: a Admin e o Joca leem os totais por joca_resumo().
create or replace function public.joca_totais()
returns table (a_receber numeric, disponivel numeric, pago numeric)
language sql
stable
security definer
set search_path = public
as $$
  with c as (
    select v.status_financeiro, coalesce(sum(k.valor), 0) as comissao
      from public.vendas v left join public.comissoes_joca k on k.venda_id = v.id
     group by v.id, v.status_financeiro
  ),
  p as (select coalesce(sum(valor), 0) as total from public.pagamentos_joca where situacao = 'ATIVO')
  select coalesce((select sum(comissao) from c where status_financeiro = 'A_RECEBER'), 0)::numeric(12,2),
         (coalesce((select sum(comissao) from c where status_financeiro = 'RECEBIDO'), 0) - p.total)::numeric(12,2),
         p.total::numeric(12,2)
    from p
$$;


-- ---------------------------------------------------------------------
-- 5. Pagamentos ao Joca (R91)
-- ---------------------------------------------------------------------
create or replace function public.registrar_pagamento_joca(
  p_data             date,
  p_valor            numeric,
  p_forma_pagamento  text,
  p_obs              text,
  p_chave            uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id     uuid;
  v_disp   numeric(12,2);
  v_forma  public.forma_pagamento;
  v_obs    text := nullif(trim(coalesce(p_obs, '')), '');
begin
  perform public.exigir_admin();
  perform pg_advisory_xact_lock(hashtext('arts_com_voce.pagamento_joca'));

  -- Mesmo envio repetido: devolve o pagamento já gravado.
  if p_chave is not null then
    select id into v_id from public.pagamentos_joca where chave_envio = p_chave;
    if v_id is not null then return v_id; end if;
  end if;

  if p_data is null then raise exception 'Informe a data do pagamento.'; end if;
  if p_data > public.hoje() then raise exception 'A data do pagamento não pode ser no futuro.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'O valor precisa ser maior que zero.'; end if;
  if round(p_valor, 2) <> p_valor then raise exception 'Use no máximo duas casas decimais no valor.'; end if;
  if p_forma_pagamento is null or p_forma_pagamento not in (select e.enumlabel from pg_enum e where e.enumtypid = 'public.forma_pagamento'::regtype) then
    raise exception 'Escolha a forma de pagamento.';
  end if;
  v_forma := p_forma_pagamento::public.forma_pagamento;
  if v_obs is not null and length(v_obs) > 500 then raise exception 'A observação pode ter até 500 caracteres.'; end if;

  select disponivel into v_disp from public.joca_totais();
  if v_disp <= 0 then
    raise exception 'Não há valor disponível para pagar ao Joca. A comissão só fica disponível quando o pedido está todo recebido.';
  end if;
  if p_valor > v_disp then
    raise exception 'O valor passa do Disponível do Joca (R$ %). Não existe adiantamento de comissão.',
      replace(to_char(v_disp, 'FM9999999990.00'), '.', ',');
  end if;

  insert into public.pagamentos_joca (data, valor, forma_pagamento, obs, chave_envio)
  values (p_data, p_valor, v_forma, v_obs, p_chave)
  returning id into v_id;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, pagamento_joca_id, obs)
  values (p_data, 'SAIDA', 'PAGAMENTO_JOCA', p_valor, 'Pagamento ao Joca', v_id, v_obs);

  return v_id;
end;
$$;

-- Correção (J8, R45): o pagamento fica no histórico; o estorno devolve o
-- valor ao Caixa com a data de hoje e o valor volta ao Disponível.
create or replace function public.estornar_pagamento_joca(p_pagamento_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pag  public.pagamentos_joca;
  v_mov  public.movimentos_caixa;
begin
  perform public.exigir_admin();
  perform pg_advisory_xact_lock(hashtext('arts_com_voce.pagamento_joca'));
  if p_motivo is null or length(trim(p_motivo)) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  if length(trim(p_motivo)) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  select * into v_pag from public.pagamentos_joca where id = p_pagamento_id for update;
  if not found then raise exception 'Pagamento não encontrado.'; end if;
  if v_pag.situacao = 'ESTORNADO' then raise exception 'Este pagamento já foi estornado.'; end if;

  select * into v_mov from public.movimentos_caixa where pagamento_joca_id = p_pagamento_id;
  update public.pagamentos_joca
     set situacao = 'ESTORNADO', estornado_em = now(), motivo_estorno = trim(p_motivo)
   where id = p_pagamento_id;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, movimento_estornado_id, obs)
  values (public.hoje(), 'ENTRADA', 'ESTORNO', v_mov.valor, 'Estorno: Pagamento ao Joca', v_mov.id, trim(p_motivo));
end;
$$;

-- Conferência no fim da gravação: pagamento ATIVO tem exatamente uma saída
-- no Caixa, com a mesma data e o mesmo valor, não estornada; ESTORNADO tem
-- a saída estornada.
create or replace function public.conferir_pagamento_joca(p_pagamento_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pag   public.pagamentos_joca;
  v_qtd   integer;
  v_ok    integer;
  v_est   integer;
begin
  select * into v_pag from public.pagamentos_joca where id = p_pagamento_id;
  if not found then return; end if;
  select count(*),
         count(*) filter (where m.data = v_pag.data and m.valor = v_pag.valor and m.tipo = 'SAIDA'),
         count(*) filter (where exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id))
    into v_qtd, v_ok, v_est
    from public.movimentos_caixa m where m.pagamento_joca_id = p_pagamento_id;
  if v_qtd <> 1 or v_ok <> 1 then
    raise exception 'Conferência do pagamento ao Joca: a saída no Caixa não bate. Nada foi gravado.';
  end if;
  if (v_pag.situacao = 'ATIVO') <> (v_est = 0) then
    raise exception 'Conferência do pagamento ao Joca: o estorno no Caixa não bate. Nada foi gravado.';
  end if;
end;
$$;

create or replace function public.tg_pagamentos_joca_conferir()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.conferir_pagamento_joca(new.id);
  return null;
end;
$$;

create constraint trigger trg_pagamentos_joca_conferir
  after insert or update on public.pagamentos_joca
  deferrable initially deferred
  for each row execute function public.tg_pagamentos_joca_conferir();

create or replace function public.tg_movimentos_caixa_conferir_joca()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pag uuid := new.pagamento_joca_id;
begin
  if new.origem = 'ESTORNO' then
    select pagamento_joca_id into v_pag from public.movimentos_caixa where id = new.movimento_estornado_id;
  end if;
  if v_pag is not null then
    perform public.conferir_pagamento_joca(v_pag);
  end if;
  return null;
end;
$$;

create constraint trigger trg_movimentos_caixa_conferir_joca
  after insert on public.movimentos_caixa
  deferrable initially deferred
  for each row execute function public.tg_movimentos_caixa_conferir_joca();

-- Caixa: o pagamento ao Joca só é estornado na área do Joca.
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
  if v_mov.origem = 'PAGAMENTO_JOCA' then
    raise exception 'Este movimento é um pagamento ao Joca. Para corrigir, estorne o pagamento na área Joca ⭐.';
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
-- 6. Funções do Joca (R92, R26): só os valores dele
--    Ele não lê nenhuma tabela. Nada de percentual, base, total do pedido,
--    cliente, Caixa ou outros dados da loja.
-- ---------------------------------------------------------------------
create or replace function public.joca_resumo()
returns table (a_receber numeric, disponivel numeric, ja_recebi numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (public.is_joca() or public.is_admin()) then
    raise exception 'Acesso permitido só ao Joca e à Admin.';
  end if;
  return query select t.a_receber, t.disponivel, t.pago from public.joca_totais() t;
end;
$$;

create or replace function public.joca_extrato()
returns table (tipo text, data date, descricao text, canal text, valor numeric, situacao text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (public.is_joca() or public.is_admin()) then
    raise exception 'Acesso permitido só ao Joca e à Admin.';
  end if;
  return query
  select x.tipo, x.data, x.descricao, x.canal, x.valor, x.situacao from (
    select 'PEDIDO'::text as tipo, p.data, p.numero,
           (select string_agg(case when i.quantidade > 1 then i.quantidade || '× ' else '' end || i.descricao, ', ' order by i.ordem)
              from public.itens_venda i where i.venda_id = p.venda_id) as descricao,
           (select cn.nome from public.vendas v join public.canais cn on cn.id = v.canal_id where v.id = p.venda_id) as canal,
           p.comissao as valor,
           case p.situacao when 'A_RECEBER' then 'A receber' when 'DISPONIVEL' then 'Disponível'
                           when 'PAGA' then 'Recebido' when 'PAGA_EM_PARTE' then 'Recebido em parte'
                           when 'CANCELADO' then 'Cancelado' end as situacao,
           1 as ordem
      from public.vw_joca_pedidos p
     where p.situacao <> 'SEM_COMISSAO' and (p.comissao <> 0 or p.registros > 0)
    union all
    select 'PAGAMENTO', g.data, null, 'Pagamento que recebi', null, g.valor, 'Recebido', 2
      from public.pagamentos_joca g where g.situacao = 'ATIVO'
  ) x
  order by x.data desc, x.ordem, x.numero desc nulls last;
end;
$$;


-- ---------------------------------------------------------------------
-- 7. Pedidos já registrados (J3): uma única vez; rodar de novo não cria nada
-- ---------------------------------------------------------------------
create or replace function public.migrar_comissoes_joca()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id  uuid;
  v_antes integer;
begin
  select count(*) into v_antes from public.comissoes_joca;
  for v_id in select id from public.vendas order by numero loop
    perform public.sincronizar_comissao_joca(v_id, 'Comissão do pedido (lançamento inicial)');
  end loop;
  return jsonb_build_object(
    'pedidos', (select count(*) from public.vendas),
    'registros_criados', (select count(*) from public.comissoes_joca) - v_antes,
    'a_receber', (select a_receber from public.joca_totais()),
    'disponivel', (select disponivel from public.joca_totais()));
end;
$$;

do $$
declare
  v_resultado jsonb;
begin
  v_resultado := public.migrar_comissoes_joca();
  raise notice 'Comissões do Joca: %', v_resultado;
end;
$$;


-- ---------------------------------------------------------------------
-- 8. Segurança
--    Leitura das tabelas e consultas: só a Admin (RLS). O Joca usa só
--    joca_resumo() e joca_extrato(). Gravação: só pelas funções acima.
-- ---------------------------------------------------------------------
alter table public.comissao_joca_pedido enable row level security;
alter table public.comissoes_joca       enable row level security;
alter table public.pagamentos_joca      enable row level security;

revoke all on public.comissao_joca_pedido, public.comissoes_joca, public.pagamentos_joca from public, anon, authenticated;
revoke all on public.vw_joca_pedidos from public, anon, authenticated;
grant select on public.comissao_joca_pedido, public.comissoes_joca, public.pagamentos_joca to authenticated;
grant select on public.vw_joca_pedidos to authenticated;

create policy comissao_joca_pedido_select_admin on public.comissao_joca_pedido
  for select to authenticated using (public.is_admin());
create policy comissoes_joca_select_admin on public.comissoes_joca
  for select to authenticated using (public.is_admin());
create policy pagamentos_joca_select_admin on public.pagamentos_joca
  for select to authenticated using (public.is_admin());

-- Funções internas: ninguém chama pela API.
revoke all on function public.percentual_joca_em(date) from public, anon, authenticated;
revoke all on function public.sincronizar_comissao_joca(uuid, text) from public, anon, authenticated;
revoke all on function public.tg_vendas_comissao_joca() from public, anon, authenticated;
revoke all on function public.joca_totais() from public, anon, authenticated;
revoke all on function public.conferir_pagamento_joca(uuid) from public, anon, authenticated;
revoke all on function public.tg_pagamentos_joca_conferir() from public, anon, authenticated;
revoke all on function public.tg_movimentos_caixa_conferir_joca() from public, anon, authenticated;
revoke all on function public.tg_comissoes_joca_protege() from public, anon, authenticated;
revoke all on function public.tg_pagamentos_joca_protege() from public, anon, authenticated;
revoke all on function public.migrar_comissoes_joca() from public, anon, authenticated;

-- Admin (a função confere): pagamentos e o estorno do Caixa.
revoke all on function public.registrar_pagamento_joca(date, numeric, text, text, uuid) from public, anon;
revoke all on function public.estornar_pagamento_joca(uuid, text) from public, anon;
revoke all on function public.estornar_movimento(uuid, text) from public, anon;
grant execute on function public.registrar_pagamento_joca(date, numeric, text, text, uuid) to authenticated;
grant execute on function public.estornar_pagamento_joca(uuid, text) to authenticated;
grant execute on function public.estornar_movimento(uuid, text) to authenticated;

-- Joca e Admin (a função confere): só os valores do Joca.
revoke all on function public.joca_resumo() from public, anon;
revoke all on function public.joca_extrato() from public, anon;
grant execute on function public.joca_resumo() to authenticated;
grant execute on function public.joca_extrato() to authenticated;

commit;
