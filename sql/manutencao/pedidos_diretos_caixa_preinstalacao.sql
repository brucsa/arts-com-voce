-- =====================================================================
-- Arts com Você · Conferência ANTES da integração Pedidos Diretos → Caixa
-- (sql/09_caixa_origens_pedidos.sql e sql/10_pedidos_diretos_caixa.sql)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run.
--
-- Mostra, numa tabela só:
--   A. a estrutura necessária (resultado "OK" ou "FALHOU");
--   B. cada recebimento e cada devolução já registrados, com a data real
--      que vai para o Caixa (só os ATIVOS entram);
--   C. os aportes registrados desde o primeiro recebimento, para conferir
--      se algum deles foi, na verdade, dinheiro de pedido (não pode ser);
--   D. o saldo do Caixa hoje e o saldo esperado depois da migração.
-- =====================================================================

with
lanc as (
  select 'Recebimento'::text as tipo, v.numero, c.nome as cliente, r.data, r.valor, r.forma_pagamento::text as forma,
         r.situacao::text as situacao, r.confirmado_em as registrado_em
    from public.recebimentos_venda r join public.vendas v on v.id = r.venda_id join public.clientes c on c.id = v.cliente_id
  union all
  select 'Devolução', v.numero, c.nome, d.data, d.valor, d.forma_pagamento::text, d.situacao::text, d.created_at
    from public.devolucoes_venda d join public.vendas v on v.id = d.venda_id join public.clientes c on c.id = v.cliente_id
),
primeiro as (select min(data) as data from lanc),
totais as (
  select coalesce(sum(valor) filter (where tipo = 'Recebimento' and situacao = 'ATIVO'), 0) as receb,
         coalesce(sum(valor) filter (where tipo = 'Devolução' and situacao = 'ATIVO'), 0) as devol
    from lanc
),
saldo as (select coalesce(sum(case when tipo = 'ENTRADA' then valor else -valor end), 0) as atual from public.movimentos_caixa),
linhas (bloco, ordem, item, data, valor, resultado, detalhe) as (

  -- A. Estrutura -------------------------------------------------------
  select 'A. Estrutura', 1, 'P1-a e P1-b instalados (pedidos, recebimentos e devoluções)', null::date, null::numeric,
         case when to_regclass('public.vendas') is not null and to_regclass('public.recebimentos_venda') is not null
                   and to_regclass('public.devolucoes_venda') is not null then 'OK' else 'FALHOU' end, ''
  union all
  select 'A. Estrutura', 2, 'Funções do P1-b na versão esperada (antes da integração)', null, null,
         case when to_regprocedure('public.registrar_recebimento(uuid, date, numeric, text, text, boolean)') is not null
                   and to_regprocedure('public.registrar_devolucao(uuid, date, numeric, text, text)') is not null
                   and exists (select 1 from pg_proc where oid = to_regprocedure('public.conferir_pedido(uuid)')
                                  and prosrc like '%recebimentos_venda%' and prosrc not like '%movimentos_caixa%')
              then 'OK' else 'FALHOU' end, ''
  union all
  select 'A. Estrutura', 3, 'Integração ainda não instalada (colunas e funções livres)', null, null,
         case when not exists (select 1 from pg_attribute where attrelid = 'public.movimentos_caixa'::regclass
                                  and attname in ('recebimento_id', 'devolucao_id') and not attisdropped)
                   and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                                      and proname in ('migrar_pedidos_para_caixa', 'tg_movimentos_caixa_conferir_pedido', 'numero_pedido_texto'))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 'A. Estrutura', 4, 'Origens do Caixa hoje (RECEBIMENTO e REEMBOLSO entram pelo passo 1)', null, null, 'INFO',
         (select string_agg(enumlabel, ', ' order by enumsortorder) from pg_enum where enumtypid = 'public.origem_caixa'::regtype)
  union all
  select 'A. Estrutura', 5, 'Nenhum movimento do Caixa já ligado a pedido', null, null,
         case when not exists (select 1 from pg_enum where enumtypid = 'public.origem_caixa'::regtype and enumlabel in ('RECEBIMENTO', 'REEMBOLSO'))
                then 'OK'
              when (select count(*) from public.movimentos_caixa where origem::text in ('RECEBIMENTO', 'REEMBOLSO')) = 0 then 'OK'
              else 'FALHOU' end, ''
  union all
  select 'A. Estrutura', 6, 'Datas dos lançamentos ativos entre a data do pedido e hoje', null, null,
         case when not exists (
                select 1 from public.recebimentos_venda r join public.vendas v on v.id = r.venda_id
                 where r.situacao = 'ATIVO' and (r.data < v.data or r.data > public.hoje())
                union all
                select 1 from public.devolucoes_venda d join public.vendas v on v.id = d.venda_id
                 where d.situacao = 'ATIVO' and (d.data < v.data or d.data > public.hoje()))
              then 'OK' else 'FALHOU' end, ''

  -- B. Lançamentos que vão para o Caixa ----------------------------------
  union all
  select 'B. Lançamentos', 10 + row_number() over (order by l.data, l.registrado_em)::int,
         l.tipo || ' · pedido ' || '#' || lpad(l.numero::text, greatest(4, length(l.numero::text)), '0') || ' · ' || l.cliente,
         l.data, l.valor,
         case when l.situacao = 'ATIVO' then (case when l.tipo = 'Recebimento' then 'ENTRA no Caixa' else 'SAI do Caixa' end)
              else 'Estornado: não vai para o Caixa' end,
         'Forma: ' || l.forma || ' · registrado em ' || to_char(l.registrado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
    from lanc l

  -- C. Aportes desde o primeiro recebimento -----------------------------
  union all
  select 'C. Aportes desde o 1º lançamento', 100 + row_number() over (order by m.data, m.seq)::int,
         'Aporte' || case when exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id) then ' (estornado)' else '' end,
         m.data, m.valor, 'CONFERIR', coalesce(m.obs, '')
    from public.movimentos_caixa m, primeiro p
   where m.origem = 'APORTE' and p.data is not null and m.data >= p.data
  union all
  select 'C. Aportes desde o 1º lançamento', 199,
         (select count(*) from public.movimentos_caixa m, primeiro p where m.origem = 'APORTE' and m.data >= p.data)::text
           || ' aporte(s) desde o primeiro lançamento de pedido', null, null,
         'INFO', 'Se algum aporte foi dinheiro de pedido, avise antes da migração'

  -- D. Totais e saldo ----------------------------------------------------
  union all
  select 'D. Totais', 201, 'Recebimentos ATIVOS (entram no Caixa)', null, t.receb, 'INFO', '' from totais t
  union all
  select 'D. Totais', 202, 'Devoluções ATIVAS (saem do Caixa)', null, t.devol, 'INFO', '' from totais t
  union all
  select 'D. Totais', 203, 'Saldo do Caixa hoje', null, s.atual, 'INFO', '' from saldo s
  union all
  select 'D. Totais', 204, 'Saldo do Caixa esperado depois da migração', null, s.atual + t.receb - t.devol, 'INFO',
         'Saldo de hoje + recebimentos ativos − devoluções ativas' from saldo s, totais t
)
select bloco, item, to_char(data, 'DD/MM/YYYY') as data,
       case when valor is null then '' else replace(to_char(valor, 'FM9999999990.00'), '.', ',') end as valor,
       resultado, detalhe
  from linhas
 order by ordem;
