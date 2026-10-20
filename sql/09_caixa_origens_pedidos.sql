-- =====================================================================
-- Arts com Você · Integração Pedidos Diretos → Caixa · Passo 1 de 2
-- Acrescenta duas origens ao Caixa:
--   · RECEBIMENTO — entrada de dinheiro de um recebimento de pedido;
--   · REEMBOLSO   — saída de dinheiro de uma devolução ao cliente.
--
-- ⚠ PERMANENTE: o banco não remove valores desta lista depois de criados
--   (especificação, nota da Fase A2).
--
-- Por que é um passo separado: o Postgres só deixa usar um valor novo de
-- uma lista depois que a gravação que o criou termina. Rode este arquivo
-- sozinho, ANTES de sql/10_pedidos_diretos_caixa.sql.
--
-- Não altera nenhum dado nem nenhum movimento existente.
-- Pode ser rodado de novo sem efeito (if not exists).
-- =====================================================================

alter type public.origem_caixa add value if not exists 'RECEBIMENTO';
alter type public.origem_caixa add value if not exists 'REEMBOLSO';
