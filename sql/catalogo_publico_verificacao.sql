-- =====================================================================
-- Arts com Você · Verificação do catálogo público (R85–R88)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'Marcações no_catalogo e personalizado existem, obrigatórias, começando desligadas',
         (select count(*) from pg_attribute a
           where a.attrelid = 'public.produtos'::regclass and a.attname in ('no_catalogo', 'personalizado')
             and not a.attisdropped and a.attnotnull and a.atttypid = 'boolean'::regtype
             and pg_get_expr((select d.adbin from pg_attrdef d where d.adrelid = a.attrelid and d.adnum = a.attnum), a.attrelid) = 'false') = 2, ''

  union all
  select 2, 'definir_produto_catalogo exige a Admin e o visitante não executa',
         exists (select 1 from pg_proc where oid = to_regprocedure('public.definir_produto_catalogo(uuid, boolean, boolean)')
                    and prosecdef and prosrc like '%exigir_admin()%')
     and not has_function_privilege('anon', 'public.definir_produto_catalogo(uuid, boolean, boolean)', 'EXECUTE'), ''

  union all
  select 3, 'catalogo_publico devolve só nome, preço, descrição, foto e cores (e o código do produto)',
         exists (select 1 from pg_proc where oid = to_regprocedure('public.catalogo_publico()')
                    and prosecdef and provolatile = 's'
                    and pg_get_function_result(oid) = 'TABLE(id uuid, nome text, descricao text, preco numeric, sob_consulta boolean, foto_path text, cores text[])'), ''

  union all
  select 4, 'catalogo_publico só mostra produtos ativos marcados',
         exists (select 1 from pg_proc where oid = to_regprocedure('public.catalogo_publico()')
                    and prosrc like '%p.ativo and p.no_catalogo%'), ''

  union all
  select 5, 'Visitante sem login executa catalogo_publico e foto_no_catalogo',
         has_function_privilege('anon', 'public.catalogo_publico()', 'EXECUTE')
     and has_function_privilege('anon', 'public.foto_no_catalogo(text)', 'EXECUTE'), ''

  union all
  select 6, 'Visitante sem login continua sem acesso a tabelas e consultas de produtos e materiais',
         not exists (select 1 from (values ('produtos'), ('produto_cores'), ('vw_produtos'), ('materiais')) t(nome)
                      where has_table_privilege('anon', 'public.' || t.nome, 'SELECT')
                         or has_table_privilege('anon', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('anon', 'public.' || t.nome, 'UPDATE')
                         or has_table_privilege('anon', 'public.' || t.nome, 'DELETE')), ''

  union all
  select 7, 'Visitante sem login não executa as funções de gravação de produtos',
         not has_function_privilege('anon', 'public.salvar_produto(uuid, text, text, text, integer, integer, numeric, numeric, numeric, numeric, numeric, uuid[])', 'EXECUTE')
     and not has_function_privilege('anon', 'public.definir_produto_ativo(uuid, boolean)', 'EXECUTE')
     and not has_function_privilege('anon', 'public.excluir_produto(uuid)', 'EXECUTE')
     and not has_function_privilege('anon', 'public.definir_produto_catalogo(uuid, boolean, boolean)', 'EXECUTE'), ''

  union all
  select 8, 'Fotos do catálogo: regra só de leitura, só para fotos de produtos marcados',
         exists (select 1 from pg_policies
                  where schemaname = 'storage' and tablename = 'objects' and policyname = 'produtos_fotos_select_catalogo'
                    and cmd = 'SELECT' and qual like '%produtos%' and qual like '%foto_no_catalogo%'), ''

  union all
  select 9, 'Regras da Admin para as fotos continuam iguais; nenhuma regra de sobrescrever',
         (select count(*) from pg_policies
           where schemaname = 'storage' and tablename = 'objects'
             and policyname in ('produtos_fotos_select_admin', 'produtos_fotos_insert_admin', 'produtos_fotos_delete_admin')
             and coalesce(qual, '') || coalesce(with_check, '') like '%is_admin()%') = 3
     and not exists (select 1 from pg_policies
                      where schemaname = 'storage' and tablename = 'objects' and cmd <> 'SELECT'
                        and policyname not in ('produtos_fotos_insert_admin', 'produtos_fotos_delete_admin')
                        and coalesce(qual, '') || coalesce(with_check, '') like '%''produtos''%'), ''

  union all
  select 10, 'Pasta "produtos" continua privada',
         exists (select 1 from storage.buckets where id = 'produtos' and not public), ''

  union all
  select 11, 'Produtos no catálogo (informativo)',
         true,
         (select count(*) from public.catalogo_publico())::text || ' visível(is) · '
           || (select count(*) from public.produtos where no_catalogo and not ativo)::text || ' marcado(s) mas inativo(s) · '
           || (select count(*) from public.catalogo_publico() where sob_consulta)::text || ' sob consulta'

  union all
  select 12, 'Produtos visíveis sem foto ou sem descrição (informativo)',
         true,
         (select count(*) from public.catalogo_publico() where foto_path is null)::text || ' sem foto · '
           || (select count(*) from public.catalogo_publico() where descricao is null)::text || ' sem descrição'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
