-- =====================================================================
-- Arts com Você · Vendas da Shopee (Etapa 6) · Lote C2 · Passo 2 de 2
-- Especificação v1.11, R106, R107, R109 e R110 (decisões V1–V11 e C2-1 a C2-4).
--
-- Antes: rode sql/18_repasse_shopee_origem.sql sozinho (origem REPASSE_SHOPEE).
--
-- O que este arquivo faz:
--   · repasses_shopee: o repasse de cada venda da Shopee, confirmado pela
--     Admin; entra no Caixa como Repasse Shopee e só se corrige por estorno
--     (R106). Um repasse ativo por venda;
--   · repasse diferente do estimado: a taxa da Shopee da venda passa a ser
--     faturamento − repasse (C2-1); o estorno devolve a taxa de antes;
--   · com o repasse confirmado, a venda conta como recebida: o status
--     financeiro vira Recebido e a comissão do Joca fica Disponível (R107);
--   · vw_repasses_shopee_pendentes: a lista "Repasses para confirmar" — vendas
--     cujo pedido aparece como Concluído na última importação (R106);
--   · vw_avisos_shopee: vendas cujo pedido aparece como cancelado ou devolvido
--     na Shopee (R109); a Admin cancela, edita ou dispensa o aviso com motivo
--     (C2-2, C2-3), registrado em avisos_shopee_dispensados;
--   · depois do repasse confirmado, só o status da venda muda: editar
--     valores, itens e cores e cancelar exigem estornar o repasse antes (R110).
--
-- Funções trocadas (mesma assinatura, regras antigas iguais; só o acréscimo
-- da venda da Shopee): recalcular_pedido, conferir_pedido,
-- tg_movimentos_caixa_conferir_pedido, tg_vendas_protege, salvar_venda_shopee
-- e definir_cores_partes.
--
-- O que NÃO muda:
--   · nenhum registro existente (vendas, itens, Caixa, Joca, Shopee);
--   · os pedidos diretos, os recebimentos, as devoluções, a produção e a
--     importação da planilha (R70).
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/repasses_shopee_verificacao.sql e as gerais.
-- Tudo ou nada: se qualquer passo falhar, nada é alterado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_attribute where attrelid = 'public.vendas'::regclass
                   and attname = 'shopee_pedido_ref' and not attisdropped) then
    raise exception 'As vendas da Shopee (sql/17, Lote C1) precisam estar instaladas. Nada foi alterado.';
  end if;
  if not exists (select 1 from pg_enum where enumtypid = 'public.origem_caixa'::regtype and enumlabel = 'REPASSE_SHOPEE') then
    raise exception 'Rode antes o sql/18_repasse_shopee_origem.sql, sozinho. Nada foi alterado.';
  end if;
  if to_regclass('public.repasses_shopee') is not null or to_regclass('public.avisos_shopee_dispensados') is not null then
    raise exception 'Os repasses da Shopee já estão instalados. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
               and proname in ('confirmar_repasse_shopee', 'estornar_repasse_shopee', 'dispensar_aviso_shopee',
                               'exigir_venda_sem_repasse', 'tg_repasses_shopee_protege', 'tg_avisos_shopee_protege')) then
    raise exception 'Já existe função dos repasses da Shopee. Nada foi alterado.';
  end if;
  if exists (select 1 from public.movimentos_caixa where origem = 'REPASSE_SHOPEE') then
    raise exception 'Já há movimento de repasse da Shopee no Caixa. Nada foi alterado.';
  end if;
  if exists (select 1 from public.vendas v where v.shopee_pedido_ref is not null
               and (v.valor_recebido <> 0 or v.valor_devolvido <> 0)) then
    raise exception 'Há venda da Shopee com valor recebido ou devolvido. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------

-- Repasse da Shopee (R106): só entra com a confirmação da Admin. Nunca
-- apagado; erro = estorno com motivo. faturamento e taxa guardam a conta
-- do dia: taxa = faturamento − repasse (C2-1); taxa_anterior é a taxa da
-- venda antes da confirmação, devolvida no estorno.
create table public.repasses_shopee (
  id              uuid primary key default gen_random_uuid(),
  venda_id        uuid not null references public.vendas (id) on delete restrict,
  data            date not null,
  valor           numeric(12,2) not null check (valor > 0),
  faturamento     numeric(12,2) not null check (faturamento > 0),
  taxa            numeric(12,2) not null check (taxa >= 0),
  taxa_anterior   numeric(12,2) not null check (taxa_anterior >= 0),
  observacao      text check (observacao is null or length(observacao) <= 500),
  confirmado_em   timestamptz not null default clock_timestamp(),
  confirmado_por  uuid not null default auth.uid(),
  situacao        public.situacao_lancamento_pedido not null default 'ATIVO',
  estornado_em    timestamptz,
  motivo_estorno  text check (motivo_estorno is null or length(motivo_estorno) <= 500),
  chave_envio     uuid unique,
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),
  updated_at      timestamptz not null default now(),

  constraint repasses_shopee_taxa_calculada check (taxa = faturamento - valor),
  constraint repasses_shopee_estorno_completo check (
    (situacao = 'ESTORNADO')
    = (estornado_em is not null and coalesce(length(trim(motivo_estorno)), 0) > 0))
);

create unique index uq_repasses_shopee_ativo on public.repasses_shopee (venda_id) where situacao = 'ATIVO';
create index idx_repasses_shopee_venda on public.repasses_shopee (venda_id, data);

comment on table public.repasses_shopee is
  'Repasses das vendas da Shopee (R106), confirmados pela Admin. Entram no Caixa como Repasse Shopee. Nunca apagados; correção = estorno.';

