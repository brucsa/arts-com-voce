-- =====================================================================
-- Arts com Você · Etapa 4 · Catálogo Essencial de Produtos
-- Especificação v1.3, regras R71–R75.
--
-- O que este arquivo cria (só acréscimos):
--   · tabelas produtos e produto_cores;
--   · a consulta vw_produtos;
--   · as funções salvar_produto, definir_produto_ativo e excluir_produto;
--   · a pasta privada "produtos" no Storage, com as regras de acesso dela.
--
-- O que este arquivo NÃO faz:
--   · não altera nenhuma tabela, função, permissão ou registro existente
--     (materiais, estoque, caixa, gastos, Shopee, Joca, configurações);
--   · não movimenta estoque nem Caixa (R71);
--   · não liga produtos a pedidos (integração futura).
--
-- Regras:
--   · Só o nome é obrigatório. Os números informados precisam ser maiores
--     que zero. Tempo em horas + minutos (0 a 59), guardado em minutos (R74).
--   · Cores = filamentos já cadastrados em Materiais. Só filamentos ativos
--     podem entrar; um filamento desativado depois continua no produto.
--     Filamento ligado a um produto não pode ser excluído (R72).
--   · Uma foto por produto, na pasta privada do Storage, até 2 MB, JPEG,
--     PNG ou WebP. Um arquivo nunca é sobrescrito: não existe regra de
--     alteração de arquivo, só de envio e de exclusão (R73).
--   · Só a Admin lê e grava. O Joca e visitantes não acessam nada (R75).
--   · Excluir: permitido enquanto nenhum pedido usar o produto; desativar:
--     sempre (R75).
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência: rodar sql/produtos_verificacao.sql.
-- Tudo ou nada: se qualquer passo falhar, nada é criado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Trava: não instala por cima de algo que já exista
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.produtos') is not null or to_regclass('public.produto_cores') is not null then
    raise exception 'Já existe uma tabela produtos ou produto_cores. Nada foi alterado.';
  end if;
  if exists (select 1 from storage.buckets where id = 'produtos') then
    raise exception 'Já existe uma pasta "produtos" no Storage. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------
create table public.produtos (
  id                   uuid primary key default gen_random_uuid(),
  nome                 text not null check (length(trim(nome)) between 1 and 150),
  descricao            text check (descricao is null or length(descricao) <= 4000),
  foto_path            text unique check (foto_path is null or foto_path ~
                         '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(webp|jpg|png)$'),
  tempo_impressao_min  integer check (tempo_impressao_min is null or tempo_impressao_min > 0),
  peso_g               numeric(10,2) check (peso_g is null or peso_g > 0),
  altura_cm            numeric(8,2) check (altura_cm is null or altura_cm > 0),
  largura_cm           numeric(8,2) check (largura_cm is null or largura_cm > 0),
  profundidade_cm      numeric(8,2) check (profundidade_cm is null or profundidade_cm > 0),
  preco_venda          numeric(12,2) check (preco_venda is null or preco_venda > 0),
  ativo                boolean not null default true,
  created_at           timestamptz not null default now(),
  created_by           uuid default auth.uid(),
  updated_at           timestamptz not null default now()
);

comment on table public.produtos is
  'Catálogo Essencial (R71–R75): um registro por produto. Só o nome é obrigatório. Não movimenta estoque nem Caixa.';

-- Cores do produto: filamentos de Materiais (R72).
create table public.produto_cores (
  id           uuid primary key default gen_random_uuid(),
  produto_id   uuid not null references public.produtos (id) on delete cascade,
  material_id  uuid not null references public.materiais (id) on delete restrict,
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  unique (produto_id, material_id)
);

create index idx_produto_cores_material on public.produto_cores (material_id);

comment on table public.produto_cores is
  'Cores de cada produto = filamentos de Materiais. Apagadas junto com o produto; impedem excluir o filamento ligado (R72).';

create trigger trg_produtos_updated_at before update on public.produtos
  for each row execute function public.tg_updated_at();
create trigger trg_produtos_auditoria after insert or update or delete on public.produtos
  for each row execute function public.tg_auditoria();
create trigger trg_produto_cores_auditoria after insert or update or delete on public.produto_cores
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 2. Consulta da lista (com as cores juntas)
-- ---------------------------------------------------------------------
create view public.vw_produtos with (security_invoker = true) as
select p.id, p.nome, p.descricao, p.foto_path,
       p.tempo_impressao_min,
       p.tempo_impressao_min / 60 as tempo_horas,
       p.tempo_impressao_min % 60 as tempo_minutos,
       p.peso_g, p.altura_cm, p.largura_cm, p.profundidade_cm,
       p.preco_venda, (p.preco_venda is null) as sem_preco,
       p.ativo, p.created_at, p.updated_at,
       coalesce(c.cores, '[]'::jsonb) as cores
  from public.produtos p
  left join lateral (
    select jsonb_agg(jsonb_build_object(
             'material_id', m.id, 'tipo', m.tipo, 'cor', m.variacao, 'ativo', m.ativo)
             order by lower(m.tipo), lower(m.variacao)) as cores
      from public.produto_cores pc
      join public.materiais m on m.id = pc.material_id
     where pc.produto_id = p.id
  ) c on true;


