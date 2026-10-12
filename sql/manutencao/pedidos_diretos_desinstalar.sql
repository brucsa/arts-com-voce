-- =====================================================================
-- Arts com Você · DESINSTALAR os Pedidos Diretos Essencial (lote P1-a)
--
-- ⚠ Só rodar com autorização específica da Bruna.
--
-- ⚠ SÓ REMOVE UMA INSTALAÇÃO VAZIA: se existir qualquer cliente, pedido,
--   item ou registro de status, o roteiro recusa e nada é removido.
--   Pedidos reais nunca são apagados por este roteiro.
--
-- Remove SOMENTE o que sql/07_pedidos_diretos_essencial.sql criou:
--   · as funções de clientes e de pedidos, as internas e as de gatilho;
--   · a consulta vw_pedidos;
--   · as tabelas historico_status_pedido, itens_venda, vendas e clientes
--     (com as regras e gatilhos delas);
--   · os tipos status_pedido_direto, origem_pedido_direto e
--     status_financeiro_pedido.
-- Nada das outras etapas é tocado: Catálogo, materiais, estoque, Caixa,
-- gastos, Shopee, Joca, configurações, perfis e auditoria ficam como
-- estão (os registros de auditoria continuam guardados como histórico).
--
-- Tudo ou nada: se qualquer passo falhar, nada é removido.
-- Antes e depois: rodar o retrato (sql/manutencao/shopee_retrato.sql).
-- =====================================================================

begin;

-- Travas de segurança
do $$
begin
  if to_regclass('public.clientes') is null or to_regclass('public.vendas') is null
     or to_regclass('public.itens_venda') is null or to_regclass('public.historico_status_pedido') is null then
    raise exception 'Os Pedidos Diretos Essencial não estão instalados (ou estão incompletos). Nada foi removido.';
  end if;
  if exists (
    select 1 from pg_constraint
     where contype = 'f'
       and confrelid in ('public.clientes'::regclass, 'public.vendas'::regclass,
                         'public.itens_venda'::regclass, 'public.historico_status_pedido'::regclass)
       and conrelid not in ('public.clientes'::regclass, 'public.vendas'::regclass,
                            'public.itens_venda'::regclass, 'public.historico_status_pedido'::regclass)
  ) then
    raise exception 'Outra tabela do sistema (por exemplo, recebimentos do P1-b) já usa os pedidos. Nada foi removido.';
  end if;
  if exists (select 1 from public.clientes) or exists (select 1 from public.vendas)
     or exists (select 1 from public.itens_venda) or exists (select 1 from public.historico_status_pedido) then
    raise exception 'Já existem clientes ou pedidos cadastrados (% cliente(s), % pedido(s)). Este roteiro só remove uma instalação vazia. Nada foi removido.',
      (select count(*) from public.clientes), (select count(*) from public.vendas);
  end if;
end;
$$;

drop function public.salvar_cliente(uuid, text, text);
drop function public.definir_cliente_ativo(uuid, boolean);
drop function public.excluir_cliente(uuid);
drop function public.salvar_pedido(uuid, date, uuid, text, date, text, numeric, numeric, text, jsonb);
drop function public.mudar_status_pedido(uuid, text);
drop function public.cancelar_pedido(uuid, text);

-- Sem "cascade": se algo inesperado depender destes objetos, o banco
-- recusa e nada é removido.
drop view public.vw_pedidos;
drop table public.historico_status_pedido;
drop table public.itens_venda;
drop table public.vendas;
drop table public.clientes;

drop function public.proximo_numero_pedido();
drop function public.canal_boca_a_boca();
drop function public.recalcular_pedido(uuid);
drop function public.conferir_pedido(uuid);
drop function public.tg_vendas_protege();
drop function public.tg_itens_venda_protege();
drop function public.tg_historico_status_imutavel();
drop function public.tg_vendas_conferir();
drop function public.tg_itens_venda_conferir();

drop type public.status_financeiro_pedido;
drop type public.origem_pedido_direto;
drop type public.status_pedido_direto;

commit;
