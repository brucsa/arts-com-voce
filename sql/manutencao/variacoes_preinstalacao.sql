-- =====================================================================
-- Arts com Você · Conferência ANTES das variações de produto (sql/22)
--
-- SÓ LEITURA: não cria, não altera e não apaga nada no banco.
-- Supabase → SQL Editor → colar → Run. Esperado: nenhum "FALHOU".
-- =====================================================================

with linhas (ordem, item, resultado, detalhe) as (
  select 1, 'Lotes anteriores instalados (repasses sql/19, fotos sql/20, descrição interna sql/21)',
         case when to_regclass('public.repasses_shopee') is not null and to_regclass('public.produto_fotos') is not null
                   and exists (select 1 from pg_attribute where attrelid = 'public.produtos'::regclass
                                 and attname = 'descricao_interna' and not attisdropped)
              then 'OK' else 'FALHOU' end, ''
  union all
  select 2, 'Variações ainda não instaladas',
         case when to_regclass('public.produto_variacoes') is null
                   and not exists (select 1 from pg_attribute where attname = 'variacao_id' and not attisdropped
                                     and attrelid in ('public.itens_venda'::regclass, 'public.producoes'::regclass, 'public.pecas_prontas'::regclass))
              then 'OK' else 'FALHOU' end, ''
  union all
  select 3, 'registrar_producao na forma anterior (sem a combinação)',
         case when to_regprocedure('public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid)') is not null
              then 'OK' else 'FALHOU' end, ''
  union all
  select 10, 'Produtos, itens de pedido e peças prontas (nada disso muda)', 'INFO',
         (select count(*) from public.produtos)::text || ' produto(s) · '
         || (select count(*) from public.itens_venda)::text || ' item(ns) · '
         || (select count(*) from public.pecas_prontas)::text || ' lote(s) de peças prontas'
)
select ordem, item, resultado, detalhe from linhas order by ordem;
