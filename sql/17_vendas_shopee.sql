-- =====================================================================
-- Arts com Você · Vendas da Shopee (Etapa 6) · Lote C1
-- Especificação v1.9, R101–R105, R107, R108, R110 e R111 (decisões V1–V11);
-- R70, R77 e R78 complementadas.
--
-- O que este arquivo faz:
--   · vendas ganha três colunas: shopee_pedido_ref (o pedido importado que
--     virou a venda), taxa_plataforma e frete_comprador; cliente e origem
--     passam a poder ficar vazios SÓ na venda da Shopee (R104) — nos pedidos
--     diretos continuam obrigatórios, conferido por regra do banco;
--   · salvar_venda_shopee: registra (ou edita) a venda a partir de um pedido
--     importado, com os itens ligados ou não ao catálogo (R102, R110);
--   · consultas trocadas para incluir a venda da Shopee (sem cliente):
--     vw_pedidos (+ canal, pedido da Shopee, taxa e frete do comprador, no
--     fim), vw_joca_pedidos, vw_itens_producao e vw_pedido_custos (o lucro
--     passa a descontar a taxa da Shopee, R108);
--   · recebimento e devolução manuais ficam recusados na venda da Shopee:
--     o dinheiro entra pelo repasse (Lote C2, R106).
--
-- O que NÃO muda:
--   · nenhum registro existente (os pedidos diretos ficam como estão);
--   · as funções dos pedidos diretos, do Caixa, do Joca, da ficha e da
--     produção; a importação da planilha (R70) continua sem gerar venda.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/vendas_shopee_verificacao.sql e as gerais.
-- Tudo ou nada: se qualquer passo falhar, nada é alterado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_attribute where attrelid = 'public.vendas'::regclass
               and attname = 'shopee_pedido_ref' and not attisdropped) then
    raise exception 'As vendas da Shopee já estão instaladas. Nada foi alterado.';
  end if;
  if to_regclass('public.shopee_pedidos') is null then
    raise exception 'O módulo Pedidos da Shopee (sql/shopee_pedidos.sql) precisa estar instalado. Nada foi alterado.';
  end if;
  if to_regclass('public.producoes') is null or to_regclass('public.vw_pedido_custos') is null then
    raise exception 'A produção (sql/16) precisa estar instalada. Nada foi alterado.';
  end if;
  if not exists (select 1 from public.canais where lower(trim(nome)) = 'shopee') then
    raise exception 'O canal "Shopee" não foi encontrado em Configurações › Canais. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
               and proname in ('salvar_venda_shopee', 'canal_shopee', 'tg_vendas_canal_coerente',
                               'tg_lancamento_venda_shopee')) then
    raise exception 'Já existe função das vendas da Shopee. Nada foi alterado.';
  end if;
  if exists (select 1 from public.vendas where cliente_id is null or origem is null) then
    raise exception 'Há pedido sem cliente ou sem origem. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Pedidos: venda da Shopee (R103, R104, R105)
-- ---------------------------------------------------------------------
create or replace function public.canal_shopee()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.canais where lower(trim(nome)) = 'shopee';
  if v_id is null then
    raise exception 'O canal "Shopee" não foi encontrado em Configurações › Canais. Confira o nome do canal.';
  end if;
  return v_id;
end;
$$;

alter table public.vendas
  alter column cliente_id drop not null,
  alter column origem drop not null,
  add column shopee_pedido_ref uuid unique references public.shopee_pedidos (id) on delete restrict,
  add column taxa_plataforma   numeric(12,2) not null default 0 check (taxa_plataforma >= 0),
  add column frete_comprador   numeric(12,2) not null default 0 check (frete_comprador >= 0),
  -- Pedido direto: cliente e origem obrigatórios (R77, R78). Venda da
  -- Shopee: sem cliente e sem origem (R104), frete do comprador separado.
  add constraint vendas_shopee_coerente check (
    (shopee_pedido_ref is null) = (cliente_id is not null and origem is not null)
    and (shopee_pedido_ref is not null or (taxa_plataforma = 0 and frete_comprador = 0))
    and (shopee_pedido_ref is null or frete = 0)),
  -- A taxa nunca passa do que a loja fatura (o repasse não fica negativo).
  add constraint vendas_taxa_ate_faturamento check (taxa_plataforma <= subtotal - desconto);

comment on column public.vendas.shopee_pedido_ref is 'Venda da Shopee (R102): o pedido importado que virou esta venda. Vazio nos pedidos diretos.';
comment on column public.vendas.taxa_plataforma is 'Taxa da Shopee (R105, R7): comissão + serviço + transação da planilha, corrigível.';
comment on column public.vendas.frete_comprador is 'Frete pago pelo comprador na Shopee (R8): só informativo, fora da comissão e do lucro.';

