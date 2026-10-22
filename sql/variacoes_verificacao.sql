-- =====================================================================
-- Arts com Você · Verificação das variações de produto (sql/22, Lote D1,
-- R112–R116, R118, R119, R121)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with tabelas(nome) as (
  values ('produto_opcoes'), ('produto_opcao_valores'), ('produto_variacoes'), ('produto_variacao_valores'),
         ('variacao_partes'), ('variacao_materiais')
),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'As 6 tabelas novas existem e pedido, produção e peças prontas têm a coluna da combinação',
         (select count(*) from tabelas t where to_regclass('public.' || t.nome) is not null) = 6
     and (select count(*) from pg_attribute where attname = 'variacao_id' and not attisdropped
            and attrelid in ('public.itens_venda'::regclass, 'public.producoes'::regclass, 'public.pecas_prontas'::regclass)) = 3, ''

  union all
  select 2, 'Funções da Admin: o usuário logado executa (elas exigem a Admin); o visitante não',
         not exists (select 1 from (values ('public.salvar_variacoes_produto(uuid, jsonb, jsonb)'),
                                           ('public.salvar_ficha_variacao(uuid, jsonb, jsonb)'),
                                           ('public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid, uuid)')) f(a)
                      where to_regprocedure(f.a) is null
                         or not has_function_privilege('authenticated', f.a, 'EXECUTE')
                         or has_function_privilege('anon', f.a, 'EXECUTE'))
     and to_regprocedure('public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid)') is null, ''

  union all
  select 3, 'Funções internas fechadas (nem o usuário logado executa)',
         not exists (select 1 from (values ('public.variacao_tem_ficha(uuid)'), ('public.tg_itens_venda_variacao()'),
                                           ('public.tg_itens_venda_copiar_ficha()'), ('public.tg_itens_venda_producao_protege()'),
                                           ('public.tg_vendas_embalagem()')) f(a)
                      where has_function_privilege('authenticated', f.a, 'EXECUTE') or has_function_privilege('anon', f.a, 'EXECUTE')), ''

  union all
  select 4, 'Só a Admin lê as tabelas novas; ninguém grava direto (regras de acesso ligadas)',
         not exists (select 1 from tabelas t join pg_class c on c.oid = to_regclass('public.' || t.nome) where not c.relrowsecurity)
     and not exists (select 1 from tabelas t, (values ('INSERT'), ('UPDATE'), ('DELETE')) p(x)
                      where has_table_privilege('authenticated', 'public.' || t.nome, p.x) or has_table_privilege('anon', 'public.' || t.nome, p.x))
     and not exists (select 1 from tabelas t where has_table_privilege('anon', 'public.' || t.nome, 'SELECT'))
     and (select count(*) from pg_policies where schemaname = 'public' and tablename in (select nome from tabelas)) = 6, ''

  union all
  select 5, 'Gatilhos ligados: combinação do item, cópia da ficha e proteção da produção olham a combinação',
         exists (select 1 from pg_trigger where tgname = 'trg_itens_venda_variacao' and not tgisinternal)
     and exists (select 1 from pg_trigger where tgname = 'trg_itens_venda_copiar_ficha' and pg_get_triggerdef(oid) like '%variacao_id%')
     and exists (select 1 from pg_trigger where tgname = 'trg_itens_venda_producao_protege' and pg_get_triggerdef(oid) like '%variacao_id%')
     and (select count(*) from pg_trigger where not tgisinternal and tgrelid in (select to_regclass('public.' || nome) from tabelas)
            and (tgname like '%auditoria' or tgname like '%updated_at')) = 10, ''

  union all
  select 6, 'Até 3 opções por produto; toda combinação tem um valor de cada opção do produto',
         not exists (select 1 from public.produto_opcoes group by produto_id having count(*) > 3)
     and not exists (select 1 from public.produto_variacoes pv
                      where (select count(*) from public.produto_variacao_valores x where x.variacao_id = pv.id)
                            <> (select count(*) from public.produto_opcoes o where o.produto_id = pv.produto_id)
                         or exists (select 1 from public.produto_variacao_valores x
                                      join public.produto_opcao_valores ov on ov.id = x.valor_id
                                      join public.produto_opcoes o on o.id = ov.opcao_id
                                     where x.variacao_id = pv.id and o.produto_id <> pv.produto_id)), ''

  union all
  select 7, 'Item do pedido, produção e peça pronta: a combinação é do mesmo produto',
         not exists (select 1 from public.itens_venda i join public.produto_variacoes pv on pv.id = i.variacao_id where pv.produto_id is distinct from i.produto_id)
     and not exists (select 1 from public.producoes p join public.produto_variacoes pv on pv.id = p.variacao_id where pv.produto_id is distinct from p.produto_id)
     and not exists (select 1 from public.pecas_prontas l join public.produto_variacoes pv on pv.id = l.variacao_id where pv.produto_id is distinct from l.produto_id), ''

  union all
  select 8, 'Peça pronta usada em pedido é da mesma combinação do item (R119)',
         not exists (select 1 from public.saidas_pecas_prontas s
                       join public.pecas_prontas l on l.id = s.lote_id
                       join public.itens_venda i on i.id = s.item_id
                      where s.situacao = 'ATIVO' and l.variacao_id is distinct from i.variacao_id), ''

  union all
  select 9, 'Venda da Shopee sem combinação (R120)',
         not exists (select 1 from public.itens_venda i join public.vendas v on v.id = i.venda_id
                      where v.shopee_pedido_ref is not null and i.variacao_id is not null), ''

  union all
  select 10, 'Informativo: combinações',
         true,
         (select count(distinct produto_id) from public.produto_variacoes)::text || ' produto(s) com combinações · '
         || (select count(*) from public.produto_variacoes where ativo)::text || ' ligada(s) de '
         || (select count(*) from public.produto_variacoes)::text || ' · '
         || (select count(*) from public.produto_variacoes pv where public.variacao_tem_ficha(pv.id))::text || ' com ficha própria'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
