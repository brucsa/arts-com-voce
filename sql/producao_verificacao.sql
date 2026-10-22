-- =====================================================================
-- Arts com Você · Verificação da produção (sql/15 e sql/16, R95–R100)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with
tabelas(nome) as (values ('producoes'), ('producao_consumos'), ('pecas_prontas'), ('saidas_pecas_prontas'),
                         ('embalagens_pedido'), ('ajustes_estoque')),
views(nome) as (values ('vw_itens_producao'), ('vw_pecas_prontas'), ('vw_perdas'), ('vw_pedido_custos')),
-- registrar_producao: com o sql/22 (variações) ganha p_variacao_id no fim.
-- Texto anterior: só a assinatura sem o último uuid.
gravacao(assinatura) as (values
  (coalesce(to_regprocedure('public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid, uuid)')::text,
            'public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid)')),
  ('public.estornar_producao(uuid, text)'), ('public.usar_peca_pronta(uuid, uuid, integer, uuid)'),
  ('public.baixar_peca_pronta(uuid, integer, text, text, date, uuid)'), ('public.estornar_saida_peca(uuid, text)'),
  ('public.ajustar_estoque(uuid, numeric, text, date, uuid)')),
mov_prod as (   -- movimentos de estoque que a produção criou
  select movimento_id as id from public.producao_consumos
  union all select movimento_id from public.embalagens_pedido
  union all select movimento_id from public.ajustes_estoque
),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'Motivos de estoque da produção existem (PRODUCAO, FALHA, EMBALAGEM, AJUSTE)',
         (select count(*) from pg_enum where enumtypid = 'public.motivo_estoque'::regtype
            and enumlabel in ('PRODUCAO', 'FALHA', 'EMBALAGEM', 'AJUSTE')) = 4, ''

  union all
  select 2, 'As 6 tabelas existem, com RLS ligado e leitura só para a Admin',
         (select count(*) from pg_class c join tabelas t on c.oid = to_regclass('public.' || t.nome) where c.relrowsecurity) = 6
     and (select count(*) from pg_policies p join tabelas t on t.nome = p.tablename
           where p.schemaname = 'public' and p.cmd = 'SELECT' and p.qual like '%is_admin()%') = 6
     and not exists (select 1 from pg_policies p join tabelas t on t.nome = p.tablename where p.schemaname = 'public' and p.cmd <> 'SELECT'), ''

  union all
  select 3, 'As 4 consultas respeitam o acesso de quem consulta (security_invoker)',
         (select count(*) from pg_class c join views v on c.oid = to_regclass('public.' || v.nome)
           where c.reloptions::text like '%security_invoker=true%') = 4, ''

  union all
  select 4, 'Visitante não lê; ninguém grava direto nas tabelas',
         not exists (select 1 from (select nome from tabelas union all select nome from views) t
                      where has_table_privilege('anon', 'public.' || t.nome, 'SELECT'))
     and not exists (select 1 from tabelas t
                      where has_table_privilege('authenticated', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'UPDATE')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'DELETE')), ''

  union all
  select 5, 'As 6 funções de gravação: o usuário logado executa (elas exigem a Admin); o visitante não',
         not exists (select 1 from gravacao g where not has_function_privilege('authenticated', g.assinatura, 'EXECUTE')
                                                 or has_function_privilege('anon', g.assinatura, 'EXECUTE')), ''

  union all
  select 6, 'Funções internas fechadas (nem o usuário logado executa)',
         not exists (select 1 from (values ('public.baixar_material(uuid, numeric, date, public.motivo_estoque, text)'),
                                           ('public.atualizar_pedido_pronto(uuid)')) f(a)
                      where has_function_privilege('authenticated', f.a, 'EXECUTE') or has_function_privilege('anon', f.a, 'EXECUTE')), ''

  union all
  select 7, 'Gatilhos ligados (embalagem em Pronto, proteção dos itens, proteções e auditoria)',
         (select count(*) from pg_trigger where not tgisinternal and tgname in
            ('trg_vendas_embalagem', 'trg_itens_venda_producao_protege',
             'trg_producoes_protege', 'trg_producao_consumos_protege', 'trg_pecas_prontas_protege',
             'trg_saidas_pecas_prontas_protege', 'trg_embalagens_pedido_protege', 'trg_ajustes_estoque_protege',
             'trg_producoes_auditoria', 'trg_producao_consumos_auditoria', 'trg_pecas_prontas_auditoria',
             'trg_saidas_pecas_prontas_auditoria', 'trg_embalagens_pedido_auditoria', 'trg_ajustes_estoque_auditoria')) = 14, ''

  union all
  select 8, 'Cada consumo, embalagem e ajuste tem o seu movimento de estoque (mesma quantidade e valor)',
         not exists (select 1 from public.producao_consumos pc join public.movimentos_estoque m on m.id = pc.movimento_id
                      where m.material_id <> pc.material_id or m.quantidade <> pc.quantidade or m.valor <> pc.valor or m.tipo <> 'SAIDA')
     and not exists (select 1 from public.embalagens_pedido e join public.movimentos_estoque m on m.id = e.movimento_id
                      where m.material_id <> e.material_id or m.quantidade <> e.quantidade or m.valor <> e.valor or m.motivo::text <> 'EMBALAGEM')
     and not exists (select 1 from public.ajustes_estoque a join public.movimentos_estoque m on m.id = a.movimento_id
                      where m.quantidade <> abs(a.diferenca) or m.valor <> a.valor or m.motivo::text <> 'AJUSTE'
                         or (m.tipo = 'ENTRADA') <> (a.diferenca > 0)), ''

  union all
  select 9, 'Nenhum movimento da produção solto (sem o registro correspondente)',
         not exists (select 1 from public.movimentos_estoque m
                      where m.motivo::text in ('PRODUCAO', 'FALHA', 'EMBALAGEM', 'AJUSTE')
                        and not exists (select 1 from mov_prod x where x.id = m.id)), ''

  union all
  select 10, 'Produção ativa: consumos sem estorno; estornada: todos estornados no estoque',
         not exists (select 1 from public.producoes p join public.producao_consumos pc on pc.producao_id = p.id
                      where (p.situacao = 'ATIVO') = (pc.movimento_estorno_id is not null))
     and not exists (select 1 from public.producao_consumos pc join public.movimentos_estoque e on e.id = pc.movimento_estorno_id
                      where e.movimento_estornado_id <> pc.movimento_id or e.tipo <> 'ENTRADA'), ''

  union all
  select 11, 'Custos de cada produção batem (filamento e insumos = consumos; energia pela R16)',
         not exists (select 1 from public.producoes p
                      where p.custo_filamento + p.custo_insumos <> coalesce((select sum(valor) from public.producao_consumos where producao_id = p.id), 0)
                         or p.custo_energia <> round(p.potencia_w / 1000 * p.tempo_min / 60.0 * p.tarifa_kwh, 2)), ''

  union all
  select 12, 'Peças prontas: nunca saem mais peças do que entraram',
         not exists (select 1 from public.vw_pecas_prontas where saldo < 0 or custo_saldo < 0), ''

  union all
  select 13, 'Nenhum item de pedido com mais peças prontas do que a quantidade dele',
         not exists (select 1 from public.vw_itens_producao where produzidas + de_estoque > quantidade), ''

  union all
  select 14, 'Informativo: produção',
         true,
         (select count(*) from public.producoes where situacao = 'ATIVO')::text || ' produção(ões) ativa(s) · '
         || (select coalesce(sum(saldo), 0) from public.vw_pecas_prontas)::text || ' peça(s) pronta(s) · Perdas: R$ '
         || replace(to_char((select coalesce(sum(valor), 0) from public.vw_perdas), 'FM9999999990.00'), '.', ',')
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
