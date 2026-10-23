-- =====================================================================
-- Arts com Você · Relatórios · canais (Etapa 11, R129–R131, versão 1.15)
--
-- O que este arquivo faz:
--   · relatorio_canais(p_inicio, p_fim) (nova, só a Admin): Direto e Shopee
--     lado a lado no período, com o total — pedidos, ticket médio,
--     faturamento, frete, taxas, custos, comissão do Joca, lucro dos pedidos,
--     margem e pedidos sem custo de produção. Mesmas regras do Início (R123).
--     Só lê: não grava nada.
--
-- O que NÃO muda:
--   · nenhuma tabela, consulta, gatilho ou função existente;
--   · pedidos, produção, Caixa, estoque, Joca, Shopee e catálogo.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/relatorios_verificacao.sql e as gerais.
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
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'relatorio_canais') then
    raise exception 'Já existe a função relatorio_canais. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Canais (R130, R131)
-- ---------------------------------------------------------------------
create function public.relatorio_canais(p_inicio date, p_fim date)
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
  -- Pedidos do período (pela data do pedido), sem os cancelados — como no Início (R123)
  ped as (
    select case when v.shopee_pedido_ref is not null then 'SHOPEE' else 'DIRETO' end as canal,
           c.receita, v.frete, c.taxa_plataforma as taxa, c.custo_total as custo, c.comissao_joca as comissao
      from public.vendas v
      join public.vw_pedido_custos c on c.venda_id = v.id
     where v.data between p_inicio and p_fim and v.status_pedido <> 'CANCELADO'
  ),
  linhas as (
    select k.canal,
           count(p.canal) as pedidos,
           coalesce(sum(p.receita), 0) as faturamento,
           coalesce(sum(p.frete), 0) as frete,
           coalesce(sum(p.taxa), 0) as taxas,
           coalesce(sum(p.custo), 0) as custos,
           coalesce(sum(p.comissao), 0) as comissao,
           count(*) filter (where p.canal is not null and p.custo = 0) as sem_custo
      from (values ('DIRETO', 1), ('SHOPEE', 2)) k(canal, ordem)
      left join ped p on p.canal = k.canal
     group by k.canal, k.ordem
     order by k.ordem
  ),
  com_total as (
    select canal, pedidos, faturamento, frete, taxas, custos, comissao, sem_custo from linhas
    union all
    select 'TOTAL', sum(pedidos), sum(faturamento), sum(frete), sum(taxas), sum(custos), sum(comissao), sum(sem_custo) from linhas
  ),
  calc as (
    select *, faturamento + frete - taxas - custos - comissao as lucro from com_total
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim),
    'canais', (select jsonb_agg(jsonb_build_object(
        'canal', canal, 'pedidos', pedidos,
        'ticket_medio', case when pedidos > 0 then round(faturamento / pedidos, 2) end,
        'faturamento', faturamento, 'frete', frete, 'taxas', taxas, 'custos', custos, 'comissao_joca', comissao,
        'lucro', lucro,
        'margem', case when faturamento > 0 then round(lucro / faturamento * 100, 1) end,
        'pedidos_sem_custo', sem_custo)
        order by case canal when 'DIRETO' then 1 when 'SHOPEE' then 2 else 3 end)
      from calc))
    into v_res;
  return v_res;
end;
$$;

comment on function public.relatorio_canais(date, date) is
  'Relatórios (R129–R131): Direto e Shopee lado a lado no período, com o total. Só lê.';


-- ---------------------------------------------------------------------
-- 2. Acesso: só a Admin (a função exige a Admin)
-- ---------------------------------------------------------------------
revoke all on function public.relatorio_canais(date, date) from public, anon;
grant execute on function public.relatorio_canais(date, date) to authenticated;

commit;

-- Pronto. Confira com sql/relatorios_verificacao.sql.
