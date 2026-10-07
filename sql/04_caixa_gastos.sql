-- =====================================================================
-- Arts com Você — Sistema de Gestão
-- Etapa 2 · Caixa e gastos
--
-- O que este script cria:
--   1. Gastos (lancamentos): o que foi comprado, quando e como
--   2. Pagamentos dos gastos: quando o dinheiro saiu de verdade
--   3. Movimentos do caixa: entradas e saídas efetivas, com estornos
--   4. Funções para registrar, editar, pagar, cancelar e estornar
--   5. Consultas prontas: gastos com situação, extrato e saldos
--   6. Segurança: só a Admin; ninguém grava nas tabelas direto pela API
--   7. Travas R36 (natureza da categoria) e R37 (categoria usada)
--
-- Regras aplicadas: R9, R22, R23, R36, R37, R42 a R48.
-- Como rodar: Supabase → SQL Editor → colar tudo → Run. Uma única vez.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Data de hoje no fuso de São Paulo
-- ---------------------------------------------------------------------
create or replace function public.hoje()
returns date
language sql
stable
as $$
  select (now() at time zone 'America/Sao_Paulo')::date
$$;

grant execute on function public.hoje() to authenticated;


-- ---------------------------------------------------------------------
-- 1. Tipos
-- ---------------------------------------------------------------------
create type public.forma_pagamento as enum
  ('PIX', 'DINHEIRO', 'CARTAO_CREDITO', 'CARTAO_DEBITO', 'BOLETO', 'TRANSFERENCIA', 'OUTROS');

create type public.status_registro as enum ('ATIVO', 'CANCELADO');

create type public.tipo_movimento as enum ('ENTRADA', 'SAIDA');

-- Novas origens (recebimento de venda, pagamento do Joca, reembolso)
-- entram nas próximas etapas com: alter type public.origem_caixa add value '...';
create type public.origem_caixa as enum ('PAGAMENTO_GASTO', 'APORTE', 'RETIRADA', 'ESTORNO');


-- ---------------------------------------------------------------------
-- 2. Tabelas
-- ---------------------------------------------------------------------
create table public.lancamentos (
  id                   uuid primary key default gen_random_uuid(),
  data                 date not null,
  descricao            text not null check (length(trim(descricao)) > 0),
  categoria_id         uuid not null references public.categorias_lanc (id) on delete restrict,
  valor                numeric(12,2) not null check (valor > 0),
  forma_pagamento      public.forma_pagamento not null,
  fornecedor           text,
  obs                  text,
  status               public.status_registro not null default 'ATIVO',
  cancelado_em         date,
  motivo_cancelamento  text,
  created_at           timestamptz not null default now(),
  created_by           uuid default auth.uid(),
  updated_at           timestamptz not null default now(),
  constraint lancamentos_cancelamento_completo check (
    (status = 'ATIVO' and cancelado_em is null)
    or (status = 'CANCELADO' and cancelado_em is not null and length(trim(coalesce(motivo_cancelamento, ''))) > 0)
  )
);

create index idx_lancamentos_data on public.lancamentos (data desc);
create index idx_lancamentos_categoria on public.lancamentos (categoria_id);

create table public.pagamentos_lancamento (
  id               uuid primary key default gen_random_uuid(),
  lancamento_id    uuid not null references public.lancamentos (id) on delete restrict,
  data             date not null,
  valor            numeric(12,2) not null check (valor > 0),
  status           public.status_registro not null default 'ATIVO',
  estornado_em     date,
  motivo_estorno   text,
  created_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),
  updated_at       timestamptz not null default now()
);

create index idx_pagamentos_lancamento on public.pagamentos_lancamento (lancamento_id);

