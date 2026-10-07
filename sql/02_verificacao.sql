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

  -- Etapa 1: Configurações ---------------------------------------------
  -- (as linhas abaixo só passam depois de rodar sql/03_configuracoes.sql)
  union all
  select 13, 'Configurações: todas as regras de acesso exigem a Admin',
         (select count(*) from pg_policies
           where schemaname = 'public'
             and tablename in ('configuracoes', 'configuracoes_hist', 'canais',
                               'categorias_lanc', 'categorias_produto', 'materiais')) = 7
     and not exists (
           select 1 from pg_policies
            where schemaname = 'public'
              and tablename in ('configuracoes', 'configuracoes_hist', 'canais',
                                'categorias_lanc', 'categorias_produto', 'materiais')
              and coalesce(qual, '') || coalesce(with_check, '') not like '%is_admin()%'),
         (select count(*)::text || ' regras encontradas (esperado 7)' from pg_policies
           where schemaname = 'public'
             and tablename in ('configuracoes', 'configuracoes_hist', 'canais',
                               'categorias_lanc', 'categorias_produto', 'materiais'))

  union all
  select 14, 'Parâmetros: existe exatamente 1 linha',
         case when to_regclass('public.configuracoes') is null then false
              else (xpath('/row/c/text()',
                     query_to_xml('select count(*) as c from public.configuracoes', false, true, '')))[1]::text = '1'
         end,
         case when to_regclass('public.configuracoes') is null then 'Rode sql/03_configuracoes.sql' else '' end

  union all
  select 15, 'Parâmetros e histórico: ninguém cria, apaga ou grava histórico pela API',
         case when to_regclass('public.configuracoes_hist') is null then false
              else has_table_privilege('authenticated', 'public.configuracoes_hist', 'SELECT')
               and not has_table_privilege('authenticated', 'public.configuracoes_hist', 'INSERT')
               and not has_table_privilege('authenticated', 'public.configuracoes_hist', 'UPDATE')
               and not has_table_privilege('authenticated', 'public.configuracoes_hist', 'DELETE')
               and not has_table_privilege('authenticated', 'public.configuracoes', 'INSERT')
               and not has_table_privilege('authenticated', 'public.configuracoes', 'DELETE')
         end,
         case when to_regclass('public.configuracoes_hist') is null then 'Rode sql/03_configuracoes.sql' else '' end

  union all
  select 16, 'Sem categoria de energia elétrica (R35)',
         case when to_regclass('public.categorias_lanc') is null then false
              else (xpath('/row/c/text()',
                     query_to_xml($q$select count(*) as c from public.categorias_lanc
                                    where lower(nome) like '%energia%' or lower(nome) like '%luz%'$q$,
                                  false, true, '')))[1]::text = '0'
         end,
         case when to_regclass('public.categorias_lanc') is null then 'Rode sql/03_configuracoes.sql' else '' end
  -- Etapa 2: Caixa e gastos --------------------------------------------
  -- (as linhas abaixo só passam depois de rodar sql/04_caixa_gastos.sql)
  union all
  select 17, 'Caixa e gastos: só a Admin lê',
         (select count(*) from pg_policies
           where schemaname = 'public'
             and tablename in ('lancamentos', 'pagamentos_lancamento', 'movimentos_caixa')
             and cmd = 'SELECT' and qual like '%is_admin()%') = 3,
         case when to_regclass('public.movimentos_caixa') is null then 'Rode sql/04_caixa_gastos.sql' else '' end

  union all
  select 18, 'Caixa e gastos: ninguém grava direto nas tabelas (só pelas funções)',
         case when to_regclass('public.movimentos_caixa') is null then false
              else not exists (
                select 1 from unnest(array['public.lancamentos', 'public.pagamentos_lancamento', 'public.movimentos_caixa']) t
                 where has_table_privilege('authenticated', t, 'INSERT')
                    or has_table_privilege('authenticated', t, 'UPDATE')
                    or has_table_privilege('authenticated', t, 'DELETE'))
         end,
         ''

  union all
  select 19, 'Funções de caixa: visitante não executa; internas fechadas',
         case when to_regprocedure('public.registrar_gasto(date, text, uuid, numeric, public.forma_pagamento, text, text, boolean, date)') is null then false
              else not has_function_privilege('anon', 'public.registrar_gasto(date, text, uuid, numeric, public.forma_pagamento, text, text, boolean, date)', 'EXECUTE')
               and not has_function_privilege('anon', 'public.registrar_movimento(public.origem_caixa, date, numeric, text)', 'EXECUTE')
               and not has_function_privilege('authenticated', 'public.inserir_pagamento(uuid, date, numeric)', 'EXECUTE')
               and not has_function_privilege('authenticated', 'public.estornar_pagamento_interno(uuid, text, date)', 'EXECUTE')
         end,
         ''

  union all
  select 20, 'Caixa consistente: cada pagamento tem sua saída e cada estorno sua entrada',
         case when to_regclass('public.movimentos_caixa') is null then false
              else (xpath('/row/c/text()', query_to_xml($q$
                select count(*) as c from public.pagamentos_lancamento p
                 where (select count(*) from public.movimentos_caixa m
                         where m.pagamento_id = p.id and m.origem = 'PAGAMENTO_GASTO' and m.valor = p.valor) <> 1
                    or (p.status = 'CANCELADO' and not exists (
                          select 1 from public.movimentos_caixa m join public.movimentos_caixa e on e.movimento_estornado_id = m.id
                           where m.pagamento_id = p.id))
                    or (select coalesce(sum(valor), 0) from public.pagamentos_lancamento x
                         where x.lancamento_id = p.lancamento_id and x.status = 'ATIVO')
                       > (select valor from public.lancamentos l where l.id = p.lancamento_id)
              $q$, false, true, '')))[1]::text = '0'
         end,
         ''
)
select ordem as "#",
       verificacao as "Verificação",
       case when passou then 'OK' else 'FALHOU' end as "Resultado",
       nullif(detalhe, '') as "Detalhe"
  from checagens
 order by ordem;
