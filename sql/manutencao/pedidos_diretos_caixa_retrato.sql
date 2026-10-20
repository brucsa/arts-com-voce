-- =====================================================================
-- Arts com Você · Retrato de segurança da integração Pedidos Diretos → Caixa
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
--
-- Como usar:
--   1. Rodar ANTES de sql/09_caixa_origens_pedidos.sql e salvar o resultado
--      (Export → CSV).
--   2. Rodar 09 e 10, sem usar o sistema entre os passos.
--   3. Rodar DE NOVO e comparar com o primeiro.
--
-- Bloco P (Preservado): precisa ficar IDÊNTICO antes e depois — quantidade
--   e impressão digital (md5) de cada tabela, sempre pelas colunas que já
--   existiam antes da integração; funções, regras de acesso, gatilhos,
--   consultas e listas fixas que a integração não toca.
-- Bloco M (Muda de propósito): o que a integração acrescenta — movimentos
--   novos no Caixa (só RECEBIMENTO), saldo, funções trocadas, origens novas.
--   Antes: 0 movimentos de pedidos. Depois: 3 recebimentos, R$ 125,60.
-- =====================================================================

with
-- Funções que a integração troca ou cria (ficam no bloco M)
trocadas(nome) as (
  values ('conferir_pedido'), ('registrar_recebimento'), ('registrar_devolucao'), ('estornar_recebimento'),
         ('estornar_devolucao'), ('estornar_movimento'), ('migrar_pedidos_para_caixa'),
         ('tg_movimentos_caixa_conferir_pedido'), ('numero_pedido_texto')
),
dados(item, qtd, md5) as (
  -- Pedidos Diretos (colunas originais)
  select 'clientes', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.clientes t
  union all select 'vendas', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.vendas t
  union all select 'itens_venda', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.itens_venda t
  union all select 'historico_status_pedido', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.historico_status_pedido t
  union all select 'recebimentos_venda (colunas originais)', count(*), md5(coalesce(string_agg(
      row(t.id, t.venda_id, t.data, t.valor, t.forma_pagamento, t.observacao, t.confirmado_em, t.confirmado_por,
          t.situacao, t.estornado_em, t.motivo_estorno, t.created_at, t.created_by, t.updated_at)::text, '|' order by t.id), ''))
    from public.recebimentos_venda t
  union all select 'devolucoes_venda (colunas originais)', count(*), md5(coalesce(string_agg(
      row(t.id, t.venda_id, t.data, t.valor, t.forma_pagamento, t.motivo, t.situacao, t.estornado_em,
          t.motivo_estorno, t.created_at, t.created_by, t.updated_at)::text, '|' order by t.id), ''))
    from public.devolucoes_venda t
  -- Caixa: movimentos que já existiam (colunas originais; origens antigas)
  union all select 'movimentos_caixa já existentes (colunas originais)', count(*), md5(coalesce(string_agg(
      row(t.id, t.seq, t.data, t.tipo, t.origem, t.valor, t.descricao, t.pagamento_id, t.movimento_estornado_id,
          t.obs, t.created_at, t.created_by)::text, '|' order by t.seq), ''))
    from public.movimentos_caixa t where t.origem::text in ('PAGAMENTO_GASTO', 'APORTE', 'RETIRADA')
       or (t.origem::text = 'ESTORNO' and exists (select 1 from public.movimentos_caixa o where o.id = t.movimento_estornado_id
                                                   and o.origem::text in ('PAGAMENTO_GASTO', 'APORTE', 'RETIRADA')))
  union all select 'lancamentos', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.lancamentos t
  union all select 'pagamentos_lancamento', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.pagamentos_lancamento t
  -- Catálogo, Estoque, Configurações, Shopee, perfis
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
  -- Auditoria: tudo, menos os registros dos movimentos novos do Caixa
  union all select 'auditoria (sem os registros de movimentos_caixa)', count(*), md5(coalesce(string_agg(
      row(t.id, t.tabela, t.registro_id, t.acao, t.antes, t.depois, t.usuario, t.quando)::text, '|' order by t.id), ''))
    from public.auditoria t where t.tabela <> 'movimentos_caixa'
  union all select 'auditoria de movimentos_caixa já existentes', count(*), md5(coalesce(string_agg(
      row(t.id, t.acao, t.antes, t.depois)::text, '|' order by t.id), ''))
    from public.auditoria t where t.tabela = 'movimentos_caixa'
     and coalesce(t.depois, t.antes) ->> 'origem' in ('PAGAMENTO_GASTO', 'APORTE', 'RETIRADA')
),
objetos(item, qtd, md5) as (
  select 'funções não tocadas pela integração', count(*), md5(coalesce(string_agg(
      p.proname || ':' || md5(pg_get_functiondef(p.oid)) || ':' || coalesce(array_to_string(p.proacl, ','), ''), '|'
      order by p.proname, pg_get_function_identity_arguments(p.oid)), ''))
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname not in (select nome from trocadas)
  union all
  select 'regras de acesso (RLS)', count(*), md5(coalesce(string_agg(
      schemaname || '.' || tablename || '.' || policyname || ':' || cmd || ':' || coalesce(qual, '') || ':' || coalesce(with_check, ''), '|'
      order by schemaname, tablename, policyname), ''))
    from pg_policies where schemaname in ('public', 'storage')
  union all
  select 'gatilhos (menos o novo do Caixa)', count(*), md5(coalesce(string_agg(
      c.relname || '.' || t.tgname || ':' || pg_get_triggerdef(t.oid), '|' order by c.relname, t.tgname), ''))
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
     and t.tgname <> 'trg_movimentos_caixa_conferir_pedido'
  union all
  select 'consultas (views)', count(*), md5(coalesce(string_agg(
      c.relname || ':' || pg_get_viewdef(c.oid) || ':' || coalesce(array_to_string(c.reloptions, ','), ''), '|' order by c.relname), ''))
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
  union all
  select 'listas fixas (menos origem_caixa)', count(*), md5(coalesce(string_agg(
      t.typname || ':' || e.enumlabel, '|' order by t.typname, e.enumsortorder), ''))
    from pg_type t join pg_enum e on e.enumtypid = t.oid
   where t.typnamespace = 'public'::regnamespace and t.typname <> 'origem_caixa'
  union all
  select 'origem_caixa: valores antigos preservados', count(*), md5(coalesce(string_agg(e.enumlabel, '|' order by e.enumsortorder), ''))
    from pg_enum e where e.enumtypid = 'public.origem_caixa'::regtype
     and e.enumlabel in ('PAGAMENTO_GASTO', 'APORTE', 'RETIRADA', 'ESTORNO')
),
muda(item, qtd, valor) as (
  select 'movimentos do Caixa ligados a pedidos (RECEBIMENTO)', count(*), coalesce(sum(valor), 0)
    from public.movimentos_caixa where origem::text = 'RECEBIMENTO'
  union all
  select 'movimentos do Caixa ligados a pedidos (REEMBOLSO)', count(*), coalesce(sum(valor), 0)
    from public.movimentos_caixa where origem::text = 'REEMBOLSO'
  union all
  select 'recebimentos ativos dos pedidos', count(*), coalesce(sum(valor), 0)
    from public.recebimentos_venda where situacao = 'ATIVO'
  union all
  select 'saldo do Caixa', count(*), coalesce(sum(case when tipo = 'ENTRADA' then valor else -valor end), 0)
    from public.movimentos_caixa
  union all
  select 'origem_caixa: valores', count(*), null
    from pg_enum where enumtypid = 'public.origem_caixa'::regtype
  union all
  select 'funções trocadas/criadas pela integração', count(*), null
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in (select nome from trocadas)
)
select 'P. Preservado' as bloco, item, qtd::text as quantidade, md5 as impressao_digital from dados
union all
select 'P. Preservado', item, qtd::text, md5 from objetos
union all
select 'M. Muda de propósito', item, qtd::text,
       case when valor is null then '' else 'R$ ' || replace(to_char(valor, 'FM9999999990.00'), '.', ',') end
  from muda
order by 1 desc, 2;
