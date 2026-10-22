-- =====================================================================
-- Arts com Você · Desinstalar as vendas da Shopee (desfaz sql/17)
--
-- Use só se precisar voltar atrás logo depois de instalar, ANTES de
-- registrar qualquer venda da Shopee: recusa se já houver alguma.
-- Devolve as consultas às versões anteriores (sql/07, sql/13 e sql/16),
-- tira as colunas, regras, gatilhos e funções do sql/17 e volta cliente e
-- origem a obrigatórios. Não mexe nos pedidos diretos. Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if not exists (select 1 from pg_attribute where attrelid = 'public.vendas'::regclass
                    and attname = 'shopee_pedido_ref' and not attisdropped) then
    raise exception 'As vendas da Shopee não estão instaladas. Nada foi alterado.';
  end if;
  if exists (select 1 from public.vendas where shopee_pedido_ref is not null) then
    raise exception 'Já existem vendas da Shopee registradas. A desinstalação não é possível. Nada foi alterado.';
  end if;
end;
$$;

-- Consultas: versões anteriores (as que ganharam colunas saem e voltam inteiras).
drop view public.vw_pedidos;
create view public.vw_pedidos with (security_invoker = true) as
select v.id,
       v.numero,
       '#' || case when v.numero < 10000 then lpad(v.numero::text, 4, '0') else v.numero::text end as numero_formatado,
       v.data,
       v.cliente_id, c.nome as cliente_nome, c.contato as cliente_contato, c.ativo as cliente_ativo,
       v.origem, v.data_prometida, v.forma_pagamento, v.observacao,
       v.subtotal, v.desconto, v.frete, v.total,
       v.status_pedido,
       v.valor_recebido, v.valor_devolvido, (v.valor_recebido - v.valor_devolvido) as valor_liquido,
       v.saldo, v.status_financeiro,
       v.cancelado_em, v.motivo_cancelamento,
       (v.status_pedido in ('ENTREGUE', 'CANCELADO')) as edicao_bloqueada,
       -- Selos de prazo (R81): só em pedido não entregue e não cancelado
       case when v.data_prometida is null or v.status_pedido in ('ENTREGUE', 'CANCELADO') then null
            when v.data_prometida < public.hoje() then 'ATRASADO'
            when v.data_prometida = public.hoje() then 'VENCE_HOJE'
            when v.data_prometida = public.hoje() + 1 then 'VENCE_AMANHA'
       end as selo_prazo,
       (select count(*) from public.itens_venda i where i.venda_id = v.id) as quantidade_itens,
       v.editado_em, v.created_at, v.updated_at
  from public.vendas v
  join public.clientes c on c.id = v.cliente_id;

drop view public.vw_pedido_custos;
create view public.vw_pedido_custos with (security_invoker = true) as
select v.id as venda_id,
       coalesce(pr.custo, 0)::numeric(12,2) as custo_producao,
       coalesce(sp.custo, 0)::numeric(12,2) as custo_pecas_prontas,
       coalesce(em.custo, 0)::numeric(12,2) as custo_embalagem,
       (coalesce(pr.custo, 0) + coalesce(sp.custo, 0) + coalesce(em.custo, 0))::numeric(12,2) as custo_total,
       coalesce(cj.valor, 0)::numeric(12,2) as comissao_joca,
       case when v.status_pedido = 'CANCELADO' or v.total <= 0 then 0::numeric(12,2)
            else round((v.subtotal - v.desconto) * greatest(v.total - v.valor_devolvido, 0) / v.total, 2) end as receita,
       (case when v.status_pedido = 'CANCELADO' or v.total <= 0 then 0
             else round((v.subtotal - v.desconto) * greatest(v.total - v.valor_devolvido, 0) / v.total, 2) end
        - coalesce(pr.custo, 0) - coalesce(sp.custo, 0) - coalesce(em.custo, 0) - coalesce(cj.valor, 0))::numeric(12,2) as lucro_estimado,
       exists (select 1 from public.itens_venda i where i.venda_id = v.id and public.item_faltam(i.id) > 0) as falta_produzir
  from public.vendas v
  left join lateral (select sum(p.custo_total) as custo from public.producoes p
                      where p.venda_id = v.id and p.resultado = 'OK' and p.situacao = 'ATIVO') pr on true
  left join lateral (select sum(s.custo) as custo from public.saidas_pecas_prontas s
                      where s.venda_id = v.id and s.situacao = 'ATIVO') sp on true
  left join lateral (select sum(e.valor) as custo from public.embalagens_pedido e where e.venda_id = v.id) em on true
  left join lateral (select sum(k.valor) as valor from public.comissoes_joca k where k.venda_id = v.id) cj on true;

