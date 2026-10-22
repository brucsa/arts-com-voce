-- =====================================================================
-- Arts com Você · Verificação das vendas da Shopee (sql/17, R101–R111)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'Colunas novas em vendas e as regras de coerência existem',
         (select count(*) from pg_attribute where attrelid = 'public.vendas'::regclass and not attisdropped
            and attname in ('shopee_pedido_ref', 'taxa_plataforma', 'frete_comprador')) = 3
     and (select count(*) from pg_constraint where conrelid = 'public.vendas'::regclass
            and conname in ('vendas_shopee_coerente', 'vendas_taxa_ate_faturamento')) = 2, ''

  union all
  select 2, 'salvar_venda_shopee: o usuário logado executa (ela exige a Admin); o visitante não',
         has_function_privilege('authenticated', 'public.salvar_venda_shopee(uuid, uuid, date, numeric, numeric, numeric, text, jsonb)', 'EXECUTE')
     and not has_function_privilege('anon', 'public.salvar_venda_shopee(uuid, uuid, date, numeric, numeric, numeric, text, jsonb)', 'EXECUTE'), ''

  union all
  select 3, 'Funções internas fechadas (nem o usuário logado executa)',
         not exists (select 1 from (values ('public.canal_shopee()'), ('public.tg_vendas_canal_coerente()'),
                                           ('public.tg_lancamento_venda_shopee()')) f(a)
                      where has_function_privilege('authenticated', f.a, 'EXECUTE') or has_function_privilege('anon', f.a, 'EXECUTE')), ''

  union all
  select 4, 'Gatilhos ligados (canal da venda; sem recebimento ou devolução manual na Shopee)',
         (select count(*) from pg_trigger where not tgisinternal and tgname in
            ('trg_vendas_canal_coerente', 'trg_recebimentos_venda_shopee', 'trg_devolucoes_venda_shopee')) = 3, ''

  union all
  select 5, 'Pedido direto: cliente, origem e canal Boca a Boca (R77, R78)',
         not exists (select 1 from public.vendas v join public.canais c on c.id = v.canal_id
                      where v.shopee_pedido_ref is null
                        and (v.cliente_id is null or v.origem is null or lower(trim(c.nome)) <> 'boca a boca'
                             or v.taxa_plataforma <> 0 or v.frete_comprador <> 0)), ''

  union all
  select 6, 'Venda da Shopee: canal Shopee, sem cliente e sem origem, frete do comprador separado (R104, R105)',
         not exists (select 1 from public.vendas v join public.canais c on c.id = v.canal_id
                      where v.shopee_pedido_ref is not null
                        and (v.cliente_id is not null or v.origem is not null or lower(trim(c.nome)) <> 'shopee' or v.frete <> 0)), ''

  union all
  select 7, 'Cada pedido da Shopee virou no máximo uma venda (R102)',
         not exists (select 1 from public.vendas where shopee_pedido_ref is not null
                      group by shopee_pedido_ref having count(*) > 1), ''

  union all
  select 8, 'Venda da Shopee sem recebimento nem devolução manual (o dinheiro entra pelo repasse)',
         not exists (select 1 from public.recebimentos_venda r join public.vendas v on v.id = r.venda_id where v.shopee_pedido_ref is not null)
     and not exists (select 1 from public.devolucoes_venda d join public.vendas v on v.id = d.venda_id where v.shopee_pedido_ref is not null), ''

  union all
  select 9, 'A taxa da Shopee nunca passa do faturamento (produtos − desconto)',
         not exists (select 1 from public.vendas where taxa_plataforma > subtotal - desconto), ''

  union all
  select 10, 'As consultas mostram todos os pedidos (com e sem cliente): lista, Joca, itens a produzir e custo',
         (select count(*) from public.vw_pedidos) = (select count(*) from public.vendas)
     and (select count(*) from public.vw_joca_pedidos) = (select count(*) from public.vendas)
     and (select count(*) from public.vw_pedido_custos) = (select count(*) from public.vendas)
     and (select count(*) from public.vw_itens_producao) = (select count(*) from public.itens_venda), ''

  union all
  select 11, 'Informativo: vendas da Shopee',
         true,
         (select count(*) from public.vendas where shopee_pedido_ref is not null)::text || ' venda(s) · faturamento R$ '
         || replace(to_char((select coalesce(sum(subtotal - desconto), 0) from public.vendas
                              where shopee_pedido_ref is not null and status_pedido <> 'CANCELADO'), 'FM9999999990.00'), '.', ',')
         || ' · taxas R$ '
         || replace(to_char((select coalesce(sum(taxa_plataforma), 0) from public.vendas
                              where shopee_pedido_ref is not null and status_pedido <> 'CANCELADO'), 'FM9999999990.00'), '.', ',')
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
