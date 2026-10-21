-- =====================================================================
-- Arts com Você · Conferência ANTES da produção (sql/15 e sql/16)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run. Esperado: nenhum "FALHOU".
-- =====================================================================

with linhas (ordem, item, resultado, detalhe) as (
  select 1, 'Ficha de consumo (sql/14) e área do Joca (sql/13) instaladas',
         case when to_regclass('public.produto_partes') is not null and to_regclass('public.item_venda_partes') is not null
                   and to_regclass('public.comissoes_joca') is not null
              then 'OK' else 'FALHOU' end, ''
  union all
  select 2, 'Produção ainda não instalada (tabelas e funções livres)',
         case when to_regclass('public.producoes') is null and to_regclass('public.pecas_prontas') is null
                   and to_regclass('public.ajustes_estoque') is null
                   and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                                      and proname in ('registrar_producao', 'usar_peca_pronta', 'ajustar_estoque', 'baixar_material'))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 3, 'Nenhum movimento de estoque com motivo da produção',
         case when not exists (select 1 from public.movimentos_estoque
                                where motivo::text in ('PRODUCAO', 'FALHA', 'EMBALAGEM', 'AJUSTE'))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 4, 'Motivos de estoque hoje (os da produção entram pelo passo 1)', 'INFO',
         (select string_agg(enumlabel, ', ' order by enumsortorder) from pg_enum where enumtypid = 'public.motivo_estoque'::regtype)
  union all
  select 5, 'Potência da impressora e tarifa de energia (precisam estar preenchidas para registrar produção)',
         case when (select potencia_impressora_w is not null and tarifa_kwh is not null from public.configuracoes where id = 1)
              then 'INFO' else 'AVISO' end,
         (select coalesce(potencia_impressora_w::text || ' W', 'potência vazia') || ' · '
                 || coalesce('R$ ' || replace(tarifa_kwh::text, '.', ',') || '/kWh', 'tarifa vazia')
            from public.configuracoes where id = 1)
  union all
  select 10, 'Pedidos em aberto (Aguardando, Produzindo ou Pronto)', 'INFO',
         (select count(*) from public.vendas where status_pedido in ('AGUARDANDO', 'PRODUZINDO', 'PRONTO'))::text
  union all
  select 11, 'Materiais com saldo em estoque', 'INFO',
         (select count(*) from public.saldos_material where quantidade > 0)::text
  union all
  select 12, 'Produtos com ficha de consumo', 'INFO',
         (select count(distinct produto_id) from public.produto_partes)::text || ' com partes · '
         || (select count(distinct produto_id) from public.produto_materiais)::text || ' com outros materiais'
)
select ordem, item, resultado, detalhe from linhas order by ordem;
