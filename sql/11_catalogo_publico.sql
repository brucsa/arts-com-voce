-- =====================================================================
-- Arts com Você · Catálogo público (vitrine) · Especificação v1.6, R85–R88
--
-- O que este arquivo faz (só acréscimos):
--   · duas marcações novas em produtos: no_catalogo e personalizado
--     (começam desligadas: nada aparece no catálogo até a Admin marcar);
--   · a função definir_produto_catalogo, para a Admin gravar as marcações;
--   · a função catalogo_publico, a ÚNICA leitura aberta ao público: devolve
--     só nome, preço, descrição, foto e cores dos produtos ativos marcados;
--   · uma regra de leitura no Storage para as fotos desses produtos (links
--     temporários). As outras fotos continuam vistas só pela Admin.
--
-- O que este arquivo NÃO faz:
--   · não abre nenhuma tabela ao público (o público não lê tabelas nem grava);
--   · não altera salvar_produto, definir_produto_ativo, excluir_produto,
--     vw_produtos nem as regras de acesso que já existem;
--   · não grava pedidos: o pedido vai só pelo WhatsApp (R87);
--   · não depende da integração com o Caixa (scripts 09 e 10).
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Antes: sql/manutencao/catalogo_publico_preinstalacao.sql e o retrato.
-- Depois: sql/catalogo_publico_verificacao.sql e o retrato de novo.
-- Tudo ou nada: se qualquer passo falhar, nada é criado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Trava: só instala sobre o Catálogo Essencial e uma única vez
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_attribute where attrelid = to_regclass('public.produtos')
                and attname in ('no_catalogo', 'personalizado') and not attisdropped)
     or to_regprocedure('public.catalogo_publico()') is not null then
    raise exception 'O catálogo público já está instalado. Nada foi alterado.';
  end if;
  if to_regclass('public.produtos') is null or to_regclass('public.produto_cores') is null
     or to_regprocedure('public.salvar_produto(uuid, text, text, text, integer, integer, numeric, numeric, numeric, numeric, numeric, uuid[])') is null
     or not exists (select 1 from storage.buckets where id = 'produtos') then
    raise exception 'O Catálogo Essencial de Produtos (sql/06) não está instalado como esperado. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
                and proname in ('definir_produto_catalogo', 'catalogo_publico', 'foto_no_catalogo')) then
    raise exception 'Já existe uma função com o nome definir_produto_catalogo, catalogo_publico ou foto_no_catalogo. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                and policyname = 'produtos_fotos_select_catalogo') then
    raise exception 'Já existe a regra produtos_fotos_select_catalogo no Storage. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Marcações (R86): começam desligadas em todos os produtos
-- ---------------------------------------------------------------------
alter table public.produtos
  add column no_catalogo   boolean not null default false,
  add column personalizado boolean not null default false;

comment on column public.produtos.no_catalogo is
  'Catálogo público (R85–R86): produto ativo com esta marcação aparece na vitrine. Só a Admin grava.';
comment on column public.produtos.personalizado is
  'Catálogo público (R86): peça personalizada, mostrada como "Sob consulta", sem preço. Só a Admin grava.';


-- ---------------------------------------------------------------------
-- 2. Gravação das marcações (só a Admin)
-- ---------------------------------------------------------------------
create or replace function public.definir_produto_catalogo(p_id uuid, p_no_catalogo boolean, p_personalizado boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.exigir_admin();
  if p_no_catalogo is null or p_personalizado is null then
    raise exception 'Informe as duas marcações do catálogo.';
  end if;
  update public.produtos
     set no_catalogo = p_no_catalogo, personalizado = p_personalizado
   where id = p_id
     and (no_catalogo, personalizado) is distinct from (p_no_catalogo, p_personalizado);
  if not found and not exists (select 1 from public.produtos where id = p_id) then
    raise exception 'Produto não encontrado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 3. Leitura pública (R85, R86, R88): só estes campos, só produtos ativos
--    marcados. Personalizado ou sem preço → preco vazio e sob_consulta.
--    Cores: nome da cor dos filamentos ativos, sem o tipo e sem repetição.
-- ---------------------------------------------------------------------
create or replace function public.catalogo_publico()
returns table (id uuid, nome text, descricao text, preco numeric, sob_consulta boolean, foto_path text, cores text[])
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.nome, p.descricao,
         case when p.personalizado then null else p.preco_venda end,
         (p.personalizado or p.preco_venda is null),
         p.foto_path,
         coalesce((select array_agg(c.cor order by lower(c.cor))
                     from (select distinct on (lower(trim(m.variacao))) trim(m.variacao) as cor
                             from public.produto_cores pc
                             join public.materiais m on m.id = pc.material_id
                            where pc.produto_id = p.id and m.ativo and m.categoria = 'FILAMENTO'
                              and nullif(trim(m.variacao), '') is not null
                            order by lower(trim(m.variacao)), trim(m.variacao)) c), '{}')
    from public.produtos p
   where p.ativo and p.no_catalogo
   order by lower(p.nome), p.id;
$$;

-- Usada só pela regra do Storage abaixo: diz se o arquivo é a foto de um
-- produto ativo marcado no catálogo.
create or replace function public.foto_no_catalogo(p_nome text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.produtos p
                  where p.foto_path = p_nome and p.ativo and p.no_catalogo);
$$;


-- ---------------------------------------------------------------------
-- 4. Fotos do catálogo (R86): leitura por links temporários, só das fotos
--    dos produtos ativos marcados. As regras da Admin continuam iguais.
-- ---------------------------------------------------------------------
create policy produtos_fotos_select_catalogo on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'produtos' and public.foto_no_catalogo(name));


-- ---------------------------------------------------------------------
-- 5. Permissões
-- ---------------------------------------------------------------------
revoke all on function public.definir_produto_catalogo(uuid, boolean, boolean) from public, anon;
grant execute on function public.definir_produto_catalogo(uuid, boolean, boolean) to authenticated;

revoke all on function public.catalogo_publico() from public;
grant execute on function public.catalogo_publico() to anon, authenticated;

revoke all on function public.foto_no_catalogo(text) from public;
grant execute on function public.foto_no_catalogo(text) to anon, authenticated;

commit;
