-- =====================================================================
-- Arts com Você · Conferência ANTES da descrição interna (sql/21)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run. Esperado: nenhum "FALHOU".
-- =====================================================================

with linhas (ordem, item, resultado, detalhe) as (
  select 1, 'Catálogo público (sql/11) e fotos do produto (sql/20) instalados',
         case when to_regprocedure('public.catalogo_publico()') is not null and to_regclass('public.produto_fotos') is not null
              then 'OK' else 'FALHOU' end, ''
  union all
  select 2, 'catalogo_publico ainda na forma anterior (sem o tempo de impressão)',
         case when pg_get_function_result(to_regprocedure('public.catalogo_publico()'))
                   = 'TABLE(id uuid, nome text, descricao text, preco numeric, sob_consulta boolean, foto_path text, cores text[])'
              then 'OK' else 'FALHOU' end, ''
  union all
  select 3, 'Descrição interna ainda não instalada',
         case when not exists (select 1 from pg_attribute where attrelid = 'public.produtos'::regclass
                                  and attname = 'descricao_interna' and not attisdropped)
                   and to_regprocedure('public.salvar_descricao_interna(uuid, text)') is null
              then 'OK' else 'FALHOU' end, ''
  union all
  select 10, 'Produtos com descrição (passa a ser a do cliente)', 'INFO',
         (select count(*) from public.produtos where descricao is not null)::text || ' de ' || (select count(*) from public.produtos)::text
)
select ordem, item, resultado, detalhe from linhas order by ordem;
