-- =====================================================================
-- Arts com Você · Verificação dos Relatórios (sql/25, Etapa 11, R129–R131)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with f as (select to_regprocedure('public.relatorio_canais(date, date)') as oid),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'A função relatorio_canais existe',
         (select oid from f) is not null, ''

  union all
  select 2, 'Só a Admin usa: o usuário logado executa (a função exige a Admin); o visitante não',
         (select oid from f) is not null
     and has_function_privilege('authenticated', 'public.relatorio_canais(date, date)', 'EXECUTE')
     and not has_function_privilege('anon', 'public.relatorio_canais(date, date)', 'EXECUTE')
     and exists (select 1 from pg_proc p, f where p.oid = f.oid and p.prosecdef and p.prosrc like '%exigir_admin()%'), ''

  union all
  select 3, 'Só lê: estável e sem inserir, alterar ou apagar nada',
         exists (select 1 from pg_proc p, f where p.oid = f.oid and p.provolatile = 's'
                   and p.prosrc !~* '\m(insert|update|delete|truncate)\M'), ''

  union all
  select 4, 'Usa os mesmos custos do pedido do Início (vw_pedido_custos)',
         exists (select 1 from pg_proc p, f where p.oid = f.oid and p.prosrc like '%vw_pedido_custos%'), ''
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