-- Aviso de cancelado ou devolvido dispensado pela Admin (C2-3): vale para
-- aquele status da Shopee; se o status mudar de novo, o aviso volta.
create table public.avisos_shopee_dispensados (
  id                uuid primary key default gen_random_uuid(),
  venda_id          uuid not null references public.vendas (id) on delete restrict,
  status_shopee     text,
  status_devolucao  text,
  motivo            text not null check (length(trim(motivo)) between 1 and 500),
  created_at        timestamptz not null default now(),
  created_by        uuid default auth.uid()
);

create index idx_avisos_shopee_venda on public.avisos_shopee_dispensados (venda_id);

comment on table public.avisos_shopee_dispensados is
  'Avisos de venda cancelada ou devolvida na Shopee (R109) que a Admin decidiu manter como estão, com motivo. Nunca apagados.';

-- Caixa: o movimento do repasse aponta para ele (no máximo um).
alter table public.movimentos_caixa
  add column repasse_shopee_id uuid unique references public.repasses_shopee (id) on delete restrict,
  add constraint movimentos_caixa_origem_repasse_shopee check ((origem = 'REPASSE_SHOPEE') = (repasse_shopee_id is not null));

comment on column public.movimentos_caixa.repasse_shopee_id is
  'Entrada do repasse de uma venda da Shopee (R106). O estorno aponta para este movimento.';


-- ---------------------------------------------------------------------
-- 2. updated_at, auditoria e proteção
-- ---------------------------------------------------------------------
create trigger trg_repasses_shopee_updated_at before update on public.repasses_shopee
  for each row execute function public.tg_updated_at();
create trigger trg_repasses_shopee_auditoria after insert or update or delete on public.repasses_shopee
  for each row execute function public.tg_auditoria();
create trigger trg_avisos_shopee_dispensados_auditoria after insert or update or delete on public.avisos_shopee_dispensados
  for each row execute function public.tg_auditoria();

-- Repasse: nada é apagado; a única mudança aceita é ATIVO → ESTORNADO.
create or replace function public.tg_repasses_shopee_protege()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_livres text[] := array['situacao', 'estornado_em', 'motivo_estorno', 'updated_at'];
begin
  if tg_op = 'DELETE' then
    raise exception 'Repasses da Shopee não podem ser excluídos. Para corrigir, estorne o repasse.';
  end if;
  if old.situacao = 'ESTORNADO' then
    raise exception 'Este repasse já foi estornado e não pode ser alterado.';
  end if;
  if new.situacao <> 'ESTORNADO' or (to_jsonb(new) - v_livres) is distinct from (to_jsonb(old) - v_livres) then
    raise exception 'Valor, data e venda de um repasse não podem ser alterados. Para corrigir, estorne e confirme de novo.';
  end if;
  return new;
end;
$$;

create trigger trg_repasses_shopee_protege before update or delete on public.repasses_shopee
  for each row execute function public.tg_repasses_shopee_protege();

-- Aviso dispensado: fica registrado como foi.
create or replace function public.tg_avisos_shopee_protege()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'O registro de um aviso dispensado não pode ser alterado nem excluído.';
end;
$$;

create trigger trg_avisos_shopee_dispensados_protege before update or delete on public.avisos_shopee_dispensados
  for each row execute function public.tg_avisos_shopee_protege();


-- ---------------------------------------------------------------------
-- 3. Funções trocadas: a venda da Shopee no resumo e na conferência
-- ---------------------------------------------------------------------

-- Recalcula o resumo do pedido. Na venda da Shopee (R106, R107), o recebido
-- é o faturamento quitado pelo repasse ativo (repasse + taxa retida pela
-- Shopee); sem repasse ativo, zero. O dinheiro que entrou de fato está no
-- Caixa e em repasses_shopee.
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
  v_venda public.vendas;
begin
  select coalesce(sum(valor_item), 0) into v_soma from public.itens_venda where venda_id = p_venda_id;
  select coalesce(sum(valor), 0) into v_rec
    from public.recebimentos_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  select coalesce(sum(valor), 0) into v_dev
    from public.devolucoes_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  -- Venda da Shopee: recebido = faturamento quitado pelo repasse ativo.
  select * into v_venda from public.vendas where id = p_venda_id;
  if v_venda.shopee_pedido_ref is not null then
    v_rec := case when exists (select 1 from public.repasses_shopee
                                where venda_id = p_venda_id and situacao = 'ATIVO')
                  then v_soma - v_venda.desconto + v_venda.frete else 0 end;
  end if;

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

-- Conferência do pedido. Acréscimo da venda da Shopee: o recebido segue o
-- repasse ativo; o repasse ativo bate com a taxa e o faturamento da venda
-- e tem a sua entrada no Caixa; o estornado tem o movimento estornado.
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
  -- Venda da Shopee: recebido = faturamento quitado pelo repasse ativo.
  if v_venda.shopee_pedido_ref is not null then
    v_rec := case when exists (select 1 from public.repasses_shopee
                                where venda_id = p_venda_id and situacao = 'ATIVO')
                  then v_venda.subtotal - v_venda.desconto + v_venda.frete else 0 end;
  end if;
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

  -- Repasses da Shopee (R106): só na venda da Shopee; o ativo bate com
  -- a taxa e o faturamento da venda.
  if exists (select 1 from public.repasses_shopee r where r.venda_id = p_venda_id
              and (v_venda.shopee_pedido_ref is null
                   or (r.situacao = 'ATIVO' and (r.taxa <> v_venda.taxa_plataforma
                        or r.faturamento <> v_venda.subtotal - v_venda.desconto)))) then
    raise exception 'Conferência do pedido %: o repasse da Shopee não bate com a venda. Nada foi gravado.',
      public.numero_pedido_texto(v_venda.numero);
  end if;

  -- Caixa: repasses da Shopee
  if exists (
    select 1 from public.repasses_shopee r
     where r.venda_id = p_venda_id
       and ((r.situacao = 'ATIVO' and not exists (
              select 1 from public.movimentos_caixa m
               where m.repasse_shopee_id = r.id and m.origem = 'REPASSE_SHOPEE' and m.tipo = 'ENTRADA'
                 and m.valor = r.valor and m.data = r.data
                 and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id)))
         or (r.situacao = 'ESTORNADO' and exists (
              select 1 from public.movimentos_caixa m
               where m.repasse_shopee_id = r.id
                 and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id))))
  ) then
    raise exception 'Conferência do pedido %: um repasse da Shopee não bate com o Caixa. Nada foi gravado.',
      public.numero_pedido_texto(v_venda.numero);
  end if;
