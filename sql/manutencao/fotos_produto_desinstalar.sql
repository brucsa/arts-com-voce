-- =====================================================================
-- Arts com Você · Desinstalar as fotos do produto (desfaz sql/20)
--
-- Use só se precisar voltar atrás logo depois de instalar, ANTES de
-- cadastrar qualquer foto a mais: recusa se já houver alguma. Devolve
-- foto_no_catalogo à versão do sql/11 e tira a tabela, os gatilhos e as
-- funções do sql/20. As capas dos produtos não mudam. Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.produto_fotos') is null then
    raise exception 'As fotos do produto não estão instaladas. Nada foi alterado.';
  end if;
  if exists (select 1 from public.produto_fotos) then
    raise exception 'Já existem fotos a mais cadastradas. A desinstalação não é possível. Nada foi alterado.';
  end if;
end;
$$;

-- foto_no_catalogo: versão do sql/11 (mesma assinatura e permissões)
create or replace function public.foto_no_catalogo(p_nome text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.produtos p
                  where p.foto_path = p_nome and p.ativo and p.no_catalogo);
$$;

drop trigger trg_produtos_foto_unica on public.produtos;
drop table public.produto_fotos;
drop function public.salvar_fotos_produto(uuid, text[]);
drop function public.catalogo_fotos(uuid);
drop function public.tg_fotos_produto_unicas();

commit;

-- Pronto. Confira com as verificações gerais.
