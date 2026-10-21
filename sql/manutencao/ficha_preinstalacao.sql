-- =====================================================================
-- Arts com Você · Conferência ANTES da ficha de consumo (sql/14)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run. Esperado: nenhum "FALHOU".
-- =====================================================================

with linhas (ordem, item, resultado, detalhe) as (
  select 1, 'Produtos (sql/06) e Pedidos Diretos (sql/07 e 08) instalados',
         case when to_regclass('public.produtos') is not null and to_regclass('public.itens_venda') is not null
                   and to_regprocedure('public.salvar_pedido(uuid, date, uuid, text, date, text, numeric, numeric, text, jsonb)') is not null
              then 'OK' else 'FALHOU' end, ''
  union all
  select 2, 'Ficha de consumo ainda não instalada (tabelas e funções livres)',
         case when to_regclass('public.produto_partes') is null and to_regclass('public.produto_materiais') is null
                   and to_regclass('public.item_venda_partes') is null
                   and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                                      and proname in ('salvar_ficha_produto', 'definir_cores_partes',
                                                      'tg_itens_venda_copiar_ficha', 'tg_item_venda_partes_protege'))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 3, 'Funções de apoio existem (exigir_admin, is_admin, auditoria, updated_at)',
         case when (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
                      and proname in ('exigir_admin', 'is_admin', 'tg_auditoria', 'tg_updated_at')) >= 4
              then 'OK' else 'FALHOU' end, ''
  union all
  select 10, 'Produtos cadastrados (nenhum ganha ficha sozinho)', 'INFO', (select count(*) from public.produtos)::text
  union all
  select 11, 'Itens de pedido já registrados (continuam sem partes)', 'INFO', (select count(*) from public.itens_venda)::text
  union all
  select 12, 'Insumos e embalagens ativos (podem entrar na ficha)', 'INFO',
         coalesce((select string_agg(tipo || coalesce(' · ' || variacao, ''), ', ' order by tipo, variacao)
                     from public.materiais where categoria in ('INSUMO', 'EMBALAGEM') and ativo), 'nenhum')
  union all
  select 13, 'Filamentos ativos (cores das partes)', 'INFO',
         (select count(*) from public.materiais where categoria = 'FILAMENTO' and ativo)::text
)
select ordem, item, resultado, detalhe from linhas order by ordem;
