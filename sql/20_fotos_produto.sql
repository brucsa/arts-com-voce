-- =====================================================================
-- Arts com Você · Fotos do produto (até 5 por produto)
-- Especificação v1.12: R73, R113 e R117 complementadas.
--
-- O que este arquivo faz:
--   · produto_fotos: as fotos a mais de cada produto (2ª a 5ª). A 1ª, a
--     capa, continua em produtos.foto_path, como hoje: a lista de produtos,
--     a vitrine, o carrinho e os pedidos seguem mostrando a capa sem mudar;
--   · salvar_fotos_produto: grava as fotos do produto na ordem escolhida pela
--     Admin (a primeira é a capa), até 5, com as mesmas regras da foto atual
--     (nome único na pasta privada, nunca sobrescreve, um arquivo pertence a
--     um produto só);
--   · catalogo_fotos: as fotos de um produto do catálogo público, na ordem,
--     para o cliente passar na página do produto (R117);
--   · foto_no_catalogo (trocada, mesma assinatura): o público também vê as
--     fotos a mais dos produtos ativos marcados no catálogo, por links
--     temporários — as outras continuam vistas só pela Admin.
--
-- O que NÃO muda:
--   · nenhum produto, foto ou arquivo existente (a capa de cada produto fica
--     como está; ninguém ganha foto a mais sozinho);
--   · salvar_produto, excluir_produto, catalogo_publico e as regras da pasta;
--   · pedidos, Caixa, estoque, Joca e Shopee.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/fotos_produto_verificacao.sql e as gerais.
-- Tudo ou nada: se qualquer passo falhar, nada é alterado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.produtos') is null
     or not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'catalogo_publico') then
    raise exception 'Os produtos (sql/06) e o catálogo público (sql/11) precisam estar instalados. Nada foi alterado.';
  end if;
  if to_regclass('public.produto_fotos') is not null then
    raise exception 'As fotos do produto já estão instaladas. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
               and proname in ('salvar_fotos_produto', 'catalogo_fotos', 'tg_fotos_produto_unicas')) then
    raise exception 'Já existe função das fotos do produto. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Tabela
-- ---------------------------------------------------------------------
-- Fotos a mais (ordem 2 a 5). A capa (ordem 1) é produtos.foto_path.
create table public.produto_fotos (
  id          uuid primary key default gen_random_uuid(),
  produto_id  uuid not null references public.produtos (id) on delete cascade,
  ordem       smallint not null check (ordem between 2 and 5),
  foto_path   text not null unique check (foto_path ~
                '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(webp|jpg|png)$'),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  constraint uq_produto_fotos_ordem unique (produto_id, ordem)
);

comment on table public.produto_fotos is
  'Fotos a mais de cada produto (2ª a 5ª, R73 v1.12). A capa é produtos.foto_path. Excluídas junto com o produto.';

create trigger trg_produto_fotos_auditoria after insert or update or delete on public.produto_fotos
  for each row execute function public.tg_auditoria();

-- Um arquivo é foto de um produto só: a capa de um produto não pode ser
-- foto a mais (dele ou de outro), e vice-versa.
create or replace function public.tg_fotos_produto_unicas()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_table_name = 'produtos' then
    -- Produto com fotos a mais não fica sem capa (só pela tela nova, que
    -- grava todas juntas).
    if new.foto_path is null and exists (select 1 from public.produto_fotos where produto_id = new.id) then
      raise exception 'Este produto tem mais fotos: atualize a página e mude as fotos pelo formulário do produto.';
    end if;
    if new.foto_path is not null and exists (select 1 from public.produto_fotos where foto_path = new.foto_path) then
      raise exception 'Esta foto já está em outro lugar do cadastro. Envie a foto de novo.';
    end if;
  elsif exists (select 1 from public.produtos where foto_path = new.foto_path) then
    raise exception 'Esta foto já está em outro lugar do cadastro. Envie a foto de novo.';
  end if;
  return new;
end;
$$;

create trigger trg_produtos_foto_unica before insert or update of foto_path on public.produtos
  for each row execute function public.tg_fotos_produto_unicas();
create trigger trg_produto_fotos_unica before insert or update of foto_path on public.produto_fotos
  for each row execute function public.tg_fotos_produto_unicas();


