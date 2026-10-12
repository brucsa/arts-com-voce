-- =====================================================================
-- Arts com Você · Pedidos Diretos Essencial · Lote P1-b
-- Pagamentos e devoluções. Especificação v1.4 (R83, R84, fórmulas e
-- validações), decisões C1, C2, F1, F2, F3.
--
-- Pré-requisito: P1-a instalado (sql/07_pedidos_diretos_essencial.sql).
--
-- O que este arquivo cria (acréscimos):
--   · o tipo situacao_lancamento_pedido (ATIVO, ESTORNADO);
--   · as tabelas recebimentos_venda e devolucoes_venda;
--   · as funções registrar_recebimento, registrar_devolucao,
--     estornar_recebimento e estornar_devolucao (só a Admin);
--   · gatilhos de proteção e de conferência dos lançamentos.
--
-- O que este arquivo atualiza (só o conteúdo, nenhuma tabela é recriada):
--   · recalcular_pedido: recebido e devolvido = soma dos lançamentos ATIVOS;
--   · conferir_pedido: o resumo do pedido precisa ser igual a essas somas;
--   · salvar_pedido: a data do pedido não pode ficar depois do primeiro
--     lançamento ativo (as demais regras do P1-a ficam idênticas).
--
-- O que este arquivo NÃO faz:
--   · não movimenta o Caixa ("Ainda fora do Caixa"), o estoque nem gera
--     comissão do Joca (R76, R83);
--   · não altera nenhum outro módulo nem os dados existentes.
--
-- Fórmulas (definitivas, v1.4):
--   R = soma dos recebimentos ativos (só confirmados); D = soma das
--   devoluções ativas; L = R − D (sempre ≥ 0; fora do cancelado, ≤ T — C1);
--   S = 0 se cancelado ou T = 0; senão máx(0, T − R) — a devolução nunca
--   gera nova cobrança (F1); T = 0 → Sem cobrança (F2).
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Antes: sql/manutencao/pedidos_diretos_pagamentos_preinstalacao.sql e o retrato.
-- Conferência: sql/pedidos_diretos_verificacao.sql e
--              sql/pedidos_diretos_pagamentos_verificacao.sql.
-- Tudo ou nada: se qualquer passo falhar, nada é criado nem alterado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
declare
  v_nomes text;
begin
  -- P1-a instalado, na versão esperada
  if to_regclass('public.vendas') is null or to_regclass('public.itens_venda') is null
     or to_regclass('public.clientes') is null or to_regclass('public.historico_status_pedido') is null
     or to_regprocedure('public.recalcular_pedido(uuid)') is null
     or to_regprocedure('public.conferir_pedido(uuid)') is null
     or to_regprocedure('public.salvar_pedido(uuid, date, uuid, text, date, text, numeric, numeric, text, jsonb)') is null
     or to_regtype('public.status_pedido_direto') is null then
    raise exception 'O P1-a dos Pedidos Diretos não está instalado. Instale sql/07_pedidos_diretos_essencial.sql antes. Nada foi alterado.';
  end if;
  if not exists (select 1 from pg_proc where oid = to_regprocedure('public.conferir_pedido(uuid)')
                    and prosrc like '%ainda não existem nesta etapa%') then
    raise exception 'A função conferir_pedido não está na versão do P1-a (o P1-b já foi instalado?). Nada foi alterado.';
  end if;

  -- Nomes livres
  select string_agg(n, ', ') into v_nomes
    from unnest(array['recebimentos_venda', 'devolucoes_venda']) n
   where to_regclass('public.' || n) is not null;
  if v_nomes is not null then raise exception 'Já existe no banco: %. Nada foi alterado.', v_nomes; end if;
  if to_regtype('public.situacao_lancamento_pedido') is not null then
    raise exception 'Já existe o tipo situacao_lancamento_pedido. Nada foi alterado.';
  end if;
  select string_agg(distinct p.proname, ', ') into v_nomes
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('registrar_recebimento', 'registrar_devolucao', 'estornar_recebimento',
                       'estornar_devolucao', 'tg_lancamentos_pedido_protege', 'tg_lancamentos_pedido_conferir');
  if v_nomes is not null then raise exception 'Já existe a função: %. Nada foi alterado.', v_nomes; end if;

  -- Nenhum resumo financeiro preenchido sem lançamento (estado do P1-a)
  if exists (select 1 from public.vendas where valor_recebido <> 0 or valor_devolvido <> 0) then
    raise exception 'Há pedidos com recebido ou devolvido diferente de zero sem lançamentos. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Tipo e tabelas