end;
$$;

-- Conferência também quando o Caixa recebe um movimento de repasse.
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
  elsif v_mov.repasse_shopee_id is not null then
    select venda_id into v_venda from public.repasses_shopee where id = v_mov.repasse_shopee_id;
  end if;
  if v_venda is not null then
    perform public.conferir_pedido(v_venda);
  end if;
  return null;
end;
$$;

-- Pedidos: acréscimo da venda da Shopee com repasse confirmado (R110):
-- só o status muda, e cancelar exige estornar o repasse antes (C2-2).
-- A taxa só muda pela confirmação ou pelo estorno do repasse (C2-1).
create or replace function public.tg_vendas_protege()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  -- Em Entregue e Cancelado só podem mudar: o status (pelas funções), o
  -- resumo financeiro (P1-b) e o updated_at técnico. Saldo e status
  -- financeiro são calculados pelo banco.
  v_livres text[] := array['status_pedido', 'valor_recebido', 'valor_devolvido',
                           'saldo', 'status_financeiro', 'updated_at'];
begin
  if tg_op = 'DELETE' then
    raise exception 'Pedidos não podem ser excluídos. Para desistir de um pedido, cancele-o com motivo.';
  end if;

  if new.id is distinct from old.id or new.numero is distinct from old.numero then
    raise exception 'O número do pedido não pode ser alterado.';
  end if;

  if old.status_pedido = 'CANCELADO' and new.status_pedido <> 'CANCELADO' then
    raise exception 'O pedido #% está cancelado. O cancelamento é definitivo.', lpad(old.numero::text, greatest(4, length(old.numero::text)), '0');
  end if;

  -- A taxa da venda da Shopee só muda pelo repasse (C2-1).
  if old.shopee_pedido_ref is not null and current_setting('arts.repasse_shopee', true) = 'sim' then
    v_livres := v_livres || array['taxa_plataforma'];
  end if;

  -- Venda da Shopee com repasse confirmado (R110): só o status muda;
  -- para cancelar, estorne o repasse antes (C2-2).
  if old.shopee_pedido_ref is not null
     and exists (select 1 from public.repasses_shopee r where r.venda_id = old.id and r.situacao = 'ATIVO') then
    if new.status_pedido = 'CANCELADO' and old.status_pedido <> 'CANCELADO' then
      raise exception 'O repasse desta venda da Shopee já foi confirmado. Para cancelar a venda, estorne o repasse antes (no detalhe da venda).';
    end if;
    if (to_jsonb(new) - (v_livres || array['editado_em'])) is distinct from (to_jsonb(old) - (v_livres || array['editado_em'])) then
      raise exception 'O repasse desta venda da Shopee já foi confirmado: agora só o status pode mudar. Para corrigir, estorne o repasse antes (no detalhe da venda).';
    end if;
  end if;

  if old.status_pedido in ('ENTREGUE', 'CANCELADO') then
    if old.status_pedido <> 'CANCELADO' and new.status_pedido = 'CANCELADO' then
      v_livres := v_livres || array['cancelado_em', 'motivo_cancelamento'];
    end if;
    if (to_jsonb(new) - v_livres) is distinct from (to_jsonb(old) - v_livres) then
      raise exception 'Pedido entregue ou cancelado não pode ser editado. Para corrigir um pedido entregue, volte o status para Pronto antes.';
    end if;
  end if;

  return new;
end;
$$;

-- Trava da edição (R110): depois do repasse, só o status.
create or replace function public.exigir_venda_sem_repasse(p_venda_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.repasses_shopee where venda_id = p_venda_id and situacao = 'ATIVO') then
    raise exception 'O repasse desta venda da Shopee já foi confirmado: agora só o status pode mudar. Para corrigir valores, itens ou cores, estorne o repasse antes (no detalhe da venda).';
  end if;
end;
$$;

