-- =====================================================================
-- Arts com Você · Verificação do módulo "Pedidos da Shopee"
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with tabelas(nome) as (
  values ('shopee_importacoes'), ('shopee_pedidos'), ('shopee_pedido_itens')
),
checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'As 3 tabelas da Shopee existem',
         (select count(*) from tabelas t where to_regclass('public.' || t.nome) is not null) = 3, ''

  union all
  select 2, 'As 3 tabelas da Shopee têm RLS ligado',
         not exists (select 1 from tabelas t join pg_class c on c.oid = to_regclass('public.' || t.nome)
                      where not c.relrowsecurity), ''

  union all
  select 3, 'Visitante sem login não acessa as tabelas da Shopee',
         not exists (select 1 from tabelas t
                      where has_table_privilege('anon', 'public.' || t.nome, 'SELECT')
                         or has_table_privilege('anon', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('anon', 'public.' || t.nome, 'UPDATE')
                         or has_table_privilege('anon', 'public.' || t.nome, 'DELETE')), ''

  union all
  select 4, 'Usuário logado não grava direto nas tabelas da Shopee (só pela função)',
         not exists (select 1 from tabelas t
                      where has_table_privilege('authenticated', 'public.' || t.nome, 'INSERT')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'UPDATE')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'DELETE')
                         or has_table_privilege('authenticated', 'public.' || t.nome, 'TRUNCATE')), ''

  union all
  select 5, 'Leitura das tabelas da Shopee só para a Admin',
         (select count(*) from pg_policies p join tabelas t on t.nome = p.tablename
           where p.schemaname = 'public' and p.cmd = 'SELECT' and p.qual like '%is_admin()%') = 3
     and not exists (select 1 from pg_policies p join tabelas t on t.nome = p.tablename
                      where p.schemaname = 'public' and p.cmd <> 'SELECT'), ''

  union all
  select 6, 'A função de importação exige a Admin',
         exists (select 1 from pg_proc where proname = 'importar_pedidos_shopee'
                    and prosecdef and prosrc like '%exigir_admin()%'), ''

  union all
  select 7, 'Visitante sem login não executa a importação',
         not has_function_privilege('anon',
           'public.importar_pedidos_shopee(text, integer, integer, jsonb, boolean)', 'EXECUTE'), ''

  union all
  select 8, 'Nenhum dado pessoal do comprador guardado (colunas e cópias)',
         not exists (select 1 from information_schema.columns c join tabelas t on t.nome = c.table_name
                      where c.table_schema = 'public'
                        and c.column_name ~* '^(cpf|telefone|endereco|cep|cidade|bairro|uf|pais|destinatario|nome_destinatario|comprador_usuario|usuario_comprador)$')
     and not exists (select 1 from public.shopee_pedidos
                      where colunas ?| array['Nome de usuário (comprador)', 'Nome do destinatário', 'Telefone',
                                             'CPF do Comprador', 'Endereço de entrega', 'Cidade', 'Bairro', 'UF',
                                             'País', 'CEP', 'Observação do comprador'])
     and not exists (select 1 from public.shopee_pedido_itens
                      where colunas ?| array['Nome de usuário (comprador)', 'Nome do destinatário', 'Telefone',
                                             'CPF do Comprador', 'Endereço de entrega', 'Cidade', 'Bairro', 'UF',
                                             'País', 'CEP', 'Observação do comprador']),
         ''

  union all
  select 9, 'Itens nunca são apagados junto com o pedido (sem exclusão em cascata)',
         exists (select 1 from pg_constraint
                  where conrelid = 'public.shopee_pedido_itens'::regclass and contype = 'f'
                    and confrelid = 'public.shopee_pedidos'::regclass and confdeltype = 'r'), ''

  union all
  select 10, 'Alterações nas tabelas da Shopee ficam na auditoria',
         (select count(*) from pg_trigger tg join pg_class c on c.oid = tg.tgrelid join tabelas t on t.nome = c.relname
           where not tg.tgisinternal and tg.tgfoid = 'public.tg_auditoria()'::regprocedure) = 3, ''
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