-- ---------------------------------------------------------------------
create type public.situacao_lancamento_pedido as enum ('ATIVO', 'ESTORNADO');

-- Recebimentos (R83): só entram com a confirmação explícita da Admin.
-- Só os ATIVOS contam no recebido (R).
create table public.recebimentos_venda (
  id               uuid primary key default gen_random_uuid(),
  venda_id         uuid not null references public.vendas (id) on delete restrict,
  data             date not null,
  valor            numeric(12,2) not null check (valor > 0),
  forma_pagamento  public.forma_pagamento not null,
  observacao       text check (observacao is null or length(observacao) <= 500),
  confirmado_em    timestamptz not null default clock_timestamp(),
  confirmado_por   uuid not null default auth.uid(),
  situacao         public.situacao_lancamento_pedido not null default 'ATIVO',
  estornado_em     timestamptz,
  motivo_estorno   text check (motivo_estorno is null or length(motivo_estorno) <= 500),
  created_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),
  updated_at       timestamptz not null default now(),

  constraint recebimentos_venda_estorno_completo check (
    (situacao = 'ESTORNADO')
    = (estornado_em is not null and coalesce(length(trim(motivo_estorno)), 0) > 0))
);

create index idx_recebimentos_venda_venda on public.recebimentos_venda (venda_id, data);

comment on table public.recebimentos_venda is
  'Recebimentos dos Pedidos Diretos (R83). Nunca apagados; erro de lançamento = estorno com motivo. Ainda fora do Caixa.';

-- Devoluções (R83, N3, F1, F3): parcial ou integral; nunca geram cobrança.
create table public.devolucoes_venda (
  id               uuid primary key default gen_random_uuid(),
  venda_id         uuid not null references public.vendas (id) on delete restrict,
  data             date not null,
  valor            numeric(12,2) not null check (valor > 0),
  forma_pagamento  public.forma_pagamento not null,
  motivo           text not null check (length(trim(motivo)) between 1 and 500),
  situacao         public.situacao_lancamento_pedido not null default 'ATIVO',
  estornado_em     timestamptz,
  motivo_estorno   text check (motivo_estorno is null or length(motivo_estorno) <= 500),
  created_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),
  updated_at       timestamptz not null default now(),

  constraint devolucoes_venda_estorno_completo check (
    (situacao = 'ESTORNADO')
    = (estornado_em is not null and coalesce(length(trim(motivo_estorno)), 0) > 0))
);

create index idx_devolucoes_venda_venda on public.devolucoes_venda (venda_id, data);

comment on table public.devolucoes_venda is
  'Devoluções de dinheiro dos Pedidos Diretos (R83). Nunca apagadas; devolução errada = estorno com motivo (F3). Ainda fora do Caixa.';


-- ---------------------------------------------------------------------
-- 2. updated_at e auditoria
-- ---------------------------------------------------------------------
create trigger trg_recebimentos_venda_updated_at before update on public.recebimentos_venda
  for each row execute function public.tg_updated_at();
create trigger trg_devolucoes_venda_updated_at before update on public.devolucoes_venda
  for each row execute function public.tg_updated_at();

create trigger trg_recebimentos_venda_auditoria after insert or update or delete on public.recebimentos_venda
  for each row execute function public.tg_auditoria();
create trigger trg_devolucoes_venda_auditoria after insert or update or delete on public.devolucoes_venda
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 3. Proteção dos lançamentos (vale até para as funções)
--    Nada é apagado. A única mudança aceita é ATIVO → ESTORNADO, com data
--    e motivo; valor, data, forma e pedido nunca mudam. Estornado é final.
-- ---------------------------------------------------------------------
create or replace function public.tg_lancamentos_pedido_protege()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_livres text[] := array['situacao', 'estornado_em', 'motivo_estorno', 'updated_at'];
begin
  if tg_op = 'DELETE' then
    raise exception 'Recebimentos e devoluções não podem ser excluídos. Para corrigir um lançamento errado, use o estorno.';
  end if;
  if old.situacao = 'ESTORNADO' then
    raise exception 'Este lançamento já foi estornado e não pode ser alterado.';
  end if;
  if (to_jsonb(new) - v_livres) is distinct from (to_jsonb(old) - v_livres) then
    raise exception 'Valor, data, forma e pedido de um lançamento não podem ser alterados. Para corrigir, estorne e registre de novo.';
  end if;
  return new;
