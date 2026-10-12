-- =====================================================================
-- Arts com Você · Conferência ANTES de instalar os Pedidos Diretos
-- Essencial (lote P1-a, sql/07_pedidos_diretos_essencial.sql)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run.
-- Resultado esperado: todas as linhas "OK". Qualquer "FALHOU" impede a
-- instalação (a própria instalação também recusa, sem alterar nada).
-- =====================================================================

with nomes_tabela(nome) as (
  values ('clientes'), ('vendas'), ('itens_venda'), ('historico_status_pedido'), ('vw_pedidos'),
         ('recebimentos_venda'), ('devolucoes_venda')
),
nomes_tipo(nome) as (
  values ('status_pedido_direto'), ('origem_pedido_direto'), ('status_financeiro_pedido')
),
nomes_funcao(nome) as (
  values ('salvar_cliente'), ('definir_cliente_ativo'), ('excluir_cliente'), ('salvar_pedido'),
         ('mudar_status_pedido'), ('cancelar_pedido'), ('proximo_numero_pedido'), ('canal_boca_a_boca'),
         ('recalcular_pedido'), ('conferir_pedido'), ('tg_vendas_protege'), ('tg_itens_venda_protege'),
         ('tg_historico_status_imutavel'), ('tg_vendas_conferir'), ('tg_itens_venda_conferir')
),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'Nomes de tabelas e consulta livres (inclusive os do P1-b)',
         not exists (select 1 from nomes_tabela n where to_regclass('public.' || n.nome) is not null),
         coalesce((select 'Já existem: ' || string_agg(n.nome, ', ') from nomes_tabela n
                    where to_regclass('public.' || n.nome) is not null), '')

  union all
  select 2, 'Nomes de tipos livres',
         not exists (select 1 from nomes_tipo n where to_regtype('public.' || n.nome) is not null),
         coalesce((select 'Já existem: ' || string_agg(n.nome, ', ') from nomes_tipo n
                    where to_regtype('public.' || n.nome) is not null), '')

  union all
  select 3, 'Nomes de funções livres',
         not exists (select 1 from pg_proc p join nomes_funcao n on n.nome = p.proname
                      where p.pronamespace = 'public'::regnamespace),
         coalesce((select 'Já existem: ' || string_agg(distinct p.proname, ', ') from pg_proc p
                     join nomes_funcao n on n.nome = p.proname
                    where p.pronamespace = 'public'::regnamespace), '')

  union all
  select 4, 'Tabelas usadas existem: canais, materiais, produtos, produto_cores, auditoria',
         to_regclass('public.canais') is not null and to_regclass('public.materiais') is not null
     and to_regclass('public.produtos') is not null and to_regclass('public.produto_cores') is not null
     and to_regclass('public.auditoria') is not null, ''

  union all
  select 5, 'Funções usadas existem: exigir_admin, is_admin, hoje, tg_auditoria, tg_updated_at',
         to_regprocedure('public.exigir_admin()') is not null and to_regprocedure('public.is_admin()') is not null
     and to_regprocedure('public.hoje()') is not null and to_regprocedure('public.tg_auditoria()') is not null
     and to_regprocedure('public.tg_updated_at()') is not null, ''

  union all
  select 6, 'exigir_admin confere a Admin (is_admin) e roda como dono',
         exists (select 1 from pg_proc where oid = to_regprocedure('public.exigir_admin()')
                    and prosecdef and prosrc like '%is_admin()%'), ''

  union all
  select 7, 'Lista de formas de pagamento como aprovada na P3',
         (select array_agg(e.enumlabel order by e.enumsortorder) from pg_enum e
           where e.enumtypid = to_regtype('public.forma_pagamento'))
           = array['PIX', 'DINHEIRO', 'CARTAO_CREDITO', 'CARTAO_DEBITO', 'BOLETO', 'TRANSFERENCIA', 'OUTROS']::name[],
         coalesce((select string_agg(e.enumlabel, ', ' order by e.enumsortorder) from pg_enum e
                    where e.enumtypid = to_regtype('public.forma_pagamento')), 'tipo não encontrado')

  union all
  select 8, 'Canal "Boca a Boca" existe uma única vez, sem repasse',
         (select count(*) from public.canais where lower(trim(nome)) = 'boca a boca') = 1
     and exists (select 1 from public.canais where lower(trim(nome)) = 'boca a boca' and not usa_repasse),
         coalesce((select string_agg(nome || case when ativo then '' else ' (inativo)' end, ', ' order by ordem)
                     from public.canais), '')

  union all
  select 9, 'Colunas usadas do Catálogo e de Materiais existem',
         (select count(*) from pg_attribute
           where not attisdropped and attnum > 0
             and ((attrelid = to_regclass('public.produtos') and attname in ('id', 'nome', 'ativo'))
               or (attrelid = to_regclass('public.produto_cores') and attname in ('produto_id', 'material_id'))
               or (attrelid = to_regclass('public.materiais') and attname in ('id', 'categoria', 'tipo', 'variacao', 'ativo')))) = 10, ''

  union all
  select 10, 'Versão do Postgres 15 ou mais (colunas calculadas e consulta com security_invoker)',
         current_setting('server_version_num')::integer >= 150000,
         current_setting('server_version')

  union all
  select 11, 'Modo padrão das gravações é "read committed" (usado pela numeração)',
         current_setting('default_transaction_isolation') = 'read committed',
         current_setting('default_transaction_isolation')

  union all
  select 12, 'Informativo: produtos, filamentos e canais cadastrados hoje',
         true,
         (select count(*) from public.produtos)::text || ' produto(s) · '
           || (select count(*) from public.materiais where categoria = 'FILAMENTO')::text || ' filamento(s) · '
           || (select count(*) from public.canais)::text || ' canal(is)'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
