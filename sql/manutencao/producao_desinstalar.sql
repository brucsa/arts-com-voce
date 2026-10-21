-- =====================================================================
-- Arts com Você · Desinstalar a produção (desfaz sql/16)
--
-- Use só se precisar voltar atrás logo depois de instalar, ANTES de
-- registrar qualquer produção, peça pronta, embalagem ou ajuste: recusa se
-- já houver algum (os movimentos de estoque nunca são apagados).
-- Remove as tabelas, consultas, funções e gatilhos da produção.
-- Os motivos do sql/15 continuam na lista: são permanentes.
-- Não mexe em produtos, pedidos, estoque nem Caixa. Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.producoes') is null then
    raise exception 'A produção não está instalada. Nada foi alterado.';
  end if;
  if exists (select 1 from public.producoes) or exists (select 1 from public.saidas_pecas_prontas)
     or exists (select 1 from public.embalagens_pedido) or exists (select 1 from public.ajustes_estoque) then
    raise exception 'Já existem produções, peças prontas, embalagens ou ajustes registrados. A desinstalação não é possível, porque os movimentos de estoque nunca são apagados. Nada foi alterado.';
  end if;
end;
$$;

drop trigger if exists trg_vendas_embalagem on public.vendas;
drop trigger if exists trg_itens_venda_producao_protege on public.itens_venda;
drop view if exists public.vw_pedido_custos;
drop view if exists public.vw_perdas;
drop view if exists public.vw_pecas_prontas;
drop view if exists public.vw_itens_producao;
drop table public.ajustes_estoque;
drop table public.embalagens_pedido;
drop table public.saidas_pecas_prontas;
drop table public.pecas_prontas;
drop table public.producao_consumos;
drop table public.producoes;
drop type public.tipo_saida_peca;
drop type public.resultado_producao;
drop type public.destino_producao;
drop function if exists public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid);
drop function if exists public.estornar_producao(uuid, text);
drop function if exists public.usar_peca_pronta(uuid, uuid, integer, uuid);
drop function if exists public.baixar_peca_pronta(uuid, integer, text, text, date, uuid);
drop function if exists public.estornar_saida_peca(uuid, text);
drop function if exists public.ajustar_estoque(uuid, numeric, text, date, uuid);
drop function if exists public.atualizar_pedido_pronto(uuid);
drop function if exists public.item_faltam(uuid);
drop function if exists public.baixar_material(uuid, numeric, date, public.motivo_estoque, text);
drop function if exists public.tg_vendas_embalagem();
drop function if exists public.tg_itens_venda_producao_protege();
drop function if exists public.tg_producao_protege();

-- O histórico da auditoria dessas tabelas fica guardado.

commit;
