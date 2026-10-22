-- =====================================================================
-- Arts com Você · Conferência ANTES dos repasses da Shopee (sql/18 e 19)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run. Esperado: nenhum "FALHOU".
-- =====================================================================

with linhas (ordem, item, resultado, detalhe) as (
  select 1, 'Vendas da Shopee (sql/17, Lote C1) instaladas',
         case when exists (select 1 from pg_attribute where attrelid = 'public.vendas'::regclass
                             and attname = 'shopee_pedido_ref' and not attisdropped)
                   and exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'salvar_venda_shopee')
              then 'OK' else 'FALHOU' end, ''
  union all
  select 2, 'Repasses da Shopee ainda não instalados',
         case when to_regclass('public.repasses_shopee') is null and to_regclass('public.avisos_shopee_dispensados') is null
                   and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                                      and proname in ('confirmar_repasse_shopee', 'estornar_repasse_shopee', 'dispensar_aviso_shopee'))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 3, 'Nenhum movimento do Caixa com a origem Repasse Shopee',
         case when not exists (select 1 from public.movimentos_caixa where origem::text = 'REPASSE_SHOPEE')
              then 'OK' else 'FALHOU' end, ''
  union all
  select 4, 'Nenhuma venda da Shopee com valor recebido ou devolvido',
         case when not exists (select 1 from public.vendas where to_jsonb(vendas) ->> 'shopee_pedido_ref' is not null
                                  and (valor_recebido <> 0 or valor_devolvido <> 0))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 10, 'Vendas da Shopee registradas', 'INFO',
         (select count(*) from public.vendas where to_jsonb(vendas) ->> 'shopee_pedido_ref' is not null)::text
  union all
  select 11, 'Pedidos da Shopee importados como Concluído (entram em "Repasses para confirmar" quando viram venda)', 'INFO',
         (select count(*) from public.shopee_pedidos where lower(trim(coalesce(status, ''))) like 'conclu%')::text
)
select ordem, item, resultado, detalhe from linhas order by ordem;
