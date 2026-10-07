-- =====================================================================
-- Arts com Você — Verificação do banco (pode rodar quantas vezes quiser)
--
-- Supabase → SQL Editor → colar → Run.
-- Resultado esperado: todas as linhas com "OK".
-- Não altera nada no banco: só consulta.
-- =====================================================================

with checagens (ordem, verificacao, passou, detalhe) as (

  -- Segurança geral ----------------------------------------------------
  select 1, 'Todas as tabelas do sistema têm RLS ligado',
         not exists (
           select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
         coalesce((
           select 'Sem RLS: ' || string_agg(c.relname, ', ')
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), '')

  union all
  select 2, 'Visitante sem login não acessa nenhuma tabela',
         not exists (
           select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r'
              and (has_table_privilege('anon', c.oid, 'SELECT')
                or has_table_privilege('anon', c.oid, 'INSERT')
                or has_table_privilege('anon', c.oid, 'UPDATE')
                or has_table_privilege('anon', c.oid, 'DELETE'))),
         coalesce((
           select 'Acessíveis: ' || string_agg(c.relname, ', ')
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r'
              and has_table_privilege('anon', c.oid, 'SELECT')), '')

  union all
  select 3, 'Visitante sem login não executa as funções de papel',
         not has_function_privilege('anon', 'public.is_admin()', 'EXECUTE')
     and not has_function_privilege('anon', 'public.is_joca()', 'EXECUTE')
     and not has_function_privilege('anon', 'public.papel_atual()', 'EXECUTE'),
         ''

  -- Perfis ---------------------------------------------------------------
  union all
  select 4, 'Usuário logado só lê e edita perfis (não cria nem apaga)',
         has_table_privilege('authenticated', 'public.perfis', 'SELECT')
     and has_table_privilege('authenticated', 'public.perfis', 'UPDATE')
     and not has_table_privilege('authenticated', 'public.perfis', 'INSERT')
     and not has_table_privilege('authenticated', 'public.perfis', 'DELETE'),
         ''

  union all
  select 5, 'Regras de acesso dos perfis existem (2)',
         (select count(*) from pg_policies where schemaname = 'public' and tablename = 'perfis') = 2,
         (select count(*)::text || ' encontradas' from pg_policies where schemaname = 'public' and tablename = 'perfis')

  union all
  select 6, 'Proteção da conta Admin ativa',
         exists (select 1 from pg_trigger where tgname = 'trg_perfis_protege_admin' and not tgisinternal),
         ''

  union all
  select 7, 'Existe exatamente 1 Admin ativa',
         (select count(*) from public.perfis where papel = 'ADMIN' and ativo) = 1,
         (select coalesce(string_agg(nome, ', '), 'nenhuma') from public.perfis where papel = 'ADMIN' and ativo)

  union all
  select 8, 'Existe exatamente 1 Joca ativo',
         (select count(*) from public.perfis where papel = 'JOCA' and ativo) = 1,
         (select coalesce(string_agg(nome, ', '), 'nenhum') from public.perfis where papel = 'JOCA' and ativo)

  union all
  select 9, 'E-mails das duas contas confirmados',
         not exists (
           select 1 from public.perfis p join auth.users u on u.id = p.id
            where u.email_confirmed_at is null),
         coalesce((
           select 'Sem confirmação: ' || string_agg(u.email, ', ')
             from public.perfis p join auth.users u on u.id = p.id
            where u.email_confirmed_at is null), '')

  union all
  select 10, 'Nenhum usuário do Auth sem perfil',
         not exists (
           select 1 from auth.users u where not exists (select 1 from public.perfis p where p.id = u.id)),
         coalesce((
           select 'Sem perfil: ' || string_agg(u.email, ', ')
             from auth.users u where not exists (select 1 from public.perfis p where p.id = u.id)), '')

  -- Auditoria -----------------------------------------------------------
  union all
  select 11, 'Auditoria: usuário logado só lê (ninguém grava pela API)',
         has_table_privilege('authenticated', 'public.auditoria', 'SELECT')
     and not has_table_privilege('authenticated', 'public.auditoria', 'INSERT')
     and not has_table_privilege('authenticated', 'public.auditoria', 'UPDATE')
     and not has_table_privilege('authenticated', 'public.auditoria', 'DELETE'),
         ''

  union all
  select 12, 'Auditoria registrando alterações de perfis',
         exists (select 1 from pg_trigger where tgname = 'trg_perfis_auditoria' and not tgisinternal)
     and exists (select 1 from public.auditoria where tabela = 'perfis'),
         (select count(*)::text || ' registros de perfis' from public.auditoria where tabela = 'perfis')
)
select ordem as "#",
       verificacao as "Verificação",
       case when passou then 'OK' else 'FALHOU' end as "Resultado",
       nullif(detalhe, '') as "Detalhe"
  from checagens
 order by ordem;
