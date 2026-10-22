-- =====================================================================
-- Arts com Você · Variações no catálogo público (Lote D2, R117)
--
-- O que este arquivo faz:
--   · catalogo_variacoes (nova, o visitante executa): para cada produto do
--     catálogo que tem combinações, devolve as opções (só os valores que
--     aparecem em alguma combinação ligada) e as combinações ligadas, com o
--     preço de cada uma. Produto personalizado: combinações sem preço
--     (sob consulta). Combinação desligada não aparece.
--     Não devolve custos, fichas, peças prontas nem combinações desligadas.
--
-- O que NÃO muda:
--   · catalogo_publico, catalogo_fotos, as fotos e as regras da pasta;
--   · produtos, combinações, pedidos, produção, Caixa, estoque, Joca e Shopee.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/catalogo_variacoes_verificacao.sql e as gerais.
-- Tudo ou nada: se qualquer passo falhar, nada é alterado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.catalogo_publico()') is null then
    raise exception 'O catálogo público (sql/11) precisa estar instalado. Nada foi alterado.';
  end if;
  if to_regclass('public.produto_variacoes') is null then
    raise exception 'As variações de produto (sql/22) precisam estar instaladas. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'catalogo_variacoes') then
    raise exception 'Já existe a função catalogo_variacoes. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Combinações do catálogo (R117)
-- ---------------------------------------------------------------------
create function public.catalogo_variacoes()
returns table (produto_id uuid, opcoes jsonb, combinacoes jsonb)
language sql
stable
security definer
set search_path = public
as $$
  with prod as (
    select p.id, p.personalizado
      from public.produtos p
     where p.ativo and p.no_catalogo
       and exists (select 1 from public.produto_variacoes v where v.produto_id = p.id)
  ),
  ligadas as (
    select v.id, v.produto_id, v.descricao, v.ordem,
           case when pr.personalizado then null else v.preco end as preco
      from public.produto_variacoes v
      join prod pr on pr.id = v.produto_id
     where v.ativo
  ),
  usados as (
    select distinct x.valor_id
      from public.produto_variacao_valores x
      join ligadas l on l.id = x.variacao_id
  )
  select pr.id,
         coalesce((select jsonb_agg(jsonb_build_object(
                      'nome', o.nome,
                      'valores', coalesce((select jsonb_agg(ov.valor order by ov.ordem)
                                             from public.produto_opcao_valores ov
                                            where ov.opcao_id = o.id and ov.id in (select valor_id from usados)), '[]'::jsonb))
                    order by o.ordem)
                     from public.produto_opcoes o where o.produto_id = pr.id), '[]'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object(
                      'id', l.id,
                      'descricao', l.descricao,
                      'preco', l.preco,
                      'valores', (select jsonb_agg(ov.valor order by o.ordem)
                                    from public.produto_variacao_valores x
                                    join public.produto_opcao_valores ov on ov.id = x.valor_id
                                    join public.produto_opcoes o on o.id = ov.opcao_id
                                   where x.variacao_id = l.id))
                    order by l.ordem, l.descricao)
                     from ligadas l where l.produto_id = pr.id), '[]'::jsonb)
    from prod pr
   order by pr.id;
$$;

comment on function public.catalogo_variacoes() is
  'Catálogo público (R117): opções e combinações ligadas dos produtos do catálogo, com o preço de cada combinação.';


-- ---------------------------------------------------------------------
-- 2. Acesso
-- ---------------------------------------------------------------------
revoke all on function public.catalogo_variacoes() from public;
grant execute on function public.catalogo_variacoes() to anon, authenticated;

commit;

-- Pronto. Confira com sql/catalogo_variacoes_verificacao.sql.
