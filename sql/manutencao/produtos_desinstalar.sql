-- =====================================================================
-- Arts com Você · DESINSTALAR o Catálogo Essencial de Produtos
--
-- ⚠ Só rodar com autorização específica da Bruna.
--
-- ⚠ PERDA DE DADOS: apaga TODOS os produtos cadastrados e as cores de cada
--   um. Não há como desfazer pelo sistema. Antes, se quiser guardar os
--   dados, exporte a tabela produtos (Supabase → Table Editor → produtos
--   → Export → CSV).
--
-- ⚠ FOTOS: este roteiro NÃO apaga as fotos, nem a pasta "produtos" do
--   Storage. Ele só roda com a pasta VAZIA, para nenhuma foto ficar
--   esquecida. Antes de rodar:
--     1. Supabase → Storage → produtos → selecionar todas as fotos →
--        Delete (as fotos somem de vez; baixe antes as que quiser guardar).
--     2. Rodar este roteiro.
--     3. Depois, Supabase → Storage → produtos → Delete bucket (apaga a
--        pasta vazia).
--
-- Remove SOMENTE o que sql/06_produtos_essencial.sql criou:
--   · as funções salvar_produto, definir_produto_ativo e excluir_produto;
--   · a consulta vw_produtos;
--   · as tabelas produto_cores e produtos (com as regras e gatilhos delas);
--   · as 3 regras de acesso das fotos no Storage.
-- Nada das outras etapas é tocado: materiais, estoque, caixa, gastos,
-- Shopee, Joca, configurações, perfis e auditoria ficam como estão (os
-- registros de auditoria dos produtos continuam guardados como histórico).
--
-- Tudo ou nada: se qualquer passo falhar, nada é removido.
-- Antes e depois: rodar o retrato (sql/manutencao/shopee_retrato.sql).
-- =====================================================================

begin;

-- Travas de segurança
do $$
begin
  if to_regclass('public.produtos') is null or to_regclass('public.produto_cores') is null then
    raise exception 'O Catálogo Essencial de Produtos não está instalado (ou está incompleto). Nada foi removido.';
  end if;
  if exists (
    select 1 from pg_constraint
     where contype = 'f'
       and confrelid in ('public.produtos'::regclass, 'public.produto_cores'::regclass)
       and conrelid not in ('public.produtos'::regclass, 'public.produto_cores'::regclass)
  ) then
    raise exception 'Outra tabela do sistema (por exemplo, pedidos) já usa os produtos. Nada foi removido; fale com o suporte antes.';
  end if;
  if exists (select 1 from storage.objects where bucket_id = 'produtos') then
    raise exception 'A pasta "produtos" do Storage ainda tem % foto(s). Apague as fotos pelo painel do Storage antes (veja o topo deste roteiro). Nada foi removido.',
      (select count(*) from storage.objects where bucket_id = 'produtos');
  end if;
end;
$$;

drop policy produtos_fotos_select_admin on storage.objects;
drop policy produtos_fotos_insert_admin on storage.objects;
drop policy produtos_fotos_delete_admin on storage.objects;

drop function public.salvar_produto(uuid, text, text, text, integer, integer, numeric, numeric, numeric, numeric, numeric, uuid[]);
drop function public.definir_produto_ativo(uuid, boolean);
drop function public.excluir_produto(uuid);

-- Sem "cascade": se algo inesperado depender destes objetos, o banco
-- recusa e nada é removido.
drop view public.vw_produtos;
drop table public.produto_cores;
drop table public.produtos;

commit;

-- Último passo, manual: Supabase → Storage → produtos → Delete bucket.