create or replace view public.vw_joca_pedidos with (security_invoker = true) as
with c as (
  select v.id as venda_id, v.numero, v.data, v.status_pedido, v.status_financeiro, cl.nome as cliente,
         p.percentual, (v.subtotal - v.desconto) as base, v.total, v.valor_devolvido,
         coalesce(s.soma, 0)::numeric(12,2) as comissao, coalesce(s.registros, 0) as registros
    from public.vendas v
    join public.clientes cl on cl.id = v.cliente_id
    left join public.comissao_joca_pedido p on p.venda_id = v.id
    left join (select venda_id, sum(valor) as soma, count(*) as registros
                 from public.comissoes_joca group by venda_id) s on s.venda_id = v.id
),
pago as (
  select coalesce(sum(valor), 0) as total from public.pagamentos_joca where situacao = 'ATIVO'
),
disp as (
  select venda_id, sum(comissao) over (order by data, numero rows between unbounded preceding and current row) as acumulado
    from c where status_financeiro = 'RECEBIDO' and comissao > 0
)
select c.*,
       case
         when c.status_pedido = 'CANCELADO' then 'CANCELADO'
         when c.comissao <= 0 then 'SEM_COMISSAO'
         when c.status_financeiro <> 'RECEBIDO' then 'A_RECEBER'
         when d.acumulado <= pago.total then 'PAGA'
         when d.acumulado - c.comissao < pago.total then 'PAGA_EM_PARTE'
         else 'DISPONIVEL'
       end as situacao
  from c
  cross join pago
  left join disp d on d.venda_id = c.venda_id;

create or replace view public.vw_itens_producao with (security_invoker = true) as
select i.id as item_id, i.venda_id, v.numero, '#' || lpad(v.numero::text, greatest(4, length(v.numero::text)), '0') as numero_formatado,
       c.nome as cliente, v.status_pedido, v.data as data_pedido, v.data_prometida,
       i.ordem, i.produto_id, i.descricao, i.quantidade, i.material_id, i.cor_descricao,
       coalesce(pr.pecas, 0)::integer as produzidas,
       coalesce(sp.pecas, 0)::integer as de_estoque,
       greatest(i.quantidade - coalesce(pr.pecas, 0) - coalesce(sp.pecas, 0), 0)::integer as faltam,
       exists (select 1 from public.item_venda_partes p where p.item_id = i.id) as tem_partes,
       not exists (select 1 from public.item_venda_partes p where p.item_id = i.id and p.material_id is null) as cores_definidas
  from public.itens_venda i
  join public.vendas v on v.id = i.venda_id
  join public.clientes c on c.id = v.cliente_id
  left join lateral (select sum(p.pecas) as pecas from public.producoes p
                      where p.item_id = i.id and p.resultado = 'OK' and p.situacao = 'ATIVO') pr on true
  left join lateral (select sum(s.quantidade) as pecas from public.saidas_pecas_prontas s
                      where s.item_id = i.id and s.situacao = 'ATIVO') sp on true;

revoke all on public.vw_pedidos, public.vw_pedido_custos from public, anon, authenticated;
grant select on public.vw_pedidos, public.vw_pedido_custos to authenticated;

drop trigger if exists trg_vendas_canal_coerente on public.vendas;
drop trigger if exists trg_recebimentos_venda_shopee on public.recebimentos_venda;
drop trigger if exists trg_devolucoes_venda_shopee on public.devolucoes_venda;
drop function if exists public.salvar_venda_shopee(uuid, uuid, date, numeric, numeric, numeric, text, jsonb);
drop function if exists public.tg_vendas_canal_coerente();
drop function if exists public.tg_lancamento_venda_shopee();

alter table public.vendas
  drop constraint vendas_shopee_coerente,
  drop constraint vendas_taxa_ate_faturamento,
  drop column shopee_pedido_ref,
  drop column taxa_plataforma,
  drop column frete_comprador,
  alter column cliente_id set not null,
  alter column origem set not null;
drop function if exists public.canal_shopee();

commit;