end;
$$;

create trigger trg_recebimentos_venda_protege
  before update or delete on public.recebimentos_venda
  for each row execute function public.tg_lancamentos_pedido_protege();
create trigger trg_devolucoes_venda_protege
  before update or delete on public.devolucoes_venda
  for each row execute function public.tg_lancamentos_pedido_protege();

-- Conferência no fim da gravação: o resumo do pedido tem de bater com os
-- lançamentos ativos. "security definer" pelo mesmo motivo do P1-a.
create or replace function public.tg_lancamentos_pedido_conferir()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.conferir_pedido(new.venda_id);
  return null;
end;
$$;

create constraint trigger trg_recebimentos_venda_conferir
  after insert or update on public.recebimentos_venda
  deferrable initially deferred
  for each row execute function public.tg_lancamentos_pedido_conferir();
create constraint trigger trg_devolucoes_venda_conferir
  after insert or update on public.devolucoes_venda
  deferrable initially deferred
  for each row execute function public.tg_lancamentos_pedido_conferir();


-- ---------------------------------------------------------------------
-- 4. Funções do P1-a atualizadas (mesma assinatura; só o conteúdo muda)
-- ---------------------------------------------------------------------

-- Recalcula o resumo a partir das fontes: subtotal = soma dos itens;
-- total pela fórmula; recebido = soma dos recebimentos ATIVOS;
-- devolvido = soma das devoluções ATIVAS. Saldo e status financeiro são
-- calculados pelo próprio banco a partir destes campos.
create or replace function public.recalcular_pedido(p_venda_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_soma  numeric(12,2);
  v_rec   numeric(12,2);
  v_dev   numeric(12,2);
begin
  select coalesce(sum(valor_item), 0) into v_soma from public.itens_venda where venda_id = p_venda_id;
  select coalesce(sum(valor), 0) into v_rec
    from public.recebimentos_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  select coalesce(sum(valor), 0) into v_dev
    from public.devolucoes_venda where venda_id = p_venda_id and situacao = 'ATIVO';

  update public.vendas
     set subtotal = v_soma,
         total = v_soma - desconto + frete,
         valor_recebido = v_rec,
         valor_devolvido = v_dev
   where id = p_venda_id
     and (subtotal, total, valor_recebido, valor_devolvido)
         is distinct from (v_soma, v_soma - desconto + frete, v_rec, v_dev);
end;
$$;

-- Conferência do pedido: pelo menos 1 item (P6), subtotal = soma dos itens
-- e recebido/devolvido = soma dos lançamentos ativos. Se algo não bater,
-- a gravação inteira é recusada.
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
    raise exception 'Conferência do pedido #%: o subtotal não bate com a soma dos itens. Nada foi gravado.',
      lpad(v_venda.numero::text, greatest(4, length(v_venda.numero::text)), '0');
  end if;

  select coalesce(sum(valor), 0) into v_rec
    from public.recebimentos_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  select coalesce(sum(valor), 0) into v_dev
    from public.devolucoes_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  if v_venda.valor_recebido <> v_rec or v_venda.valor_devolvido <> v_dev then
    raise exception 'Conferência do pedido #%: o recebido ou o devolvido não bate com os lançamentos ativos. Nada foi gravado.',
      lpad(v_venda.numero::text, greatest(4, length(v_venda.numero::text)), '0');
  end if;
end;
$$;

-- salvar_pedido: idêntico ao do P1-a, mais a regra da data do pedido em
-- relação ao primeiro lançamento ativo.
create or replace function public.salvar_pedido(
  p_id               uuid,
  p_data             date,
  p_cliente_id       uuid,
  p_origem           text,
  p_data_prometida   date,
  p_forma_pagamento  text,
  p_desconto         numeric,
  p_frete            numeric,
  p_observacao       text,
  p_itens            jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_uuid      constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  c_limite    constant numeric := 9999999.99;
  v_atual     public.vendas;
  v_cliente   public.clientes;
  v_id        uuid;
  v_numero    integer;
  v_origem    public.origem_pedido_direto;
  v_forma     public.forma_pagamento;
  v_desconto  numeric := coalesce(p_desconto, 0);
  v_frete     numeric := coalesce(p_frete, 0);
  v_obs       text := nullif(trim(coalesce(p_observacao, '')), '');
  v_subtotal  numeric := 0;
  v_total     numeric;
  v_liquido   numeric;

  v_item      jsonb;
  v_n         integer;
  v_txt       text;
  v_iid       uuid;
  v_ids       uuid[] := '{}';
  v_old       public.itens_venda;
  v_tem_old   boolean;
  v_prod_id   uuid;
  v_prod      public.produtos;
  v_mat_id    uuid;
  v_mat       public.materiais;
  v_cor_txt   text;
  v_desc      text;
  v_cor       text;
  v_qtd       integer;
  v_preco     numeric;
  v_troca_prod boolean;
  v_troca_cor  boolean;
  v_norm      jsonb := '[]'::jsonb;
  v_x         jsonb;
  v_linhas    integer;
  v_mudou     boolean := false;   -- P4: editado_em só quando algo mudou
  v_primeiro  date;               -- P1-b: data do primeiro lançamento ativo
begin
  perform public.exigir_admin();

  -- Pedido existente: trava e confere se ainda pode ser editado (R82)
  if p_id is not null then
    select * into v_atual from public.vendas where id = p_id for update;
    if not found then raise exception 'Pedido não encontrado.'; end if;
    if v_atual.status_pedido in ('ENTREGUE', 'CANCELADO') then
      raise exception 'Pedido entregue ou cancelado não pode ser editado. Para corrigir um pedido entregue, volte o status para Pronto antes.';
    end if;
  end if;

  -- Data real, nunca futura (R81)
  if p_data is null then raise exception 'Informe a data do pedido.'; end if;
  if p_data > public.hoje() then raise exception 'A data do pedido não pode ser futura.'; end if;
  -- P1-b: a data do pedido não pode ficar depois do primeiro recebimento ou
  -- devolução ativos (cada lançamento tem data entre a do pedido e hoje).
  if p_id is not null then
    select min(x.data) into v_primeiro
      from (select data from public.recebimentos_venda where venda_id = p_id and situacao = 'ATIVO'
            union all
            select data from public.devolucoes_venda where venda_id = p_id and situacao = 'ATIVO') x;
    if v_primeiro is not null and p_data > v_primeiro then
      raise exception 'A data do pedido não pode ficar depois do primeiro pagamento ou devolução registrado (%).',
        to_char(v_primeiro, 'DD/MM/YYYY');
    end if;
  end if;
  if p_data_prometida is not null and p_data_prometida < p_data then
    raise exception 'A data prometida não pode ser anterior à data do pedido.';
  end if;

  -- Cliente obrigatório (P1); ativo quando é escolhido (R77)
  if p_cliente_id is null then raise exception 'Escolha o cliente do pedido.'; end if;
  select * into v_cliente from public.clientes where id = p_cliente_id;
  if not found then raise exception 'Cliente não encontrado.'; end if;
  if not v_cliente.ativo and (p_id is null or v_atual.cliente_id is distinct from p_cliente_id) then
    raise exception 'O cliente "%" está inativo e não pode ser escolhido em um pedido.', v_cliente.nome;
  end if;

  -- Origem obrigatória (P2, R78)
  if p_origem is null or p_origem not in ('WHATSAPP', 'INSTAGRAM', 'PESSOALMENTE', 'OUTRO') then
    raise exception 'Escolha a origem do pedido: WhatsApp, Instagram, Pessoalmente ou Outro.';
  end if;
  v_origem := p_origem::public.origem_pedido_direto;

  -- Forma de pagamento combinada: opcional, da lista existente (P3)
  if nullif(trim(coalesce(p_forma_pagamento, '')), '') is not null then
    if p_forma_pagamento not in (select unnest(enum_range(null::public.forma_pagamento))::text) then
      raise exception 'Forma de pagamento inválida.';
    end if;
    v_forma := p_forma_pagamento::public.forma_pagamento;
  end if;

  if length(coalesce(v_obs, '')) > 2000 then raise exception 'A observação pode ter até 2.000 caracteres.'; end if;

  -- Desconto e frete (R80)
  if v_desconto < 0 then raise exception 'O desconto não pode ser negativo.'; end if;
  if v_frete < 0 then raise exception 'O frete não pode ser negativo.'; end if;
  if v_desconto <> round(v_desconto, 2) or v_frete <> round(v_frete, 2) then
    raise exception 'Desconto e frete aceitam até 2 casas decimais.';
  end if;
  if v_desconto > c_limite or v_frete > c_limite then raise exception 'Valor acima do limite do sistema (R$ 9.999.999,99).'; end if;

  -- Itens: pelo menos 1 (P6)
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'O pedido precisa ter pelo menos um item (do catálogo ou personalizado).';
  end if;
  if jsonb_array_length(p_itens) > 200 then raise exception 'Um pedido pode ter até 200 itens.'; end if;

  for v_item, v_n in select e, o::integer from jsonb_array_elements(p_itens) with ordinality t(e, o) loop
    if jsonb_typeof(v_item) <> 'object' then raise exception 'Item %: formato inválido.', v_n; end if;

    -- Item que já existe (só ao editar)
    v_iid := null; v_tem_old := false;
    v_txt := nullif(trim(coalesce(v_item ->> 'id', '')), '');
    if v_txt is not null then
      if v_txt !~ c_uuid or p_id is null then raise exception 'Item %: identificador inválido.', v_n; end if;
      v_iid := v_txt::uuid;
      if v_iid = any (v_ids) then raise exception 'Item %: aparece duas vezes na lista.', v_n; end if;
      select * into v_old from public.itens_venda where id = v_iid and venda_id = p_id;
      if not found then raise exception 'Item %: não pertence a este pedido.', v_n; end if;
      v_tem_old := true;
      v_ids := v_ids || v_iid;
    end if;

    -- Quantidade inteira ≥ 1
    v_txt := v_item ->> 'quantidade';
    if v_txt is null or v_txt !~ '^[0-9]{1,6}$' then
      raise exception 'Item %: a quantidade precisa ser um número inteiro, no mínimo 1.', v_n;
    end if;
    v_qtd := v_txt::integer;
    if v_qtd < 1 then
      raise exception 'Item %: a quantidade precisa ser um número inteiro, no mínimo 1.', v_n;
    end if;

    -- Preço unitário ≥ 0, até 2 casas (R$ 0,00 = brinde)
    v_txt := v_item ->> 'preco_unitario';
    if v_txt is null or v_txt !~ '^[0-9]{1,10}(\.[0-9]{1,2})?$' then
      raise exception 'Item %: informe o preço unitário (R$ 0,00 ou mais, até 2 casas decimais).', v_n;
    end if;
    v_preco := v_txt::numeric;
    if v_preco > c_limite or v_qtd * v_preco > c_limite then
      raise exception 'Item %: valor acima do limite do sistema (R$ 9.999.999,99).', v_n;
    end if;

    -- Produto e cor
    v_txt := nullif(trim(coalesce(v_item ->> 'produto_id', '')), '');
    if v_txt is not null and v_txt !~ c_uuid then raise exception 'Item %: produto inválido.', v_n; end if;
    v_prod_id := v_txt::uuid;

    v_txt := nullif(trim(coalesce(v_item ->> 'material_id', '')), '');
    if v_txt is not null and v_txt !~ c_uuid then raise exception 'Item %: cor inválida.', v_n; end if;
    v_mat_id := v_txt::uuid;

    v_cor_txt := nullif(trim(coalesce(v_item ->> 'cor_texto', '')), '');

    v_troca_prod := not v_tem_old or v_old.produto_id is distinct from v_prod_id;
    v_troca_cor  := v_troca_prod or v_old.material_id is distinct from v_mat_id;

    if v_prod_id is not null then
      -- Item do catálogo (R79): nome copiado; só produto ativo ao entrar
      if v_cor_txt is not null then
        raise exception 'Item %: no item do catálogo, escolha uma das cores do produto.', v_n;
      end if;
      if v_troca_prod then
        select * into v_prod from public.produtos where id = v_prod_id;
        if not found then raise exception 'Item %: produto não encontrado.', v_n; end if;
        if not v_prod.ativo then
          raise exception 'Item %: o produto "%" está inativo e não pode entrar no pedido.', v_n, v_prod.nome;
        end if;
        v_desc := v_prod.nome;
      else
        v_desc := v_old.descricao;
      end if;

      if v_mat_id is null then
        v_cor := null;
      elsif v_troca_cor then
        if not exists (select 1 from public.produto_cores where produto_id = v_prod_id and material_id = v_mat_id) then
          raise exception 'Item %: a cor escolhida não é uma das cores do produto.', v_n;
        end if;
        select * into v_mat from public.materiais where id = v_mat_id;
        v_cor := left(v_mat.tipo || ' · ' || v_mat.variacao, 80);
      else
        v_cor := v_old.cor_descricao;
      end if;
    else
      -- Item personalizado (R79): descrição livre; cor = filamento ativo ou texto livre
      v_desc := trim(coalesce(v_item ->> 'descricao', ''));
      if length(v_desc) = 0 then raise exception 'Item %: descreva o item personalizado.', v_n; end if;
      if length(v_desc) > 150 then raise exception 'Item %: a descrição pode ter até 150 caracteres.', v_n; end if;

      if v_mat_id is not null and v_cor_txt is not null then
        raise exception 'Item %: escolha um filamento ou escreva a cor, não os dois.', v_n;
      end if;
      if v_mat_id is not null then
        if v_troca_cor then
          select * into v_mat from public.materiais where id = v_mat_id;
          if not found then raise exception 'Item %: o filamento escolhido não existe mais em Materiais.', v_n; end if;
          if v_mat.categoria <> 'FILAMENTO' then
            raise exception 'Item %: "%" não é um filamento.', v_n, v_mat.tipo;
          end if;
          if not v_mat.ativo then
            raise exception 'Item %: o filamento % · % está inativo e não pode ser escolhido.', v_n, v_mat.tipo, v_mat.variacao;
          end if;
          v_cor := left(v_mat.tipo || ' · ' || v_mat.variacao, 80);
        else
          v_cor := v_old.cor_descricao;
        end if;
      elsif v_cor_txt is not null then
        if length(v_cor_txt) > 80 then raise exception 'Item %: a cor pode ter até 80 caracteres.', v_n; end if;
        v_cor := v_cor_txt;
      else
        v_cor := null;
      end if;
    end if;

    v_subtotal := v_subtotal + round(v_qtd * v_preco, 2);
    v_norm := v_norm || jsonb_build_array(jsonb_build_object(
      'id', v_iid, 'ordem', v_n, 'produto_id', v_prod_id, 'descricao', v_desc,
      'preco_unitario', v_preco, 'quantidade', v_qtd, 'material_id', v_mat_id, 'cor_descricao', v_cor));
  end loop;

  -- Valores (R80)
  if v_subtotal > c_limite then raise exception 'O subtotal passa do limite do sistema (R$ 9.999.999,99).'; end if;
  if v_desconto > v_subtotal then
    raise exception 'O desconto não pode passar do subtotal dos itens.';
  end if;
  v_total := v_subtotal - v_desconto + v_frete;
  if v_total > c_limite then raise exception 'O total passa do limite do sistema (R$ 9.999.999,99).'; end if;

  -- Novo total ≥ dinheiro líquido já recebido (C1). No P1-a o líquido é 0.
  v_liquido := coalesce(v_atual.valor_recebido, 0) - coalesce(v_atual.valor_devolvido, 0);
  if v_total < v_liquido then
    raise exception 'O novo total (R$ %) ficaria menor que o valor líquido já recebido (R$ %). Registre antes a devolução da diferença.',
      replace(to_char(v_total, 'FM9999999990.00'), '.', ','), replace(to_char(v_liquido, 'FM9999999990.00'), '.', ',');
  end if;

  -- Gravação do cabeçalho
  if p_id is null then
    v_numero := public.proximo_numero_pedido();
    insert into public.vendas (numero, data, cliente_id, canal_id, origem, data_prometida, forma_pagamento,
                               observacao, subtotal, desconto, frete, total)
    values (v_numero, p_data, p_cliente_id, public.canal_boca_a_boca(), v_origem, p_data_prometida, v_forma,
            v_obs, v_subtotal, v_desconto, v_frete, v_total)
    returning id into v_id;

    insert into public.historico_status_pedido (venda_id, status_anterior, status_novo)
    values (v_id, null, 'AGUARDANDO');
  else
    v_id := p_id;
    v_numero := v_atual.numero;
    update public.vendas
       set data = p_data, cliente_id = p_cliente_id, origem = v_origem, data_prometida = p_data_prometida,
           forma_pagamento = v_forma, observacao = v_obs,
           subtotal = v_subtotal, desconto = v_desconto, frete = v_frete, total = v_total
     where id = v_id
       and (data, cliente_id, origem, data_prometida, forma_pagamento, observacao, subtotal, desconto, frete, total)
           is distinct from (p_data, p_cliente_id, v_origem, p_data_prometida, v_forma, v_obs,
                             v_subtotal::numeric(12,2), v_desconto::numeric(12,2), v_frete::numeric(12,2), v_total::numeric(12,2));
    get diagnostics v_linhas = row_count;
    v_mudou := v_linhas > 0;
  end if;

  -- Itens: remove os que saíram, atualiza os que ficaram, inclui os novos
  delete from public.itens_venda where venda_id = v_id and id <> all (v_ids);
  get diagnostics v_linhas = row_count;
  v_mudou := v_mudou or v_linhas > 0;

  for v_x in select e from jsonb_array_elements(v_norm) e loop
    if v_x ->> 'id' is not null then
      update public.itens_venda
         set ordem = (v_x ->> 'ordem')::integer,
             produto_id = (v_x ->> 'produto_id')::uuid,
             descricao = v_x ->> 'descricao',
             preco_unitario = (v_x ->> 'preco_unitario')::numeric,
             quantidade = (v_x ->> 'quantidade')::integer,
             material_id = (v_x ->> 'material_id')::uuid,
             cor_descricao = v_x ->> 'cor_descricao'
       where id = (v_x ->> 'id')::uuid
         and (ordem, produto_id, descricao, preco_unitario, quantidade, material_id, cor_descricao)
             is distinct from ((v_x ->> 'ordem')::integer, (v_x ->> 'produto_id')::uuid, v_x ->> 'descricao',
                               (v_x ->> 'preco_unitario')::numeric, (v_x ->> 'quantidade')::integer,
                               (v_x ->> 'material_id')::uuid, v_x ->> 'cor_descricao');
      get diagnostics v_linhas = row_count;
      v_mudou := v_mudou or v_linhas > 0;
    else
      insert into public.itens_venda (venda_id, ordem, produto_id, descricao, preco_unitario, quantidade,
                                      material_id, cor_descricao)
      values (v_id, (v_x ->> 'ordem')::integer, (v_x ->> 'produto_id')::uuid, v_x ->> 'descricao',
              (v_x ->> 'preco_unitario')::numeric, (v_x ->> 'quantidade')::integer,
              (v_x ->> 'material_id')::uuid, v_x ->> 'cor_descricao');
      v_mudou := true;
    end if;
  end loop;

  -- P4: a data da última edição só muda quando os dados ou os itens mudaram
  -- (pedido novo fica sem editado_em; a tela mostra a data de criação).
  if p_id is not null and v_mudou then
    update public.vendas set editado_em = now() where id = v_id;
  end if;

  perform public.recalcular_pedido(v_id);
  perform public.conferir_pedido(v_id);

  return jsonb_build_object('id', v_id, 'numero', v_numero);
end;
$$;


-- ---------------------------------------------------------------------
-- 5. Funções financeiras (só a Admin; cada uma trava o pedido; tudo ou nada)
-- ---------------------------------------------------------------------

-- Registra um recebimento confirmado (R83).
-- Regras: pedido não cancelado; T > 0; 0 < valor ≤ S; data entre a do
-- pedido e hoje; confirmação explícita. Pedido Entregue aceita, sem reabrir.
create or replace function public.registrar_recebimento(
  p_venda_id         uuid,
  p_data             date,
  p_valor            numeric,
  p_forma_pagamento  text,
  p_observacao       text,
  p_confirmado       boolean
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
begin
  perform public.exigir_admin();

  if p_confirmado is not true then
    raise exception 'Confirme que o dinheiro foi recebido. Só pagamentos confirmados são registrados.';
  end if;

  select * into v_venda from public.vendas where id = p_venda_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
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

  insert into public.recebimentos_venda (venda_id, data, valor, forma_pagamento, observacao, confirmado_por)
  values (p_venda_id, p_data, p_valor, p_forma_pagamento::public.forma_pagamento, v_obs, auth.uid())
  returning id into v_id;

  perform public.recalcular_pedido(p_venda_id);
  perform public.conferir_pedido(p_venda_id);
  return v_id;
end;
$$;

-- Registra uma devolução de dinheiro ao cliente (R83), parcial ou integral.
-- Regras: 0 < valor ≤ L; data entre a do pedido e hoje; motivo. Permitida
-- também em pedido cancelado (R84). Nunca gera nova cobrança (F1).
create or replace function public.registrar_devolucao(
  p_venda_id         uuid,
  p_data             date,
  p_valor            numeric,
  p_forma_pagamento  text,
  p_motivo           text
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
begin
  perform public.exigir_admin();

  select * into v_venda from public.vendas where id = p_venda_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
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

  insert into public.devolucoes_venda (venda_id, data, valor, forma_pagamento, motivo)
  values (p_venda_id, p_data, p_valor, p_forma_pagamento::public.forma_pagamento, v_motivo)
  returning id into v_id;

  perform public.recalcular_pedido(p_venda_id);
  perform public.conferir_pedido(p_venda_id);
  return v_id;
end;
$$;

-- Estorna um recebimento lançado por engano (R83). O lançamento continua
-- visível e deixa de contar. Regra: R − valor ≥ D. Permitido também em
-- pedido cancelado (R84).
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
  v_motivo    text := trim(coalesce(p_motivo, ''));
begin
  perform public.exigir_admin();

  if length(v_motivo) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  -- Trava primeiro o pedido, depois o lançamento (mesma ordem em todas as funções)
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

  update public.recebimentos_venda
     set situacao = 'ESTORNADO', estornado_em = now(), motivo_estorno = v_motivo
   where id = p_recebimento_id;

  perform public.recalcular_pedido(v_venda_id);
  perform public.conferir_pedido(v_venda_id);
end;
$$;

-- Estorna uma devolução registrada por engano (F3, R83). O lançamento
-- continua visível e deixa de contar. Regra: em pedido não cancelado, o
-- líquido resultante não pode passar do total (C1).
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

  update public.devolucoes_venda
     set situacao = 'ESTORNADO', estornado_em = now(), motivo_estorno = v_motivo
   where id = p_devolucao_id;

  perform public.recalcular_pedido(v_venda_id);
  perform public.conferir_pedido(v_venda_id);
end;
$$;


-- ---------------------------------------------------------------------
-- 6. Segurança: só a Admin lê; gravação só pelas funções acima
-- ---------------------------------------------------------------------
alter table public.recebimentos_venda enable row level security;
alter table public.devolucoes_venda   enable row level security;

revoke all on public.recebimentos_venda, public.devolucoes_venda from public, anon, authenticated;
grant select on public.recebimentos_venda, public.devolucoes_venda to authenticated;

create policy recebimentos_venda_select_admin on public.recebimentos_venda
  for select to authenticated using (public.is_admin());
create policy devolucoes_venda_select_admin on public.devolucoes_venda
  for select to authenticated using (public.is_admin());

revoke all on function public.tg_lancamentos_pedido_protege() from public, anon, authenticated;
revoke all on function public.tg_lancamentos_pedido_conferir() from public, anon, authenticated;
-- As 3 funções do P1-a mantêm as permissões (create or replace não muda);
-- reaplicadas aqui por segurança.
revoke all on function public.recalcular_pedido(uuid) from public, anon, authenticated;
revoke all on function public.conferir_pedido(uuid) from public, anon, authenticated;
revoke all on function public.salvar_pedido(uuid, date, uuid, text, date, text, numeric, numeric, text, jsonb) from public, anon;
grant execute on function public.salvar_pedido(uuid, date, uuid, text, date, text, numeric, numeric, text, jsonb) to authenticated;

revoke all on function public.registrar_recebimento(uuid, date, numeric, text, text, boolean) from public, anon;
revoke all on function public.registrar_devolucao(uuid, date, numeric, text, text) from public, anon;
revoke all on function public.estornar_recebimento(uuid, text) from public, anon;
revoke all on function public.estornar_devolucao(uuid, text) from public, anon;
grant execute on function public.registrar_recebimento(uuid, date, numeric, text, text, boolean) to authenticated;
grant execute on function public.registrar_devolucao(uuid, date, numeric, text, text) to authenticated;
grant execute on function public.estornar_recebimento(uuid, text) to authenticated;
grant execute on function public.estornar_devolucao(uuid, text) to authenticated;

commit;
