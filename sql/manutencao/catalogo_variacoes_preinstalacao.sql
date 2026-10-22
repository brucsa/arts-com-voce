-- =====================================================================
-- Arts com Você · Conferência ANTES das variações no catálogo (sql/23)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run. Esperado: nenhum "FALHOU".
-- =====================================================================

with linhas (ordem, item, resultado, detalhe) as (
  select 1, 'Catálogo público (sql/11, sql/21) e variações de produto (sql/22) instalados',
         case when to_regprocedure('public.catalogo_publico()') is not null and to_regclass('public.produto_variacoes') is not null
              then 'OK' else 'FALHOU' end, ''
  union all
  select 2, 'Combinações no catálogo ainda não instaladas',
         case when not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'catalogo_variacoes')
              then 'OK' else 'FALHOU' end, ''
  union all
  select 10, 'Produtos do catálogo com combinações', 'INFO',
         (select count(distinct p.id) from public.produtos p join public.produto_variacoes v on v.produto_id = p.id
           where p.ativo and p.no_catalogo)::text || ' de '
         || (select count(*) from public.produtos where ativo and no_catalogo)::text || ' no catálogo'
)
select ordem, item, resultado, detalhe from linhas order by ordem;
