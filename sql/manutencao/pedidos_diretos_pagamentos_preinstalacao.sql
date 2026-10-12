-- =====================================================================
-- Arts com Você · Conferência ANTES de instalar o P1-b dos Pedidos
-- Diretos (pagamentos e devoluções, sql/08_pedidos_diretos_pagamentos.sql)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run.
-- Resultado esperado: todas as linhas "OK".
-- =====================================================================

with checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'P1-a instalado: 4 tabelas, consulta vw_pedidos e 3 tipos',
         to_regclass('public.clientes') is not null and to_regclass('public.vendas') is not null
     and to_regclass('public.itens_venda') is not null and to_regclass('public.historico_status_pedido') is not null
     and to_regclass('public.vw_pedidos') is not null
     and to_regtype('public.status_pedido_direto') is not null and to_regtype('public.origem_pedido_direto') is not null
     and to_regtype('public.status_financeiro_pedido') is not null, ''

  union all
  select 2, 'Funções do P1-a que serão atualizadas existem, na versão do P1-a',
         to_regprocedure('public.recalcular_pedido(uuid)') is not null
     and to_regprocedure('public.salvar_pedido(uuid, date, uuid, text, date, text, numeric, numeric, text, jsonb)') is not null
     and exists (select 1 from pg_proc where oid = to_regprocedure('public.conferir_pedido(uuid)')
                    and prosrc like '%ainda não existem nesta etapa%'), ''

  union all
  select 3, 'Nomes do P1-b livres (tabelas, tipo e funções)',
         to_regclass('public.recebimentos_venda') is null and to_regclass('public.devolucoes_venda') is null
     and to_regtype('public.situacao_lancamento_pedido') is null
     and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                        and proname in ('registrar_recebimento', 'registrar_devolucao', 'estornar_recebimento',
                                        'estornar_devolucao', 'tg_lancamentos_pedido_protege', 'tg_lancamentos_pedido_conferir')),
         coalesce((select 'Já existem: ' || string_agg(proname, ', ') from pg_proc
                    where pronamespace = 'public'::regnamespace
                      and proname in ('registrar_recebimento', 'registrar_devolucao', 'estornar_recebimento',
                                      'estornar_devolucao', 'tg_lancamentos_pedido_protege', 'tg_lancamentos_pedido_conferir')), '')

  union all
  select 4, 'Nenhum pedido com recebido ou devolvido preenchido (estado do P1-a)',
         not exists (select 1 from public.vendas where valor_recebido <> 0 or valor_devolvido <> 0), ''

  union all
  select 5, 'Funções e tipo usados existem: exigir_admin, is_admin, hoje, tg_auditoria, tg_updated_at, forma_pagamento',
         to_regprocedure('public.exigir_admin()') is not null and to_regprocedure('public.is_admin()') is not null
     and to_regprocedure('public.hoje()') is not null and to_regprocedure('public.tg_auditoria()') is not null
     and to_regprocedure('public.tg_updated_at()') is not null and to_regtype('public.forma_pagamento') is not null, ''

  union all
  select 6, 'Informativo: pedidos, clientes e itens cadastrados hoje',
         true,
         (select count(*) from public.vendas)::text || ' pedido(s) · '
           || (select count(*) from public.clientes)::text || ' cliente(s) · '
           || (select count(*) from public.itens_venda)::text || ' item(ns)'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
