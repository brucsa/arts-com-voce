-- =====================================================================
-- Arts com Você · Verificação da integração Pedidos Diretos → Caixa
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with funcoes_admin(assinatura) as (
  values ('public.registrar_recebimento(uuid, date, numeric, text, text, boolean, uuid)'),
         ('public.registrar_devolucao(uuid, date, numeric, text, text, uuid)'),
         ('public.estornar_recebimento(uuid, text)'),
         ('public.estornar_devolucao(uuid, text)'),
         ('public.estornar_movimento(uuid, text)')
),
funcoes_internas(assinatura) as (
  values ('public.numero_pedido_texto(integer)'),
         ('public.tg_movimentos_caixa_conferir_pedido()'),
         ('public.migrar_pedidos_para_caixa()'),
         ('public.conferir_pedido(uuid)')
),
mov_ativo as (   -- movimento ligado a pedido e ainda não estornado no Caixa
  select m.* from public.movimentos_caixa m
   where not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id)
),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'Origens RECEBIMENTO e REEMBOLSO existem no Caixa',
         (select count(*) from pg_enum where enumtypid = 'public.origem_caixa'::regtype
            and enumlabel in ('RECEBIMENTO', 'REEMBOLSO')) = 2, ''

  union all
  select 2, 'Cada recebimento e cada devolução tem no máximo um movimento (ligação única, sem apagar em cascata)',
         (select count(*) from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
           where c.conrelid = 'public.movimentos_caixa'::regclass and c.contype = 'u'
             and a.attname in ('recebimento_id', 'devolucao_id')) = 2
     and (select count(*) from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
           where c.conrelid = 'public.movimentos_caixa'::regclass and c.contype = 'f' and c.confdeltype = 'r'
             and a.attname in ('recebimento_id', 'devolucao_id')) = 2
     and exists (select 1 from pg_constraint where conrelid = 'public.movimentos_caixa'::regclass
                    and conname = 'movimentos_caixa_origem_pedido'), ''

  union all
  select 3, 'Código de envio único nos recebimentos e devoluções',
         (select count(*) from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
           where c.contype = 'u' and a.attname = 'chave_envio'
             and c.conrelid in ('public.recebimentos_venda'::regclass, 'public.devolucoes_venda'::regclass)) = 2, ''

  union all
  select 4, 'Funções exigem a Admin e o visitante não executa',
         (select count(*) from funcoes_admin f join pg_proc p on p.oid = to_regprocedure(f.assinatura)
           where p.prosecdef and p.prosrc like '%exigir_admin()%') = 5
     and not exists (select 1 from funcoes_admin f where has_function_privilege('anon', f.assinatura, 'EXECUTE'))
     and to_regprocedure('public.registrar_recebimento(uuid, date, numeric, text, text, boolean)') is null
     and to_regprocedure('public.registrar_devolucao(uuid, date, numeric, text, text)') is null, ''

  union all
  select 5, 'Funções internas fechadas (nem o usuário logado executa)',
         (select count(*) from funcoes_internas f where to_regprocedure(f.assinatura) is not null) = 4
     and not exists (select 1 from funcoes_internas f
                      where has_function_privilege('authenticated', f.assinatura, 'EXECUTE')
                         or has_function_privilege('anon', f.assinatura, 'EXECUTE')), ''

  union all
  select 6, 'Conferência no fim da gravação também no Caixa',
         exists (select 1 from pg_trigger where tgrelid = 'public.movimentos_caixa'::regclass and tgenabled <> 'D'
                    and tgdeferrable and tginitdeferred
                    and tgfoid = 'public.tg_movimentos_caixa_conferir_pedido()'::regprocedure)
     and exists (select 1 from pg_proc where oid = to_regprocedure('public.conferir_pedido(uuid)')
                    and prosrc like '%movimentos_caixa%'), ''

  union all
  select 7, 'Todo recebimento ATIVO tem sua entrada no Caixa (mesma data e valor, não estornada)',
         not exists (select 1 from public.recebimentos_venda r
                      where r.situacao = 'ATIVO'
                        and not exists (select 1 from mov_ativo m where m.recebimento_id = r.id and m.origem = 'RECEBIMENTO'
                                           and m.tipo = 'ENTRADA' and m.valor = r.valor and m.data = r.data)),
         (select count(*) from public.recebimentos_venda where situacao = 'ATIVO')::text || ' recebimento(s) ativo(s)'

  union all
  select 8, 'Toda devolução ATIVA tem sua saída no Caixa (mesma data e valor, não estornada)',
         not exists (select 1 from public.devolucoes_venda d
                      where d.situacao = 'ATIVO'
                        and not exists (select 1 from mov_ativo m where m.devolucao_id = d.id and m.origem = 'REEMBOLSO'
                                           and m.tipo = 'SAIDA' and m.valor = d.valor and m.data = d.data)),
         (select count(*) from public.devolucoes_venda where situacao = 'ATIVO')::text || ' devolução(ões) ativa(s)'

  union all
  select 9, 'Lançamento estornado: sem movimento (antes da integração) ou com o movimento estornado no Caixa',
         not exists (select 1 from mov_ativo m join public.recebimentos_venda r on r.id = m.recebimento_id where r.situacao = 'ESTORNADO')
     and not exists (select 1 from mov_ativo m join public.devolucoes_venda d on d.id = m.devolucao_id where d.situacao = 'ESTORNADO'), ''

  union all
  select 10, 'Nenhum movimento de pedido solto (sem o lançamento correspondente)',
         not exists (select 1 from public.movimentos_caixa where origem = 'RECEBIMENTO' and recebimento_id is null)
     and not exists (select 1 from public.movimentos_caixa where origem = 'REEMBOLSO' and devolucao_id is null), ''

  union all
  select 11, 'Totais batem: entradas de pedidos no Caixa = recebimentos ativos; saídas = devoluções ativas',
         (select coalesce(sum(valor), 0) from mov_ativo where origem = 'RECEBIMENTO')
           = (select coalesce(sum(valor), 0) from public.recebimentos_venda where situacao = 'ATIVO')
     and (select coalesce(sum(valor), 0) from mov_ativo where origem = 'REEMBOLSO')
           = (select coalesce(sum(valor), 0) from public.devolucoes_venda where situacao = 'ATIVO'),
         'Recebido no Caixa: R$ ' || replace(to_char((select coalesce(sum(valor), 0) from mov_ativo where origem = 'RECEBIMENTO'), 'FM9999999990.00'), '.', ',')
           || ' · Devolvido: R$ ' || replace(to_char((select coalesce(sum(valor), 0) from mov_ativo where origem = 'REEMBOLSO'), 'FM9999999990.00'), '.', ',')

  union all
  select 12, 'Informativo: saldo atual do Caixa', true,
         'R$ ' || replace(to_char((select coalesce(sum(case when tipo = 'ENTRADA' then valor else -valor end), 0) from public.movimentos_caixa), 'FM9999999990.00'), '.', ',')
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
