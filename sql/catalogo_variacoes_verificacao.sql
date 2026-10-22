-- =====================================================================
-- Arts com Você · Verificação das variações no catálogo (sql/23, Lote D2, R117)
-- Supabase → SQL Editor → colar → Run. Resultado esperado: tudo "OK".
-- Só consulta: não altera nada no banco.
-- =====================================================================

with checagens (ordem, verificacao, passou, detalhe) as (

  select 1, 'catalogo_variacoes existe e o visitante executa',
         to_regprocedure('public.catalogo_variacoes()') is not null
     and has_function_privilege('anon', 'public.catalogo_variacoes()', 'EXECUTE'), ''

  union all
  select 2, 'catalogo_variacoes só lê (estável) e não mostra custo, ficha nem peça pronta',
         exists (select 1 from pg_proc where oid = to_regprocedure('public.catalogo_variacoes()')
                   and prosecdef and provolatile = 's'
                   and prosrc not like '%variacao_partes%' and prosrc not like '%variacao_materiais%'
                   and prosrc not like '%pecas_prontas%' and prosrc not like '%custo%'), ''

  union all
  select 3, 'Só aparecem produtos ativos marcados “No catálogo”',
         not exists (select 1 from public.catalogo_variacoes() c join public.produtos p on p.id = c.produto_id
                      where not (p.ativo and p.no_catalogo)), ''

  union all
  select 4, 'Combinação desligada não aparece',
         not exists (select 1 from public.catalogo_variacoes() c, jsonb_array_elements(c.combinacoes) e
                       join public.produto_variacoes v on v.id = (e ->> 'id')::uuid
                      where not v.ativo), ''

  union all
  select 5, 'Produto personalizado: combinações sem preço (sob consulta)',
         not exists (select 1 from public.catalogo_variacoes() c join public.produtos p on p.id = c.produto_id,
                            jsonb_array_elements(c.combinacoes) e
                      where p.personalizado and e ->> 'preco' is not null), ''

  union all
  select 6, 'O visitante continua sem ler as tabelas das combinações',
         not exists (select 1 from (values ('produto_opcoes'), ('produto_opcao_valores'), ('produto_variacoes'),
                                           ('produto_variacao_valores'), ('variacao_partes'), ('variacao_materiais')) t(nome)
                      where has_table_privilege('anon', 'public.' || t.nome, 'SELECT')), ''

  union all
  select 7, 'Informativo: catálogo',
         true,
         (select count(*) from public.catalogo_variacoes())::text || ' produto(s) com combinações no catálogo · '
         || coalesce((select sum(jsonb_array_length(combinacoes)) from public.catalogo_variacoes()), 0)::text || ' combinação(ões) à venda'
)
select ordem, verificacao, case when passou then 'OK' else 'FALHOU' end as resultado, detalhe
  from checagens order by ordem;
