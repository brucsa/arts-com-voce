-- =====================================================================
-- Arts com Você · Conferência ANTES da área do Joca
-- (sql/12_caixa_origem_joca.sql e sql/13_joca_comissoes.sql)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run.
--
-- Mostra, numa tabela só:
--   A. a estrutura necessária ("OK" ou "FALHOU");
--   B. cada pedido com a comissão que vai ser lançada (percentual da data do
--      pedido × (produtos − desconto), na proporção do que não foi devolvido;
--      cancelado = 0) e a situação: A receber ou Disponível;
--   C. as mudanças do percentual do Joca em Configurações;
--   D. os totais esperados depois da migração.
-- =====================================================================

with
hist as (
  select h.id, h.quando, h.valor_anterior, h.valor_novo
    from public.configuracoes_hist h where h.campo = 'comissao_joca_pct'
),
pct_em as (
  select v.id as venda_id,
         coalesce((select h.valor_anterior::numeric from hist h
                    where (h.quando at time zone 'America/Sao_Paulo')::date > v.data order by h.quando, h.id limit 1),
                  (select comissao_joca_pct from public.configuracoes limit 1), 10) as percentual
    from public.vendas v
),
prev as (
  select v.numero, v.data, v.status_pedido::text as status, v.status_financeiro::text as financeiro,
         (v.subtotal - v.desconto) as base, v.total, v.valor_devolvido, p.percentual,
         case when v.status_pedido = 'CANCELADO' or v.total <= 0 then 0::numeric(12,2)
              else round(p.percentual / 100 * (v.subtotal - v.desconto)
                         * greatest(v.total - v.valor_devolvido, 0) / v.total, 2) end as comissao
    from public.vendas v join pct_em p on p.venda_id = v.id
),
linhas (bloco, ordem, item, data, valor, resultado, detalhe) as (

  select 'A. Estrutura', 1, 'Integração Pedidos Diretos → Caixa instalada (sql/10)', null::date, null::numeric,
         case when exists (select 1 from pg_attribute where attrelid = to_regclass('public.movimentos_caixa')
                              and attname = 'recebimento_id' and not attisdropped)
              then 'OK' else 'FALHOU' end, ''
  union all
  select 'A. Estrutura', 2, 'Área do Joca ainda não instalada (tabelas e funções livres)', null, null,
         case when to_regclass('public.comissoes_joca') is null and to_regclass('public.pagamentos_joca') is null
                   and to_regclass('public.comissao_joca_pedido') is null
                   and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                                      and proname in ('joca_resumo', 'joca_extrato', 'registrar_pagamento_joca', 'migrar_comissoes_joca'))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 'A. Estrutura', 3, 'Nenhum pagamento ao Joca já lançado no Caixa', null, null,
         case when not exists (select 1 from pg_enum where enumtypid = 'public.origem_caixa'::regtype and enumlabel = 'PAGAMENTO_JOCA')
                then 'OK'
              when (select count(*) from public.movimentos_caixa where origem::text = 'PAGAMENTO_JOCA') = 0 then 'OK'
              else 'FALHOU' end, ''
  union all
  select 'A. Estrutura', 4, 'Origens do Caixa hoje (PAGAMENTO_JOCA entra pelo passo 1)', null, null, 'INFO',
         (select string_agg(enumlabel, ', ' order by enumsortorder) from pg_enum where enumtypid = 'public.origem_caixa'::regtype)

  -- B. Pedidos ----------------------------------------------------------
  union all
  select 'B. Comissão por pedido', 10 + row_number() over (order by p.numero)::int,
         'Pedido ' || public.numero_pedido_texto(p.numero) || ' · ' || lower(p.status) || ' · '
           || replace(to_char(p.percentual, 'FM990.00'), '.', ',') || '% de R$ ' || replace(to_char(p.base, 'FM9999999990.00'), '.', ',')
           || case when p.valor_devolvido > 0 then ' (devolvido R$ ' || replace(to_char(p.valor_devolvido, 'FM9999999990.00'), '.', ',') || ')' else '' end,
         p.data, p.comissao,
         case when p.status = 'CANCELADO' then 'Cancelado: sem comissão'
              when p.comissao = 0 then 'Sem comissão'
              when p.financeiro = 'RECEBIDO' then 'Disponível'
              else 'A receber' end,
         ''
    from prev p

  -- C. Percentual -------------------------------------------------------
  union all
  select 'C. Percentual do Joca', 500, 'Percentual atual em Configurações', null,
         (select comissao_joca_pct from public.configuracoes limit 1), 'INFO', ''
  union all
  select 'C. Percentual do Joca', 500 + row_number() over (order by h.quando, h.id)::int,
         'Mudança de ' || coalesce(h.valor_anterior, '—') || '% para ' || coalesce(h.valor_novo, '—') || '%',
         (h.quando at time zone 'America/Sao_Paulo')::date, null, 'INFO', 'Vale para pedidos a partir desta data'
    from hist h

  -- D. Totais -----------------------------------------------------------
  union all
  select 'D. Totais', 901, 'Comissão A receber (pedidos ainda não todo recebidos)', null,
         coalesce((select sum(comissao) from prev where financeiro = 'A_RECEBER'), 0), 'INFO', ''
  union all
  select 'D. Totais', 902, 'Comissão Disponível (pedidos todo recebidos)', null,
         coalesce((select sum(comissao) from prev where financeiro = 'RECEBIDO'), 0), 'INFO', ''
  union all
  select 'D. Totais', 903, 'Já pago ao Joca', null, 0, 'INFO', 'Nenhum pagamento antes da instalação'
)
select bloco, item, to_char(data, 'DD/MM/YYYY') as data,
       case when valor is null then '' else replace(to_char(valor, 'FM9999999990.00'), '.', ',') end as valor,
       resultado, detalhe
  from linhas
 order by ordem;
