-- =====================================================================
-- Arts com Você · Verificação dos repasses da Shopee (sql/18 e 19, R106,
-- R107, R109, R110)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'Origem Repasse Shopee no Caixa, tabelas e consultas novas existem',
         exists (select 1 from pg_enum where enumtypid = 'public.origem_caixa'::regtype and enumlabel = 'REPASSE_SHOPEE')
     and to_regclass('public.repasses_shopee') is not null and to_regclass('public.avisos_shopee_dispensados') is not null
     and to_regclass('public.vw_repasses_shopee_pendentes') is not null and to_regclass('public.vw_avisos_shopee') is not null
     and exists (select 1 from pg_attribute where attrelid = 'public.movimentos_caixa'::regclass
                   and attname = 'repasse_shopee_id' and not attisdropped), ''

  union all
  select 2, 'Funções da Admin: o usuário logado executa (elas exigem a Admin); o visitante não',
         not exists (select 1 from (values ('public.confirmar_repasse_shopee(uuid, date, numeric, text, boolean, uuid)'),
                                           ('public.estornar_repasse_shopee(uuid, text)'),
                                           ('public.dispensar_aviso_shopee(uuid, text)')) f(a)
                      where not has_function_privilege('authenticated', f.a, 'EXECUTE')
                         or has_function_privilege('anon', f.a, 'EXECUTE')), ''

  union all
  select 3, 'Funções internas fechadas (nem o usuário logado executa)',
         not exists (select 1 from (values ('public.tg_repasses_shopee_protege()'), ('public.tg_avisos_shopee_protege()'),
                                           ('public.exigir_venda_sem_repasse(uuid)'), ('public.recalcular_pedido(uuid)'),
                                           ('public.conferir_pedido(uuid)'), ('public.tg_movimentos_caixa_conferir_pedido()'),
                                           ('public.tg_vendas_protege()')) f(a)
                      where has_function_privilege('authenticated', f.a, 'EXECUTE') or has_function_privilege('anon', f.a, 'EXECUTE')), ''

  union all
  select 4, 'Só a Admin lê; ninguém grava direto nas tabelas novas (regras de acesso ligadas)',
         (select bool_and(relrowsecurity) from pg_class where oid in ('public.repasses_shopee'::regclass, 'public.avisos_shopee_dispensados'::regclass))
     and not exists (select 1 from (values ('public.repasses_shopee'), ('public.avisos_shopee_dispensados')) t(n),
                       (values ('INSERT'), ('UPDATE'), ('DELETE')) p(x)
                      where has_table_privilege('authenticated', t.n, p.x) or has_table_privilege('anon', t.n, p.x))
     and not has_table_privilege('anon', 'public.repasses_shopee', 'SELECT')
     and (select count(*) from pg_policies where schemaname = 'public'
            and policyname in ('repasses_shopee_select_admin', 'avisos_shopee_dispensados_select_admin')) = 2, ''

  union all
  select 5, 'Gatilhos ligados (proteção, auditoria e updated_at)',
         (select count(*) from pg_trigger where not tgisinternal and tgname in
            ('trg_repasses_shopee_protege', 'trg_repasses_shopee_auditoria', 'trg_repasses_shopee_updated_at',
             'trg_avisos_shopee_dispensados_protege', 'trg_avisos_shopee_dispensados_auditoria')) = 5, ''

  union all
  select 6, 'Repasse só em venda da Shopee, no máximo um ativo por venda',
         not exists (select 1 from public.repasses_shopee r join public.vendas v on v.id = r.venda_id where v.shopee_pedido_ref is null)
     and not exists (select 1 from public.repasses_shopee where situacao = 'ATIVO' group by venda_id having count(*) > 1), ''

  union all
  select 7, 'Repasse ativo: taxa da venda = faturamento − repasse (C2-1)',
         not exists (select 1 from public.repasses_shopee r join public.vendas v on v.id = r.venda_id
                      where r.situacao = 'ATIVO'
                        and (r.faturamento <> v.subtotal - v.desconto or r.taxa <> v.taxa_plataforma)), ''

  union all
  select 8, 'Cada repasse ativo tem a sua entrada no Caixa (mesma data e valor, não estornada)',
         not exists (select 1 from public.repasses_shopee r
                      where r.situacao = 'ATIVO'
                        and not exists (select 1 from public.movimentos_caixa m
                                         where m.repasse_shopee_id = r.id and m.origem = 'REPASSE_SHOPEE' and m.tipo = 'ENTRADA'
                                           and m.valor = r.valor and m.data = r.data
                                           and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id))), ''

  union all
  select 9, 'Cada repasse estornado tem o movimento estornado no Caixa',
         not exists (select 1 from public.repasses_shopee r
                      where r.situacao = 'ESTORNADO'
                        and exists (select 1 from public.movimentos_caixa m
                                     where m.repasse_shopee_id = r.id
                                       and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id))), ''

  union all
  select 10, 'Todo movimento Repasse Shopee do Caixa é de um repasse',
         not exists (select 1 from public.movimentos_caixa m
                      where m.origem = 'REPASSE_SHOPEE' and not exists (select 1 from public.repasses_shopee r where r.id = m.repasse_shopee_id)), ''

  union all
  select 11, 'Venda da Shopee: recebida só com repasse ativo (R106, R107)',
         not exists (select 1 from public.vendas v
                      where v.shopee_pedido_ref is not null
                        and v.valor_recebido <> case when exists (select 1 from public.repasses_shopee r
                                                                    where r.venda_id = v.id and r.situacao = 'ATIVO')
                                                     then v.total else 0 end), ''

  union all
  select 12, 'Informativo: repasses da Shopee',
         true,
         (select count(*) from public.repasses_shopee where situacao = 'ATIVO')::text || ' confirmado(s), R$ '
         || replace(to_char((select coalesce(sum(valor), 0) from public.repasses_shopee where situacao = 'ATIVO'), 'FM9999999990.00'), '.', ',')
         || ' · ' || (select count(*) from public.vw_repasses_shopee_pendentes)::text || ' para confirmar · '
         || (select count(*) from public.vw_avisos_shopee)::text || ' aviso(s)'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
