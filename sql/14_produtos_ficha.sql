-- =====================================================================
-- Arts com Você · Produção Essencial (Etapa 5) · Lote A
-- Especificação v1.8, R93 (ficha de consumo) e R94 (cores por parte).
--
-- O que este arquivo cria (só acréscimos):
--   · produto_partes: as partes impressas de cada produto, com os gramas
--     da peça e da purga (R93);
--   · produto_materiais: os outros materiais de cada produto (insumos e
--     embalagens), com a quantidade por peça (R93);
--   · item_venda_partes: as partes de cada item do pedido, copiadas da
--     ficha quando o item entra, com a cor (filamento) de cada parte (R94);
--   · a função salvar_ficha_produto (só a Admin);
--   · a função definir_cores_partes (só a Admin), chamada pela tela logo
--     depois de salvar_pedido;
--   · um gatilho em itens_venda que copia a ficha quando um item do
--     catálogo entra no pedido ou troca de produto.
--
-- O que este arquivo NÃO faz:
--   · não altera nenhuma função, consulta, permissão ou registro existente
--     (salvar_produto, salvar_pedido e vw_produtos continuam iguais);
--   · não cria ficha para nenhum produto e não mexe nos pedidos já
--     registrados: os itens que já existem continuam sem partes;
--   · não movimenta estoque nem Caixa (isso é o Lote B).
--
-- Regras:
--   · A ficha é opcional e não guarda cor. Parte: nome (único no produto),
--     gramas da peça > 0 e gramas de purga ≥ 0, até 2 casas. Outros
--     materiais: só INSUMO ou EMBALAGEM de Materiais, quantidade > 0, até
--     3 casas, cada material uma vez. Novos precisam estar ativos.
--   · Pedido: as partes e os gramas são copiados da ficha e não são
--     editados no pedido. Mudanças depois na ficha não alteram pedidos
--     já registrados (como o nome e o preço, R79).
--   · Cor de cada parte: um filamento de Materiais, ou "a definir".
--     Novo precisa estar ativo; um filamento desativado depois continua.
--   · Pedido Entregue ou Cancelado não muda as cores.
--   · Só a Admin lê e grava. O Joca e visitantes não acessam nada.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/ficha_verificacao.sql e as verificações gerais.
-- Tudo ou nada: se qualquer passo falhar, nada é criado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.produto_partes') is not null or to_regclass('public.produto_materiais') is not null
     or to_regclass('public.item_venda_partes') is not null then
    raise exception 'A ficha de consumo já está instalada. Nada foi alterado.';
  end if;
  if to_regclass('public.itens_venda') is null or to_regclass('public.produtos') is null then
    raise exception 'Produtos (sql/06) e Pedidos Diretos (sql/07) precisam estar instalados. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
               and proname in ('salvar_ficha_produto', 'definir_cores_partes', 'tg_itens_venda_copiar_ficha',
                               'tg_item_venda_partes_protege')) then
    raise exception 'Já existe função da ficha de consumo. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------
-- Partes impressas de cada produto (R93). Sem cor.
create table public.produto_partes (
  id          uuid primary key default gen_random_uuid(),
  produto_id  uuid not null references public.produtos (id) on delete cascade,
  ordem       integer not null check (ordem between 1 and 30),
  nome        text not null check (length(trim(nome)) between 1 and 60),
  gramas      numeric(10,2) not null check (gramas > 0),
  purga_g     numeric(10,2) not null default 0 check (purga_g >= 0),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  updated_at  timestamptz not null default now(),
  constraint produto_partes_ordem_unica unique (produto_id, ordem) deferrable initially deferred
);

create unique index produto_partes_nome_unico on public.produto_partes (produto_id, lower(trim(nome)));

comment on table public.produto_partes is
  'Ficha de consumo (R93): partes impressas de cada produto, com gramas da peça e da purga. Não guarda cor.';

-- Outros materiais de cada produto: insumos e embalagens (R93).
create table public.produto_materiais (
  id           uuid primary key default gen_random_uuid(),
  produto_id   uuid not null references public.produtos (id) on delete cascade,
  material_id  uuid not null references public.materiais (id) on delete restrict,
  quantidade   numeric(12,3) not null check (quantidade > 0),
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  updated_at   timestamptz not null default now(),
  unique (produto_id, material_id)
);

