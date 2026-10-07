-- =====================================================================
-- Arts com Você — Manutenção única, antes do uso real do financeiro
-- Limpeza dos testes da Etapa 2 · PARTE 1: PRÉVIA (só leitura)
--
-- Não altera nada. Mostra o que a PARTE 2 vai apagar e confere se é
-- seguro apagar. Rode, confira a lista e só então rode a PARTE 2.
-- =====================================================================

with
gastos as (
  select l.id, l.data, l.descricao, l.valor, l.status
    from public.lancamentos l
),
pagamentos as (
  select p.id, p.lancamento_id, p.data, p.valor, p.status
    from public.pagamentos_lancamento p
),
movimentos as (
  select m.id, m.seq, m.data, m.tipo, m.origem, m.valor, m.descricao, m.obs,
         m.pagamento_id, m.movimento_estornado_id
    from public.movimentos_caixa m
),
-- Movimentos de aporte/retirada que NÃO foram estornados seriam dinheiro real: bloqueiam a limpeza.
aporte_retirada_sem_estorno as (
  select m.* from movimentos m
   where m.origem in ('APORTE', 'RETIRADA')
     and not exists (select 1 from movimentos e where e.movimento_estornado_id = m.id)
)
select 'Resumo' as bloco, 1 as ordem,
       'Gastos: ' || (select count(*) from gastos)
       || ' · Pagamentos: ' || (select count(*) from pagamentos)
       || ' · Movimentos de caixa: ' || (select count(*) from movimentos) as detalhe
union all
select 'Resumo', 2,
       'Saldo atual: R$ ' || replace(to_char(coalesce((select saldo_atual from public.vw_caixa_resumo), 0), 'FM999999990.00'), '.', ',')
       || ' · A pagar: R$ ' || replace(to_char(coalesce((select a_pagar from public.vw_caixa_resumo), 0), 'FM999999990.00'), '.', ',')
union all
select 'Segurança', 3,
       case when exists (select 1 from gastos where descricao not ilike '%TESTE%' or status <> 'CANCELADO')
            then 'BLOQUEADO: existe gasto que não é TESTE cancelado → ' ||
                 (select string_agg(descricao || ' (' || status || ')', ', ') from gastos
                   where descricao not ilike '%TESTE%' or status <> 'CANCELADO')
            else 'OK: todos os gastos são de TESTE e estão cancelados' end
union all
select 'Segurança', 4,
       case when exists (select 1 from aporte_retirada_sem_estorno)
            then 'BLOQUEADO: existe aporte/retirada sem estorno (pode ser dinheiro real) → ' ||
                 (select string_agg(origem || ' de R$ ' || replace(to_char(valor, 'FM999999990.00'), '.', ',') || ' em ' || to_char(data, 'DD/MM/YYYY'), ', ') from aporte_retirada_sem_estorno)
            else 'OK: todo aporte/retirada foi estornado' end
union all
select 'Segurança', 5,
       case when coalesce((select saldo_atual from public.vw_caixa_resumo), 0) <> 0
              or coalesce((select a_pagar from public.vw_caixa_resumo), 0) <> 0
            then 'BLOQUEADO: o caixa não está zerado'
            else 'OK: saldo e A pagar em R$ 0,00' end
union all
select 'Será apagado: gasto', 10 + row_number() over (order by data, descricao),
       to_char(data, 'DD/MM/YYYY') || ' · ' || descricao || ' · R$ ' || replace(to_char(valor, 'FM999999990.00'), '.', ',') || ' · ' || status
  from gastos
union all
select 'Será apagado: movimento', 100 + row_number() over (order by seq),
       to_char(data, 'DD/MM/YYYY') || ' · ' || origem || ' · ' || tipo || ' · R$ ' || replace(to_char(valor, 'FM999999990.00'), '.', ',') || ' · ' || descricao
       || coalesce(' · ' || obs, '')
  from movimentos
order by ordem;
