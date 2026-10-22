-- =====================================================================
-- Arts com Você · Desinstalar as variações no catálogo (desfaz sql/23)
--
-- Tira só a função catalogo_variacoes. O catálogo volta a mostrar os
-- produtos sem a escolha das opções. Nenhum dado é apagado. Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.catalogo_variacoes()') is null then
    raise exception 'As variações no catálogo não estão instaladas. Nada foi alterado.';
  end if;
end;
$$;

drop function public.catalogo_variacoes();

commit;

-- Pronto. Confira com as verificações gerais.
