-- =====================================================================
-- Arts com Você · Verificação dos Pedidos Diretos · Lote P1-b
-- (pagamentos e devoluções: R83, R84, C1, F1, F2, F3)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- Rodar junto com sql/pedidos_diretos_verificacao.sql (P1-a).
-- =====================================================================

with tabelas(nome) as (
  values ('recebimentos_venda'), ('devolucoes_venda')
),
funcoes_admin(assinatura) as (
  values ('public.registrar_recebimento(uuid, date, numeric, text, text, boolean)'),
         ('public.registrar_devolucao(uuid, date, numeric, text, text)'),
         ('public.estornar_recebimento(uuid, text)'),
         ('public.estornar_devolucao(uuid, text)')
),
funcoes_internas(assinatura) as (
  values ('public.tg_lancamentos_pedido_protege()'),
         ('public.tg_lancamentos_pedido_conferir()'),
         ('public.recalcular_pedido(uuid)'),
         ('public.conferir_pedido(uuid)')
),
somas as (
  select v.id, v.numero, v.data, v.status_pedido, v.total, v.valor_recebido, v.valor_devolvido, v.saldo, v.status_financeiro,
         coalesce((select sum(r.valor) from public.recebimentos_venda r where r.venda_id = v.id and r.situacao = 'ATIVO'), 0) as r,
         coalesce((select sum(d.valor) from public.devolucoes_venda d where d.venda_id = v.id and d.situacao = 'ATIVO'), 0) as d
    from public.vendas v
),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'As 2 tabelas de lançamentos existem, com o tipo ATIVO/ESTORNADO',
         (select count(*) from tabelas t where to_regclass('public.' || t.nome) is not null) = 2
     and (select array_agg(e.enumlabel order by e.enumsortorder) from pg_enum e
           where e.enumtypid = to_regtype('public.situacao_lancamento_pedido')) = array['ATIVO', 'ESTORNADO']::name[], ''

  union all
  select 2, 'As 2 tabelas têm RLS ligado e leitura só para a Admin (o Joca não vê)',
         not exists (select 1 from tabelas t join pg_class c on c.oid = to_regclass('public.' || t.nome)
                      where not c.relrowsecurity)
     and (select count(*) from pg_policies p join tabelas t on t.nome = p.tablename
           where p.schemaname = 'public' and p.cmd = 'SELECT' and p.qual like '%is_admin()%') = 2
     and not exists (select 1 from pg_policies p join tabelas t on t.nome = p.tablename
                      where p.schemaname = 'public' and (p.cmd <> 'SELECT' or p.qual not like '%is_admin()%')), ''

  union all
  select 3, 'Visitante não acessa; usuário logado não grava direto',
         not exists (select 1 from tabelas t
                      where has_table_privilege('anon', 'public.' || t.nome, 'SELECT')
                         or has_table_privilege('anon', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'UPDATE')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'DELETE')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'TRUNCATE')), ''

  union all
  select 4, 'As 4 funções financeiras exigem a Admin e o visitante não executa',
         (select count(*) from funcoes_admin f join pg_proc p on p.oid = to_regprocedure(f.assinatura)
           where p.prosecdef and p.prosrc like '%exigir_admin()%') = 4
     and not exists (select 1 from funcoes_admin f where has_function_privilege('anon', f.assinatura, 'EXECUTE')), ''

  union all
  select 5, 'Funções internas fechadas (nem o usuário logado executa)',
         (select count(*) from funcoes_internas f where to_regprocedure(f.assinatura) is not null) = 4
     and not exists (select 1 from funcoes_internas f
                      where has_function_privilege('authenticated', f.assinatura, 'EXECUTE')
                         or has_function_privilege('anon', f.assinatura, 'EXECUTE')), ''

  union all
  select 6, 'Funções do P1-a atualizadas para somar os lançamentos ativos',
         exists (select 1 from pg_proc where oid = to_regprocedure('public.recalcular_pedido(uuid)')
                    and prosrc like '%recebimentos_venda%' and prosrc like '%devolucoes_venda%')
     and exists (select 1 from pg_proc where oid = to_regprocedure('public.conferir_pedido(uuid)')
                    and prosrc like '%recebimentos_venda%' and prosrc not like '%ainda não existem nesta etapa%')
     and exists (select 1 from pg_proc
                  where oid = to_regprocedure('public.salvar_pedido(uuid, date, uuid, text, date, text, numeric, numeric, text, jsonb)')
                    and prosrc like '%v_primeiro%'), ''

  union all
  select 7, 'Lançamentos ligados ao pedido sem apagar em cascata',
         (select count(*) from pg_constraint c join tabelas t on c.conrelid = to_regclass('public.' || t.nome)
           where c.contype = 'f' and c.confrelid = 'public.vendas'::regclass and c.confdeltype = 'r') = 2, ''

  union all
  select 8, 'Auditoria, proteção (sem excluir; só ATIVO → ESTORNADO) e conferência no fim da gravação ligadas',
         (select count(*) from pg_trigger tg join tabelas t on tg.tgrelid = to_regclass('public.' || t.nome)
           where not tg.tgisinternal and tg.tgenabled <> 'D'
             and tg.tgfoid in ('public.tg_auditoria()'::regprocedure, 'public.tg_lancamentos_pedido_protege()'::regprocedure)) = 4
     and (select count(*) from pg_trigger tg join tabelas t on tg.tgrelid = to_regclass('public.' || t.nome)
           where tg.tgenabled <> 'D' and tg.tgdeferrable and tg.tginitdeferred
             and tg.tgfoid = 'public.tg_lancamentos_pedido_conferir()'::regprocedure) = 2, ''

  union all
  select 9, 'Recebido e devolvido de cada pedido = soma dos lançamentos ATIVOS',
         not exists (select 1 from somas where valor_recebido <> r or valor_devolvido <> d),
         (select count(*) from public.recebimentos_venda)::text || ' recebimento(s) · '
           || (select count(*) from public.devolucoes_venda)::text || ' devolução(ões)'

  union all
  select 10, 'C1: líquido (R − D) ≥ 0 e, fora do cancelado, ≤ total',
         not exists (select 1 from somas where r - d < 0 or (status_pedido <> 'CANCELADO' and r - d > total)), ''

  union all
  select 11, 'Saldo e status financeiro pelas fórmulas da v1.4 (F1, F2)',
         not exists (select 1 from somas
                      where saldo <> case when status_pedido = 'CANCELADO' or total = 0 then 0 else greatest(total - r, 0) end
                         or status_financeiro::text <> case when status_pedido = 'CANCELADO' then 'CANCELADO'
                                                            when total = 0 then 'SEM_COBRANCA'
                                                            when r >= total then 'RECEBIDO'
                                                            else 'A_RECEBER' end), ''

  union all
  select 12, 'Datas dos lançamentos ativos entre a data do pedido e hoje',
         not exists (select 1 from (select venda_id, data from public.recebimentos_venda where situacao = 'ATIVO'
                                    union all
                                    select venda_id, data from public.devolucoes_venda where situacao = 'ATIVO') l
                       join public.vendas v on v.id = l.venda_id
                      where l.data < v.data or l.data > public.hoje()), ''

  union all
  select 13, 'Todo recebimento tem a confirmação registrada; todo estorno tem data e motivo',
         not exists (select 1 from public.recebimentos_venda where confirmado_em is null or confirmado_por is null)
     and not exists (select 1 from public.recebimentos_venda where situacao = 'ESTORNADO' and (estornado_em is null or motivo_estorno is null))
     and not exists (select 1 from public.devolucoes_venda where situacao = 'ESTORNADO' and (estornado_em is null or motivo_estorno is null)), ''

  union all
  select 14, 'Nenhum recebimento ativo registrado depois do cancelamento do pedido (R84)',
         not exists (select 1 from public.recebimentos_venda r join public.vendas v on v.id = r.venda_id
                      where v.status_pedido = 'CANCELADO' and r.situacao = 'ATIVO' and r.confirmado_em > v.cancelado_em), ''
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
