-- =====================================================================
-- Arts com Você · Produção Essencial (Etapa 5) · Lote B · Passo 1 de 2
-- Acrescenta os motivos de movimento de estoque da produção:
--   PRODUCAO  (filamento, purga e insumos de uma produção)
--   FALHA     (material de uma falha de impressão: perda, R17)
--   EMBALAGEM (embalagem baixada quando o pedido fica Pronto, R15)
--   AJUSTE    (ajuste de inventário, R56/R99)
--
-- ⚠ PERMANENTE: o banco não remove valores desta lista depois de criados.
--
-- Por que é um passo separado: o Postgres só deixa usar um valor novo de
-- uma lista depois que a gravação que o criou termina. Rode este arquivo
-- sozinho, ANTES de sql/16_producao.sql.
--
-- Não altera nenhum dado nem nenhum movimento existente.
-- Pode ser rodado de novo sem efeito (if not exists).
-- =====================================================================

alter type public.motivo_estoque add value if not exists 'PRODUCAO';
alter type public.motivo_estoque add value if not exists 'FALHA';
alter type public.motivo_estoque add value if not exists 'EMBALAGEM';
alter type public.motivo_estoque add value if not exists 'AJUSTE';
