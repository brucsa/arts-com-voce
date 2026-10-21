-- =====================================================================
-- Arts com Você · Desinstalar a ficha de consumo (desfaz sql/14)
--
-- Use só se precisar voltar atrás logo depois de instalar, ANTES de
-- cadastrar fichas ou cores por parte: recusa se já houver alguma.
-- Remove as 3 tabelas, as funções e o gatilho de itens_venda.
-- Não mexe em produtos, pedidos, estoque nem Caixa. Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.produto_partes') is null then
    raise exception 'A ficha de consumo não está instalada. Nada foi alterado.';
  end if;
  if exists (select 1 from public.produto_partes) or exists (select 1 from public.produto_materiais)
     or exists (select 1 from public.item_venda_partes) then
    raise exception 'Já existem fichas ou cores por parte cadastradas. A desinstalação apagaria esses dados. Nada foi alterado.';
  end if;
end;
$$;

drop trigger if exists trg_itens_venda_copiar_ficha on public.itens_venda;
drop table public.item_venda_partes;
drop table public.produto_materiais;
drop table public.produto_partes;
drop function if exists public.tg_itens_venda_copiar_ficha();
drop function if exists public.tg_item_venda_partes_protege();
drop function if exists public.salvar_ficha_produto(uuid, jsonb, jsonb);
drop function if exists public.definir_cores_partes(uuid, jsonb);

-- O histórico da auditoria dessas tabelas fica guardado.

commit;