-- Canal coerente: pedido direto no Boca a Boca; venda da Shopee no canal Shopee.
create or replace function public.tg_vendas_canal_coerente()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.shopee_pedido_ref is not null and new.canal_id is distinct from public.canal_shopee() then
    raise exception 'A venda da Shopee precisa estar no canal Shopee.';
  end if;
  if new.shopee_pedido_ref is null and new.canal_id is distinct from public.canal_boca_a_boca() then
    raise exception 'O pedido direto precisa estar no canal Boca a Boca.';
  end if;
  if tg_op = 'UPDATE' and new.shopee_pedido_ref is distinct from old.shopee_pedido_ref then
    raise exception 'O pedido da Shopee ligado a esta venda não pode mudar.';
  end if;
  return new;
end;
$$;

create trigger trg_vendas_canal_coerente
  before insert or update of canal_id, shopee_pedido_ref on public.vendas
  for each row execute function public.tg_vendas_canal_coerente();

-- Venda da Shopee: o dinheiro entra pelo repasse (R106), não por
-- recebimento nem devolução manual.
create or replace function public.tg_lancamento_venda_shopee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.vendas where id = new.venda_id and shopee_pedido_ref is not null) then
    raise exception 'Venda da Shopee: o dinheiro entra pelo repasse da Shopee, não por recebimento ou devolução manual.';
  end if;
  return new;
end;
$$;

create trigger trg_recebimentos_venda_shopee before insert on public.recebimentos_venda
  for each row execute function public.tg_lancamento_venda_shopee();
create trigger trg_devolucoes_venda_shopee before insert on public.devolucoes_venda
  for each row execute function public.tg_lancamento_venda_shopee();


-- ---------------------------------------------------------------------
-- 2. Registrar ou editar a venda da Shopee (R102, R110)
-- ---------------------------------------------------------------------
--   p_id:     vazio = registrar; preenchido = editar
--   p_itens:  [{"id": "..."?, "produto_id": "..."?, "descricao": "...", "quantidade": 1,
--               "preco_unitario": 25.9, "material_id": "..."?}, ...]
-- Item ligado ao catálogo copia o nome do produto (R79); a cor única é uma
-- das cores do produto; produto com ficha tem as cores por parte gravadas
-- por definir_cores_partes depois (R94).
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


-- ---------------------------------------------------------------------
-- 3. Consultas: a venda da Shopee aparece (sem cliente)
-- ---------------------------------------------------------------------
-- Lista de pedidos: mesmas colunas; no fim, canal, pedido da Shopee,
-- taxa e frete do comprador.
create or replace view public.vw_pedidos with (security_invoker = true) as
select v.id,
       v.numero,
       '#' || case when v.numero < 10000 then lpad(v.numero::text, 4, '0') else v.numero::text end as numero_formatado,
       v.data,
       v.cliente_id, c.nome as cliente_nome, c.contato as cliente_contato, c.ativo as cliente_ativo,
       v.origem, v.data_prometida, v.forma_pagamento, v.observacao,
       v.subtotal, v.desconto, v.frete, v.total,
       v.status_pedido,
       v.valor_recebido, v.valor_devolvido, (v.valor_recebido - v.valor_devolvido) as valor_liquido,
       v.saldo, v.status_financeiro,
       v.cancelado_em, v.motivo_cancelamento,
       (v.status_pedido in ('ENTREGUE', 'CANCELADO')) as edicao_bloqueada,
       case when v.data_prometida is null or v.status_pedido in ('ENTREGUE', 'CANCELADO') then null
            when v.data_prometida < public.hoje() then 'ATRASADO'
            when v.data_prometida = public.hoje() then 'VENCE_HOJE'
            when v.data_prometida = public.hoje() + 1 then 'VENCE_AMANHA'
       end as selo_prazo,
       (select count(*) from public.itens_venda i where i.venda_id = v.id) as quantidade_itens,
       v.editado_em, v.created_at, v.updated_at,
       cn.nome as canal,
       (v.shopee_pedido_ref is not null) as eh_shopee,
       v.shopee_pedido_ref,
       sp.pedido_id as pedido_shopee,
       v.taxa_plataforma,
       v.frete_comprador
  from public.vendas v
  left join public.clientes c on c.id = v.cliente_id
  join public.canais cn on cn.id = v.canal_id
  left join public.shopee_pedidos sp on sp.id = v.shopee_pedido_ref;

