-- =====================================================================
-- Arts com Você · Repasses da Shopee (Etapa 6, Lote C2) · Passo 1 de 2
-- Acrescenta a origem REPASSE_SHOPEE ao Caixa (entrada do repasse da
-- Shopee confirmado pela Admin, R106).
--
-- ⚠ PERMANENTE: o banco não remove valores desta lista depois de criados.
--
-- Por que é um passo separado: o Postgres só deixa usar um valor novo de
-- uma lista depois que a gravação que o criou termina. Rode este arquivo
-- sozinho, ANTES de sql/19_repasses_shopee.sql.
--
-- Não altera nenhum dado nem nenhum movimento existente.
-- Pode ser rodado de novo sem efeito (if not exists).
-- =====================================================================

alter type public.origem_caixa add value if not exists 'REPASSE_SHOPEE';

-- Pronto. Agora rode sql/19_repasses_shopee.sql.
