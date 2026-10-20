-- =====================================================================
-- Arts com Você · Desinstalar o catálogo público (desfaz sql/11)
--
-- Use só se precisar voltar atrás. Remove a regra das fotos do catálogo,
-- as funções definir_produto_catalogo, catalogo_publico e foto_no_catalogo
-- e as colunas no_catalogo e personalizado. Não mexe em mais nada.
--
-- Recusa se algum produto estiver marcado: desmarque antes, para não
-- perder marcações sem querer. Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if not exists (select 1 from pg_attribute where attrelid = to_regclass('public.produtos')
                    and attname in ('no_catalogo', 'personalizado') and not attisdropped) then
    raise exception 'O catálogo público não está instalado. Nada foi alterado.';
  end if;
  if exists (select 1 from public.produtos where no_catalogo or personalizado) then
    raise exception 'Há produtos marcados "No catálogo" ou "Personalizado". Desmarque todos antes de desinstalar. Nada foi alterado.';
  end if;
end;
$$;

drop policy if exists produtos_fotos_select_catalogo on storage.objects;
drop function if exists public.foto_no_catalogo(text);
drop function if exists public.catalogo_publico();
drop function if exists public.definir_produto_catalogo(uuid, boolean, boolean);
alter table public.produtos drop column personalizado, drop column no_catalogo;

commit;