-- Registrar ou editar a venda da Shopee: igual ao Lote C1, mais a trava do
-- repasse (R110).
create or replace function public.salvar_venda_shopee(
  p_id               uuid,
  p_shopee_ref       uuid,
  p_data             date,
  p_desconto         numeric,
  p_taxa             numeric,
  p_frete_comprador  numeric,
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
  v_sp        public.shopee_pedidos;
  v_id        uuid;
  v_numero    integer;
  v_desconto  numeric := coalesce(p_desconto, 0);
  v_taxa      numeric := coalesce(p_taxa, 0);
  v_frete     numeric := coalesce(p_frete_comprador, 0);
  v_obs       text := nullif(trim(coalesce(p_observacao, '')), '');
  v_subtotal  numeric := 0;
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
  v_desc      text;
  v_cor       text;
  v_qtd       integer;
  v_preco     numeric;
  v_troca     boolean;
  v_norm      jsonb := '[]'::jsonb;
  v_x         jsonb;
  v_linhas    integer;
  v_mudou     boolean := false;
begin
  perform public.exigir_admin();

  -- Pedido da Shopee
  if p_shopee_ref is null then raise exception 'Escolha o pedido da Shopee.'; end if;
  select * into v_sp from public.shopee_pedidos where id = p_shopee_ref for update;
  if not found then raise exception 'Pedido da Shopee não encontrado. Importe a planilha de novo.'; end if;

  if p_id is null then
    select * into v_atual from public.vendas where shopee_pedido_ref = p_shopee_ref;
    if found then
      raise exception 'O pedido % da Shopee já virou o pedido %.', v_sp.pedido_id, public.numero_pedido_texto(v_atual.numero);
    end if;
    if lower(coalesce(v_sp.status, '')) ~ 'cancel' then
      raise exception 'O pedido % está cancelado na Shopee e não vira venda.', v_sp.pedido_id;
    end if;
  else
    select * into v_atual from public.vendas where id = p_id for update;
    if not found then raise exception 'Pedido não encontrado.'; end if;
    if v_atual.shopee_pedido_ref is distinct from p_shopee_ref then
      raise exception 'Este pedido não é a venda do pedido % da Shopee.', v_sp.pedido_id;
    end if;
    if v_atual.status_pedido in ('ENTREGUE', 'CANCELADO') then
      raise exception 'Pedido entregue ou cancelado não pode ser editado. Para corrigir um pedido entregue, volte o status para Pronto antes.';
    end if;
    perform public.exigir_venda_sem_repasse(p_id);
  end if;

  -- Data da venda (R9): real, nunca futura
  if p_data is null then raise exception 'Informe a data da venda.'; end if;
  if p_data > public.hoje() then raise exception 'A data da venda não pode ser futura.'; end if;
  if length(coalesce(v_obs, '')) > 2000 then raise exception 'A observação pode ter até 2.000 caracteres.'; end if;

  -- Valores (R105)
  if v_desconto < 0 or v_taxa < 0 or v_frete < 0 then raise exception 'Desconto, taxa e frete não podem ser negativos.'; end if;
  if v_desconto <> round(v_desconto, 2) or v_taxa <> round(v_taxa, 2) or v_frete <> round(v_frete, 2) then
    raise exception 'Desconto, taxa e frete aceitam até 2 casas decimais.';
  end if;
  if greatest(v_desconto, v_taxa, v_frete) > c_limite then raise exception 'Valor acima do limite do sistema (R$ 9.999.999,99).'; end if;

  -- Itens: pelo menos 1
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'A venda precisa ter pelo menos um item.';
  end if;
  if jsonb_array_length(p_itens) > 200 then raise exception 'Uma venda pode ter até 200 itens.'; end if;

  for v_item, v_n in select e, o::integer from jsonb_array_elements(p_itens) with ordinality t(e, o) loop
    if jsonb_typeof(v_item) <> 'object' then raise exception 'Item %: formato inválido.', v_n; end if;

    v_iid := null; v_tem_old := false;
    v_txt := nullif(trim(coalesce(v_item ->> 'id', '')), '');
    if v_txt is not null then
      if v_txt !~ c_uuid or p_id is null then raise exception 'Item %: identificador inválido.', v_n; end if;
      v_iid := v_txt::uuid;
      if v_iid = any (v_ids) then raise exception 'Item %: aparece duas vezes na lista.', v_n; end if;
      select * into v_old from public.itens_venda where id = v_iid and venda_id = p_id;
      if not found then raise exception 'Item %: não pertence a esta venda.', v_n; end if;
      v_tem_old := true;
      v_ids := v_ids || v_iid;
    end if;

    v_txt := v_item ->> 'quantidade';
    if v_txt is null or v_txt !~ '^[0-9]{1,6}$' or v_txt::integer < 1 then
      raise exception 'Item %: a quantidade precisa ser um número inteiro, no mínimo 1.', v_n;
    end if;
    v_qtd := v_txt::integer;
    v_txt := v_item ->> 'preco_unitario';
    if v_txt is null or v_txt !~ '^[0-9]{1,10}(\.[0-9]{1,2})?$' then
      raise exception 'Item %: informe o preço (R$ 0,00 ou mais, até 2 casas decimais).', v_n;
    end if;
    v_preco := v_txt::numeric;
    if v_preco > c_limite or v_qtd * v_preco > c_limite then
      raise exception 'Item %: valor acima do limite do sistema (R$ 9.999.999,99).', v_n;
    end if;

    v_txt := nullif(trim(coalesce(v_item ->> 'produto_id', '')), '');
    if v_txt is not null and v_txt !~ c_uuid then raise exception 'Item %: produto inválido.', v_n; end if;
    v_prod_id := v_txt::uuid;
    v_txt := nullif(trim(coalesce(v_item ->> 'material_id', '')), '');
    if v_txt is not null and v_txt !~ c_uuid then raise exception 'Item %: cor inválida.', v_n; end if;
    v_mat_id := v_txt::uuid;

    v_troca := not v_tem_old or v_old.produto_id is distinct from v_prod_id;
    if v_prod_id is not null then
      -- Ligado ao catálogo (R102): nome do produto copiado; só produto ativo ao entrar
      if v_troca then
        select * into v_prod from public.produtos where id = v_prod_id;
        if not found then raise exception 'Item %: produto não encontrado.', v_n; end if;
        if not v_prod.ativo then raise exception 'Item %: o produto "%" está inativo.', v_n, v_prod.nome; end if;
        v_desc := v_prod.nome;
      else
        v_desc := v_old.descricao;
      end if;
      if v_mat_id is null then
        v_cor := null;
      elsif v_troca or v_old.material_id is distinct from v_mat_id then
        if not exists (select 1 from public.produto_cores where produto_id = v_prod_id and material_id = v_mat_id) then
          raise exception 'Item %: a cor escolhida não é uma das cores do produto.', v_n;
        end if;
        select * into v_mat from public.materiais where id = v_mat_id;
        v_cor := left(v_mat.tipo || ' · ' || v_mat.variacao, 80);
      else
        v_cor := v_old.cor_descricao;
      end if;
    else
      -- Sem ligação: o nome vem da planilha (como item personalizado)
      v_desc := left(trim(coalesce(v_item ->> 'descricao', '')), 150);
      if length(v_desc) = 0 then raise exception 'Item %: informe a descrição do item.', v_n; end if;
      if v_mat_id is not null then
        if v_troca or v_old.material_id is distinct from v_mat_id then
          select * into v_mat from public.materiais where id = v_mat_id;
          if not found or v_mat.categoria <> 'FILAMENTO' then raise exception 'Item %: a cor precisa ser um filamento.', v_n; end if;
          if not v_mat.ativo then raise exception 'Item %: o filamento % · % está inativo.', v_n, v_mat.tipo, v_mat.variacao; end if;
          v_cor := left(v_mat.tipo || ' · ' || v_mat.variacao, 80);
        else
          v_cor := v_old.cor_descricao;
        end if;
      else
        v_cor := null;
      end if;
    end if;

    v_subtotal := v_subtotal + round(v_qtd * v_preco, 2);
    v_norm := v_norm || jsonb_build_array(jsonb_build_object(
      'id', v_iid, 'ordem', v_n, 'produto_id', v_prod_id, 'descricao', v_desc,
      'preco_unitario', v_preco, 'quantidade', v_qtd, 'material_id', v_mat_id, 'cor_descricao', v_cor));
  end loop;

  if v_subtotal > c_limite then raise exception 'O subtotal passa do limite do sistema (R$ 9.999.999,99).'; end if;
  if v_desconto > v_subtotal then raise exception 'O desconto do vendedor não pode passar do valor dos produtos.'; end if;
  if v_taxa > v_subtotal - v_desconto then
    raise exception 'A taxa da Shopee não pode passar do valor dos produtos menos o desconto.';
  end if;

  if p_id is null then
    v_numero := public.proximo_numero_pedido();
    insert into public.vendas (numero, data, cliente_id, canal_id, origem, observacao, subtotal, desconto, frete, total,
                               shopee_pedido_ref, taxa_plataforma, frete_comprador)
    values (v_numero, p_data, null, public.canal_shopee(), null, v_obs, v_subtotal, v_desconto, 0, v_subtotal - v_desconto,
            p_shopee_ref, v_taxa, v_frete)
    returning id into v_id;
    insert into public.historico_status_pedido (venda_id, status_anterior, status_novo)
    values (v_id, null, 'AGUARDANDO');
  else
    v_id := p_id;
    v_numero := v_atual.numero;
    update public.vendas
       set data = p_data, observacao = v_obs, subtotal = v_subtotal, desconto = v_desconto, total = v_subtotal - v_desconto,
           taxa_plataforma = v_taxa, frete_comprador = v_frete
     where id = v_id
       and (data, observacao, subtotal, desconto, taxa_plataforma, frete_comprador)
           is distinct from (p_data, v_obs, v_subtotal::numeric(12,2), v_desconto::numeric(12,2),
                             v_taxa::numeric(12,2), v_frete::numeric(12,2));
    get diagnostics v_linhas = row_count;
    v_mudou := v_linhas > 0;
  end if;

  delete from public.itens_venda where venda_id = v_id and id <> all (v_ids);
  get diagnostics v_linhas = row_count;
  v_mudou := v_mudou or v_linhas > 0;

  for v_x in select e from jsonb_array_elements(v_norm) e loop
    if v_x ->> 'id' is not null then
      update public.itens_venda
         set ordem = (v_x ->> 'ordem')::integer, produto_id = (v_x ->> 'produto_id')::uuid, descricao = v_x ->> 'descricao',
             preco_unitario = (v_x ->> 'preco_unitario')::numeric, quantidade = (v_x ->> 'quantidade')::integer,
             material_id = (v_x ->> 'material_id')::uuid, cor_descricao = v_x ->> 'cor_descricao'
       where id = (v_x ->> 'id')::uuid
         and (ordem, produto_id, descricao, preco_unitario, quantidade, material_id, cor_descricao)
             is distinct from ((v_x ->> 'ordem')::integer, (v_x ->> 'produto_id')::uuid, v_x ->> 'descricao',
                               (v_x ->> 'preco_unitario')::numeric, (v_x ->> 'quantidade')::integer,
                               (v_x ->> 'material_id')::uuid, v_x ->> 'cor_descricao');
      get diagnostics v_linhas = row_count;
      v_mudou := v_mudou or v_linhas > 0;
    else
      insert into public.itens_venda (venda_id, ordem, produto_id, descricao, preco_unitario, quantidade, material_id, cor_descricao)
      values (v_id, (v_x ->> 'ordem')::integer, (v_x ->> 'produto_id')::uuid, v_x ->> 'descricao',
              (v_x ->> 'preco_unitario')::numeric, (v_x ->> 'quantidade')::integer,
              (v_x ->> 'material_id')::uuid, v_x ->> 'cor_descricao');
      v_mudou := true;
    end if;
  end loop;

  if p_id is not null and v_mudou then
    update public.vendas set editado_em = now() where id = v_id;
  end if;

  perform public.recalcular_pedido(v_id);
  perform public.conferir_pedido(v_id);
  return jsonb_build_object('id', v_id, 'numero', v_numero);
end;
$$;

-- Cores das partes: igual ao Lote A, mais a trava do repasse na venda da
-- Shopee (R110).
create or replace function public.definir_cores_partes(p_venda_id uuid, p_itens jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c_uuid    constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_venda   public.vendas;
  v_x       jsonb;
  v_n       integer;
  v_item    public.itens_venda;
  v_cores   jsonb;
  v_qtd     integer;
  v_parte   public.item_venda_partes;
  v_txt     text;
  v_mat_id  uuid;
  v_mat     public.materiais;
  v_cor     text;
  v_ordens  integer[] := '{}';
  v_linhas  integer;
  v_mudou   boolean := false;
begin
  perform public.exigir_admin();

  select * into v_venda from public.vendas where id = p_venda_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if v_venda.status_pedido in ('ENTREGUE', 'CANCELADO') then
    raise exception 'Pedido entregue ou cancelado não pode ter as cores alteradas. Para corrigir um pedido entregue, volte o status para Pronto antes.';
  end if;
  perform public.exigir_venda_sem_repasse(p_venda_id);

  if p_itens is null or jsonb_typeof(p_itens) <> 'array' then raise exception 'Cores em formato inválido.'; end if;

  for v_x, v_n in select e, o::integer from jsonb_array_elements(p_itens) with ordinality t(e, o) loop
    v_txt := v_x ->> 'ordem';
    if jsonb_typeof(v_x) <> 'object' or v_txt is null or v_txt !~ '^[0-9]{1,4}$' then
      raise exception 'Cores: item % em formato inválido.', v_n;
    end if;
    if v_txt::integer = any (v_ordens) then raise exception 'Cores: o item % aparece duas vezes.', v_txt; end if;
    v_ordens := v_ordens || v_txt::integer;

    select * into v_item from public.itens_venda where venda_id = p_venda_id and ordem = v_txt::integer;
    if not found then raise exception 'Item %: não pertence a este pedido.', v_txt; end if;
    select count(*) into v_qtd from public.item_venda_partes where item_id = v_item.id;
    if v_qtd = 0 then raise exception 'Item %: este item não tem partes para escolher cor.', v_item.ordem; end if;

    v_cores := v_x -> 'cores';
    if v_cores is null or jsonb_typeof(v_cores) <> 'array' or jsonb_array_length(v_cores) <> v_qtd then
      raise exception 'Item %: informe a cor de cada uma das % partes.', v_item.ordem, v_qtd;
    end if;

    for v_parte in select * from public.item_venda_partes where item_id = v_item.id order by ordem loop
      v_txt := v_cores ->> (v_parte.ordem - 1);
      v_txt := nullif(trim(coalesce(v_txt, '')), '');
      if v_txt is not null and v_txt !~ c_uuid then
        raise exception 'Item %, parte %: cor inválida.', v_item.ordem, v_parte.nome;
      end if;
      v_mat_id := v_txt::uuid;
      if v_mat_id is not distinct from v_parte.material_id then continue; end if;

      if v_mat_id is null then
        v_cor := null;
      else
        select * into v_mat from public.materiais where id = v_mat_id;
        if not found then raise exception 'Item %, parte %: o filamento escolhido não existe mais em Materiais.', v_item.ordem, v_parte.nome; end if;
        if v_mat.categoria <> 'FILAMENTO' then
          raise exception 'Item %, parte %: "%" não é um filamento.', v_item.ordem, v_parte.nome, v_mat.tipo;
        end if;
        if not v_mat.ativo then
          raise exception 'Item %, parte %: o filamento % · % está inativo e não pode ser escolhido.',
            v_item.ordem, v_parte.nome, v_mat.tipo, v_mat.variacao;
        end if;
        v_cor := left(v_mat.tipo || ' · ' || v_mat.variacao, 80);
      end if;

      update public.item_venda_partes set material_id = v_mat_id, cor_descricao = v_cor where id = v_parte.id;
      get diagnostics v_linhas = row_count;
      v_mudou := v_mudou or v_linhas > 0;
    end loop;
  end loop;

  -- Mudança de cor conta como edição do pedido (P4).
  if v_mudou then
    update public.vendas set editado_em = now() where id = p_venda_id;
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 4. Confirmar e estornar o repasse (R106, C2-1)
-- ---------------------------------------------------------------------
--   p_valor:      o que caiu de fato; vem sugerido o estimado
--                 (faturamento − taxa da planilha)
--   p_confirmado: a Admin conferiu o repasse na Shopee
create or replace function public.confirmar_repasse_shopee(
  p_venda_id    uuid,
  p_data        date,
  p_valor       numeric,
  p_observacao  text,
  p_confirmado  boolean,
  p_chave       uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda  public.vendas;
  v_sp     public.shopee_pedidos;
  v_obs    text := nullif(trim(coalesce(p_observacao, '')), '');
  v_fat    numeric(12,2);
  v_taxa   numeric(12,2);
  v_id     uuid;
  v_outro  uuid;
begin
  perform public.exigir_admin();

  if p_confirmado is not true then
    raise exception 'Confirme que conferiu o repasse na Shopee. Só repasses confirmados entram no Caixa.';
  end if;

  select * into v_venda from public.vendas where id = p_venda_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if v_venda.shopee_pedido_ref is null then raise exception 'Este pedido não é uma venda da Shopee.'; end if;

  -- Mesmo envio repetido: devolve o repasse já gravado.
  if p_chave is not null then
    select id, venda_id into v_id, v_outro from public.repasses_shopee where chave_envio = p_chave;
    if v_id is not null then
      if v_outro <> p_venda_id then raise exception 'Código de envio já usado em outra venda.'; end if;
      return v_id;
    end if;
  end if;

  if v_venda.status_pedido = 'CANCELADO' then raise exception 'Venda cancelada não recebe repasse.'; end if;
  if exists (select 1 from public.repasses_shopee where venda_id = p_venda_id and situacao = 'ATIVO') then
    raise exception 'O repasse desta venda já foi confirmado.';
  end if;

  select * into v_sp from public.shopee_pedidos where id = v_venda.shopee_pedido_ref;
  if lower(trim(coalesce(v_sp.status, ''))) not like 'conclu%' then
    raise exception 'O pedido % ainda não aparece como Concluído na Shopee. Importe a planilha atualizada antes de confirmar o repasse.', v_sp.pedido_id;
  end if;

  v_fat := v_venda.subtotal - v_venda.desconto;
  if p_valor is null or p_valor <= 0 then raise exception 'Informe o valor do repasse, maior que zero.'; end if;
  if p_valor <> round(p_valor, 2) then raise exception 'O valor aceita até 2 casas decimais.'; end if;
  if p_valor > v_fat then
    raise exception 'O repasse (R$ %) não pode passar do faturamento da venda (R$ %). Confira o valor ou edite a venda antes.',
      replace(to_char(p_valor, 'FM9999999990.00'), '.', ','), replace(to_char(v_fat, 'FM9999999990.00'), '.', ',');
  end if;

  if p_data is null then raise exception 'Informe a data do repasse.'; end if;
  if p_data < v_venda.data then raise exception 'A data do repasse não pode ser anterior à data da venda.'; end if;
  if p_data > public.hoje() then raise exception 'A data do repasse não pode ser futura.'; end if;
  if length(coalesce(v_obs, '')) > 500 then raise exception 'A observação pode ter até 500 caracteres.'; end if;

  v_taxa := v_fat - p_valor;

  -- Taxa da Shopee = faturamento − repasse (C2-1)
  perform set_config('arts.repasse_shopee', 'sim', true);
  update public.vendas set taxa_plataforma = v_taxa
   where id = p_venda_id and taxa_plataforma is distinct from v_taxa;

  insert into public.repasses_shopee (venda_id, data, valor, faturamento, taxa, taxa_anterior, observacao, confirmado_por, chave_envio)
  values (p_venda_id, p_data, p_valor, v_fat, v_taxa, v_venda.taxa_plataforma, v_obs, auth.uid(), p_chave)
  returning id into v_id;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, repasse_shopee_id, obs)
  values (p_data, 'ENTRADA', 'REPASSE_SHOPEE', p_valor,
          'Repasse Shopee do pedido ' || public.numero_pedido_texto(v_venda.numero) || ' (Shopee ' || v_sp.pedido_id || ')',
          v_id, v_obs);

  perform public.recalcular_pedido(p_venda_id);
  perform set_config('arts.repasse_shopee', '', true);
  perform public.conferir_pedido(p_venda_id);
  return v_id;
end;
$$;

-- Estorno de repasse confirmado por engano → estorno do movimento no Caixa
-- (saída), com a data de hoje (R45). A taxa da venda volta a ser a de antes
-- da confirmação e a venda pode ser editada de novo.
create or replace function public.estornar_repasse_shopee(p_repasse_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda_id  uuid;
  v_venda     public.vendas;
  v_rep       public.repasses_shopee;
  v_mov       public.movimentos_caixa;
  v_motivo    text := trim(coalesce(p_motivo, ''));
begin
  perform public.exigir_admin();

  if length(v_motivo) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  select venda_id into v_venda_id from public.repasses_shopee where id = p_repasse_id;
  if v_venda_id is null then raise exception 'Repasse não encontrado.'; end if;
  select * into v_venda from public.vendas where id = v_venda_id for update;
  select * into v_rep from public.repasses_shopee where id = p_repasse_id for update;
  if v_rep.situacao = 'ESTORNADO' then raise exception 'Este repasse já foi estornado.'; end if;

  select * into v_mov from public.movimentos_caixa where repasse_shopee_id = p_repasse_id for update;
  if not found then
    raise exception 'O repasse não foi encontrado no Caixa. Nada foi alterado; fale com o suporte.';
  end if;

  perform set_config('arts.repasse_shopee', 'sim', true);
  update public.repasses_shopee
     set situacao = 'ESTORNADO', estornado_em = now(), motivo_estorno = v_motivo
   where id = p_repasse_id;
  update public.vendas set taxa_plataforma = v_rep.taxa_anterior
   where id = v_venda_id and taxa_plataforma is distinct from v_rep.taxa_anterior;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, movimento_estornado_id, obs)
  values (public.hoje(), 'SAIDA', 'ESTORNO', v_mov.valor, 'Estorno: ' || v_mov.descricao, v_mov.id, v_motivo);

  perform public.recalcular_pedido(v_venda_id);
  perform set_config('arts.repasse_shopee', '', true);
  perform public.conferir_pedido(v_venda_id);
end;
$$;


-- ---------------------------------------------------------------------
-- 5. Avisos de cancelado ou devolvido (R109, C2-2, C2-3)
-- ---------------------------------------------------------------------
-- Manter a venda como está: o aviso some para aquele status da Shopee.
create or replace function public.dispensar_aviso_shopee(p_venda_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda   public.vendas;
  v_sp      public.shopee_pedidos;
  v_motivo  text := trim(coalesce(p_motivo, ''));
begin
  perform public.exigir_admin();

  if length(v_motivo) = 0 then raise exception 'Informe o motivo para manter a venda como está.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  select * into v_venda from public.vendas where id = p_venda_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if v_venda.shopee_pedido_ref is null then raise exception 'Este pedido não é uma venda da Shopee.'; end if;

  if not exists (select 1 from public.vw_avisos_shopee where venda_id = p_venda_id) then
    raise exception 'Não há aviso da Shopee para esta venda.';
  end if;

  select * into v_sp from public.shopee_pedidos where id = v_venda.shopee_pedido_ref;
  insert into public.avisos_shopee_dispensados (venda_id, status_shopee, status_devolucao, motivo)
  values (p_venda_id, v_sp.status, v_sp.status_devolucao, v_motivo);
end;
$$;


-- ---------------------------------------------------------------------
-- 6. Consultas
-- ---------------------------------------------------------------------

-- Repasses para confirmar (R106): vendas da Shopee cujo pedido aparece como
-- Concluído na última importação, sem repasse ativo. Valor estimado =
-- faturamento − taxa; data sugerida = dia da importação.
create view public.vw_repasses_shopee_pendentes with (security_invoker = true) as
select v.id as venda_id, v.numero,
       '#' || lpad(v.numero::text, greatest(4, length(v.numero::text)), '0') as numero_formatado,
       s.pedido_id as pedido_shopee, s.status as status_shopee,
       v.data, v.status_pedido,
       (v.subtotal - v.desconto)::numeric(12,2) as faturamento,
       v.taxa_plataforma,
       (v.subtotal - v.desconto - v.taxa_plataforma)::numeric(12,2) as repasse_estimado,
       greatest(v.data, coalesce((i.created_at at time zone 'America/Sao_Paulo')::date, v.data)) as data_sugerida,
       i.created_at as importado_em
  from public.vendas v
  join public.shopee_pedidos s on s.id = v.shopee_pedido_ref
  left join public.shopee_importacoes i on i.id = s.ultima_importacao_id
 where lower(trim(coalesce(s.status, ''))) like 'conclu%'
   and v.status_pedido <> 'CANCELADO'
   and not exists (select 1 from public.repasses_shopee r where r.venda_id = v.id and r.situacao = 'ATIVO');

-- Avisos (R109): venda da Shopee ativa cujo pedido aparece como cancelado ou
-- devolvido, e que a Admin ainda não dispensou para esse status.
create view public.vw_avisos_shopee with (security_invoker = true) as
select v.id as venda_id, v.numero,
       '#' || lpad(v.numero::text, greatest(4, length(v.numero::text)), '0') as numero_formatado,
       s.pedido_id as pedido_shopee, s.status as status_shopee, s.status_devolucao,
       case when lower(coalesce(s.status, '')) ~ 'cancel' then 'CANCELADO' else 'DEVOLVIDO' end as tipo,
       v.status_pedido,
       exists (select 1 from public.repasses_shopee r where r.venda_id = v.id and r.situacao = 'ATIVO') as tem_repasse
  from public.vendas v
  join public.shopee_pedidos s on s.id = v.shopee_pedido_ref
 where v.status_pedido <> 'CANCELADO'
   and (lower(coalesce(s.status, '')) ~ 'cancel|devolu|reembols'
        or nullif(trim(coalesce(s.status_devolucao, '')), '') is not null)
   and not exists (select 1 from public.avisos_shopee_dispensados d
                    where d.venda_id = v.id
                      and d.status_shopee is not distinct from s.status
                      and d.status_devolucao is not distinct from s.status_devolucao);


-- ---------------------------------------------------------------------
-- 7. Acesso: só a Admin lê; ninguém grava direto
-- ---------------------------------------------------------------------
alter table public.repasses_shopee enable row level security;
alter table public.avisos_shopee_dispensados enable row level security;

revoke all on public.repasses_shopee, public.avisos_shopee_dispensados from public, anon, authenticated;
revoke all on public.vw_repasses_shopee_pendentes, public.vw_avisos_shopee from public, anon, authenticated;
grant select on public.repasses_shopee, public.avisos_shopee_dispensados to authenticated;
grant select on public.vw_repasses_shopee_pendentes, public.vw_avisos_shopee to authenticated;

create policy repasses_shopee_select_admin on public.repasses_shopee for select to authenticated using (public.is_admin());
create policy avisos_shopee_dispensados_select_admin on public.avisos_shopee_dispensados for select to authenticated using (public.is_admin());

-- Internas: ninguém executa direto
revoke all on function public.tg_repasses_shopee_protege() from public, anon, authenticated;
revoke all on function public.tg_avisos_shopee_protege() from public, anon, authenticated;
revoke all on function public.exigir_venda_sem_repasse(uuid) from public, anon, authenticated;

revoke all on function public.confirmar_repasse_shopee(uuid, date, numeric, text, boolean, uuid) from public, anon;
grant execute on function public.confirmar_repasse_shopee(uuid, date, numeric, text, boolean, uuid) to authenticated;
revoke all on function public.estornar_repasse_shopee(uuid, text) from public, anon;
grant execute on function public.estornar_repasse_shopee(uuid, text) to authenticated;
revoke all on function public.dispensar_aviso_shopee(uuid, text) from public, anon;
grant execute on function public.dispensar_aviso_shopee(uuid, text) to authenticated;

commit;

-- Pronto. Confira com sql/repasses_shopee_verificacao.sql.
