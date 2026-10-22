-- =====================================================================
-- Arts com Você · Conferência ANTES das vendas da Shopee (sql/17)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run. Esperado: nenhum "FALHOU".
-- =====================================================================

with linhas (ordem, item, resultado, detalhe) as (
  select 1, 'Pedidos da Shopee (consulta), produção (sql/16) e área do Joca (sql/13) instalados',
         case when to_regclass('public.shopee_pedidos') is not null and to_regclass('public.vw_pedido_custos') is not null
                   and to_regclass('public.vw_joca_pedidos') is not null
              then 'OK' else 'FALHOU' end, ''
  union all
  select 2, 'Vendas da Shopee ainda não instaladas',
         case when not exists (select 1 from pg_attribute where attrelid = 'public.vendas'::regclass
                                  and attname = 'shopee_pedido_ref' and not attisdropped)
                   and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                                      and proname in ('salvar_venda_shopee', 'canal_shopee'))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 3, 'Canal "Shopee" existe em Configurações › Canais (com repasse)',
         case when exists (select 1 from public.canais where lower(trim(nome)) = 'shopee')
              then 'OK' else 'FALHOU' end,
         coalesce((select case when usa_repasse then 'com repasse' else 'sem repasse' end from public.canais where lower(trim(nome)) = 'shopee'), '')
  union all
  select 4, 'Todo pedido atual tem cliente e origem (pedidos diretos)',
         case when not exists (select 1 from public.vendas where cliente_id is null or origem is null)
              then 'OK' else 'FALHOU' end, ''
  union all
  select 5, 'Todo pedido atual está no canal Boca a Boca',
         case when not exists (select 1 from public.vendas v join public.canais c on c.id = v.canal_id
                                where lower(trim(c.nome)) <> 'boca a boca')
              then 'OK' else 'FALHOU' end, ''
  union all
  select 10, 'Pedidos (diretos) registrados', 'INFO', (select count(*) from public.vendas)::text
  union all
  select 11, 'Pedidos da Shopee importados (podem virar venda)', 'INFO',
         (select count(*) from public.shopee_pedidos)::text || ' · '
         || (select count(*) from public.shopee_pedidos where lower(coalesce(status, '')) ~ 'cancel')::text || ' cancelado(s)'
)
select ordem, item, resultado, detalhe from linhas order by ordem;