create index idx_produto_materiais_material on public.produto_materiais (material_id);

comment on table public.produto_materiais is
  'Ficha de consumo (R93): insumos e embalagens de cada produto, com a quantidade por peça.';

-- Partes de cada item do pedido, copiadas da ficha, com a cor (R94).
create table public.item_venda_partes (
  id             uuid primary key default gen_random_uuid(),
  item_id        uuid not null references public.itens_venda (id) on delete cascade,
  ordem          integer not null check (ordem >= 1),
  nome           text not null check (length(trim(nome)) between 1 and 60),       -- cópia da ficha
  gramas         numeric(10,2) not null check (gramas > 0),                         -- cópia, por peça
  purga_g        numeric(10,2) not null check (purga_g >= 0),                       -- cópia, por peça
  material_id    uuid references public.materiais (id) on delete restrict,         -- vazio = a definir
  cor_descricao  text check (cor_descricao is null or length(trim(cor_descricao)) between 1 and 80),
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid(),
  updated_at     timestamptz not null default now(),
  unique (item_id, ordem),
  constraint item_venda_partes_cor_copiada check ((material_id is null) = (cor_descricao is null))
);

create index idx_item_venda_partes_material on public.item_venda_partes (material_id);

comment on table public.item_venda_partes is
  'Cores por parte no pedido (R94): partes e gramas copiados da ficha quando o item entra; só a cor muda.';

create trigger trg_produto_partes_updated_at before update on public.produto_partes
  for each row execute function public.tg_updated_at();
create trigger trg_produto_materiais_updated_at before update on public.produto_materiais
  for each row execute function public.tg_updated_at();
create trigger trg_item_venda_partes_updated_at before update on public.item_venda_partes
  for each row execute function public.tg_updated_at();
create trigger trg_produto_partes_auditoria after insert or update or delete on public.produto_partes
  for each row execute function public.tg_auditoria();
create trigger trg_produto_materiais_auditoria after insert or update or delete on public.produto_materiais
  for each row execute function public.tg_auditoria();
create trigger trg_item_venda_partes_auditoria after insert or update or delete on public.item_venda_partes
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 2. Proteções
-- ---------------------------------------------------------------------
-- Partes do item: não mudam de item; nome e gramas não mudam (vêm da
-- ficha); nada muda quando o pedido está Entregue ou Cancelado.
-- A remoção junto com o item (troca de produto ou item removido) segue a
-- regra do próprio item.
create or replace function public.tg_item_venda_partes_protege()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_status public.status_pedido_direto;
begin
  if tg_op = 'UPDATE' then
    if new.item_id is distinct from old.item_id or new.ordem is distinct from old.ordem
       or new.nome is distinct from old.nome or new.gramas is distinct from old.gramas
       or new.purga_g is distinct from old.purga_g then
      raise exception 'As partes e os gramas vêm da ficha do produto e não são alterados no pedido. Só a cor de cada parte pode mudar.';
    end if;
  end if;

  select v.status_pedido into v_status
    from public.itens_venda i join public.vendas v on v.id = i.venda_id
   where i.id = case when tg_op = 'DELETE' then old.item_id else new.item_id end;
  if v_status in ('ENTREGUE', 'CANCELADO') then
    raise exception 'Pedido entregue ou cancelado não pode ter as cores alteradas. Para corrigir um pedido entregue, volte o status para Pronto antes.';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger trg_item_venda_partes_protege
  before insert or update or delete on public.item_venda_partes
  for each row execute function public.tg_item_venda_partes_protege();


-- ---------------------------------------------------------------------
-- 3. Cópia da ficha para o pedido (R94)
-- ---------------------------------------------------------------------
-- Item do catálogo que entra no pedido, ou que troca de produto: as partes
-- da ficha são copiadas, com a cor "a definir". Item que já existe e não
-- troca de produto não muda (pedidos já registrados ficam como estão).
create or replace function public.tg_itens_venda_copiar_ficha()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.produto_id is not distinct from old.produto_id then
    return null;
  end if;
  if tg_op = 'UPDATE' then
    delete from public.item_venda_partes where item_id = new.id;
  end if;
  if new.produto_id is not null then
    insert into public.item_venda_partes (item_id, ordem, nome, gramas, purga_g)
    select new.id, row_number() over (order by pp.ordem), pp.nome, pp.gramas, pp.purga_g
      from public.produto_partes pp
     where pp.produto_id = new.produto_id
     order by pp.ordem;
  end if;
  return null;
