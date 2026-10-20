-- =====================================================================
-- Arts com Você · Retrato de segurança do catálogo público (sql/11)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
--
-- Como usar:
--   1. Rodar ANTES de sql/11_catalogo_publico.sql e salvar o resultado
--      (Export → CSV).
--   2. Rodar o 11, sem usar o sistema entre os passos.
--   3. Rodar DE NOVO e comparar com o primeiro.
--
-- Bloco P (Preservado): precisa ficar IDÊNTICO antes e depois — quantidade
--   e impressão digital (md5) de cada tabela (produtos pelas colunas que já
--   existiam), funções, regras de acesso, gatilhos, consultas e listas fixas.
-- Bloco M (Muda de propósito): o que o 11 acrescenta.
--   Antes: 0 colunas, 0 funções, 0 regra. Depois: 2 colunas, 3 funções,
--   1 regra, 0 produtos marcados, 0 visíveis.
-- =====================================================================

with
novas(nome) as (values ('definir_produto_catalogo'), ('catalogo_publico'), ('foto_no_catalogo')),
dados(item, qtd, md5) as (
  select 'produtos (colunas originais)', count(*), md5(coalesce(string_agg(
      row(t.id, t.nome, t.descricao, t.foto_path, t.tempo_impressao_min, t.peso_g, t.altura_cm, t.largura_cm,
          t.profundidade_cm, t.preco_venda, t.ativo, t.created_at, t.created_by, t.updated_at)::text, '|' order by t.id), ''))
    from public.produtos t
  union all select 'produto_cores', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.produto_cores t
  union all select 'materiais', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.materiais t
  union all select 'clientes', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.clientes t
  union all select 'vendas', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.vendas t
  union all select 'itens_venda', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.itens_venda t
  union all select 'historico_status_pedido', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.historico_status_pedido t
  union all select 'recebimentos_venda', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.recebimentos_venda t
  union all select 'devolucoes_venda', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.devolucoes_venda t
  union all select 'movimentos_caixa', count(*), md5(coalesce(string_agg(t::text, '|' order by t.seq), '')) from public.movimentos_caixa t
  union all select 'lancamentos', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lancamentos t
  union all select 'pagamentos_lancamento', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.pagamentos_lancamento t
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
  union all select 'storage: pastas (configuração)', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from storage.buckets t
  union all select 'auditoria', count(*), md5(coalesce(string_agg(
      row(t.id, t.tabela, t.registro_id, t.acao, t.antes, t.depois, t.usuario, t.quando)::text, '|' order by t.id), ''))
    from public.auditoria t
),
objetos(item, qtd, md5) as (
  select 'funções que já existiam', count(*), md5(coalesce(string_agg(
      p.proname || ':' || md5(pg_get_functiondef(p.oid)) || ':' || coalesce(array_to_string(p.proacl, ','), ''), '|'
      order by p.proname, pg_get_function_identity_arguments(p.oid)), ''))
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname not in (select nome from novas)
  union all
  select 'regras de acesso (menos a nova das fotos do catálogo)', count(*), md5(coalesce(string_agg(
      schemaname || '.' || tablename || '.' || policyname || ':' || cmd || ':' || array_to_string(roles, ',') || ':'
      || coalesce(qual, '') || ':' || coalesce(with_check, ''), '|' order by schemaname, tablename, policyname), ''))
    from pg_policies where schemaname in ('public', 'storage') and policyname <> 'produtos_fotos_select_catalogo'
  union all
  select 'permissões das tabelas e consultas', count(*), md5(coalesce(string_agg(
      c.relname || ':' || coalesce(array_to_string(c.relacl, ','), ''), '|' order by c.relname), ''))
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'v')
  union all
  select 'gatilhos', count(*), md5(coalesce(string_agg(
      c.relname || '.' || t.tgname || ':' || pg_get_triggerdef(t.oid), '|' order by c.relname, t.tgname), ''))
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
  union all
  select 'consultas (views)', count(*), md5(coalesce(string_agg(
      c.relname || ':' || pg_get_viewdef(c.oid) || ':' || coalesce(array_to_string(c.reloptions, ','), ''), '|' order by c.relname), ''))
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
  union all
  select 'listas fixas', count(*), md5(coalesce(string_agg(
      t.typname || ':' || e.enumlabel, '|' order by t.typname, e.enumsortorder), ''))
    from pg_type t join pg_enum e on e.enumtypid = t.oid
   where t.typnamespace = 'public'::regnamespace
  union all
  select 'colunas que já existiam em produtos', count(*), md5(coalesce(string_agg(
      a.attname || ':' || format_type(a.atttypid, a.atttypmod) || ':' || a.attnotnull, '|' order by a.attnum), ''))
    from pg_attribute a where a.attrelid = 'public.produtos'::regclass and a.attnum > 0 and not a.attisdropped
     and a.attname not in ('no_catalogo', 'personalizado')
),
muda(item, qtd) as (
  select 'colunas novas em produtos (no_catalogo, personalizado)', count(*)
    from pg_attribute where attrelid = 'public.produtos'::regclass and attname in ('no_catalogo', 'personalizado') and not attisdropped
  union all
  select 'funções novas (definir_produto_catalogo, catalogo_publico, foto_no_catalogo)', count(*)
    from pg_proc where pronamespace = 'public'::regnamespace and proname in (select nome from novas)
  union all
  select 'regra nova das fotos do catálogo', count(*)
    from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'produtos_fotos_select_catalogo'
)
select 'P. Preservado' as bloco, item, qtd::text as quantidade, md5 as impressao_digital from dados
union all
select 'P. Preservado', item, qtd::text, md5 from objetos
union all
select 'M. Muda de propósito', item, qtd::text, '' from muda
order by 1 desc, 2;
