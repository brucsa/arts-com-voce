-- =====================================================================
-- Arts com Você · Conferência ANTES do Relatórios (sql/25)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run. Esperado: nenhum "FALHOU".
-- =====================================================================

with linhas (ordem, item, resultado, detalhe) as (
  select 1, 'Lotes anteriores instalados (produção sql/16, repasses sql/19, variações sql/22)',
         case when to_regclass('public.vw_pedido_custos') is not null
                   and to_regclass('public.repasses_shopee') is not null and to_regclass('public.produto_variacoes') is not null
              then 'OK' else 'FALHOU' end, ''
  union all
  select 2, 'Relatórios ainda não instalados',
         case when not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'relatorio_canais')
              then 'OK' else 'FALHOU' end, ''
  union all
  select 10, 'Pedidos e Caixa (nada disso muda)', 'INFO',
         (select count(*) from public.vendas)::text || ' pedido(s) · '
         || (select count(*) from public.movimentos_caixa)::text || ' movimento(s) no Caixa'
)
select ordem, item, resultado, detalhe from linhas order by ordem;
