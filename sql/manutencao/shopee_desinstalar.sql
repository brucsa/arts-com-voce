-- =====================================================================
-- Arts com Você · DESINSTALAR o módulo "Pedidos da Shopee"
--
-- ⚠ Só rodar com autorização específica da Bruna.
--
-- Remove SOMENTE o que sql/shopee_pedidos.sql criou:
--   · a função importar_pedidos_shopee;
--   · as tabelas shopee_pedido_itens, shopee_pedidos e shopee_importacoes
--     (com as regras de acesso e gatilhos delas).
-- Os pedidos da Shopee importados são apagados junto (podem ser importados
-- de novo a partir da planilha). Nada das Etapas 0–3 é tocado: caixa,
-- gastos, estoque, materiais, configurações, perfis e auditoria ficam como
-- estão. (Os registros de auditoria do próprio módulo continuam guardados
-- como histórico.)
--
-- Arquivos no Storage: o módulo não usa Storage, então não há nada a apagar
-- (o bloco I do retrato confirma que buckets e arquivos ficaram iguais).
--
-- Tudo ou nada: se qualquer passo falhar, nada é removido.
-- Antes e depois: rodar sql/manutencao/shopee_retrato.sql. Depois da
-- desinstalação, os blocos A–I e o resumo Z precisam voltar a ser iguais
-- aos do retrato tirado antes da instalação.
-- =====================================================================

begin;

-- Trava de segurança: só continua se o módulo estiver instalado e se as
-- tabelas forem mesmo as dele (nenhuma outra tabela depende delas).
do $$
begin
  if to_regclass('public.shopee_pedidos') is null
     or to_regclass('public.shopee_pedido_itens') is null
     or to_regclass('public.shopee_importacoes') is null then
    raise exception 'O módulo "Pedidos da Shopee" não está instalado (ou está incompleto). Nada foi removido.';
  end if;
  if exists (
    select 1 from pg_constraint
     where contype = 'f'
       and confrelid in ('public.shopee_pedidos'::regclass, 'public.shopee_pedido_itens'::regclass, 'public.shopee_importacoes'::regclass)
       and conrelid not in ('public.shopee_pedidos'::regclass, 'public.shopee_pedido_itens'::regclass, 'public.shopee_importacoes'::regclass)
  ) then
    raise exception 'Outra tabela do sistema depende das tabelas da Shopee. Nada foi removido; fale com o suporte antes.';
  end if;
end;
$$;

drop function public.importar_pedidos_shopee(text, integer, integer, jsonb, boolean);

-- Sem "cascade": se algo inesperado depender destas tabelas, o banco recusa
-- e nada é removido.
drop table public.shopee_pedido_itens;
drop table public.shopee_pedidos;
drop table public.shopee_importacoes;

commit;