-- Comissões do Joca (R107): inclui a venda da Shopee.
create or replace view public.vw_joca_pedidos with (security_invoker = true) as
with c as (
  select v.id as venda_id, v.numero, v.data, v.status_pedido, v.status_financeiro, coalesce(cl.nome, 'Shopee') as cliente,
         p.percentual, (v.subtotal - v.desconto) as base, v.total, v.valor_devolvido,
         coalesce(s.soma, 0)::numeric(12,2) as comissao, coalesce(s.registros, 0) as registros
    from public.vendas v
    left join public.clientes cl on cl.id = v.cliente_id
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

-- Itens a produzir: inclui a venda da Shopee (cliente = "Shopee").
create or replace view public.vw_itens_producao with (security_invoker = true) as
select i.id as item_id, i.venda_id, v.numero, '#' || lpad(v.numero::text, greatest(4, length(v.numero::text)), '0') as numero_formatado,
       coalesce(c.nome, 'Shopee') as cliente, v.status_pedido, v.data as data_pedido, v.data_prometida,
       i.ordem, i.produto_id, i.descricao, i.quantidade, i.material_id, i.cor_descricao,
       coalesce(pr.pecas, 0)::integer as produzidas,
       coalesce(sp.pecas, 0)::integer as de_estoque,
       greatest(i.quantidade - coalesce(pr.pecas, 0) - coalesce(sp.pecas, 0), 0)::integer as faltam,
       exists (select 1 from public.item_venda_partes p where p.item_id = i.id) as tem_partes,
       not exists (select 1 from public.item_venda_partes p where p.item_id = i.id and p.material_id is null) as cores_definidas
  from public.itens_venda i
  join public.vendas v on v.id = i.venda_id
  left join public.clientes c on c.id = v.cliente_id
  left join lateral (select sum(p.pecas) as pecas from public.producoes p
                      where p.item_id = i.id and p.resultado = 'OK' and p.situacao = 'ATIVO') pr on true
  left join lateral (select sum(s.quantidade) as pecas from public.saidas_pecas_prontas s
                      where s.item_id = i.id and s.situacao = 'ATIVO') sp on true;

-- Custo e lucro (R100, R108): o lucro desconta também a taxa da Shopee.
create or replace view public.vw_pedido_custos with (security_invoker = true) as
select v.id as venda_id,
       coalesce(pr.custo, 0)::numeric(12,2) as custo_producao,
       coalesce(sp.custo, 0)::numeric(12,2) as custo_pecas_prontas,
       coalesce(em.custo, 0)::numeric(12,2) as custo_embalagem,
       (coalesce(pr.custo, 0) + coalesce(sp.custo, 0) + coalesce(em.custo, 0))::numeric(12,2) as custo_total,
       coalesce(cj.valor, 0)::numeric(12,2) as comissao_joca,
       case when v.status_pedido = 'CANCELADO' or v.total <= 0 then 0::numeric(12,2)
            else round((v.subtotal - v.desconto) * greatest(v.total - v.valor_devolvido, 0) / v.total, 2) end as receita,
       (case when v.status_pedido = 'CANCELADO' or v.total <= 0 then 0
             else round((v.subtotal - v.desconto) * greatest(v.total - v.valor_devolvido, 0) / v.total, 2) end
        - case when v.status_pedido = 'CANCELADO' then 0 else v.taxa_plataforma end
        - coalesce(pr.custo, 0) - coalesce(sp.custo, 0) - coalesce(em.custo, 0) - coalesce(cj.valor, 0))::numeric(12,2) as lucro_estimado,
       exists (select 1 from public.itens_venda i where i.venda_id = v.id and public.item_faltam(i.id) > 0) as falta_produzir,
       (case when v.status_pedido = 'CANCELADO' then 0 else v.taxa_plataforma end)::numeric(12,2) as taxa_plataforma
  from public.vendas v
  left join lateral (select sum(p.custo_total) as custo from public.producoes p
                      where p.venda_id = v.id and p.resultado = 'OK' and p.situacao = 'ATIVO') pr on true
  left join lateral (select sum(s.custo) as custo from public.saidas_pecas_prontas s
                      where s.venda_id = v.id and s.situacao = 'ATIVO') sp on true
  left join lateral (select sum(e.valor) as custo from public.embalagens_pedido e where e.venda_id = v.id) em on true
  left join lateral (select sum(k.valor) as valor from public.comissoes_joca k where k.venda_id = v.id) cj on true;


-- ---------------------------------------------------------------------
-- 4. Acesso
-- ---------------------------------------------------------------------
revoke all on function public.canal_shopee() from public, anon, authenticated;
revoke all on function public.tg_vendas_canal_coerente() from public, anon, authenticated;
revoke all on function public.tg_lancamento_venda_shopee() from public, anon, authenticated;
revoke all on function public.salvar_venda_shopee(uuid, uuid, date, numeric, numeric, numeric, text, jsonb) from public, anon;
grant execute on function public.salvar_venda_shopee(uuid, uuid, date, numeric, numeric, numeric, text, jsonb) to authenticated;

commit;

-- Pronto. Confira com sql/vendas_shopee_verificacao.sql.
