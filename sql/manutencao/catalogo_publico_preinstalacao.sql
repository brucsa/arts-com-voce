-- =====================================================================
-- Arts com Você · Conferência ANTES do catálogo público (sql/11_catalogo_publico.sql)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run. Resultado esperado: bloco A todo "OK".
-- =====================================================================

with linhas (bloco, ordem, item, resultado, detalhe) as (

  -- A. Estrutura -------------------------------------------------------
  select 'A. Estrutura', 1, 'Catálogo Essencial instalado (produtos, cores e funções)',
         case when to_regclass('public.produtos') is not null and to_regclass('public.produto_cores') is not null
                   and to_regclass('public.vw_produtos') is not null
                   and to_regprocedure('public.salvar_produto(uuid, text, text, text, integer, integer, numeric, numeric, numeric, numeric, numeric, uuid[])') is not null
                   and to_regprocedure('public.definir_produto_ativo(uuid, boolean)') is not null
              then 'OK' else 'FALHOU' end, ''
  union all
  select 'A. Estrutura', 2, 'Pasta "produtos" do Storage existe e é privada',
         case when exists (select 1 from storage.buckets where id = 'produtos' and not public) then 'OK' else 'FALHOU' end, ''
  union all
  select 'A. Estrutura', 3, 'Catálogo público ainda não instalado (marcações, funções e regra livres)',
         case when not exists (select 1 from pg_attribute where attrelid = to_regclass('public.produtos')
                                  and attname in ('no_catalogo', 'personalizado') and not attisdropped)
                   and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                                      and proname in ('definir_produto_catalogo', 'catalogo_publico', 'foto_no_catalogo'))
                   and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                                      and policyname = 'produtos_fotos_select_catalogo')
              then 'OK' else 'FALHOU' end, ''
  union all
  select 'A. Estrutura', 4, 'Hoje o visitante sem login não lê produtos, cores nem fotos',
         case when not has_table_privilege('anon', 'public.produtos', 'SELECT')
                   and not has_table_privilege('anon', 'public.produto_cores', 'SELECT')
                   and not has_table_privilege('anon', 'public.vw_produtos', 'SELECT')
                   and not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                                      and coalesce(qual, '') like '%produtos%'
                                      and ('anon' = any (roles) or 'public' = any (roles)))
              then 'OK' else 'FALHOU' end, ''

  -- B. Situação dos produtos (informativo) -------------------------------
  union all
  select 'B. Produtos', 10, 'Produtos ativos', 'INFO', (select count(*) from public.produtos where ativo)::text
  union all
  select 'B. Produtos', 11, 'Produtos ativos com preço', 'INFO', (select count(*) from public.produtos where ativo and preco_venda is not null)::text
  union all
  select 'B. Produtos', 12, 'Produtos ativos com foto', 'INFO', (select count(*) from public.produtos where ativo and foto_path is not null)::text
  union all
  select 'B. Produtos', 13, 'Produtos ativos com descrição', 'INFO', (select count(*) from public.produtos where ativo and descricao is not null)::text
  union all
  select 'B. Produtos', 14, 'Depois da instalação, produtos visíveis no catálogo', 'INFO', '0 (todos começam desmarcados)'
)
select bloco, item, resultado, detalhe from linhas order by ordem;