-- ---------------------------------------------------------------------
-- 3. Funções de gravação (só a Admin; tudo ou nada)
-- ---------------------------------------------------------------------

-- Cadastra (p_id vazio) ou edita um produto, com as cores.
-- Devolve {id, foto_anterior}: foto_anterior é o arquivo que deixou de ser
-- usado e que a tela apaga do Storage depois de salvar (R73).
create or replace function public.salvar_produto(
  p_id               uuid,
  p_nome             text,
  p_descricao        text,
  p_foto_path        text,
  p_tempo_horas      integer,
  p_tempo_minutos    integer,
  p_peso_g           numeric,
  p_altura_cm        numeric,
  p_largura_cm       numeric,
  p_profundidade_cm  numeric,
  p_preco_venda      numeric,
  p_cores            uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_atual    public.produtos;
  v_id       uuid;
  v_tempo    integer;
  v_foto     text := nullif(trim(coalesce(p_foto_path, '')), '');
  v_anterior text;
  v_cores    uuid[] := coalesce((select array_agg(distinct c) from unnest(p_cores) c where c is not null), '{}');
  v_mat      public.materiais;
  v_c        uuid;
begin
  perform public.exigir_admin();

  -- Nome (único campo obrigatório)
  if p_nome is null or length(trim(p_nome)) = 0 then raise exception 'Informe o nome do produto.'; end if;
  if length(trim(p_nome)) > 150 then raise exception 'O nome pode ter até 150 caracteres.'; end if;
  if length(coalesce(p_descricao, '')) > 4000 then raise exception 'A descrição pode ter até 4.000 caracteres.'; end if;

  -- Tempo: horas + minutos (0 a 59)
  if p_tempo_horas is null and p_tempo_minutos is null then
    v_tempo := null;
  else
    if coalesce(p_tempo_horas, 0) < 0 then raise exception 'As horas não podem ser negativas.'; end if;
    if coalesce(p_tempo_minutos, 0) not between 0 and 59 then raise exception 'Os minutos vão de 0 a 59.'; end if;
    v_tempo := coalesce(p_tempo_horas, 0) * 60 + coalesce(p_tempo_minutos, 0);
    if v_tempo = 0 then raise exception 'O tempo de impressão precisa ser maior que zero, ou ficar vazio.'; end if;
  end if;

  -- Números opcionais: maiores que zero quando informados
  if p_peso_g is not null and p_peso_g <= 0 then raise exception 'O peso precisa ser maior que zero, ou ficar vazio.'; end if;
  if p_altura_cm is not null and p_altura_cm <= 0 then raise exception 'A altura precisa ser maior que zero, ou ficar vazia.'; end if;
  if p_largura_cm is not null and p_largura_cm <= 0 then raise exception 'A largura precisa ser maior que zero, ou ficar vazia.'; end if;
  if p_profundidade_cm is not null and p_profundidade_cm <= 0 then raise exception 'A profundidade precisa ser maior que zero, ou ficar vazia.'; end if;
  if p_preco_venda is not null and p_preco_venda <= 0 then raise exception 'O preço precisa ser maior que zero, ou ficar vazio.'; end if;

  -- Produto existente
  if p_id is not null then
    select * into v_atual from public.produtos where id = p_id for update;
    if not found then raise exception 'Produto não encontrado.'; end if;
  end if;

  -- Foto: precisa ter sido enviada para a pasta "produtos" e não pode ser de outro produto
  if v_foto is not null and v_foto is distinct from v_atual.foto_path then
    if v_foto !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(webp|jpg|png)$' then
      raise exception 'Nome de arquivo de foto inválido.';
    end if;
    if not exists (select 1 from storage.objects where bucket_id = 'produtos' and name = v_foto) then
      raise exception 'A foto não foi encontrada no armazenamento. Envie a foto de novo.';
    end if;
    if exists (select 1 from public.produtos where foto_path = v_foto and id is distinct from p_id) then
      raise exception 'Esta foto já pertence a outro produto.';
    end if;
  end if;

  -- Cores: só filamentos; novos precisam estar ativos
  foreach v_c in array v_cores loop
    select * into v_mat from public.materiais where id = v_c;
    if not found then raise exception 'Uma das cores escolhidas não existe mais em Materiais.'; end if;
    if v_mat.categoria <> 'FILAMENTO' then
      raise exception '"%" não é um filamento. As cores do produto vêm dos filamentos de Materiais.', v_mat.tipo;
    end if;
    if not v_mat.ativo and not exists (
         select 1 from public.produto_cores where produto_id = p_id and material_id = v_c) then
      raise exception 'O filamento % · % está inativo e não pode ser escolhido.', v_mat.tipo, v_mat.variacao;
    end if;
  end loop;

  if p_id is null then
    insert into public.produtos (nome, descricao, foto_path, tempo_impressao_min, peso_g,
                                 altura_cm, largura_cm, profundidade_cm, preco_venda)
    values (trim(p_nome), nullif(trim(coalesce(p_descricao, '')), ''), v_foto, v_tempo, p_peso_g,
            p_altura_cm, p_largura_cm, p_profundidade_cm, p_preco_venda)
    returning id into v_id;
  else
    v_id := p_id;
    if v_atual.foto_path is distinct from v_foto then v_anterior := v_atual.foto_path; end if;
    update public.produtos
       set nome = trim(p_nome), descricao = nullif(trim(coalesce(p_descricao, '')), ''),
           foto_path = v_foto, tempo_impressao_min = v_tempo, peso_g = p_peso_g,
           altura_cm = p_altura_cm, largura_cm = p_largura_cm, profundidade_cm = p_profundidade_cm,
           preco_venda = p_preco_venda
     where id = v_id;
  end if;

  -- Cores: tira as que saíram, acrescenta as novas
  delete from public.produto_cores where produto_id = v_id and material_id <> all (v_cores);
  insert into public.produto_cores (produto_id, material_id)
  select v_id, c from unnest(v_cores) c
   where not exists (select 1 from public.produto_cores where produto_id = v_id and material_id = c);

  return jsonb_build_object('id', v_id, 'foto_anterior', v_anterior);
end;
$$;

-- Desativar ou reativar (sempre permitido, R75).
create or replace function public.definir_produto_ativo(p_id uuid, p_ativo boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.exigir_admin();
  if p_ativo is null then raise exception 'Informe se o produto fica ativo ou inativo.'; end if;
  update public.produtos set ativo = p_ativo where id = p_id;
  if not found then raise exception 'Produto não encontrado.'; end if;
end;
$$;

-- Excluir (R75). Quando os pedidos passarem a usar produtos, a ligação
-- deles impedirá a exclusão de um produto já usado ("desative em vez de
-- excluir"). Devolve a foto que a tela apaga do Storage depois.
create or replace function public.excluir_produto(p_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_foto text;
begin
  perform public.exigir_admin();
  delete from public.produtos where id = p_id returning foto_path into v_foto;
  if not found then raise exception 'Produto não encontrado.'; end if;
  return v_foto;
end;
$$;


-- ---------------------------------------------------------------------
-- 4. Pasta privada das fotos (R73)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('produtos', 'produtos', false, 2097152, array['image/jpeg', 'image/png', 'image/webp']);

-- Só a Admin vê, envia e apaga fotos desta pasta. Não há regra de
-- alteração: um arquivo enviado nunca é sobrescrito.
create policy produtos_fotos_select_admin on storage.objects
  for select to authenticated using (bucket_id = 'produtos' and public.is_admin());
create policy produtos_fotos_insert_admin on storage.objects
  for insert to authenticated with check (bucket_id = 'produtos' and public.is_admin());
create policy produtos_fotos_delete_admin on storage.objects
  for delete to authenticated using (bucket_id = 'produtos' and public.is_admin());


-- ---------------------------------------------------------------------
-- 5. Segurança: só a Admin lê; gravação só pelas funções acima
-- ---------------------------------------------------------------------
alter table public.produtos      enable row level security;
alter table public.produto_cores enable row level security;

revoke all on public.produtos, public.produto_cores, public.vw_produtos from public, anon, authenticated;
grant select on public.produtos, public.produto_cores, public.vw_produtos to authenticated;

create policy produtos_select_admin on public.produtos
  for select to authenticated using (public.is_admin());
create policy produto_cores_select_admin on public.produto_cores
  for select to authenticated using (public.is_admin());

revoke all on function public.salvar_produto(uuid, text, text, text, integer, integer, numeric, numeric, numeric, numeric, numeric, uuid[]) from public, anon;
revoke all on function public.definir_produto_ativo(uuid, boolean) from public, anon;
revoke all on function public.excluir_produto(uuid) from public, anon;
grant execute on function public.salvar_produto(uuid, text, text, text, integer, integer, numeric, numeric, numeric, numeric, numeric, uuid[]) to authenticated;
grant execute on function public.definir_produto_ativo(uuid, boolean) to authenticated;
grant execute on function public.excluir_produto(uuid) to authenticated;

commit;
