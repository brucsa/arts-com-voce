-- =====================================================================
-- Arts com Você · Retrato de segurança das vendas da Shopee (sql/17)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
--
-- Como usar:
--   1. Rodar ANTES de sql/17_vendas_shopee.sql e salvar o resultado
--      (Export → CSV).
--   2. Rodar 17, sem usar o sistema entre os passos.
--   3. Rodar DE NOVO e comparar com o primeiro.
--
-- Bloco P (Preservado): precisa ficar IDÊNTICO antes e depois — todos os
--   dados (vendas pelas colunas que já existiam), todas as funções, regras
--   de acesso, permissões, gatilhos, listas fixas e as consultas que o 17
--   não troca.
-- Bloco M (Muda de propósito): o que as vendas da Shopee acrescentam ou trocam.
-- =====================================================================

with
novas(nome) as (
  values ('salvar_venda_shopee'), ('canal_shopee'), ('tg_vendas_canal_coerente'), ('tg_lancamento_venda_shopee')
),
tabelas_novas(nome) as (select null::text where false),
views_trocadas(nome) as (values ('vw_pedidos'), ('vw_joca_pedidos'), ('vw_itens_producao'), ('vw_pedido_custos')),
gatilhos_novos(nome) as (values ('trg_vendas_canal_coerente'), ('trg_recebimentos_venda_shopee'), ('trg_devolucoes_venda_shopee')),
dados(item, qtd, md5) as (
  select 'clientes', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.clientes t
  union all select 'vendas (colunas que já existiam)', count(*), md5(coalesce(string_agg(
      (to_jsonb(t) - array['shopee_pedido_ref', 'taxa_plataforma', 'frete_comprador'])::text, '|' order by t.id), '')) from public.vendas t
  union all select 'itens_venda', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.itens_venda t
  union all select 'historico_status_pedido', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.historico_status_pedido t
  union all select 'recebimentos_venda', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.recebimentos_venda t
  union all select 'devolucoes_venda', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.devolucoes_venda t
  union all select 'movimentos_caixa', count(*), md5(coalesce(string_agg(t::text, '|' order by t.seq), '')) from public.movimentos_caixa t
  union all select 'comissao_joca_pedido', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.comissao_joca_pedido t
  union all select 'comissoes_joca', count(*), md5(coalesce(string_agg(t::text, '|' order by t.seq), '')) from public.comissoes_joca t
  union all select 'pagamentos_joca', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.pagamentos_joca t
  union all select 'produto_partes', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.produto_partes t
  union all select 'produto_materiais', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.produto_materiais t
  union all select 'item_venda_partes', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.item_venda_partes t
  union all select 'producoes', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.producoes t
  union all select 'producao_consumos', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.producao_consumos t
  union all select 'pecas_prontas', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.pecas_prontas t
  union all select 'saidas_pecas_prontas', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.saidas_pecas_prontas t
  union all select 'embalagens_pedido', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.embalagens_pedido t
  union all select 'ajustes_estoque', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.ajustes_estoque t
  union all select 'lancamentos', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lancamentos t
  union all select 'pagamentos_lancamento', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.pagamentos_lancamento t
  union all select 'produtos', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.produtos t
  union all select 'produto_cores', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.produto_cores t
  union all select 'materiais', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.materiais t
  union all select 'compras_estoque', count(*), md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.compras_estoque t
  union all select 'lotes_material', count(*), md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.lotes_material t
  union all select 'movimentos_estoque', count(*), md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.movimentos_estoque t
  union all select 'saldos_material', count(*), md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.saldos_material t
  union all select 'canais', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.canais t
  union all select 'categorias_lanc', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.categorias_lanc t
  union all select 'categorias_produto', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.categorias_produto t
  union all select 'configuracoes', count(*), md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.configuracoes t
  union all select 'configuracoes_hist', count(*), md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.configuracoes_hist t
  union all select 'perfis', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.perfis t
  union all select 'shopee_importacoes', count(*), md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.shopee_importacoes t
  union all select 'shopee_pedidos', count(*), md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.shopee_pedidos t
  union all select 'shopee_pedido_itens', count(*), md5(coalesce(string_agg(t::text, '|' order by t::text), '')) from public.shopee_pedido_itens t
  union all select 'storage: pasta produtos', count(*), md5(coalesce(string_agg(t.name || ':' || coalesce(t.metadata::text, ''), '|' order by t.name), ''))
    from storage.objects t where t.bucket_id = 'produtos'
  union all select 'auditoria', count(*), md5(coalesce(string_agg(
      row(t.id, t.tabela, t.registro_id, t.acao, t.antes, t.depois, t.usuario, t.quando)::text, '|' order by t.id), ''))
    from public.auditoria t where t.tabela not in (select nome from tabelas_novas)
),
objetos(item, qtd, md5) as (
  select 'funções que já existiam (todas)', count(*), md5(coalesce(string_agg(
      p.proname || ':' || md5(pg_get_functiondef(p.oid)) || ':' || coalesce(array_to_string(p.proacl, ','), ''), '|'
      order by p.proname, pg_get_function_identity_arguments(p.oid)), ''))
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname not in (select nome from novas)
  union all
  select 'regras de acesso (menos as das tabelas novas)', count(*), md5(coalesce(string_agg(
      schemaname || '.' || tablename || '.' || policyname || ':' || cmd || ':' || array_to_string(roles, ',') || ':'
      || coalesce(qual, '') || ':' || coalesce(with_check, ''), '|' order by schemaname, tablename, policyname), ''))
    from pg_policies where schemaname in ('public', 'storage') and tablename not in (select nome from tabelas_novas)
  union all
  select 'permissões das tabelas e consultas que já existiam', count(*), md5(coalesce(string_agg(
      c.relname || ':' || coalesce(array_to_string(c.relacl, ','), ''), '|' order by c.relname), ''))
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v')
     and c.relname not in (select nome from tabelas_novas)
  union all
  select 'gatilhos que já existiam', count(*), md5(coalesce(string_agg(
      c.relname || '.' || t.tgname || ':' || pg_get_triggerdef(t.oid), '|' order by c.relname, t.tgname), ''))
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
     and c.relname not in (select nome from tabelas_novas)
     and t.tgname not in (select nome from gatilhos_novos)
  union all
  select 'consultas (views) que o 17 não troca', count(*), md5(coalesce(string_agg(
      c.relname || ':' || pg_get_viewdef(c.oid) || ':' || coalesce(array_to_string(c.reloptions, ','), ''), '|' order by c.relname), ''))
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
     and c.relname not in (select nome from views_trocadas)
  union all
  select 'listas fixas', count(*), md5(coalesce(string_agg(
      t.typname || ':' || e.enumlabel, '|' order by t.typname, e.enumsortorder), ''))
    from pg_type t join pg_enum e on e.enumtypid = t.oid
   where t.typnamespace = 'public'::regnamespace
),
muda(item, qtd, valor) as (
  select 'colunas novas em vendas (pedido da Shopee, taxa, frete do comprador)', count(*), null::numeric from pg_attribute
   where attrelid = 'public.vendas'::regclass and not attisdropped and attname in ('shopee_pedido_ref', 'taxa_plataforma', 'frete_comprador')
  union all
  select 'consultas trocadas (pedidos, Joca, itens a produzir, custo)', count(*), null from views_trocadas t where to_regclass('public.' || t.nome) is not null
  union all
  select 'funções novas das vendas da Shopee', count(*), null
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in (select nome from novas)
  union all
  select 'gatilhos novos (canal da venda; sem recebimento manual na Shopee)', count(*), null
    from pg_trigger where tgname in (select nome from gatilhos_novos)
  union all
  select 'vendas da Shopee', count(*), null from public.vendas where to_jsonb(vendas) ->> 'shopee_pedido_ref' is not null
  union all
  select 'saldo do Caixa', count(*), coalesce(sum(case when tipo = 'ENTRADA' then valor else -valor end), 0)
    from public.movimentos_caixa
)
select 'P. Preservado' as bloco, item, qtd::text as quantidade, md5 as impressao_digital from dados
union all
select 'P. Preservado', item, qtd::text, md5 from objetos
union all
select 'M. Muda de propósito', item, qtd::text,
       case when valor is null then '' else 'R$ ' || replace(to_char(valor, 'FM9999999990.00'), '.', ',') end
  from muda
order by 1 desc, 2;