create table public.movimentos_caixa (
  id                       uuid primary key default gen_random_uuid(),
  seq                      bigint generated always as identity unique,  -- ordem exata de registro
  data                     date not null,
  tipo                     public.tipo_movimento not null,
  origem                   public.origem_caixa not null,
  valor                    numeric(12,2) not null check (valor > 0),
  descricao                text not null,
  pagamento_id             uuid references public.pagamentos_lancamento (id) on delete restrict,
  movimento_estornado_id   uuid unique references public.movimentos_caixa (id) on delete restrict,
  obs                      text,
  created_at               timestamptz not null default now(),
  created_by               uuid default auth.uid(),
  constraint movimentos_estorno_coerente check (
    (origem = 'ESTORNO') = (movimento_estornado_id is not null)
  )
);

create index idx_movimentos_data on public.movimentos_caixa (data, seq);

comment on table public.lancamentos is 'Gastos: data da compra (resultado), forma de pagamento e valor. Não movem o caixa sozinhos (R42).';
comment on table public.pagamentos_lancamento is 'Pagamentos efetivos dos gastos. Cada um gera uma saída no caixa (R42 a R44).';
comment on table public.movimentos_caixa is 'Dinheiro que entrou ou saiu de verdade. Nada é alterado nem apagado; correções são estornos (R45).';


-- ---------------------------------------------------------------------
-- 3. updated_at e auditoria
-- ---------------------------------------------------------------------
create trigger trg_lancamentos_updated_at before update on public.lancamentos
  for each row execute function public.tg_updated_at();
create trigger trg_pagamentos_lancamento_updated_at before update on public.pagamentos_lancamento
  for each row execute function public.tg_updated_at();

create trigger trg_lancamentos_auditoria after insert or update or delete on public.lancamentos
  for each row execute function public.tg_auditoria();
create trigger trg_pagamentos_lancamento_auditoria after insert or update or delete on public.pagamentos_lancamento
  for each row execute function public.tg_auditoria();
create trigger trg_movimentos_caixa_auditoria after insert or update or delete on public.movimentos_caixa
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 4. Travas das categorias de gastos
-- ---------------------------------------------------------------------
-- R36: a natureza trava depois do primeiro lançamento.
create or replace function public.tg_categorias_lanc_trava_natureza()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.natureza is distinct from old.natureza
     and exists (select 1 from public.lancamentos where categoria_id = old.id) then
    raise exception 'A natureza desta categoria não pode mudar porque ela já tem lançamentos.';
  end if;
  return new;
end;
$$;

create trigger trg_categorias_lanc_trava_natureza
  before update on public.categorias_lanc
  for each row execute function public.tg_categorias_lanc_trava_natureza();

-- R37: excluir categoria já usada é recusado pela chave estrangeira
-- (on delete restrict em lancamentos.categoria_id).


-- ---------------------------------------------------------------------
-- 5. Funções internas
-- ---------------------------------------------------------------------
create or replace function public.exigir_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Você não tem permissão para fazer isso.';
  end if;
end;
$$;

