-- =====================================================================
-- Arts com Você · Retrato de segurança da área do Joca (sql/12 e sql/13)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
--
-- Como usar:
--   1. Rodar ANTES de sql/12_caixa_origem_joca.sql e salvar o resultado
--      (Export → CSV).
--   2. Rodar 12 e 13, sem usar o sistema entre os passos.
--   3. Rodar DE NOVO e comparar com o primeiro.
--
-- Bloco P (Preservado): precisa ficar IDÊNTICO antes e depois — tabelas
--   (movimentos_caixa pelas colunas que já existiam), funções que a área do
--   Joca não toca, regras de acesso, gatilhos, consultas e listas fixas.
-- Bloco M (Muda de propósito): o que a área do Joca acrescenta.
-- =====================================================================

with
novas(nome) as (
  values ('percentual_joca_em'), ('sincronizar_comissao_joca'), ('tg_vendas_comissao_joca'), ('joca_totais'),
         ('registrar_pagamento_joca'), ('estornar_pagamento_joca'), ('conferir_pagamento_joca'),
         ('tg_pagamentos_joca_conferir'), ('tg_movimentos_caixa_conferir_joca'), ('tg_comissoes_joca_protege'),
         ('tg_pagamentos_joca_protege'), ('joca_resumo'), ('joca_extrato'), ('migrar_comissoes_joca'),
         ('estornar_movimento')   -- trocada: ganha a recusa do pagamento ao Joca
),
tabelas_novas(nome) as (values ('comissao_joca_pedido'), ('comissoes_joca'), ('pagamentos_joca')),
dados(item, qtd, md5) as (
  select 'clientes', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.clientes t
  union all select 'vendas', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.vendas t
  union all select 'itens_venda', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.itens_venda t
  union all select 'historico_status_pedido', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.historico_status_pedido t
  union all select 'recebimentos_venda', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.recebimentos_venda t
  union all select 'devolucoes_venda', count(*), md5(coalesce(string_agg(t::text, '|' order by t.id), '')) from public.devolucoes_venda t
  union all select 'movimentos_caixa (colunas que já existiam)', count(*), md5(coalesce(string_agg(
      row(t.id, t.seq, t.data, t.tipo, t.origem, t.valor, t.descricao, t.pagamento_id, t.movimento_estornado_id,
          t.obs, t.created_at, t.created_by, t.recebimento_id, t.devolucao_id)::text, '|' order by t.seq), ''))
    from public.movimentos_caixa t
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
  union all select 'auditoria (sem as tabelas novas do Joca)', count(*), md5(coalesce(string_agg(
      row(t.id, t.tabela, t.registro_id, t.acao, t.antes, t.depois, t.usuario, t.quando)::text, '|' order by t.id), ''))
    from public.auditoria t where t.tabela not in (select nome from tabelas_novas)
),
objetos(item, qtd, md5) as (
  select 'funções que a área do Joca não toca', count(*), md5(coalesce(string_agg(
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
     and c.relname not in (select nome from tabelas_novas) and c.relname <> 'vw_joca_pedidos'
  union all
  select 'gatilhos (menos os novos do Joca)', count(*), md5(coalesce(string_agg(
      c.relname || '.' || t.tgname || ':' || pg_get_triggerdef(t.oid), '|' order by c.relname, t.tgname), ''))
    from pg_trigger t join pg_class c on c.oid = t.tgrelid
   where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
     and c.relname not in (select nome from tabelas_novas)
     and t.tgname not in ('trg_vendas_comissao_joca', 'trg_movimentos_caixa_conferir_joca')
  union all
  select 'consultas (views) que já existiam', count(*), md5(coalesce(string_agg(
      c.relname || ':' || pg_get_viewdef(c.oid) || ':' || coalesce(array_to_string(c.reloptions, ','), ''), '|' order by c.relname), ''))
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
     and c.relname <> 'vw_joca_pedidos'
  union all
  select 'listas fixas (menos origem_caixa e a nova do Joca)', count(*), md5(coalesce(string_agg(
      t.typname || ':' || e.enumlabel, '|' order by t.typname, e.enumsortorder), ''))
    from pg_type t join pg_enum e on e.enumtypid = t.oid
   where t.typnamespace = 'public'::regnamespace and t.typname not in ('origem_caixa', 'tipo_comissao_joca')
  union all
  select 'origem_caixa: valores que já existiam', count(*), md5(coalesce(string_agg(e.enumlabel, '|' order by e.enumsortorder), ''))
    from pg_enum e where e.enumtypid = 'public.origem_caixa'::regtype and e.enumlabel <> 'PAGAMENTO_JOCA'
),
muda(item, qtd, valor) as (
  select 'origem_caixa: valores', count(*), null::numeric from pg_enum where enumtypid = 'public.origem_caixa'::regtype
  union all
  select 'funções novas ou trocadas pela área do Joca', count(*), null
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in (select nome from novas)
  union all
  select 'tabelas novas do Joca', count(*), null from tabelas_novas t where to_regclass('public.' || t.nome) is not null
  union all
  select 'pagamentos ao Joca no Caixa', count(*), coalesce(sum(valor), 0)
    from public.movimentos_caixa where origem::text = 'PAGAMENTO_JOCA'
  union all
  select 'saldo do Caixa', count(*), coalesce(sum(case when tipo = 'ENTRADA' then valor else -valor end), 0)
    from public.movimentos_caixa
  union all
  select 'pedidos', count(*), null from public.vendas
)
select 'P. Preservado' as bloco, item, qtd::text as quantidade, md5 as impressao_digital from dados
union all
select 'P. Preservado', item, qtd::text, md5 from objetos
union all
select 'M. Muda de propósito', item, qtd::text,
       case when valor is null then '' else 'R$ ' || replace(to_char(valor, 'FM9999999990.00'), '.', ',') end
  from muda
order by 1 desc, 2;
