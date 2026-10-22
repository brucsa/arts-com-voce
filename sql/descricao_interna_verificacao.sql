-- =====================================================================
-- Arts com Você · Verificação da descrição interna e do tempo no catálogo
-- (sql/21, R71 e R85 v1.13)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'Coluna descricao_interna e a função salvar_descricao_interna existem',
         exists (select 1 from pg_attribute where attrelid = 'public.produtos'::regclass
                   and attname = 'descricao_interna' and not attisdropped)
     and to_regprocedure('public.salvar_descricao_interna(uuid, text)') is not null, ''

  union all
  select 2, 'salvar_descricao_interna exige a Admin; o visitante não executa',
         exists (select 1 from pg_proc where oid = to_regprocedure('public.salvar_descricao_interna(uuid, text)')
                   and prosecdef and prosrc like '%exigir_admin()%')
     and has_function_privilege('authenticated', 'public.salvar_descricao_interna(uuid, text)', 'EXECUTE')
     and not has_function_privilege('anon', 'public.salvar_descricao_interna(uuid, text)', 'EXECUTE'), ''

  union all
  select 3, 'catalogo_publico devolve o tempo de impressão e o visitante executa',
         exists (select 1 from pg_proc where oid = to_regprocedure('public.catalogo_publico()')
                   and prosecdef and pg_get_function_result(oid) like '%tempo_impressao_min integer)')
     and has_function_privilege('anon', 'public.catalogo_publico()', 'EXECUTE'), ''

  union all
  select 4, 'A descrição interna não vai para o catálogo público',
         not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                       and proname in ('catalogo_publico', 'catalogo_fotos', 'foto_no_catalogo')
                       and prosrc like '%descricao_interna%'), ''

  union all
  select 5, 'Só a Admin lê os produtos (a descrição interna fica protegida pela mesma regra)',
         (select relrowsecurity from pg_class where oid = 'public.produtos'::regclass)
     and not has_table_privilege('anon', 'public.produtos', 'SELECT'), ''

  union all
  select 6, 'Informativo: descrições',
         true,
         (select count(*) from public.produtos where descricao is not null)::text || ' com descrição para o cliente · '
         || (select count(*) from public.produtos where descricao_interna is not null)::text || ' com descrição interna'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
