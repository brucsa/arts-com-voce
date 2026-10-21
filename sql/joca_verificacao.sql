-- =====================================================================
-- Arts com Você · Verificação da área do Joca (R89–R92)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with
esperada as (
  select v.id as venda_id, v.numero,
         case when v.status_pedido = 'CANCELADO' or v.total <= 0 then 0::numeric(12,2)
              else round(p.percentual / 100 * (v.subtotal - v.desconto)
                         * greatest(v.total - v.valor_devolvido, 0) / v.total, 2) end as valor,
         coalesce((select sum(k.valor) from public.comissoes_joca k where k.venda_id = v.id), 0) as gravada,
         p.percentual, p.data_referencia, v.data
    from public.vendas v
    left join public.comissao_joca_pedido p on p.venda_id = v.id
),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'Origem PAGAMENTO_JOCA existe no Caixa',
         exists (select 1 from pg_enum where enumtypid = 'public.origem_caixa'::regtype and enumlabel = 'PAGAMENTO_JOCA'), ''

  union all
  select 2, 'As 3 tabelas existem, com RLS ligado e leitura só para a Admin',
         (select count(*) from pg_class where oid in (to_regclass('public.comissao_joca_pedido'), to_regclass('public.comissoes_joca'),
                                                       to_regclass('public.pagamentos_joca')) and relrowsecurity) = 3
     and (select count(*) from pg_policies where schemaname = 'public'
            and tablename in ('comissao_joca_pedido', 'comissoes_joca', 'pagamentos_joca')
            and cmd = 'SELECT' and qual like '%is_admin()%') = 3
     and not exists (select 1 from pg_policies where schemaname = 'public'
                        and tablename in ('comissao_joca_pedido', 'comissoes_joca', 'pagamentos_joca') and cmd <> 'SELECT'), ''

  union all
  select 3, 'Visitante e Joca não leem as tabelas; ninguém grava direto',
         not exists (select 1 from (values ('comissao_joca_pedido'), ('comissoes_joca'), ('pagamentos_joca'),
                                           ('vw_joca_pedidos')) t(nome)
                      where has_table_privilege('anon', 'public.' || t.nome, 'SELECT')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'UPDATE')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'DELETE')), ''

  union all
  select 4, 'Consulta dos pedidos da Admin respeita o acesso de quem consulta (security_invoker)',
         exists (select 1 from pg_class where oid = to_regclass('public.vw_joca_pedidos')
                    and 'security_invoker=true' = any (reloptions)), ''

  union all
  select 5, 'Pagamento e estorno exigem a Admin; o visitante não executa',
         (select count(*) from pg_proc where oid in (to_regprocedure('public.registrar_pagamento_joca(date, numeric, text, text, uuid)'),
                                                      to_regprocedure('public.estornar_pagamento_joca(uuid, text)'))
            and prosecdef and prosrc like '%exigir_admin()%') = 2
     and not has_function_privilege('anon', 'public.registrar_pagamento_joca(date, numeric, text, text, uuid)', 'EXECUTE')
     and not has_function_privilege('anon', 'public.estornar_pagamento_joca(uuid, text)', 'EXECUTE'), ''

  union all
  select 6, 'Funções do Joca: só Joca ou Admin; o visitante não executa',
         (select count(*) from pg_proc where oid in (to_regprocedure('public.joca_resumo()'), to_regprocedure('public.joca_extrato()'))
            and prosecdef and prosrc like '%is_joca()%') = 2
     and not has_function_privilege('anon', 'public.joca_resumo()', 'EXECUTE')
     and not has_function_privilege('anon', 'public.joca_extrato()', 'EXECUTE')
     and has_function_privilege('authenticated', 'public.joca_resumo()', 'EXECUTE'), ''

  union all
  select 7, 'Funções internas fechadas (nem o usuário logado executa)',
         not exists (select 1 from (values ('public.percentual_joca_em(date)'), ('public.sincronizar_comissao_joca(uuid, text)'),
                                           ('public.joca_totais()'), ('public.conferir_pagamento_joca(uuid)'),
                                           ('public.migrar_comissoes_joca()')) f(assinatura)
                      where has_function_privilege('authenticated', f.assinatura, 'EXECUTE')
                         or has_function_privilege('anon', f.assinatura, 'EXECUTE')), ''

  union all
  select 8, 'Proteções e conferência no fim da gravação ligadas (pedidos, pagamentos e Caixa)',
         (select count(*) from pg_trigger where not tgisinternal and tgname in
            ('trg_vendas_comissao_joca', 'trg_pagamentos_joca_conferir', 'trg_movimentos_caixa_conferir_joca',
             'trg_comissoes_joca_protege', 'trg_pagamentos_joca_protege', 'trg_comissao_joca_pedido_protege',
             'trg_comissoes_joca_auditoria', 'trg_pagamentos_joca_auditoria', 'trg_comissao_joca_pedido_auditoria')) = 9, ''

  union all
  select 9, 'Todo pedido tem o percentual congelado da data dele',
         not exists (select 1 from esperada where percentual is null or data_referencia <> data),
         (select count(*) from esperada)::text || ' pedido(s)'

  union all
  select 10, 'Comissão de cada pedido = percentual × (produtos − desconto), na proporção do que não foi devolvido; cancelado = 0',
         not exists (select 1 from esperada where valor <> gravada),
         coalesce((select string_agg(public.numero_pedido_texto(numero), ', ' order by numero) from esperada where valor <> gravada), '')

  union all
  select 11, 'Cada pagamento ativo tem a sua saída no Caixa (mesma data e valor, não estornada); estornado tem o estorno',
         not exists (
           select 1 from public.pagamentos_joca g
            where (select count(*) from public.movimentos_caixa m
                    where m.pagamento_joca_id = g.id and m.origem = 'PAGAMENTO_JOCA' and m.tipo = 'SAIDA'
                      and m.data = g.data and m.valor = g.valor) <> 1
               or (g.situacao = 'ATIVO') = exists (
                    select 1 from public.movimentos_caixa m join public.movimentos_caixa e on e.movimento_estornado_id = m.id
                     where m.pagamento_joca_id = g.id))
     and not exists (select 1 from public.movimentos_caixa m
                      where m.origem = 'PAGAMENTO_JOCA' and not exists (select 1 from public.pagamentos_joca g where g.id = m.pagamento_joca_id)),
         (select count(*) from public.pagamentos_joca where situacao = 'ATIVO')::text || ' pagamento(s) ativo(s)'

  union all
  select 12, 'Totais batem: pagamentos no Caixa = pagamentos ativos',
         (select coalesce(sum(case when m.tipo = 'SAIDA' then m.valor else -m.valor end), 0)
            from public.movimentos_caixa m
           where m.origem = 'PAGAMENTO_JOCA'
              or (m.origem = 'ESTORNO' and exists (select 1 from public.movimentos_caixa o where o.id = m.movimento_estornado_id and o.origem = 'PAGAMENTO_JOCA')))
         = (select coalesce(sum(valor), 0) from public.pagamentos_joca where situacao = 'ATIVO'),
         'Pago: R$ ' || replace(to_char((select coalesce(sum(valor), 0) from public.pagamentos_joca where situacao = 'ATIVO'), 'FM9999999990.00'), '.', ',')

  union all
  select 13, 'Informativo: totais do Joca',
         true,
         (select 'A receber: R$ ' || replace(to_char(a_receber, 'FM9999999990.00'), '.', ',')
              || ' · Disponível: R$ ' || replace(to_char(disponivel, 'FM9999999990.00'), '.', ',')
              || ' · Pago: R$ ' || replace(to_char(pago, 'FM9999999990.00'), '.', ',')
            from public.joca_totais())
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
