-- =====================================================================
-- Arts com Você · Área do Joca · Passo 1 de 2
-- Acrescenta a origem PAGAMENTO_JOCA ao Caixa (saída de um pagamento ao
-- Joca, R91).
--
-- ⚠ PERMANENTE: o banco não remove valores desta lista depois de criados.
--
-- Por que é um passo separado: o Postgres só deixa usar um valor novo de
-- uma lista depois que a gravação que o criou termina. Rode este arquivo
-- sozinho, ANTES de sql/13_joca_comissoes.sql.
--
-- Não altera nenhum dado nem nenhum movimento existente.
-- Pode ser rodado de novo sem efeito (if not exists).
-- =====================================================================

alter type public.origem_caixa add value if not exists 'PAGAMENTO_JOCA';
