-- =====================================================================
-- Arts com Você · Verificação do Catálogo Essencial de Produtos (R71–R75)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with tabelas(nome) as (
  values ('produtos'), ('produto_cores')
),
funcoes(assinatura) as (
  values ('public.salvar_produto(uuid, text, text, text, integer, integer, numeric, numeric, numeric, numeric, numeric, uuid[])'),
         ('public.definir_produto_ativo(uuid, boolean)'),
         ('public.excluir_produto(uuid)')
),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'As 2 tabelas e a consulta vw_produtos existem',
         (select count(*) from tabelas t where to_regclass('public.' || t.nome) is not null) = 2
     and to_regclass('public.vw_produtos') is not null, ''

  union all
  select 2, 'As 2 tabelas têm RLS ligado',
         not exists (select 1 from tabelas t join pg_class c on c.oid = to_regclass('public.' || t.nome)
                      where not c.relrowsecurity), ''

  union all
  select 3, 'A consulta vw_produtos respeita o acesso de quem consulta (security_invoker)',
         exists (select 1 from pg_class where oid = to_regclass('public.vw_produtos')
                    and 'security_invoker=true' = any (reloptions)), ''

  union all
  select 4, 'Visitante sem login não acessa tabelas nem consulta de produtos',
         not exists (select 1 from (select nome from tabelas union all select 'vw_produtos') t
                      where has_table_privilege('anon', 'public.' || t.nome, 'SELECT')
                         or has_table_privilege('anon', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('anon', 'public.' || t.nome, 'UPDATE')
                         or has_table_privilege('anon', 'public.' || t.nome, 'DELETE')), ''

  union all
  select 5, 'Usuário logado não grava direto nas tabelas (só pelas funções)',
         not exists (select 1 from (select nome from tabelas union all select 'vw_produtos') t
                      where has_table_privilege('authenticated', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'UPDATE')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'DELETE')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'TRUNCATE')), ''

  union all
  select 6, 'Leitura dos produtos só para a Admin (o Joca não vê)',
         (select count(*) from pg_policies p join tabelas t on t.nome = p.tablename
           where p.schemaname = 'public' and p.cmd = 'SELECT' and p.qual like '%is_admin()%') = 2
     and not exists (select 1 from pg_policies p join tabelas t on t.nome = p.tablename
                      where p.schemaname = 'public' and p.cmd <> 'SELECT'), ''

  union all
  select 7, 'As 3 funções de gravação exigem a Admin',
         (select count(*) from funcoes f join pg_proc p on p.oid = to_regprocedure(f.assinatura)
           where p.prosecdef and p.prosrc like '%exigir_admin()%') = 3, ''

  union all
  select 8, 'Visitante sem login não executa as funções de produtos',
         not exists (select 1 from funcoes f where has_function_privilege('anon', f.assinatura, 'EXECUTE')), ''

  union all
  select 9, 'Pasta "produtos" do Storage: privada, até 2 MB, só JPEG, PNG e WebP',
         exists (select 1 from storage.buckets
                  where id = 'produtos' and not public and file_size_limit = 2097152
                    and allowed_mime_types @> array['image/jpeg', 'image/png', 'image/webp']
                    and cardinality(allowed_mime_types) = 3), ''

  union all
  select 10, 'Fotos: só a Admin vê, envia e apaga; nenhuma regra de sobrescrever',
         (select count(*) from pg_policies
           where schemaname = 'storage' and tablename = 'objects'
             and policyname in ('produtos_fotos_select_admin', 'produtos_fotos_insert_admin', 'produtos_fotos_delete_admin')
             and coalesce(qual, '') || coalesce(with_check, '') like '%is_admin()%'
             and coalesce(qual, '') || coalesce(with_check, '') like '%produtos%') = 3
     and not exists (select 1 from pg_policies
                      where schemaname = 'storage' and tablename = 'objects'
                        and cmd in ('UPDATE', 'ALL')
                        and coalesce(qual, '') || coalesce(with_check, '') like '%''produtos''%'), ''

  union all
  select 11, 'Cores apagadas junto com o produto; filamento ligado não pode ser excluído',
         exists (select 1 from pg_constraint where conrelid = 'public.produto_cores'::regclass and contype = 'f'
                    and confrelid = 'public.produtos'::regclass and confdeltype = 'c')
     and exists (select 1 from pg_constraint where conrelid = 'public.produto_cores'::regclass and contype = 'f'
                    and confrelid = 'public.materiais'::regclass and confdeltype = 'r'), ''

  union all
  select 12, 'Alterações nas 2 tabelas ficam na auditoria',
         (select count(*) from pg_trigger tg join pg_class c on c.oid = tg.tgrelid join tabelas t on t.nome = c.relname
           where not tg.tgisinternal and tg.tgfoid = 'public.tg_auditoria()'::regprocedure) = 2, ''

  union all
  select 13, 'Todas as cores cadastradas são filamentos',
         not exists (select 1 from public.produto_cores pc join public.materiais m on m.id = pc.material_id
                      where m.categoria <> 'FILAMENTO'),
         (select count(*) from public.produto_cores)::text || ' cor(es) cadastrada(s)'

  union all
  select 14, 'Toda foto cadastrada existe na pasta "produtos"',
         not exists (select 1 from public.produtos p where p.foto_path is not null
                        and not exists (select 1 from storage.objects o
                                         where o.bucket_id = 'produtos' and o.name = p.foto_path)),
         (select count(*) from public.produtos)::text || ' produto(s) · '
           || (select count(*) from storage.objects where bucket_id = 'produtos')::text || ' arquivo(s) na pasta'

  union all
  select 15, 'Fotos sem produto na pasta (informativo: sobras de envio interrompido)',
         true,
         (select count(*) from storage.objects o
           where o.bucket_id = 'produtos'
             and not exists (select 1 from public.produtos p where p.foto_path = o.name))::text
           || ' arquivo(s) sem produto; podem ser apagados pelo painel do Storage'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
