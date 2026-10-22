-- =====================================================================
-- Arts com Você · Verificação do Dashboard (sql/24, Etapa 10, R122, R123 e R128)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with f as (select to_regprocedure('public.dashboard(date, date)') as oid),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'A função dashboard existe',
         (select oid from f) is not null, ''

  union all
  select 2, 'Só a Admin usa: o usuário logado executa (a função exige a Admin); o visitante não',
         (select oid from f) is not null
     and has_function_privilege('authenticated', 'public.dashboard(date, date)', 'EXECUTE')
     and not has_function_privilege('anon', 'public.dashboard(date, date)', 'EXECUTE')
     and exists (select 1 from pg_proc p, f where p.oid = f.oid and p.prosecdef and p.prosrc like '%exigir_admin()%'), ''

  union all
  select 3, 'Só lê: estável e sem inserir, alterar ou apagar nada',
         exists (select 1 from pg_proc p, f where p.oid = f.oid and p.provolatile = 's'
                   and p.prosrc !~* '\m(insert|update|delete|truncate)\M'), ''

  union all
  select 4, 'Lê as mesmas consultas das outras telas (custos do pedido, perdas, alertas)',
         exists (select 1 from pg_proc p, f where p.oid = f.oid
                   and p.prosrc like '%vw_pedido_custos%' and p.prosrc like '%vw_perdas%'
                   and p.prosrc like '%vw_repasses_shopee_pendentes%' and p.prosrc like '%vw_avisos_shopee%'), ''
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
