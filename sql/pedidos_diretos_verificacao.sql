-- =====================================================================
-- Arts com Você · Verificação dos Pedidos Diretos Essencial · Lote P1-a
-- (R76–R84, P1–P6)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with tabelas(nome) as (
  values ('clientes'), ('vendas'), ('itens_venda'), ('historico_status_pedido')
),
funcoes_admin(assinatura) as (
  values ('public.salvar_cliente(uuid, text, text)'),
         ('public.definir_cliente_ativo(uuid, boolean)'),
         ('public.excluir_cliente(uuid)'),
         ('public.salvar_pedido(uuid, date, uuid, text, date, text, numeric, numeric, text, jsonb)'),
         ('public.mudar_status_pedido(uuid, text)'),
         ('public.cancelar_pedido(uuid, text)')
),
funcoes_internas(assinatura) as (
  values ('public.proximo_numero_pedido()'),
         ('public.canal_boca_a_boca()'),
         ('public.recalcular_pedido(uuid)'),
         ('public.conferir_pedido(uuid)'),
         ('public.tg_vendas_protege()'),
         ('public.tg_itens_venda_protege()'),
         ('public.tg_historico_status_imutavel()'),
         ('public.tg_vendas_conferir()'),
         ('public.tg_itens_venda_conferir()')
),
ligacoes(tabela, coluna, destino) as (
  values ('vendas', 'cliente_id', 'clientes'),
         ('vendas', 'canal_id', 'canais'),
         ('itens_venda', 'venda_id', 'vendas'),
         ('itens_venda', 'produto_id', 'produtos'),
         ('itens_venda', 'material_id', 'materiais'),
         ('historico_status_pedido', 'venda_id', 'vendas')
),
ultimo_status as (
  select distinct on (h.venda_id) h.venda_id, h.status_novo
    from public.historico_status_pedido h
   order by h.venda_id, h.quando desc
),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'As 4 tabelas e a consulta vw_pedidos existem',
         (select count(*) from tabelas t where to_regclass('public.' || t.nome) is not null) = 4
     and to_regclass('public.vw_pedidos') is not null, ''

  union all
  select 2, 'Tipos próprios do Essencial com os valores aprovados (R78, R82, P5)',
         (select array_agg(e.enumlabel order by e.enumsortorder) from pg_enum e
           where e.enumtypid = to_regtype('public.status_pedido_direto'))
           = array['AGUARDANDO', 'PRODUZINDO', 'PRONTO', 'ENTREGUE', 'CANCELADO']::name[]
     and (select array_agg(e.enumlabel order by e.enumsortorder) from pg_enum e
           where e.enumtypid = to_regtype('public.origem_pedido_direto'))
           = array['WHATSAPP', 'INSTAGRAM', 'PESSOALMENTE', 'OUTRO']::name[]
     and (select array_agg(e.enumlabel order by e.enumsortorder) from pg_enum e
           where e.enumtypid = to_regtype('public.status_financeiro_pedido'))
           = array['A_RECEBER', 'RECEBIDO', 'SEM_COBRANCA', 'CANCELADO']::name[], ''

  union all
  select 3, 'As 4 tabelas têm RLS ligado',
         not exists (select 1 from tabelas t join pg_class c on c.oid = to_regclass('public.' || t.nome)
                      where not c.relrowsecurity), ''

  union all
  select 4, 'A consulta vw_pedidos respeita o acesso de quem consulta (security_invoker)',
         exists (select 1 from pg_class where oid = to_regclass('public.vw_pedidos')
                    and 'security_invoker=true' = any (reloptions)), ''

  union all
  select 5, 'Visitante sem login não acessa tabelas nem a consulta de pedidos',
         not exists (select 1 from (select nome from tabelas union all select 'vw_pedidos') t
                      where has_table_privilege('anon', 'public.' || t.nome, 'SELECT')
                         or has_table_privilege('anon', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('anon', 'public.' || t.nome, 'UPDATE')
                         or has_table_privilege('anon', 'public.' || t.nome, 'DELETE')), ''

  union all
  select 6, 'Usuário logado não grava direto nas tabelas (só pelas funções)',
         not exists (select 1 from (select nome from tabelas union all select 'vw_pedidos') t
                      where has_table_privilege('authenticated', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'UPDATE')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'DELETE')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'TRUNCATE')), ''

  union all
  select 7, 'Leitura só para a Admin (o Joca não vê clientes nem pedidos)',
         (select count(*) from pg_policies p join tabelas t on t.nome = p.tablename
           where p.schemaname = 'public' and p.cmd = 'SELECT' and p.qual like '%is_admin()%') = 4
     and not exists (select 1 from pg_policies p join tabelas t on t.nome = p.tablename
                      where p.schemaname = 'public' and (p.cmd <> 'SELECT' or p.qual not like '%is_admin()%')), ''

  union all
  select 8, 'As 6 funções de gravação exigem a Admin',
         (select count(*) from funcoes_admin f join pg_proc p on p.oid = to_regprocedure(f.assinatura)
           where p.prosecdef and p.prosrc like '%exigir_admin()%') = 6, ''

  union all
  select 9, 'Visitante sem login não executa as funções de pedidos',
         not exists (select 1 from funcoes_admin f where has_function_privilege('anon', f.assinatura, 'EXECUTE')), ''

  union all
  select 10, 'Funções internas fechadas (nem o usuário logado executa)',
         (select count(*) from funcoes_internas f where to_regprocedure(f.assinatura) is not null) = 9
     and not exists (select 1 from funcoes_internas f
                      where has_function_privilege('authenticated', f.assinatura, 'EXECUTE')
                         or has_function_privilege('anon', f.assinatura, 'EXECUTE')), ''

  union all
  select 11, 'Nada é apagado em cascata: clientes, produtos e filamentos usados não podem ser excluídos',
         (select count(*) from ligacoes l
            join pg_constraint c on c.conrelid = to_regclass('public.' || l.tabela) and c.contype = 'f'
                                and c.confrelid = to_regclass('public.' || l.destino) and c.confdeltype = 'r'
            join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1] and a.attname = l.coluna) = 6, ''

  union all
  select 12, 'Alterações nas 4 tabelas ficam na auditoria',
         (select count(*) from pg_trigger tg join pg_class c on c.oid = tg.tgrelid join tabelas t on t.nome = c.relname
           where c.relnamespace = 'public'::regnamespace
             and not tg.tgisinternal and tg.tgfoid = 'public.tg_auditoria()'::regprocedure) = 4, ''

  union all
  select 13, 'Proteções ligadas: pedido não é excluído, histórico não muda, itens travados em Entregue/Cancelado',
         (select count(*) from pg_trigger tg
           where not tg.tgisinternal and tg.tgenabled <> 'D'
             and (tg.tgrelid, tg.tgfoid) in (('public.vendas'::regclass, 'public.tg_vendas_protege()'::regprocedure),
                                            ('public.itens_venda'::regclass, 'public.tg_itens_venda_protege()'::regprocedure),
                                            ('public.historico_status_pedido'::regclass, 'public.tg_historico_status_imutavel()'::regprocedure))) = 3, ''

  union all
  select 14, 'Conferência no fim de cada gravação ligada (pedido e itens)',
         (select count(*) from pg_trigger tg
           where tg.tgenabled <> 'D' and tg.tgdeferrable and tg.tginitdeferred
             and (tg.tgrelid, tg.tgfoid) in (('public.vendas'::regclass, 'public.tg_vendas_conferir()'::regprocedure),
                                            ('public.itens_venda'::regclass, 'public.tg_itens_venda_conferir()'::regprocedure))) = 2, ''

  union all
  select 15, 'Numeração sem lacunas: os pedidos vão de #0001 até o último, sem pular (R81)',
         (select coalesce(max(numero), 0) = count(*) and coalesce(min(numero), 1) = 1 from public.vendas),
         (select count(*) from public.vendas)::text || ' pedido(s)'

  union all
  select 16, 'Todo pedido tem pelo menos um item (P6)',
         not exists (select 1 from public.vendas v
                      where not exists (select 1 from public.itens_venda i where i.venda_id = v.id)), ''

  union all
  select 17, 'Valores consistentes: subtotal = soma dos itens e total = subtotal − desconto + frete',
         not exists (select 1 from public.vendas v
                      where v.subtotal <> (select coalesce(sum(i.valor_item), 0) from public.itens_venda i where i.venda_id = v.id)
                         or v.total <> v.subtotal - v.desconto + v.frete), ''

  union all
  -- Vale antes e depois do P1-b. Sem o P1-b, recebido e devolvido ficam em
  -- zero. Com o P1-b, a igualdade com os lançamentos é conferida em
  -- sql/pedidos_diretos_pagamentos_verificacao.sql.
  select 18, 'Resumo financeiro coerente (C1): líquido ≥ 0 e, fora do cancelado, ≤ total; sem o P1-b, tudo em zero',
         not exists (select 1 from public.vendas
                      where valor_recebido - valor_devolvido < 0
                         or (status_pedido <> 'CANCELADO' and valor_recebido - valor_devolvido > total))
     and (to_regclass('public.recebimentos_venda') is not null
          or not exists (select 1 from public.vendas where valor_recebido <> 0 or valor_devolvido <> 0)),
         case when to_regclass('public.recebimentos_venda') is null then 'P1-b não instalado' else 'P1-b instalado' end

  union all
  select 19, 'Histórico completo: todo pedido tem o registro de criação e o último status bate com o atual',
         not exists (select 1 from public.vendas v
                      where not exists (select 1 from public.historico_status_pedido h
                                         where h.venda_id = v.id and h.status_anterior is null)
                         or (select u.status_novo from ultimo_status u where u.venda_id = v.id) is distinct from v.status_pedido), ''

  union all
  -- Atualizada na v1.9 (R104): as vendas da Shopee ficam no canal Shopee.
  -- Antes: "Todos os pedidos estão num único canal, sem repasse (Boca a Boca, R78)".
  select 20, 'Pedidos diretos num único canal, sem repasse (Boca a Boca, R78); vendas da Shopee no canal Shopee (R104)',
         (select count(distinct v.canal_id) <= 1 from public.vendas v where to_jsonb(v) ->> 'shopee_pedido_ref' is null)
     and not exists (select 1 from public.vendas v join public.canais c on c.id = v.canal_id
                      where to_jsonb(v) ->> 'shopee_pedido_ref' is null and c.usa_repasse)
     and not exists (select 1 from public.vendas v join public.canais c on c.id = v.canal_id
                      where to_jsonb(v) ->> 'shopee_pedido_ref' is not null and lower(trim(c.nome)) <> 'shopee'),
         (select count(*) from public.clientes)::text || ' cliente(s) · '
           || (select count(*) from public.itens_venda)::text || ' item(ns)'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
