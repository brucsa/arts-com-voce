-- =====================================================================
-- Arts com Você · Verificação da ficha de consumo e das cores por parte
-- (sql/14, R93–R94). Supabase → SQL Editor → colar → Run.
-- Resultado esperado: tudo "OK". Só consulta: não altera nada no banco.
-- =====================================================================

with
novas(nome) as (values ('produto_partes'), ('produto_materiais'), ('item_venda_partes')),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'As 3 tabelas existem, com RLS ligado e leitura só para a Admin',
         (select count(*) from pg_class c join novas n on c.oid = to_regclass('public.' || n.nome) where c.relrowsecurity) = 3
     and (select count(*) from pg_policies p join novas n on n.nome = p.tablename
           where p.schemaname = 'public' and p.cmd = 'SELECT' and p.qual like '%is_admin()%') = 3
     and not exists (select 1 from pg_policies p join novas n on n.nome = p.tablename
                      where p.schemaname = 'public' and p.cmd <> 'SELECT'), ''

  union all
  select 2, 'Visitante não lê; ninguém grava direto nas tabelas',
         not exists (select 1 from novas n
                      where has_table_privilege('anon', 'public.' || n.nome, 'SELECT')
                         or has_table_privilege('authenticated', 'public.' || n.nome, 'INSERT')
                         or has_table_privilege('authenticated', 'public.' || n.nome, 'UPDATE')
                         or has_table_privilege('authenticated', 'public.' || n.nome, 'DELETE')), ''

  union all
  select 3, 'Funções de gravação: só o usuário logado executa (e elas exigem a Admin)',
         has_function_privilege('authenticated', 'public.salvar_ficha_produto(uuid, jsonb, jsonb)', 'EXECUTE')
     and has_function_privilege('authenticated', 'public.definir_cores_partes(uuid, jsonb)', 'EXECUTE')
     and not has_function_privilege('anon', 'public.salvar_ficha_produto(uuid, jsonb, jsonb)', 'EXECUTE')
     and not has_function_privilege('anon', 'public.definir_cores_partes(uuid, jsonb)', 'EXECUTE')
     and (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and prosecdef
            and proname in ('salvar_ficha_produto', 'definir_cores_partes', 'tg_itens_venda_copiar_ficha')) = 3, ''

  union all
  select 4, 'Gatilhos ligados (cópia da ficha no pedido, proteção das partes, auditoria)',
         (select count(*) from pg_trigger where not tgisinternal and tgname in
            ('trg_itens_venda_copiar_ficha', 'trg_item_venda_partes_protege',
             'trg_produto_partes_auditoria', 'trg_produto_materiais_auditoria', 'trg_item_venda_partes_auditoria',
             'trg_produto_partes_updated_at', 'trg_produto_materiais_updated_at', 'trg_item_venda_partes_updated_at')) = 8, ''

  union all
  select 5, 'Ficha: partes numeradas de 1 em diante, sem pular, em cada produto',
         not exists (select 1 from (select produto_id, ordem, row_number() over (partition by produto_id order by ordem) as n
                                      from public.produto_partes) x where x.ordem <> x.n), ''

  union all
  select 6, 'Ficha: outros materiais são só insumos ou embalagens',
         not exists (select 1 from public.produto_materiais pm join public.materiais m on m.id = pm.material_id
                      where m.categoria not in ('INSUMO', 'EMBALAGEM')), ''

  union all
  select 7, 'Pedido: partes só em itens do catálogo, numeradas sem pular',
         not exists (select 1 from public.item_venda_partes p join public.itens_venda i on i.id = p.item_id where i.produto_id is null)
     and not exists (select 1 from (select item_id, ordem, row_number() over (partition by item_id order by ordem) as n
                                      from public.item_venda_partes) x where x.ordem <> x.n), ''

  union all
  select 8, 'Pedido: a cor de cada parte é um filamento, com o nome copiado',
         not exists (select 1 from public.item_venda_partes p join public.materiais m on m.id = p.material_id
                      where m.categoria <> 'FILAMENTO' or p.cor_descricao is null), ''

  union all
  select 9, 'Informativo: fichas e pedidos',
         true,
         (select count(distinct produto_id) from public.produto_partes)::text || ' produto(s) com partes · '
         || (select count(distinct produto_id) from public.produto_materiais)::text || ' com outros materiais · '
         || (select count(distinct item_id) from public.item_venda_partes)::text || ' item(ns) de pedido com partes · '
         || (select count(*) from public.item_venda_partes where material_id is null)::text || ' parte(s) com cor a definir'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