end;
$$;

create trigger trg_itens_venda_copiar_ficha
  after insert or update of produto_id on public.itens_venda
  for each row execute function public.tg_itens_venda_copiar_ficha();


-- ---------------------------------------------------------------------
-- 4. Funções de gravação (só a Admin; tudo ou nada)
-- ---------------------------------------------------------------------

-- Grava a ficha inteira de um produto (R93).
--   p_partes:    [{"nome": "Flor", "gramas": 12, "purga_g": 2}, ...] na ordem
--   p_materiais: [{"material_id": "...", "quantidade": 1}, ...]
-- Listas vazias = produto sem ficha. Pedidos já registrados não mudam.
create or replace function public.salvar_ficha_produto(p_produto_id uuid, p_partes jsonb, p_materiais jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c_uuid    constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_partes  jsonb := coalesce(p_partes, '[]'::jsonb);
  v_mats    jsonb := coalesce(p_materiais, '[]'::jsonb);
  v_x       jsonb;
  v_n       integer;
  v_nome    text;
  v_txt     text;
  v_g       numeric;
  v_purga   numeric;
  v_nomes   text[] := '{}';
  v_mat_id  uuid;
  v_ids     uuid[] := '{}';
  v_mat     public.materiais;
  v_qtd     numeric;
  v_atual   record;
begin
  perform public.exigir_admin();

  perform 1 from public.produtos where id = p_produto_id for update;
  if not found then raise exception 'Produto não encontrado.'; end if;

  if jsonb_typeof(v_partes) <> 'array' or jsonb_typeof(v_mats) <> 'array' then
    raise exception 'Ficha em formato inválido.';
  end if;
  if jsonb_array_length(v_partes) > 30 then raise exception 'A ficha pode ter até 30 partes.'; end if;
  if jsonb_array_length(v_mats) > 30 then raise exception 'A ficha pode ter até 30 outros materiais.'; end if;

  -- Partes: confere tudo antes de gravar
  for v_x, v_n in select e, o::integer from jsonb_array_elements(v_partes) with ordinality t(e, o) loop
    if jsonb_typeof(v_x) <> 'object' then raise exception 'Parte %: formato inválido.', v_n; end if;
    v_nome := trim(coalesce(v_x ->> 'nome', ''));
    if length(v_nome) = 0 then raise exception 'Parte %: informe o nome da parte (ex.: Flor, Vaso).', v_n; end if;
    if length(v_nome) > 60 then raise exception 'Parte %: o nome pode ter até 60 caracteres.', v_n; end if;
    if lower(v_nome) = any (v_nomes) then raise exception 'Parte %: já existe uma parte "%" neste produto.', v_n, v_nome; end if;
    v_nomes := v_nomes || lower(v_nome);

    v_txt := v_x ->> 'gramas';
    if v_txt is null or v_txt !~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' or v_txt::numeric <= 0 then
      raise exception 'Parte % (%): informe os gramas da peça, maior que zero, até 2 casas decimais.', v_n, v_nome;
    end if;
    v_txt := coalesce(v_x ->> 'purga_g', '0');
    if v_txt !~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' then
      raise exception 'Parte % (%): a purga precisa ser zero ou mais gramas, até 2 casas decimais.', v_n, v_nome;
    end if;
  end loop;

  -- Outros materiais
  for v_x, v_n in select e, o::integer from jsonb_array_elements(v_mats) with ordinality t(e, o) loop
    if jsonb_typeof(v_x) <> 'object' then raise exception 'Material %: formato inválido.', v_n; end if;
    v_txt := nullif(trim(coalesce(v_x ->> 'material_id', '')), '');
    if v_txt is null or v_txt !~ c_uuid then raise exception 'Material %: escolha o material.', v_n; end if;
    v_mat_id := v_txt::uuid;
    if v_mat_id = any (v_ids) then raise exception 'Material %: o mesmo material aparece duas vezes.', v_n; end if;
    v_ids := v_ids || v_mat_id;
    select * into v_mat from public.materiais where id = v_mat_id;
    if not found then raise exception 'Material %: não existe mais em Materiais.', v_n; end if;
    if v_mat.categoria not in ('INSUMO', 'EMBALAGEM') then
      raise exception 'Material %: "%" não é insumo nem embalagem. Os filamentos entram pelas partes.', v_n, v_mat.tipo;
    end if;
    if not v_mat.ativo and not exists (
         select 1 from public.produto_materiais where produto_id = p_produto_id and material_id = v_mat_id) then
      raise exception 'Material %: "%" está inativo e não pode ser escolhido.', v_n,
        v_mat.tipo || coalesce(' · ' || v_mat.variacao, '');
    end if;
    v_txt := v_x ->> 'quantidade';
    if v_txt is null or v_txt !~ '^[0-9]{1,8}(\.[0-9]{1,3})?$' or v_txt::numeric <= 0 then
      raise exception 'Material % (%): informe a quantidade por peça, maior que zero, até 3 casas decimais.', v_n, v_mat.tipo;
    end if;
  end loop;

  -- Partes: atualiza pelo nome (mantém o histórico de cada parte), tira as
  -- que saíram, inclui as novas.
  delete from public.produto_partes
   where produto_id = p_produto_id and lower(trim(nome)) <> all (v_nomes);
  for v_x, v_n in select e, o::integer from jsonb_array_elements(v_partes) with ordinality t(e, o) loop
    v_nome := trim(v_x ->> 'nome');
    v_g := (v_x ->> 'gramas')::numeric;
    v_purga := coalesce(v_x ->> 'purga_g', '0')::numeric;
    select * into v_atual from public.produto_partes
     where produto_id = p_produto_id and lower(trim(nome)) = lower(v_nome);
    if found then
      update public.produto_partes set ordem = v_n, nome = v_nome, gramas = v_g, purga_g = v_purga
       where id = v_atual.id
         and (ordem, nome, gramas, purga_g) is distinct from (v_n, v_nome, v_g::numeric(10,2), v_purga::numeric(10,2));
    else
      insert into public.produto_partes (produto_id, ordem, nome, gramas, purga_g)
      values (p_produto_id, v_n, v_nome, v_g, v_purga);
    end if;
  end loop;

  -- Outros materiais
  delete from public.produto_materiais where produto_id = p_produto_id and material_id <> all (v_ids);
  for v_x in select e from jsonb_array_elements(v_mats) e loop
    v_mat_id := (v_x ->> 'material_id')::uuid;
    v_qtd := (v_x ->> 'quantidade')::numeric;
    update public.produto_materiais set quantidade = v_qtd
     where produto_id = p_produto_id and material_id = v_mat_id and quantidade is distinct from v_qtd::numeric(12,3);
    insert into public.produto_materiais (produto_id, material_id, quantidade)
    select p_produto_id, v_mat_id, v_qtd
     where not exists (select 1 from public.produto_materiais where produto_id = p_produto_id and material_id = v_mat_id);
  end loop;
end;
$$;

-- Define a cor de cada parte dos itens de um pedido (R94).
--   p_itens: [{"ordem": 1, "cores": ["<material_id>" | null, ...]}, ...]
-- "ordem" é a posição do item no pedido; "cores" segue a ordem das partes.
-- Só itens com partes entram. Chamada pela tela logo depois de salvar_pedido.
create or replace function public.definir_cores_partes(p_venda_id uuid, p_itens jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c_uuid    constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_venda   public.vendas;
  v_x       jsonb;
  v_n       integer;
  v_item    public.itens_venda;
  v_cores   jsonb;
  v_qtd     integer;
  v_parte   public.item_venda_partes;
  v_txt     text;
  v_mat_id  uuid;
  v_mat     public.materiais;
  v_cor     text;
  v_ordens  integer[] := '{}';
  v_linhas  integer;
  v_mudou   boolean := false;
begin
  perform public.exigir_admin();

  select * into v_venda from public.vendas where id = p_venda_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if v_venda.status_pedido in ('ENTREGUE', 'CANCELADO') then
    raise exception 'Pedido entregue ou cancelado não pode ter as cores alteradas. Para corrigir um pedido entregue, volte o status para Pronto antes.';
  end if;

  if p_itens is null or jsonb_typeof(p_itens) <> 'array' then raise exception 'Cores em formato inválido.'; end if;

  for v_x, v_n in select e, o::integer from jsonb_array_elements(p_itens) with ordinality t(e, o) loop
    v_txt := v_x ->> 'ordem';
    if jsonb_typeof(v_x) <> 'object' or v_txt is null or v_txt !~ '^[0-9]{1,4}$' then
      raise exception 'Cores: item % em formato inválido.', v_n;
    end if;
    if v_txt::integer = any (v_ordens) then raise exception 'Cores: o item % aparece duas vezes.', v_txt; end if;
    v_ordens := v_ordens || v_txt::integer;

    select * into v_item from public.itens_venda where venda_id = p_venda_id and ordem = v_txt::integer;
    if not found then raise exception 'Item %: não pertence a este pedido.', v_txt; end if;
    select count(*) into v_qtd from public.item_venda_partes where item_id = v_item.id;
    if v_qtd = 0 then raise exception 'Item %: este item não tem partes para escolher cor.', v_item.ordem; end if;

    v_cores := v_x -> 'cores';
    if v_cores is null or jsonb_typeof(v_cores) <> 'array' or jsonb_array_length(v_cores) <> v_qtd then
      raise exception 'Item %: informe a cor de cada uma das % partes.', v_item.ordem, v_qtd;
    end if;

    for v_parte in select * from public.item_venda_partes where item_id = v_item.id order by ordem loop
      v_txt := v_cores ->> (v_parte.ordem - 1);
      v_txt := nullif(trim(coalesce(v_txt, '')), '');
      if v_txt is not null and v_txt !~ c_uuid then
        raise exception 'Item %, parte %: cor inválida.', v_item.ordem, v_parte.nome;
      end if;
      v_mat_id := v_txt::uuid;
      if v_mat_id is not distinct from v_parte.material_id then continue; end if;

      if v_mat_id is null then
        v_cor := null;
      else
        select * into v_mat from public.materiais where id = v_mat_id;
        if not found then raise exception 'Item %, parte %: o filamento escolhido não existe mais em Materiais.', v_item.ordem, v_parte.nome; end if;
        if v_mat.categoria <> 'FILAMENTO' then
          raise exception 'Item %, parte %: "%" não é um filamento.', v_item.ordem, v_parte.nome, v_mat.tipo;
        end if;
        if not v_mat.ativo then
          raise exception 'Item %, parte %: o filamento % · % está inativo e não pode ser escolhido.',
            v_item.ordem, v_parte.nome, v_mat.tipo, v_mat.variacao;
        end if;
        v_cor := left(v_mat.tipo || ' · ' || v_mat.variacao, 80);
      end if;

      update public.item_venda_partes set material_id = v_mat_id, cor_descricao = v_cor where id = v_parte.id;
      get diagnostics v_linhas = row_count;
      v_mudou := v_mudou or v_linhas > 0;
    end loop;
  end loop;

  -- Mudança de cor conta como edição do pedido (P4).
  if v_mudou then
    update public.vendas set editado_em = now() where id = p_venda_id;
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 5. Acesso: só a Admin lê; ninguém grava direto
-- ---------------------------------------------------------------------
alter table public.produto_partes enable row level security;
alter table public.produto_materiais enable row level security;
alter table public.item_venda_partes enable row level security;

revoke all on public.produto_partes, public.produto_materiais, public.item_venda_partes from public, anon, authenticated;
grant select on public.produto_partes, public.produto_materiais, public.item_venda_partes to authenticated;

create policy produto_partes_select_admin on public.produto_partes
  for select to authenticated using (public.is_admin());
create policy produto_materiais_select_admin on public.produto_materiais
  for select to authenticated using (public.is_admin());
create policy item_venda_partes_select_admin on public.item_venda_partes
  for select to authenticated using (public.is_admin());

revoke all on function public.tg_item_venda_partes_protege() from public, anon, authenticated;
revoke all on function public.tg_itens_venda_copiar_ficha() from public, anon, authenticated;

revoke all on function public.salvar_ficha_produto(uuid, jsonb, jsonb) from public, anon;
revoke all on function public.definir_cores_partes(uuid, jsonb) from public, anon;
grant execute on function public.salvar_ficha_produto(uuid, jsonb, jsonb) to authenticated;
grant execute on function public.definir_cores_partes(uuid, jsonb) to authenticated;

commit;

-- Pronto. Confira com sql/ficha_verificacao.sql.
