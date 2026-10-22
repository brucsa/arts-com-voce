-- =====================================================================
-- Arts com Você · Verificação das fotos do produto (sql/20, R73 v1.12)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'Tabela produto_fotos e funções novas existem',
         to_regclass('public.produto_fotos') is not null
     and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace
            and proname in ('salvar_fotos_produto', 'catalogo_fotos', 'tg_fotos_produto_unicas', 'foto_no_catalogo')) = 4, ''

  union all
  select 2, 'salvar_fotos_produto: o usuário logado executa (ela exige a Admin); o visitante não',
         has_function_privilege('authenticated', 'public.salvar_fotos_produto(uuid, text[])', 'EXECUTE')
     and not has_function_privilege('anon', 'public.salvar_fotos_produto(uuid, text[])', 'EXECUTE'), ''

  union all
  select 3, 'Catálogo: o visitante executa catalogo_fotos e foto_no_catalogo; a função interna fica fechada',
         has_function_privilege('anon', 'public.catalogo_fotos(uuid)', 'EXECUTE')
     and has_function_privilege('anon', 'public.foto_no_catalogo(text)', 'EXECUTE')
     and not has_function_privilege('authenticated', 'public.tg_fotos_produto_unicas()', 'EXECUTE')
     and not has_function_privilege('anon', 'public.tg_fotos_produto_unicas()', 'EXECUTE'), ''

  union all
  select 4, 'Só a Admin lê a tabela; ninguém grava direto (regra de acesso ligada)',
         (select relrowsecurity from pg_class where oid = 'public.produto_fotos'::regclass)
     and not exists (select 1 from (values ('INSERT'), ('UPDATE'), ('DELETE')) p(x)
                      where has_table_privilege('authenticated', 'public.produto_fotos', p.x)
                         or has_table_privilege('anon', 'public.produto_fotos', p.x))
     and not has_table_privilege('anon', 'public.produto_fotos', 'SELECT')
     and exists (select 1 from pg_policies where schemaname = 'public' and policyname = 'produto_fotos_select_admin'), ''

  union all
  select 5, 'Gatilhos ligados (foto única e auditoria)',
         (select count(*) from pg_trigger where not tgisinternal and tgname in
            ('trg_produtos_foto_unica', 'trg_produto_fotos_unica', 'trg_produto_fotos_auditoria')) = 3, ''

  union all
  select 6, 'Até 5 fotos por produto, em ordem (capa + fotos 2, 3, 4, 5 sem buracos)',
         not exists (select 1 from public.produto_fotos f group by f.produto_id
                      having count(*) > 4 or max(f.ordem) <> count(*) + 1), ''

  union all
  select 7, 'Produto com fotos a mais tem capa',
         not exists (select 1 from public.produto_fotos f join public.produtos p on p.id = f.produto_id where p.foto_path is null), ''

  union all
  select 8, 'Cada arquivo é foto de um lugar só (capa ou foto a mais, de um produto)',
         not exists (select 1 from public.produto_fotos f join public.produtos p on p.foto_path = f.foto_path), ''

  union all
  select 9, 'Toda foto a mais existe na pasta "produtos"',
         not exists (select 1 from public.produto_fotos f
                      where not exists (select 1 from storage.objects o where o.bucket_id = 'produtos' and o.name = f.foto_path)), ''

  union all
  select 10, 'Informativo: fotos dos produtos',
         true,
         (select count(*) from public.produtos where foto_path is not null)::text || ' produto(s) com capa · '
         || (select count(distinct produto_id) from public.produto_fotos)::text || ' com mais fotos · '
         || (select count(*) from public.produto_fotos)::text || ' foto(s) a mais'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
