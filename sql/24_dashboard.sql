-- =====================================================================
-- Arts com Você · Dashboard (Etapa 10, R122, R123 e R128, versão 1.14)
--
-- O que este arquivo faz:
--   · dashboard(p_inicio, p_fim) (nova, só a Admin): devolve num JSON o que
--     o Início mostra — o resultado do período pela cascata e os alertas.
--     Só lê: não grava nada.
--
-- O que NÃO muda:
--   · nenhuma tabela, consulta, gatilho ou função existente;
--   · pedidos, produção, Caixa, estoque, Joca, Shopee e catálogo.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/dashboard_verificacao.sql e as gerais.
-- Tudo ou nada: se qualquer passo falhar, nada é alterado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.repasses_shopee') is null or to_regclass('public.produto_variacoes') is null then
    raise exception 'Os repasses da Shopee (sql/19) e as variações (sql/22) precisam estar instalados. Nada foi alterado.';
  end if;
  if to_regclass('public.vw_pedido_custos') is null then
    raise exception 'A produção (sql/16) precisa estar instalada. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'dashboard') then
    raise exception 'Já existe a função dashboard. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Dashboard
-- ---------------------------------------------------------------------
create function public.dashboard(p_inicio date, p_fim date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_res jsonb;
begin
  perform public.exigir_admin();
  if p_inicio is null or p_fim is null then raise exception 'Informe o início e o fim do período.'; end if;
  if p_fim < p_inicio then raise exception 'O fim do período não pode ser antes do início.'; end if;
  if p_fim - p_inicio > 3660 then raise exception 'O período pode ter até 10 anos.'; end if;

  with
  -- Pedidos do período (pela data do pedido), sem os cancelados (R123)
  ped as (
    select v.id,
           c.receita, c.taxa_plataforma as taxa, c.custo_total as custo, c.comissao_joca as comissao,
           v.frete
      from public.vendas v
      join public.vw_pedido_custos c on c.venda_id = v.id
     where v.data between p_inicio and p_fim and v.status_pedido <> 'CANCELADO'
  ),
  tot as (
    select count(*) as pedidos,
           coalesce(sum(receita), 0) as faturamento,
           coalesce(sum(frete), 0) as frete,
           coalesce(sum(taxa), 0) as taxas,
           coalesce(sum(custo), 0) as custos,
           coalesce(sum(comissao), 0) as comissao,
           count(*) filter (where custo = 0) as sem_custo
      from ped
  ),
  perdas as (select coalesce(sum(valor), 0) as valor from public.vw_perdas where data between p_inicio and p_fim),
  despesas as (
    select coalesce(sum(l.valor), 0) as valor
      from public.lancamentos l join public.categorias_lanc c on c.id = l.categoria_id
     where l.status = 'ATIVO' and c.natureza = 'DESPESA' and l.data between p_inicio and p_fim
  ),
  alertas as (
    select (select count(*) from public.vw_pedidos where selo_prazo = 'ATRASADO') as atrasados,
           (select count(*) from public.vw_pedidos where selo_prazo = 'VENCE_HOJE') as vencem_hoje,
           (select count(*) from public.vw_itens_producao
             where faltam > 0 and status_pedido in ('AGUARDANDO', 'PRODUZINDO')) as itens_a_produzir,
           (select coalesce(sum(faltam), 0) from public.vw_itens_producao
             where faltam > 0 and status_pedido in ('AGUARDANDO', 'PRODUZINDO')) as pecas_a_produzir,
           (select count(*) from public.vw_estoque where ativo and estoque_baixo) as estoque_baixo,
           (select count(*) from public.vw_repasses_shopee_pendentes) as repasses_a_confirmar,
           (select count(*) from public.vw_avisos_shopee) as avisos_shopee,
           (select count(*) from public.vw_gastos where situacao in ('A_PAGAR', 'PAGO_EM_PARTE')) as gastos_a_pagar
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),
    'resultado', jsonb_build_object(
      'pedidos', t.pedidos,
      'faturamento', t.faturamento,
      'frete', t.frete,
      'taxas', t.taxas,
      'custos', t.custos,
      'perdas', pe.valor,
      'despesas', de.valor,
      'comissao_joca', t.comissao,
      'resultado', t.faturamento + t.frete - t.taxas - t.custos - pe.valor - de.valor - t.comissao,
      'ticket_medio', case when t.pedidos > 0 then round(t.faturamento / t.pedidos, 2) end,
      'pedidos_sem_custo', t.sem_custo),
    'alertas', to_jsonb(a))
    into v_res
    from tot t, perdas pe, despesas de, alertas a;
  return v_res;
end;
$$;

comment on function public.dashboard(date, date) is
  'Início (R122, R123, R128): resultado do período e alertas. Só lê.';


-- ---------------------------------------------------------------------
-- 2. Acesso: só a Admin (a função exige a Admin)
-- ---------------------------------------------------------------------
revoke all on function public.dashboard(date, date) from public, anon;
grant execute on function public.dashboard(date, date) to authenticated;

commit;

-- Pronto. Confira com sql/dashboard_verificacao.sql.