-- ---------------------------------------------------------------------
-- 2. Gravar as fotos do produto (R73 v1.12)
-- ---------------------------------------------------------------------
--   p_fotos: nomes dos arquivos na ordem escolhida; o primeiro é a capa.
--   Vazio = produto sem foto. Os arquivos que saírem da lista são apagados
--   da pasta pela tela, depois de salvar (como hoje).
create or replace function public.salvar_fotos_produto(p_produto_id uuid, p_fotos text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c_nome  constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(webp|jpg|png)$';
  v_fotos text[] := coalesce(p_fotos, '{}');
  v_n     integer := coalesce(array_length(coalesce(p_fotos, '{}'), 1), 0);
  v_i     integer;
  v_f     text;
begin
  perform public.exigir_admin();

  perform 1 from public.produtos where id = p_produto_id for update;
  if not found then raise exception 'Produto não encontrado.'; end if;

  if v_n > 5 then raise exception 'Cada produto pode ter até 5 fotos.'; end if;
  for v_i in 1 .. v_n loop
    v_f := v_fotos[v_i];
    if v_f is null or v_f !~ c_nome then raise exception 'Foto %: nome de arquivo inválido.', v_i; end if;
    if v_f = any (v_fotos[1:v_i - 1]) then raise exception 'Foto %: a mesma foto aparece duas vezes.', v_i; end if;
    if not exists (select 1 from storage.objects where bucket_id = 'produtos' and name = v_f) then
      raise exception 'Foto %: não foi encontrada no armazenamento. Envie a foto de novo.', v_i;
    end if;
    if exists (select 1 from public.produtos where foto_path = v_f and id <> p_produto_id)
       or exists (select 1 from public.produto_fotos where foto_path = v_f and produto_id <> p_produto_id) then
      raise exception 'Foto %: já pertence a outro produto.', v_i;
    end if;
  end loop;

  delete from public.produto_fotos where produto_id = p_produto_id;
  update public.produtos set foto_path = v_fotos[1]
   where id = p_produto_id and foto_path is distinct from v_fotos[1];
  insert into public.produto_fotos (produto_id, ordem, foto_path)
  select p_produto_id, o::smallint, v_fotos[o] from generate_series(2, v_n) o;
end;
$$;


-- ---------------------------------------------------------------------
-- 3. Catálogo público (R117 v1.12)
-- ---------------------------------------------------------------------
-- Fotos de um produto do catálogo, na ordem (capa primeiro). Só de produto
-- ativo marcado no catálogo; nos outros, nada.
create or replace function public.catalogo_fotos(p_produto_id uuid)
returns table (ordem integer, foto_path text)
language sql
stable
security definer
set search_path = public
as $$
  select 1, p.foto_path from public.produtos p
   where p.id = p_produto_id and p.ativo and p.no_catalogo and p.foto_path is not null
  union all
  select f.ordem::integer, f.foto_path from public.produto_fotos f
    join public.produtos p on p.id = f.produto_id
   where f.produto_id = p_produto_id and p.ativo and p.no_catalogo
  order by 1;
$$;

-- Regra do Storage: o arquivo é a capa ou uma foto a mais de um produto
-- ativo marcado no catálogo.
create or replace function public.foto_no_catalogo(p_nome text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.produtos p
                  where p.foto_path = p_nome and p.ativo and p.no_catalogo)
      or exists (select 1 from public.produto_fotos f join public.produtos p on p.id = f.produto_id
                  where f.foto_path = p_nome and p.ativo and p.no_catalogo);
$$;


-- ---------------------------------------------------------------------
-- 4. Acesso: só a Admin lê a tabela; ninguém grava direto
-- ---------------------------------------------------------------------
alter table public.produto_fotos enable row level security;
revoke all on public.produto_fotos from public, anon, authenticated;
grant select on public.produto_fotos to authenticated;
create policy produto_fotos_select_admin on public.produto_fotos for select to authenticated using (public.is_admin());

revoke all on function public.tg_fotos_produto_unicas() from public, anon, authenticated;
revoke all on function public.salvar_fotos_produto(uuid, text[]) from public, anon;
grant execute on function public.salvar_fotos_produto(uuid, text[]) to authenticated;
revoke all on function public.catalogo_fotos(uuid) from public;
grant execute on function public.catalogo_fotos(uuid) to anon, authenticated;

commit;

-- Pronto. Confira com sql/fotos_produto_verificacao.sql.
