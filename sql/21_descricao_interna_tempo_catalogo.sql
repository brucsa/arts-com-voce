-- =====================================================================
-- Arts com Você · Descrição interna e tempo de impressão no catálogo
-- Especificação v1.13: R71 e R85 complementadas (decisões de 22/10/2026).
--
-- O que este arquivo faz:
--   · produtos ganha a coluna descricao_interna: anotações que só a Admin
--     vê. A descrição que já existe passa a ser a descrição para o cliente
--     (ela já aparece no catálogo; nada muda para quem visita);
--   · salvar_descricao_interna: grava a descrição interna (só a Admin);
--   · catalogo_publico (trocada): devolve também o tempo de impressão, no
--     fim, para o cliente ver na página do produto. Continua sem a
--     descrição interna, sem custos e sem nada da ficha.
--
-- O que NÃO muda:
--   · nenhum produto existente (a descrição interna começa vazia);
--   · salvar_produto, as fotos, as regras da pasta, pedidos, Caixa, estoque,
--     Joca e Shopee.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/descricao_interna_verificacao.sql e as gerais.
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
  if exists (select 1 from pg_attribute where attrelid = 'public.produtos'::regclass
               and attname = 'descricao_interna' and not attisdropped) then
    raise exception 'A descrição interna já está instalada. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'salvar_descricao_interna') then
    raise exception 'Já existe a função salvar_descricao_interna. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Descrição interna
-- ---------------------------------------------------------------------
alter table public.produtos
  add column descricao_interna text check (descricao_interna is null or length(descricao_interna) <= 4000);

comment on column public.produtos.descricao is 'Descrição para o cliente: aparece no catálogo público (R71, R85).';
comment on column public.produtos.descricao_interna is 'Descrição interna: só a Admin vê (R71 v1.13).';

create or replace function public.salvar_descricao_interna(p_produto_id uuid, p_texto text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_texto text := nullif(trim(coalesce(p_texto, '')), '');
begin
  perform public.exigir_admin();
  if length(coalesce(v_texto, '')) > 4000 then raise exception 'A descrição interna pode ter até 4.000 caracteres.'; end if;
  perform 1 from public.produtos where id = p_produto_id for update;
  if not found then raise exception 'Produto não encontrado.'; end if;
  update public.produtos set descricao_interna = v_texto
   where id = p_produto_id and descricao_interna is distinct from v_texto;
end;
$$;


-- ---------------------------------------------------------------------
-- 2. Catálogo público: + tempo de impressão (R85 v1.13)
--    Mesmo conteúdo de antes, com tempo_impressao_min no fim.
-- ---------------------------------------------------------------------
drop function public.catalogo_publico();

create function public.catalogo_publico()
returns table (id uuid, nome text, descricao text, preco numeric, sob_consulta boolean, foto_path text, cores text[],
               tempo_impressao_min integer)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.nome, p.descricao,
         case when p.personalizado then null else p.preco_venda end,
         (p.personalizado or p.preco_venda is null),
         p.foto_path,
         coalesce((select array_agg(c.cor order by lower(c.cor))
                     from (select distinct on (lower(trim(m.variacao))) trim(m.variacao) as cor
                             from public.produto_cores pc
                             join public.materiais m on m.id = pc.material_id
                            where pc.produto_id = p.id and m.ativo and m.categoria = 'FILAMENTO'
                              and nullif(trim(m.variacao), '') is not null
                            order by lower(trim(m.variacao)), trim(m.variacao)) c), '{}'),
         p.tempo_impressao_min
    from public.produtos p
   where p.ativo and p.no_catalogo
   order by lower(p.nome), p.id;
$$;


-- ---------------------------------------------------------------------
-- 3. Acesso
-- ---------------------------------------------------------------------
revoke all on function public.catalogo_publico() from public;
grant execute on function public.catalogo_publico() to anon, authenticated;
revoke all on function public.salvar_descricao_interna(uuid, text) from public, anon;
grant execute on function public.salvar_descricao_interna(uuid, text) to authenticated;

commit;

-- Pronto. Confira com sql/descricao_interna_verificacao.sql.
