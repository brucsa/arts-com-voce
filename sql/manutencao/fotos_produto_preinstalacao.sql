-- =====================================================================
-- Arts com Você · Conferência ANTES das fotos do produto (sql/20)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run. Esperado: nenhum "FALHOU".
-- =====================================================================

with linhas (ordem, item, resultado, detalhe) as (
  select 1, 'Produtos (sql/06) e catálogo público (sql/11) instalados',
         case when to_regclass('public.produtos') is not null
                   and exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'catalogo_publico')
                   and exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'foto_no_catalogo')
              then 'OK' else 'FALHOU' end, ''
  union all
  select 2, 'Fotos do produto ainda não instaladas',
         case when to_regclass('public.produto_fotos') is null
                   and not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                                      and proname in ('salvar_fotos_produto', 'catalogo_fotos', 'tg_fotos_produto_unicas'))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 3, 'Toda capa cadastrada existe na pasta "produtos"',
         case when not exists (select 1 from public.produtos p where p.foto_path is not null
                                  and not exists (select 1 from storage.objects o where o.bucket_id = 'produtos' and o.name = p.foto_path))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 10, 'Produtos com foto (capa)', 'INFO',
         (select count(*) from public.produtos where foto_path is not null)::text || ' de '
         || (select count(*) from public.produtos)::text
  union all
  select 11, 'Arquivos na pasta "produtos"', 'INFO',
         (select count(*) from storage.objects where bucket_id = 'produtos')::text
)
select ordem, item, resultado, detalhe from linhas order by ordem;
