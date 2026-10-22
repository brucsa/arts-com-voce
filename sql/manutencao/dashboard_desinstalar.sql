-- =====================================================================
-- Arts com Você · Desinstalar o Dashboard (desfaz sql/24)
--
-- Tira só a função dashboard. Nenhum dado é apagado. Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.dashboard(date, date)') is null then
    raise exception 'O Dashboard não está instalado. Nada foi alterado.';
  end if;
end;
$$;

drop function public.dashboard(date, date);

commit;

-- Pronto. Confira com as verificações gerais.