-- Valida os dados de um gasto (inclusão e edição).
create or replace function public.validar_gasto(
  p_data date, p_descricao text, p_categoria_id uuid, p_valor numeric, p_editando uuid default null
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cat public.categorias_lanc;
begin
  if p_data is null then raise exception 'Informe a data do gasto.'; end if;
  if p_data > public.hoje() then raise exception 'A data do gasto não pode ser no futuro.'; end if;
  if p_descricao is null or length(trim(p_descricao)) = 0 then raise exception 'Informe a descrição do gasto.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'O valor do gasto precisa ser maior que zero.'; end if;

  select * into v_cat from public.categorias_lanc where id = p_categoria_id;
  if not found then raise exception 'Escolha uma categoria.'; end if;

  -- R46: compras de estoque entram pela tela de compras (Etapa 3).
  if v_cat.natureza = 'ESTOQUE' then
    raise exception 'Compras de estoque são registradas na tela de compras, a partir da Etapa 3.';
  end if;

  -- Categoria inativa não pode ser escolhida em gasto novo (pode continuar num gasto antigo).
  if not v_cat.ativo and (p_editando is null or not exists (
      select 1 from public.lancamentos where id = p_editando and categoria_id = p_categoria_id)) then
    raise exception 'Esta categoria está inativa.';
  end if;
end;
$$;

-- Total já pago (pagamentos ativos) de um gasto.
create or replace function public.total_pago(p_lancamento_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(valor), 0)
    from public.pagamentos_lancamento
   where lancamento_id = p_lancamento_id and status = 'ATIVO'
$$;

-- Registra um pagamento e a saída correspondente no caixa.
create or replace function public.inserir_pagamento(p_lancamento_id uuid, p_data date, p_valor numeric)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lanc public.lancamentos;
  v_pago numeric;
  v_id uuid;
begin
  select * into v_lanc from public.lancamentos where id = p_lancamento_id for update;
  if not found then raise exception 'Gasto não encontrado.'; end if;
  if v_lanc.status <> 'ATIVO' then raise exception 'Este gasto está cancelado e não pode receber pagamento.'; end if;
  if p_data is null then raise exception 'Informe a data do pagamento.'; end if;
  if p_data > public.hoje() then raise exception 'A data do pagamento não pode ser no futuro.'; end if;
  if p_data < v_lanc.data then raise exception 'O pagamento não pode ser anterior à data do gasto (%).', to_char(v_lanc.data, 'DD/MM/YYYY'); end if;
  if p_valor is null or p_valor <= 0 then raise exception 'O valor do pagamento precisa ser maior que zero.'; end if;

  v_pago := public.total_pago(p_lancamento_id);
  if v_pago + p_valor > v_lanc.valor then
    raise exception 'Pagamento acima do valor do gasto "%": faltam pagar R$ %.',
      v_lanc.descricao, replace(to_char(v_lanc.valor - v_pago, 'FM999999990.00'), '.', ',');
  end if;

  insert into public.pagamentos_lancamento (lancamento_id, data, valor)
  values (p_lancamento_id, p_data, p_valor)
  returning id into v_id;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, pagamento_id)
  values (p_data, 'SAIDA', 'PAGAMENTO_GASTO', p_valor, v_lanc.descricao, v_id);

  return v_id;
end;
$$;

-- Estorna um pagamento: o original fica, o caixa recebe a entrada de estorno.
create or replace function public.estornar_pagamento_interno(p_pagamento_id uuid, p_motivo text, p_data date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pag public.pagamentos_lancamento;
  v_mov public.movimentos_caixa;
begin
  select * into v_pag from public.pagamentos_lancamento where id = p_pagamento_id for update;
  if not found then raise exception 'Pagamento não encontrado.'; end if;
  if v_pag.status <> 'ATIVO' then raise exception 'Este pagamento já foi estornado.'; end if;

  select * into v_mov from public.movimentos_caixa where pagamento_id = p_pagamento_id and origem = 'PAGAMENTO_GASTO';

  update public.pagamentos_lancamento
     set status = 'CANCELADO', estornado_em = p_data, motivo_estorno = p_motivo
   where id = p_pagamento_id;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, movimento_estornado_id, obs)
  values (p_data, 'ENTRADA', 'ESTORNO', v_mov.valor, 'Estorno: ' || v_mov.descricao, v_mov.id, p_motivo);
end;
$$;


-- ---------------------------------------------------------------------
-- 6. Funções usadas pelo sistema (só Admin)
-- ---------------------------------------------------------------------

