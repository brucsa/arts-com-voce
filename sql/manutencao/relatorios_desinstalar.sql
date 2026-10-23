-- =====================================================================
-- Arts com Você · Desinstalar os Relatórios (desfaz sql/25)
--
-- Tira só a função relatorio_canais. Nenhum dado é apagado. Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if to_regprocedure('public.relatorio_canais(date, date)') is null then
    raise exception 'Os Relatórios não estão instalados. Nada foi alterado.';
  end if;
end;
$$;

drop function public.relatorio_canais(date, date);

commit;

-- Pronto. Confira com as verificações gerais.