-- Novo gasto. Se p_pago, grava gasto e pagamento juntos (R43).
create or replace function public.registrar_gasto(
  p_data date, p_descricao text, p_categoria_id uuid, p_valor numeric,
  p_forma_pagamento public.forma_pagamento, p_fornecedor text, p_obs text,
  p_pago boolean, p_data_pagamento date
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform public.exigir_admin();
  perform public.validar_gasto(p_data, p_descricao, p_categoria_id, p_valor);

  insert into public.lancamentos (data, descricao, categoria_id, valor, forma_pagamento, fornecedor, obs)
  values (p_data, trim(p_descricao), p_categoria_id, p_valor, p_forma_pagamento,
          nullif(trim(p_fornecedor), ''), nullif(trim(p_obs), ''))
  returning id into v_id;

  if p_pago then
    perform public.inserir_pagamento(v_id, coalesce(p_data_pagamento, p_data), p_valor);
  end if;

  return v_id;
end;
$$;

-- Editar gasto. Se ele foi pago na hora (um único pagamento do valor
-- inteiro), o pagamento acompanha a correção de valor e de data.
create or replace function public.editar_gasto(
  p_id uuid, p_data date, p_descricao text, p_categoria_id uuid, p_valor numeric,
  p_forma_pagamento public.forma_pagamento, p_fornecedor text, p_obs text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lanc public.lancamentos;
  v_pago numeric;
  v_qtd int;
  v_pag public.pagamentos_lancamento;
  v_acompanha boolean;
begin
  perform public.exigir_admin();
  select * into v_lanc from public.lancamentos where id = p_id for update;
  if not found then raise exception 'Gasto não encontrado.'; end if;
  if v_lanc.status <> 'ATIVO' then raise exception 'Gasto cancelado não pode ser editado.'; end if;
  perform public.validar_gasto(p_data, p_descricao, p_categoria_id, p_valor, p_id);

  select count(*), coalesce(sum(valor), 0) into v_qtd, v_pago
    from public.pagamentos_lancamento where lancamento_id = p_id and status = 'ATIVO';

  -- Pago na hora: um único pagamento, do valor inteiro, na data do gasto.
  if v_qtd = 1 then
    select * into v_pag from public.pagamentos_lancamento where lancamento_id = p_id and status = 'ATIVO';
  end if;
  v_acompanha := v_qtd = 1 and v_pag.valor = v_lanc.valor and v_pag.data = v_lanc.data;

  if not v_acompanha and p_valor < v_pago then
    raise exception 'O valor não pode ficar abaixo do que já foi pago (R$ %).', replace(to_char(v_pago, 'FM999999990.00'), '.', ',');
  end if;
  if not v_acompanha and v_pago > 0 and p_data > (
       select min(data) from public.pagamentos_lancamento where lancamento_id = p_id and status = 'ATIVO') then
    raise exception 'A data do gasto não pode ficar depois de um pagamento já registrado.';
  end if;

  update public.lancamentos
     set data = p_data, descricao = trim(p_descricao), categoria_id = p_categoria_id, valor = p_valor,
         forma_pagamento = p_forma_pagamento,
         fornecedor = nullif(trim(p_fornecedor), ''), obs = nullif(trim(p_obs), '')
   where id = p_id;

  if v_acompanha then
    update public.pagamentos_lancamento set valor = p_valor, data = p_data where id = v_pag.id;
    update public.movimentos_caixa
       set valor = p_valor, data = p_data, descricao = trim(p_descricao)
     where pagamento_id = v_pag.id and origem = 'PAGAMENTO_GASTO';
  else
    update public.movimentos_caixa m
       set descricao = trim(p_descricao)
      from public.pagamentos_lancamento p
     where m.pagamento_id = p.id and p.lancamento_id = p_id and m.origem = 'PAGAMENTO_GASTO';
  end if;
end;
$$;

-- Cancelar gasto (R45): pagamentos feitos voltam por estorno; o restante deixa de ser cobrado.
create or replace function public.cancelar_gasto(p_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lanc public.lancamentos;
  v_pag record;
begin
  perform public.exigir_admin();
  if p_motivo is null or length(trim(p_motivo)) = 0 then raise exception 'Informe o motivo do cancelamento.'; end if;
  select * into v_lanc from public.lancamentos where id = p_id for update;
  if not found then raise exception 'Gasto não encontrado.'; end if;
  if v_lanc.status <> 'ATIVO' then raise exception 'Este gasto já está cancelado.'; end if;

  for v_pag in select id from public.pagamentos_lancamento where lancamento_id = p_id and status = 'ATIVO' loop
    perform public.estornar_pagamento_interno(v_pag.id, 'Gasto cancelado: ' || trim(p_motivo), public.hoje());
  end loop;

  update public.lancamentos
     set status = 'CANCELADO', cancelado_em = public.hoje(), motivo_cancelamento = trim(p_motivo)
   where id = p_id;
end;
$$;

-- Registrar pagamento de um ou vários gastos na mesma data (fatura, boleto, parcela).
-- p_itens: [{"lancamento_id": "...", "valor": 123.45}, ...]
create or replace function public.registrar_pagamentos(p_data date, p_itens jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item jsonb;
begin
  perform public.exigir_admin();
  if p_itens is null or jsonb_array_length(p_itens) = 0 then raise exception 'Escolha pelo menos um gasto para pagar.'; end if;
  for v_item in select * from jsonb_array_elements(p_itens) loop
    perform public.inserir_pagamento((v_item ->> 'lancamento_id')::uuid, p_data, (v_item ->> 'valor')::numeric);
  end loop;
end;
$$;

create or replace function public.estornar_pagamento(p_pagamento_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.exigir_admin();
  if p_motivo is null or length(trim(p_motivo)) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  perform public.estornar_pagamento_interno(p_pagamento_id, trim(p_motivo), public.hoje());
end;
$$;

-- Aporte ou retirada (R23).
create or replace function public.registrar_movimento(p_origem public.origem_caixa, p_data date, p_valor numeric, p_obs text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  perform public.exigir_admin();
  if p_origem not in ('APORTE', 'RETIRADA') then raise exception 'Use esta opção só para aporte ou retirada.'; end if;
  if p_data is null then raise exception 'Informe a data.'; end if;
  if p_data > public.hoje() then raise exception 'A data não pode ser no futuro.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'O valor precisa ser maior que zero.'; end if;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, obs)
  values (p_data,
          case when p_origem = 'APORTE' then 'ENTRADA'::public.tipo_movimento else 'SAIDA'::public.tipo_movimento end,
          p_origem, p_valor,
          case when p_origem = 'APORTE' then 'Aporte' else 'Retirada' end,
          nullif(trim(p_obs), ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- Estornar aporte ou retirada (R45).
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
-- 7. Consultas prontas (respeitam o RLS de quem consulta)
-- ---------------------------------------------------------------------
create view public.vw_gastos with (security_invoker = true) as
select l.id, l.data, l.descricao, l.categoria_id, c.nome as categoria, c.natureza,
       l.valor, l.forma_pagamento, l.fornecedor, l.obs, l.status, l.cancelado_em, l.motivo_cancelamento,
       coalesce(p.pago, 0) as valor_pago,
       case when l.status = 'CANCELADO' then 0 else l.valor - coalesce(p.pago, 0) end as valor_a_pagar,
       case
         when l.status = 'CANCELADO' then 'CANCELADO'
         when coalesce(p.pago, 0) = 0 then 'A_PAGAR'
         when coalesce(p.pago, 0) < l.valor then 'PAGO_EM_PARTE'
         else 'PAGO'
       end as situacao,
       l.created_at
  from public.lancamentos l
  join public.categorias_lanc c on c.id = l.categoria_id
  left join (
    select lancamento_id, sum(valor) as pago
      from public.pagamentos_lancamento where status = 'ATIVO'
     group by lancamento_id
  ) p on p.lancamento_id = l.id;

create view public.vw_extrato_caixa with (security_invoker = true) as
select m.id, m.seq, m.data, m.tipo, m.origem, m.valor, m.descricao, m.obs, m.pagamento_id,
       m.movimento_estornado_id, m.created_at,
       case when m.tipo = 'ENTRADA' then m.valor else -m.valor end as valor_assinado,
       sum(case when m.tipo = 'ENTRADA' then m.valor else -m.valor end)
         over (order by m.data, m.seq rows between unbounded preceding and current row) as saldo_apos,
       exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id) as estornado
  from public.movimentos_caixa m;

create view public.vw_caixa_resumo with (security_invoker = true) as
select
  coalesce((select sum(case when tipo = 'ENTRADA' then valor else -valor end) from public.movimentos_caixa), 0) as saldo_atual,
  coalesce((select sum(valor_a_pagar) from public.vw_gastos where status = 'ATIVO'), 0) as a_pagar,
  coalesce((select sum(case when tipo = 'ENTRADA' then valor else -valor end) from public.movimentos_caixa), 0)
    - coalesce((select sum(valor_a_pagar) from public.vw_gastos where status = 'ATIVO'), 0) as saldo_livre;


-- ---------------------------------------------------------------------
-- 8. Segurança
--    Leitura: só a Admin (RLS). Escrita: só pelas funções acima, que
--    conferem se quem chama é a Admin. Ninguém grava direto nas tabelas.
-- ---------------------------------------------------------------------
alter table public.lancamentos           enable row level security;
alter table public.pagamentos_lancamento enable row level security;
alter table public.movimentos_caixa      enable row level security;

revoke all on public.lancamentos, public.pagamentos_lancamento, public.movimentos_caixa from anon, authenticated;
revoke all on public.vw_gastos, public.vw_extrato_caixa, public.vw_caixa_resumo from anon, authenticated;

grant select on public.lancamentos, public.pagamentos_lancamento, public.movimentos_caixa to authenticated;
grant select on public.vw_gastos, public.vw_extrato_caixa, public.vw_caixa_resumo to authenticated;

create policy lancamentos_select_admin on public.lancamentos
  for select to authenticated using (public.is_admin());
create policy pagamentos_lancamento_select_admin on public.pagamentos_lancamento
  for select to authenticated using (public.is_admin());
create policy movimentos_caixa_select_admin on public.movimentos_caixa
  for select to authenticated using (public.is_admin());

-- Funções internas: ninguém chama pela API.
revoke all on function public.exigir_admin() from public, anon, authenticated;
revoke all on function public.validar_gasto(date, text, uuid, numeric, uuid) from public, anon, authenticated;
revoke all on function public.total_pago(uuid) from public, anon, authenticated;
revoke all on function public.inserir_pagamento(uuid, date, numeric) from public, anon, authenticated;
revoke all on function public.estornar_pagamento_interno(uuid, text, date) from public, anon, authenticated;
revoke all on function public.tg_categorias_lanc_trava_natureza() from public, anon, authenticated;

-- Funções do sistema: só usuários logados (e cada uma exige a Admin).
revoke all on function public.registrar_gasto(date, text, uuid, numeric, public.forma_pagamento, text, text, boolean, date) from public, anon;
revoke all on function public.editar_gasto(uuid, date, text, uuid, numeric, public.forma_pagamento, text, text) from public, anon;
revoke all on function public.cancelar_gasto(uuid, text) from public, anon;
revoke all on function public.registrar_pagamentos(date, jsonb) from public, anon;
revoke all on function public.estornar_pagamento(uuid, text) from public, anon;
revoke all on function public.registrar_movimento(public.origem_caixa, date, numeric, text) from public, anon;
revoke all on function public.estornar_movimento(uuid, text) from public, anon;
revoke all on function public.hoje() from public, anon;

grant execute on function public.registrar_gasto(date, text, uuid, numeric, public.forma_pagamento, text, text, boolean, date) to authenticated;
grant execute on function public.editar_gasto(uuid, date, text, uuid, numeric, public.forma_pagamento, text, text) to authenticated;
grant execute on function public.cancelar_gasto(uuid, text) to authenticated;
grant execute on function public.registrar_pagamentos(date, jsonb) to authenticated;
grant execute on function public.estornar_pagamento(uuid, text) to authenticated;
grant execute on function public.registrar_movimento(public.origem_caixa, date, numeric, text) to authenticated;
grant execute on function public.estornar_movimento(uuid, text) to authenticated;
grant execute on function public.hoje() to authenticated;


-- =====================================================================
-- Fim da Etapa 2.
-- Próximo passo: rodar sql/02_verificacao.sql (todas as linhas OK).
-- =====================================================================
