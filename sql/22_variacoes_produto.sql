-- =====================================================================
-- Arts com Você · Variações de produto · Lote D1
-- Especificação v1.12–1.13, R112–R116, R118, R119 e R121 (decisões VR1–VR10;
-- foto por combinação retirada na v1.12). O catálogo público (R117) fica
-- para o Lote D2.
--
-- O que este arquivo faz:
--   · produto_opcoes e produto_opcao_valores: até 3 opções por produto (ex.:
--     Tamanho, Modelo, Cor), cada uma com os seus valores (R112, R116);
--   · produto_variacoes (+ produto_variacao_valores): as combinações, com
--     preço próprio e liga/desliga (R113);
--   · variacao_partes e variacao_materiais: a ficha de consumo opcional de
--     cada combinação; sem ficha, vale a do produto (R113);
--   · salvar_variacoes_produto e salvar_ficha_variacao (só a Admin);
--   · itens_venda, producoes e pecas_prontas ganham variacao_id: o pedido
--     direto escolhe a combinação (R115), a produção usa a ficha dela (R118)
--     e as peças prontas ficam separadas por combinação (R119).
--
-- Funções trocadas (mesmas regras de antes; só o acréscimo da combinação):
--   salvar_pedido, registrar_producao (+ p_variacao_id, opcional, no fim),
--   usar_peca_pronta, tg_itens_venda_copiar_ficha,
--   tg_itens_venda_producao_protege e tg_vendas_embalagem.
-- Consultas trocadas (colunas novas no fim): vw_itens_producao e
--   vw_pecas_prontas.
--
-- O que NÃO muda (R120, R121):
--   · nenhum pedido, item, produção, peça pronta ou ficha existente;
--   · produtos sem combinações funcionam como hoje;
--   · vendas da Shopee: o item continua ligado só ao produto;
--   · Caixa, Joca, Shopee, fotos e catálogo público.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/variacoes_verificacao.sql e as gerais.
-- Tudo ou nada: se qualquer passo falhar, nada é alterado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.produto_fotos') is null
     or not exists (select 1 from pg_attribute where attrelid = 'public.produtos'::regclass and attname = 'descricao_interna' and not attisdropped)
     or to_regclass('public.repasses_shopee') is null then
    raise exception 'Instale antes os lotes anteriores (sql/19, sql/20 e sql/21). Nada foi alterado.';
  end if;
  if to_regclass('public.produto_variacoes') is not null then
    raise exception 'As variações de produto já estão instaladas. Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
               and proname in ('salvar_variacoes_produto', 'salvar_ficha_variacao', 'variacao_tem_ficha',
                               'tg_itens_venda_variacao')) then
    raise exception 'Já existe função das variações. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------
-- Opções do produto (R112): até 3, na ordem escolhida.
create table public.produto_opcoes (
  id          uuid primary key default gen_random_uuid(),
  produto_id  uuid not null references public.produtos (id) on delete cascade,
  ordem       smallint not null check (ordem between 1 and 3),
  nome        text not null check (length(trim(nome)) between 1 and 30),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  updated_at  timestamptz not null default now(),
  constraint produto_opcoes_ordem_unica unique (produto_id, ordem) deferrable initially deferred
);
create unique index produto_opcoes_nome_unico on public.produto_opcoes (produto_id, lower(trim(nome)));

-- Valores de cada opção (ex.: P, M, G). Cor como opção é só o nome (R116).
create table public.produto_opcao_valores (
  id          uuid primary key default gen_random_uuid(),
  opcao_id    uuid not null references public.produto_opcoes (id) on delete cascade,
  ordem       smallint not null check (ordem between 1 and 20),
  valor       text not null check (length(trim(valor)) between 1 and 40),
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  updated_at  timestamptz not null default now(),
  constraint produto_opcao_valores_ordem_unica unique (opcao_id, ordem) deferrable initially deferred
);
create unique index produto_opcao_valores_unico on public.produto_opcao_valores (opcao_id, lower(trim(valor)));

-- Combinações (R113): preço próprio (vazio = sob consulta) e liga/desliga.
-- descricao = os valores na ordem das opções (ex.: "P · Rosa"); chave = os
-- valores, para não repetir a mesma combinação.
create table public.produto_variacoes (
  id          uuid primary key default gen_random_uuid(),
  produto_id  uuid not null references public.produtos (id) on delete cascade,
  chave       text not null,
  descricao   text not null check (length(trim(descricao)) between 1 and 130),
  preco       numeric(12,2) check (preco is null or preco >= 0),
  ativo       boolean not null default true,
  ordem       integer not null default 1,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  updated_at  timestamptz not null default now(),
  constraint produto_variacoes_chave_unica unique (produto_id, chave)
);

create table public.produto_variacao_valores (
  variacao_id  uuid not null references public.produto_variacoes (id) on delete cascade,
  valor_id     uuid not null references public.produto_opcao_valores (id) on delete restrict,
  primary key (variacao_id, valor_id)
);
create index idx_produto_variacao_valores_valor on public.produto_variacao_valores (valor_id);

-- Ficha de consumo da combinação (opcional, R113). Sem ficha: a do produto.
create table public.variacao_partes (
  id           uuid primary key default gen_random_uuid(),
  variacao_id  uuid not null references public.produto_variacoes (id) on delete cascade,
  ordem        integer not null check (ordem between 1 and 30),
  nome         text not null check (length(trim(nome)) between 1 and 60),
  gramas       numeric(10,2) not null check (gramas > 0),
  purga_g      numeric(10,2) not null default 0 check (purga_g >= 0),
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  updated_at   timestamptz not null default now(),
  constraint variacao_partes_ordem_unica unique (variacao_id, ordem) deferrable initially deferred
);
create unique index variacao_partes_nome_unico on public.variacao_partes (variacao_id, lower(trim(nome)));

create table public.variacao_materiais (
  id           uuid primary key default gen_random_uuid(),
  variacao_id  uuid not null references public.produto_variacoes (id) on delete cascade,
  material_id  uuid not null references public.materiais (id) on delete restrict,
  quantidade   numeric(12,3) not null check (quantidade > 0),
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  updated_at   timestamptz not null default now(),
  unique (variacao_id, material_id)
);
create index idx_variacao_materiais_material on public.variacao_materiais (material_id);

comment on table public.produto_opcoes is 'Variações (R112): até 3 opções por produto (ex.: Tamanho, Modelo, Cor).';
comment on table public.produto_opcao_valores is 'Variações (R112, R116): valores de cada opção. Cor como opção é só o nome.';
comment on table public.produto_variacoes is 'Variações (R113): combinações com preço próprio e liga/desliga.';
comment on table public.variacao_partes is 'Ficha de consumo da combinação (R113, opcional): partes impressas.';
comment on table public.variacao_materiais is 'Ficha de consumo da combinação (R113, opcional): insumos e embalagens.';

-- Combinação escolhida no pedido, na produção e nas peças prontas.
alter table public.itens_venda add column variacao_id uuid references public.produto_variacoes (id) on delete restrict;
alter table public.producoes add column variacao_id uuid references public.produto_variacoes (id) on delete restrict;
alter table public.pecas_prontas add column variacao_id uuid references public.produto_variacoes (id) on delete restrict;
create index idx_itens_venda_variacao on public.itens_venda (variacao_id);
create index idx_pecas_prontas_variacao on public.pecas_prontas (variacao_id);

comment on column public.itens_venda.variacao_id is 'Combinação escolhida no pedido direto (R115). Vazia em produto sem combinações e nas vendas da Shopee (R120).';


-- ---------------------------------------------------------------------
-- 2. updated_at e auditoria
-- ---------------------------------------------------------------------
create trigger trg_produto_opcoes_updated_at before update on public.produto_opcoes
  for each row execute function public.tg_updated_at();
create trigger trg_produto_opcao_valores_updated_at before update on public.produto_opcao_valores
  for each row execute function public.tg_updated_at();
create trigger trg_produto_variacoes_updated_at before update on public.produto_variacoes
  for each row execute function public.tg_updated_at();
create trigger trg_variacao_partes_updated_at before update on public.variacao_partes
  for each row execute function public.tg_updated_at();
create trigger trg_variacao_materiais_updated_at before update on public.variacao_materiais
  for each row execute function public.tg_updated_at();

create trigger trg_produto_opcoes_auditoria after insert or update or delete on public.produto_opcoes
  for each row execute function public.tg_auditoria();
create trigger trg_produto_opcao_valores_auditoria after insert or update or delete on public.produto_opcao_valores
  for each row execute function public.tg_auditoria();
create trigger trg_produto_variacoes_auditoria after insert or update or delete on public.produto_variacoes
  for each row execute function public.tg_auditoria();
create trigger trg_variacao_partes_auditoria after insert or update or delete on public.variacao_partes
  for each row execute function public.tg_auditoria();
create trigger trg_variacao_materiais_auditoria after insert or update or delete on public.variacao_materiais
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 3. Funções internas
-- ---------------------------------------------------------------------
-- A combinação tem ficha própria (partes ou outros materiais)?
create or replace function public.variacao_tem_ficha(p_variacao_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_variacao_id is not null
     and (exists (select 1 from public.variacao_partes where variacao_id = p_variacao_id)
          or exists (select 1 from public.variacao_materiais where variacao_id = p_variacao_id));
$$;

-- Item do pedido: a combinação é do mesmo produto do item.
create or replace function public.tg_itens_venda_variacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.variacao_id is not null
     and not exists (select 1 from public.produto_variacoes where id = new.variacao_id and produto_id = new.produto_id) then
    raise exception 'A combinação escolhida não é deste produto.';
  end if;
  return new;
end;
$$;

create trigger trg_itens_venda_variacao before insert or update of produto_id, variacao_id on public.itens_venda
  for each row execute function public.tg_itens_venda_variacao();


-- ---------------------------------------------------------------------
-- 4. Funções trocadas: a combinação no pedido, na ficha e na produção
-- ---------------------------------------------------------------------
-- Cópia da ficha para o pedido (R94): da combinação, se ela tiver ficha;
-- senão, do produto (R113, R115).
create or replace function public.tg_itens_venda_copiar_ficha()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.produto_id is not distinct from old.produto_id
     and new.variacao_id is not distinct from old.variacao_id then
    return null;
  end if;
  if tg_op = 'UPDATE' then
    delete from public.item_venda_partes where item_id = new.id;
  end if;
  if public.variacao_tem_ficha(new.variacao_id) then
    insert into public.item_venda_partes (item_id, ordem, nome, gramas, purga_g)
    select new.id, row_number() over (order by vp.ordem), vp.nome, vp.gramas, vp.purga_g
      from public.variacao_partes vp
     where vp.variacao_id = new.variacao_id
     order by vp.ordem;
  elsif new.produto_id is not null then
    insert into public.item_venda_partes (item_id, ordem, nome, gramas, purga_g)
    select new.id, row_number() over (order by pp.ordem), pp.nome, pp.gramas, pp.purga_g
      from public.produto_partes pp
     where pp.produto_id = new.produto_id
     order by pp.ordem;
  end if;
  return null;
end;
$$;

drop trigger trg_itens_venda_copiar_ficha on public.itens_venda;
create trigger trg_itens_venda_copiar_ficha
  after insert or update of produto_id, variacao_id on public.itens_venda
  for each row execute function public.tg_itens_venda_copiar_ficha();

-- Item com produção ou peça pronta: também não troca de combinação.
create or replace function public.tg_itens_venda_producao_protege()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.produto_id is not distinct from old.produto_id
     and new.variacao_id is not distinct from old.variacao_id then
    return new;
  end if;
  if exists (select 1 from public.producoes where item_id = old.id)
     or exists (select 1 from public.saidas_pecas_prontas where item_id = old.id) then
    raise exception 'O item "%" já tem produção ou peça pronta registrada e não pode ser removido nem trocar de produto ou de combinação. Para mudar a quantidade ou o preço, edite o item.', old.descricao;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger trg_itens_venda_producao_protege on public.itens_venda;
create trigger trg_itens_venda_producao_protege
  before update of produto_id, variacao_id or delete on public.itens_venda
  for each row execute function public.tg_itens_venda_producao_protege();

-- Embalagem em Pronto (R97): pela ficha da combinação, se ela tiver; senão,
-- pela do produto.
create or replace function public.tg_vendas_embalagem()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_x record;
  v_r record;
begin
  if exists (select 1 from public.embalagens_pedido where venda_id = new.id) then
    return null;   -- já baixada antes (ex.: voltou de Entregue para Pronto)
  end if;
  for v_x in
    select i.id as item_id, i.ordem, pm.material_id, pm.quantidade * i.quantidade as qtd, m.tipo, m.variacao
      from public.itens_venda i
      cross join lateral (
        select vm.material_id, vm.quantidade from public.variacao_materiais vm
         where public.variacao_tem_ficha(i.variacao_id) and vm.variacao_id = i.variacao_id
        union all
        select x.material_id, x.quantidade from public.produto_materiais x
         where not public.variacao_tem_ficha(i.variacao_id) and x.produto_id = i.produto_id) pm
      join public.materiais m on m.id = pm.material_id
     where i.venda_id = new.id and m.categoria = 'EMBALAGEM'
     order by i.ordem, m.tipo, m.variacao
  loop
    select * into v_r from public.baixar_material(v_x.material_id, v_x.qtd, public.hoje(), 'EMBALAGEM',
      'Embalagem do pedido ' || public.numero_pedido_texto(new.numero));
    insert into public.embalagens_pedido (venda_id, item_id, material_id, data, quantidade, valor, movimento_id)
    values (new.id, v_x.item_id, v_x.material_id, public.hoje(), v_x.qtd, v_r.valor, v_r.movimento_id);
  end loop;
  return null;
end;
$$;

-- Pedido direto (R115): item de produto com combinações exige escolher a
-- combinação; o nome é copiado com ela (ex.: "Caneta flor · P · Rosa").
-- Itens que já existem sem combinação continuam como estão (R121).
create or replace function public.salvar_pedido(
  p_id               uuid,
  p_data             date,
  p_cliente_id       uuid,
  p_origem           text,
  p_data_prometida   date,
  p_forma_pagamento  text,
  p_desconto         numeric,
  p_frete            numeric,
  p_observacao       text,
  p_itens            jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_uuid      constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  c_limite    constant numeric := 9999999.99;
  v_atual     public.vendas;
  v_cliente   public.clientes;
  v_id        uuid;
  v_numero    integer;
  v_origem    public.origem_pedido_direto;
  v_forma     public.forma_pagamento;
  v_desconto  numeric := coalesce(p_desconto, 0);
  v_frete     numeric := coalesce(p_frete, 0);
  v_obs       text := nullif(trim(coalesce(p_observacao, '')), '');
  v_subtotal  numeric := 0;
  v_total     numeric;
  v_liquido   numeric;

  v_item      jsonb;
  v_n         integer;
  v_txt       text;
  v_iid       uuid;
  v_ids       uuid[] := '{}';
  v_old       public.itens_venda;
  v_tem_old   boolean;
  v_prod_id   uuid;
  v_prod      public.produtos;
  v_mat_id    uuid;
  v_mat       public.materiais;
  v_cor_txt   text;
  v_desc      text;
  v_cor       text;
  v_qtd       integer;
  v_preco     numeric;
  v_troca_prod boolean;
  v_troca_cor  boolean;
  v_var_id    uuid;
  v_var       public.produto_variacoes;
  v_troca_var boolean;
  v_norm      jsonb := '[]'::jsonb;
  v_x         jsonb;
  v_linhas    integer;
  v_mudou     boolean := false;   -- P4: editado_em só quando algo mudou
  v_primeiro  date;               -- P1-b: data do primeiro lançamento ativo
begin
  perform public.exigir_admin();

  -- Pedido existente: trava e confere se ainda pode ser editado (R82)
  if p_id is not null then
    select * into v_atual from public.vendas where id = p_id for update;
    if not found then raise exception 'Pedido não encontrado.'; end if;
    if v_atual.status_pedido in ('ENTREGUE', 'CANCELADO') then
      raise exception 'Pedido entregue ou cancelado não pode ser editado. Para corrigir um pedido entregue, volte o status para Pronto antes.';
    end if;
  end if;

  -- Data real, nunca futura (R81)
  if p_data is null then raise exception 'Informe a data do pedido.'; end if;
  if p_data > public.hoje() then raise exception 'A data do pedido não pode ser futura.'; end if;
  -- P1-b: a data do pedido não pode ficar depois do primeiro recebimento ou
  -- devolução ativos (cada lançamento tem data entre a do pedido e hoje).
  if p_id is not null then
    select min(x.data) into v_primeiro
      from (select data from public.recebimentos_venda where venda_id = p_id and situacao = 'ATIVO'
            union all
            select data from public.devolucoes_venda where venda_id = p_id and situacao = 'ATIVO') x;
    if v_primeiro is not null and p_data > v_primeiro then
      raise exception 'A data do pedido não pode ficar depois do primeiro pagamento ou devolução registrado (%).',
        to_char(v_primeiro, 'DD/MM/YYYY');
    end if;
  end if;
  if p_data_prometida is not null and p_data_prometida < p_data then
    raise exception 'A data prometida não pode ser anterior à data do pedido.';
  end if;

  -- Cliente obrigatório (P1); ativo quando é escolhido (R77)
  if p_cliente_id is null then raise exception 'Escolha o cliente do pedido.'; end if;
  select * into v_cliente from public.clientes where id = p_cliente_id;
  if not found then raise exception 'Cliente não encontrado.'; end if;
  if not v_cliente.ativo and (p_id is null or v_atual.cliente_id is distinct from p_cliente_id) then
    raise exception 'O cliente "%" está inativo e não pode ser escolhido em um pedido.', v_cliente.nome;
  end if;

  -- Origem obrigatória (P2, R78)
  if p_origem is null or p_origem not in ('WHATSAPP', 'INSTAGRAM', 'PESSOALMENTE', 'OUTRO') then
    raise exception 'Escolha a origem do pedido: WhatsApp, Instagram, Pessoalmente ou Outro.';
  end if;
  v_origem := p_origem::public.origem_pedido_direto;

  -- Forma de pagamento combinada: opcional, da lista existente (P3)
  if nullif(trim(coalesce(p_forma_pagamento, '')), '') is not null then
    if p_forma_pagamento not in (select unnest(enum_range(null::public.forma_pagamento))::text) then
      raise exception 'Forma de pagamento inválida.';
    end if;
    v_forma := p_forma_pagamento::public.forma_pagamento;
  end if;

  if length(coalesce(v_obs, '')) > 2000 then raise exception 'A observação pode ter até 2.000 caracteres.'; end if;

  -- Desconto e frete (R80)
  if v_desconto < 0 then raise exception 'O desconto não pode ser negativo.'; end if;
  if v_frete < 0 then raise exception 'O frete não pode ser negativo.'; end if;
  if v_desconto <> round(v_desconto, 2) or v_frete <> round(v_frete, 2) then
    raise exception 'Desconto e frete aceitam até 2 casas decimais.';
  end if;
  if v_desconto > c_limite or v_frete > c_limite then raise exception 'Valor acima do limite do sistema (R$ 9.999.999,99).'; end if;

  -- Itens: pelo menos 1 (P6)
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'O pedido precisa ter pelo menos um item (do catálogo ou personalizado).';
  end if;
  if jsonb_array_length(p_itens) > 200 then raise exception 'Um pedido pode ter até 200 itens.'; end if;

  for v_item, v_n in select e, o::integer from jsonb_array_elements(p_itens) with ordinality t(e, o) loop
    if jsonb_typeof(v_item) <> 'object' then raise exception 'Item %: formato inválido.', v_n; end if;

    -- Item que já existe (só ao editar)
    v_iid := null; v_tem_old := false;
    v_txt := nullif(trim(coalesce(v_item ->> 'id', '')), '');
    if v_txt is not null then
      if v_txt !~ c_uuid or p_id is null then raise exception 'Item %: identificador inválido.', v_n; end if;
      v_iid := v_txt::uuid;
      if v_iid = any (v_ids) then raise exception 'Item %: aparece duas vezes na lista.', v_n; end if;
      select * into v_old from public.itens_venda where id = v_iid and venda_id = p_id;
      if not found then raise exception 'Item %: não pertence a este pedido.', v_n; end if;
      v_tem_old := true;
      v_ids := v_ids || v_iid;
    end if;

    -- Quantidade inteira ≥ 1
    v_txt := v_item ->> 'quantidade';
    if v_txt is null or v_txt !~ '^[0-9]{1,6}$' then
      raise exception 'Item %: a quantidade precisa ser um número inteiro, no mínimo 1.', v_n;
    end if;
    v_qtd := v_txt::integer;
    if v_qtd < 1 then
      raise exception 'Item %: a quantidade precisa ser um número inteiro, no mínimo 1.', v_n;
    end if;

    -- Preço unitário ≥ 0, até 2 casas (R$ 0,00 = brinde)
    v_txt := v_item ->> 'preco_unitario';
    if v_txt is null or v_txt !~ '^[0-9]{1,10}(\.[0-9]{1,2})?$' then
      raise exception 'Item %: informe o preço unitário (R$ 0,00 ou mais, até 2 casas decimais).', v_n;
    end if;
    v_preco := v_txt::numeric;
    if v_preco > c_limite or v_qtd * v_preco > c_limite then
      raise exception 'Item %: valor acima do limite do sistema (R$ 9.999.999,99).', v_n;
    end if;

    -- Produto e cor
    v_txt := nullif(trim(coalesce(v_item ->> 'produto_id', '')), '');
    if v_txt is not null and v_txt !~ c_uuid then raise exception 'Item %: produto inválido.', v_n; end if;
    v_prod_id := v_txt::uuid;

    v_txt := nullif(trim(coalesce(v_item ->> 'material_id', '')), '');
    if v_txt is not null and v_txt !~ c_uuid then raise exception 'Item %: cor inválida.', v_n; end if;
    v_mat_id := v_txt::uuid;

    v_cor_txt := nullif(trim(coalesce(v_item ->> 'cor_texto', '')), '');

    -- Combinação (R115)
    v_txt := nullif(trim(coalesce(v_item ->> 'variacao_id', '')), '');
    if v_txt is not null and v_txt !~ c_uuid then raise exception 'Item %: combinação inválida.', v_n; end if;
    v_var_id := v_txt::uuid;
    if v_var_id is not null and v_prod_id is null then
      raise exception 'Item %: combinação só existe em item do catálogo.', v_n;
    end if;

    v_troca_prod := not v_tem_old or v_old.produto_id is distinct from v_prod_id;
    v_troca_var  := v_troca_prod or v_old.variacao_id is distinct from v_var_id;
    v_troca_cor  := v_troca_prod or v_old.material_id is distinct from v_mat_id;

    if v_prod_id is not null then
      -- Item do catálogo (R79): nome copiado; só produto ativo ao entrar
      if v_cor_txt is not null then
        raise exception 'Item %: no item do catálogo, escolha uma das cores do produto.', v_n;
      end if;
      if v_troca_prod then
        select * into v_prod from public.produtos where id = v_prod_id;
        if not found then raise exception 'Item %: produto não encontrado.', v_n; end if;
        if not v_prod.ativo then
          raise exception 'Item %: o produto "%" está inativo e não pode entrar no pedido.', v_n, v_prod.nome;
        end if;
        v_desc := v_prod.nome;
      else
        v_desc := v_old.descricao;
      end if;
      -- Produto com combinações: escolher uma, ligada (R115). O nome do item
      -- é copiado com ela. Item antigo sem combinação continua (R121).
      if v_troca_var then
        if v_var_id is null then
          if exists (select 1 from public.produto_variacoes where produto_id = v_prod_id) then
            select * into v_prod from public.produtos where id = v_prod_id;
            raise exception 'Item %: escolha a combinação de "%".', v_n, v_prod.nome;
          end if;
        else
          select * into v_var from public.produto_variacoes where id = v_var_id and produto_id = v_prod_id;
          if not found then raise exception 'Item %: a combinação escolhida não é deste produto.', v_n; end if;
          if not v_var.ativo then
            raise exception 'Item %: a combinação "%" está desligada e não pode entrar no pedido.', v_n, v_var.descricao;
          end if;
          select * into v_prod from public.produtos where id = v_prod_id;
          v_desc := left(v_prod.nome || ' · ' || v_var.descricao, 150);
        end if;
      end if;

      if v_mat_id is null then
        v_cor := null;
      elsif v_troca_cor then
        if not exists (select 1 from public.produto_cores where produto_id = v_prod_id and material_id = v_mat_id) then
          raise exception 'Item %: a cor escolhida não é uma das cores do produto.', v_n;
        end if;
        select * into v_mat from public.materiais where id = v_mat_id;
        v_cor := left(v_mat.tipo || ' · ' || v_mat.variacao, 80);
      else
        v_cor := v_old.cor_descricao;
      end if;
    else
      -- Item personalizado (R79): descrição livre; cor = filamento ativo ou texto livre
      v_desc := trim(coalesce(v_item ->> 'descricao', ''));
      if length(v_desc) = 0 then raise exception 'Item %: descreva o item personalizado.', v_n; end if;
      if length(v_desc) > 150 then raise exception 'Item %: a descrição pode ter até 150 caracteres.', v_n; end if;

      if v_mat_id is not null and v_cor_txt is not null then
        raise exception 'Item %: escolha um filamento ou escreva a cor, não os dois.', v_n;
      end if;
      if v_mat_id is not null then
        if v_troca_cor then
          select * into v_mat from public.materiais where id = v_mat_id;
          if not found then raise exception 'Item %: o filamento escolhido não existe mais em Materiais.', v_n; end if;
          if v_mat.categoria <> 'FILAMENTO' then
            raise exception 'Item %: "%" não é um filamento.', v_n, v_mat.tipo;
          end if;
          if not v_mat.ativo then
            raise exception 'Item %: o filamento % · % está inativo e não pode ser escolhido.', v_n, v_mat.tipo, v_mat.variacao;
          end if;
          v_cor := left(v_mat.tipo || ' · ' || v_mat.variacao, 80);
        else
          v_cor := v_old.cor_descricao;
        end if;
      elsif v_cor_txt is not null then
        if length(v_cor_txt) > 80 then raise exception 'Item %: a cor pode ter até 80 caracteres.', v_n; end if;
        v_cor := v_cor_txt;
      else
        v_cor := null;
      end if;
    end if;

    v_subtotal := v_subtotal + round(v_qtd * v_preco, 2);
    v_norm := v_norm || jsonb_build_array(jsonb_build_object(
      'id', v_iid, 'ordem', v_n, 'produto_id', v_prod_id, 'descricao', v_desc,
      'preco_unitario', v_preco, 'quantidade', v_qtd, 'material_id', v_mat_id, 'cor_descricao', v_cor,
      'variacao_id', v_var_id));
  end loop;

  -- Valores (R80)
  if v_subtotal > c_limite then raise exception 'O subtotal passa do limite do sistema (R$ 9.999.999,99).'; end if;
  if v_desconto > v_subtotal then
    raise exception 'O desconto não pode passar do subtotal dos itens.';
  end if;
  v_total := v_subtotal - v_desconto + v_frete;
  if v_total > c_limite then raise exception 'O total passa do limite do sistema (R$ 9.999.999,99).'; end if;

  -- Novo total ≥ dinheiro líquido já recebido (C1). No P1-a o líquido é 0.
  v_liquido := coalesce(v_atual.valor_recebido, 0) - coalesce(v_atual.valor_devolvido, 0);
  if v_total < v_liquido then
    raise exception 'O novo total (R$ %) ficaria menor que o valor líquido já recebido (R$ %). Registre antes a devolução da diferença.',
      replace(to_char(v_total, 'FM9999999990.00'), '.', ','), replace(to_char(v_liquido, 'FM9999999990.00'), '.', ',');
  end if;

  -- Gravação do cabeçalho
  if p_id is null then
    v_numero := public.proximo_numero_pedido();
    insert into public.vendas (numero, data, cliente_id, canal_id, origem, data_prometida, forma_pagamento,
                               observacao, subtotal, desconto, frete, total)
    values (v_numero, p_data, p_cliente_id, public.canal_boca_a_boca(), v_origem, p_data_prometida, v_forma,
            v_obs, v_subtotal, v_desconto, v_frete, v_total)
    returning id into v_id;

    insert into public.historico_status_pedido (venda_id, status_anterior, status_novo)
    values (v_id, null, 'AGUARDANDO');
  else
    v_id := p_id;
    v_numero := v_atual.numero;
    update public.vendas
       set data = p_data, cliente_id = p_cliente_id, origem = v_origem, data_prometida = p_data_prometida,
           forma_pagamento = v_forma, observacao = v_obs,
           subtotal = v_subtotal, desconto = v_desconto, frete = v_frete, total = v_total
     where id = v_id
       and (data, cliente_id, origem, data_prometida, forma_pagamento, observacao, subtotal, desconto, frete, total)
           is distinct from (p_data, p_cliente_id, v_origem, p_data_prometida, v_forma, v_obs,
                             v_subtotal::numeric(12,2), v_desconto::numeric(12,2), v_frete::numeric(12,2), v_total::numeric(12,2));
    get diagnostics v_linhas = row_count;
    v_mudou := v_linhas > 0;
  end if;

  -- Itens: remove os que saíram, atualiza os que ficaram, inclui os novos
  delete from public.itens_venda where venda_id = v_id and id <> all (v_ids);
  get diagnostics v_linhas = row_count;
  v_mudou := v_mudou or v_linhas > 0;

  for v_x in select e from jsonb_array_elements(v_norm) e loop
    if v_x ->> 'id' is not null then
      update public.itens_venda
         set ordem = (v_x ->> 'ordem')::integer,
             produto_id = (v_x ->> 'produto_id')::uuid,
             descricao = v_x ->> 'descricao',
             preco_unitario = (v_x ->> 'preco_unitario')::numeric,
             quantidade = (v_x ->> 'quantidade')::integer,
             material_id = (v_x ->> 'material_id')::uuid,
             cor_descricao = v_x ->> 'cor_descricao',
             variacao_id = (v_x ->> 'variacao_id')::uuid
       where id = (v_x ->> 'id')::uuid
         and (ordem, produto_id, descricao, preco_unitario, quantidade, material_id, cor_descricao, variacao_id)
             is distinct from ((v_x ->> 'ordem')::integer, (v_x ->> 'produto_id')::uuid, v_x ->> 'descricao',
                               (v_x ->> 'preco_unitario')::numeric, (v_x ->> 'quantidade')::integer,
                               (v_x ->> 'material_id')::uuid, v_x ->> 'cor_descricao', (v_x ->> 'variacao_id')::uuid);
      get diagnostics v_linhas = row_count;
      v_mudou := v_mudou or v_linhas > 0;
    else
      insert into public.itens_venda (venda_id, ordem, produto_id, descricao, preco_unitario, quantidade,
                                      material_id, cor_descricao, variacao_id)
      values (v_id, (v_x ->> 'ordem')::integer, (v_x ->> 'produto_id')::uuid, v_x ->> 'descricao',
              (v_x ->> 'preco_unitario')::numeric, (v_x ->> 'quantidade')::integer,
              (v_x ->> 'material_id')::uuid, v_x ->> 'cor_descricao', (v_x ->> 'variacao_id')::uuid);
      v_mudou := true;
    end if;
  end loop;

  -- P4: a data da última edição só muda quando os dados ou os itens mudaram
  -- (pedido novo fica sem editado_em; a tela mostra a data de criação).
  if p_id is not null and v_mudou then
    update public.vendas set editado_em = now() where id = v_id;
  end if;

  perform public.recalcular_pedido(v_id);
  perform public.conferir_pedido(v_id);

  return jsonb_build_object('id', v_id, 'numero', v_numero);
end;
$$;

-- Produção (R118, R119): a do pedido usa a ficha copiada para o item (da
-- combinação); a do estoque escolhe a combinação e as peças prontas ficam
-- separadas por ela.
drop function public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid);
create function public.registrar_producao(
  p_data date, p_destino text, p_resultado text, p_item_id uuid, p_produto_id uuid, p_descricao text,
  p_pecas integer, p_percentual numeric, p_tempo_min integer, p_consumos jsonb, p_obs text, p_chave uuid,
  p_variacao_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_uuid     constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  c_num      constant text := '^[0-9]{1,7}(\.[0-9]{1,3})?$';
  v_cfg      public.configuracoes;
  v_destino  public.destino_producao;
  v_result   public.resultado_producao;
  v_item     public.itens_venda;
  v_venda    public.vendas;
  v_prod     public.produtos;
  v_desc     text;
  v_obs      text := nullif(trim(coalesce(p_obs, '')), '');
  v_id       uuid;
  v_x        jsonb;
  v_n        integer;
  v_txt      text;
  v_mat      public.materiais;
  v_mat_id   uuid;
  v_parte    text;
  v_peca     numeric;
  v_purga    numeric;
  v_fator    numeric;
  v_r        record;
  v_fil      numeric := 0;
  v_ins      numeric := 0;
  v_energia  numeric;
  v_total    numeric;
  v_cores    jsonb := '[]'::jsonb;
  v_partes   integer;
  v_faltam   integer;
  v_pronto   boolean := false;
  v_motivo   public.motivo_estoque;
  v_existe   public.producoes;
  v_var      public.produto_variacoes;
begin
  perform public.exigir_admin();

  if p_chave is null then raise exception 'Código de envio ausente. Recarregue a página e tente de novo.'; end if;
  select * into v_existe from public.producoes where chave_envio = p_chave;
  if found then   -- o mesmo formulário enviado de novo
    return jsonb_build_object('id', v_existe.id, 'custo_total', v_existe.custo_total, 'pedido_pronto', false, 'repetido', true);
  end if;

  if p_data is null then raise exception 'Informe a data da produção.'; end if;
  if p_data > public.hoje() then raise exception 'A data da produção não pode ser futura.'; end if;
  if p_destino is null or p_destino not in ('PEDIDO', 'ESTOQUE', 'AVULSA') then
    raise exception 'Escolha para onde vai a produção: item de pedido, estoque de peças prontas ou avulsa.';
  end if;
  if p_resultado is null or p_resultado not in ('OK', 'FALHA') then raise exception 'Escolha o resultado: OK ou Falha.'; end if;
  v_destino := p_destino::public.destino_producao;
  v_result := p_resultado::public.resultado_producao;
  if length(coalesce(v_obs, '')) > 500 then raise exception 'A observação pode ter até 500 caracteres.'; end if;

  -- Energia (R16): potência e tarifa obrigatórias
  select * into v_cfg from public.configuracoes where id = 1;
  if v_cfg.potencia_impressora_w is null or v_cfg.tarifa_kwh is null then
    raise exception 'Preencha a potência da impressora e a tarifa de energia em Configurações antes de registrar produções.';
  end if;
  if p_tempo_min is null or p_tempo_min < 0 or p_tempo_min > 100000 then
    raise exception 'Informe o tempo de impressão (horas e minutos).';
  end if;

  -- Falha: quanto chegou a imprimir
  if v_result = 'FALHA' then
    if p_percentual is null or p_percentual <= 0 or p_percentual > 100 or p_percentual <> round(p_percentual, 2) then
      raise exception 'Informe quanto chegou a imprimir antes da falha (de 1%% a 100%%).';
    end if;
  elsif p_percentual is not null then
    raise exception 'O percentual impresso é só para falha.';
  end if;

  -- Destino
  if v_destino = 'PEDIDO' then
    if p_item_id is null then raise exception 'Escolha o item do pedido.'; end if;
    select * into v_item from public.itens_venda where id = p_item_id;
    if not found then raise exception 'Item de pedido não encontrado.'; end if;
    select * into v_venda from public.vendas where id = v_item.venda_id for update;
    if v_venda.status_pedido in ('ENTREGUE', 'CANCELADO') then
      raise exception 'O pedido % está % e não recebe produção.', public.numero_pedido_texto(v_venda.numero),
        case when v_venda.status_pedido = 'ENTREGUE' then 'entregue' else 'cancelado' end;
    end if;
    v_faltam := public.item_faltam(v_item.id);
    if v_result = 'OK' then
      if p_pecas is null or p_pecas < 1 then raise exception 'Informe quantas peças ficaram prontas.'; end if;
      if v_faltam = 0 then raise exception 'Este item já está todo pronto.'; end if;
      if p_pecas > v_faltam then
        raise exception 'O item precisa de só mais % peça(s). Peças a mais vão para o estoque como outra produção.', v_faltam;
      end if;
    end if;
    -- Cores por parte: precisam estar definidas no pedido
    if exists (select 1 from public.item_venda_partes where item_id = v_item.id and material_id is null) then
      raise exception 'Defina a cor de cada parte no pedido % antes de registrar a produção.', public.numero_pedido_texto(v_venda.numero);
    end if;
    v_desc := public.numero_pedido_texto(v_venda.numero) || ' · ' || v_item.descricao;
    p_produto_id := v_item.produto_id;
    p_variacao_id := v_item.variacao_id;   -- a do item (R118)
  elsif v_destino = 'ESTOQUE' then
    if p_item_id is not null then raise exception 'Produção para o estoque não tem item de pedido.'; end if;
    select * into v_prod from public.produtos where id = p_produto_id;
    if not found then raise exception 'Escolha o produto.'; end if;
    if v_result = 'OK' and (p_pecas is null or p_pecas < 1 or p_pecas > 10000) then
      raise exception 'Informe quantas peças ficaram prontas.';
    end if;
    v_desc := v_prod.nome;
    -- Produto com combinações: as peças prontas ficam separadas por ela (R119)
    if exists (select 1 from public.produto_variacoes where produto_id = p_produto_id) then
      if p_variacao_id is null then raise exception 'Escolha a combinação de "%".', v_prod.nome; end if;
      select * into v_var from public.produto_variacoes where id = p_variacao_id and produto_id = p_produto_id;
      if not found then raise exception 'A combinação escolhida não é deste produto.'; end if;
      v_desc := left(v_prod.nome || ' · ' || v_var.descricao, 200);
    elsif p_variacao_id is not null then
      raise exception 'Este produto não tem combinações.';
    end if;
  else
    if p_item_id is not null then raise exception 'Produção avulsa não tem item de pedido.'; end if;
    if p_variacao_id is not null then raise exception 'Produção avulsa não tem combinação.'; end if;
    v_desc := trim(coalesce(p_descricao, ''));
    if length(v_desc) = 0 then raise exception 'Descreva a produção avulsa (ex.: teste de calibração, brinde).'; end if;
    if length(v_desc) > 200 then raise exception 'A descrição pode ter até 200 caracteres.'; end if;
    if p_produto_id is not null and not exists (select 1 from public.produtos where id = p_produto_id) then
      raise exception 'Produto não encontrado.';
    end if;
  end if;
  if v_result = 'FALHA' or v_destino = 'AVULSA' then
    if p_pecas is not null then raise exception 'Peças prontas só existem em produção OK de pedido ou de estoque.'; end if;
  end if;

  -- Consumos: pelo menos 1, conferidos antes de gravar
  if p_consumos is null or jsonb_typeof(p_consumos) <> 'array' or jsonb_array_length(p_consumos) = 0 then
    raise exception 'Informe o material usado (pelo menos um filamento ou insumo).';
  end if;
  if jsonb_array_length(p_consumos) > 60 then raise exception 'Uma produção pode ter até 60 linhas de material.'; end if;

  insert into public.producoes (data, destino, resultado, item_id, venda_id, produto_id, descricao, pecas,
                                percentual_impresso, tempo_min, potencia_w, tarifa_kwh, obs, chave_envio, variacao_id)
  values (p_data, v_destino, v_result, v_item.id, v_item.venda_id, p_produto_id, v_desc,
          case when v_result = 'OK' and v_destino <> 'AVULSA' then p_pecas end,
          p_percentual, p_tempo_min, v_cfg.potencia_impressora_w, v_cfg.tarifa_kwh, v_obs, p_chave, p_variacao_id)
  returning id into v_id;

  v_motivo := case when v_result = 'FALHA' then 'FALHA'::public.motivo_estoque else 'PRODUCAO'::public.motivo_estoque end;

  for v_x, v_n in select e, o::integer from jsonb_array_elements(p_consumos) with ordinality t(e, o) loop
    if jsonb_typeof(v_x) <> 'object' then raise exception 'Material %: formato inválido.', v_n; end if;
    v_txt := nullif(trim(coalesce(v_x ->> 'material_id', '')), '');
    if v_txt is null or v_txt !~ c_uuid then raise exception 'Material %: escolha o material.', v_n; end if;
    v_mat_id := v_txt::uuid;
    select * into v_mat from public.materiais where id = v_mat_id;
    if not found then raise exception 'Material %: não existe mais em Materiais.', v_n; end if;
    v_parte := nullif(trim(coalesce(v_x ->> 'parte', '')), '');
    if length(coalesce(v_parte, '')) > 60 then raise exception 'Material %: o nome da parte pode ter até 60 caracteres.', v_n; end if;

    v_txt := coalesce(nullif(v_x ->> 'peca', ''), '0');
    if v_txt !~ c_num then raise exception 'Material % (%): quantidade inválida (até 3 casas decimais).', v_n, v_mat.tipo; end if;
    v_peca := v_txt::numeric;
    v_txt := coalesce(nullif(v_x ->> 'purga', ''), '0');
    if v_txt !~ c_num then raise exception 'Material % (%): purga inválida (até 3 casas decimais).', v_n, v_mat.tipo; end if;
    v_purga := v_txt::numeric;
    if v_peca + v_purga <= 0 then raise exception 'Material % (%): informe a quantidade usada.', v_n, v_mat.tipo; end if;

    v_fator := 1;   -- filamento é sempre em gramas (regra de Materiais); insumo na unidade dele
    if v_mat.categoria <> 'FILAMENTO' then
      if v_mat.categoria = 'EMBALAGEM' and v_destino <> 'AVULSA' then
        raise exception 'A embalagem "%" sai do estoque quando o pedido fica Pronto, não na produção.', v_mat.tipo;
      end if;
      if v_result = 'FALHA' then
        raise exception 'Na falha só sai filamento. Insumos e embalagem não saem (R96).';
      end if;
      if v_purga > 0 then raise exception 'Material % (%): purga é só para filamento.', v_n, v_mat.tipo; end if;
      if v_parte is not null then raise exception 'Material % (%): parte é só para filamento.', v_n, v_mat.tipo; end if;
    end if;

    -- Pedido com partes: cada parte usa a cor escolhida no pedido
    if v_destino = 'PEDIDO' and v_parte is not null then
      if not exists (select 1 from public.item_venda_partes where item_id = v_item.id
                       and lower(trim(nome)) = lower(v_parte) and material_id = v_mat_id) then
        raise exception 'Parte "%": o filamento precisa ser a cor escolhida no pedido.', v_parte;
      end if;
    end if;

    select * into v_r from public.baixar_material(v_mat_id, round((v_peca + v_purga) / v_fator, 3), p_data, v_motivo,
      case when v_result = 'FALHA' then 'Falha de impressão: ' else 'Produção: ' end || v_desc);
    insert into public.producao_consumos (producao_id, ordem, material_id, parte, quantidade_peca, quantidade_purga,
                                          quantidade, valor, movimento_id)
    values (v_id, v_n, v_mat_id, v_parte, round(v_peca / v_fator, 3), round((v_peca + v_purga) / v_fator, 3) - round(v_peca / v_fator, 3),
            round((v_peca + v_purga) / v_fator, 3), v_r.valor, v_r.movimento_id);
    if v_mat.categoria = 'FILAMENTO' then
      v_fil := v_fil + v_r.valor;
      if not exists (select 1 from jsonb_array_elements(v_cores) c
                      where c ->> 'parte' is not distinct from v_parte and c ->> 'material_id' = v_mat_id::text) then
        v_cores := v_cores || jsonb_build_array(jsonb_build_object(
          'parte', v_parte, 'material_id', v_mat_id, 'cor', v_mat.tipo || ' · ' || coalesce(v_mat.variacao, '')));
      end if;
    else
      v_ins := v_ins + v_r.valor;
    end if;
  end loop;

  -- Peças do estoque: produto com ficha precisa de uma cor em cada parte
  if v_destino = 'ESTOQUE' and v_result = 'OK' then
    -- Partes: da ficha da combinação, se ela tiver; senão, do produto (R113, R118)
    if exists (
         select 1 from (select vp.nome from public.variacao_partes vp
                         where public.variacao_tem_ficha(p_variacao_id) and vp.variacao_id = p_variacao_id
                        union all
                        select pp.nome from public.produto_partes pp
                         where not public.variacao_tem_ficha(p_variacao_id) and pp.produto_id = p_produto_id) pp
          where not exists (select 1 from jsonb_array_elements(v_cores) c where lower(c ->> 'parte') = lower(trim(pp.nome)))) then
      raise exception 'Informe o filamento de cada parte do produto (as cores das peças prontas vêm daí).';
    end if;
    if not exists (select 1 from jsonb_array_elements(v_cores)) then
      raise exception 'Informe pelo menos um filamento: as peças prontas são separadas pelas cores.';
    end if;
  end if;

  v_energia := round(v_cfg.potencia_impressora_w / 1000 * p_tempo_min / 60.0 * v_cfg.tarifa_kwh, 2);
  v_total := v_fil + v_ins + v_energia;
  update public.producoes
     set custo_filamento = v_fil, custo_insumos = v_ins, custo_energia = v_energia, custo_total = v_total,
         cores = (select coalesce(jsonb_agg(c order by c ->> 'parte' nulls last, c ->> 'cor'), '[]'::jsonb)
                    from jsonb_array_elements(v_cores) c)
   where id = v_id;

  if v_destino = 'ESTOQUE' and v_result = 'OK' then
    insert into public.pecas_prontas (producao_id, produto_id, cores, cores_chave, cores_descricao, quantidade,
                                      custo_total, custo_unitario, data, variacao_id)
    select v_id, p_produto_id, p.cores,
           (select string_agg(coalesce(lower(c ->> 'parte'), '') || '=' || (c ->> 'material_id'), '|' order by lower(c ->> 'parte'), c ->> 'material_id')
              from jsonb_array_elements(p.cores) c),
           (select string_agg(case when c ->> 'parte' is null then c ->> 'cor' else (c ->> 'parte') || ': ' || (c ->> 'cor') end,
                              ' · ' order by c ->> 'parte' nulls last, c ->> 'cor')
              from jsonb_array_elements(p.cores) c),
           p_pecas, v_total, round(v_total / p_pecas, 4), p_data, p_variacao_id
      from public.producoes p where p.id = v_id;
  end if;

  if v_destino = 'PEDIDO' and v_result = 'OK' then
    v_pronto := public.atualizar_pedido_pronto(v_item.venda_id);
  end if;

  return jsonb_build_object('id', v_id, 'custo_total', v_total, 'pedido_pronto', v_pronto);
end;
$$;

-- Usar peça pronta (R119): só da mesma combinação do item.
create or replace function public.usar_peca_pronta(p_item_id uuid, p_lote_id uuid, p_quantidade integer, p_chave uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item    public.itens_venda;
  v_venda   public.vendas;
  v_lote    public.pecas_prontas;
  v_saldo   integer;
  v_custo   numeric;
  v_faltam  integer;
  v_c       jsonb;
  v_linhas  integer;
  v_id      uuid;
  v_pronto  boolean;
  v_existe  public.saidas_pecas_prontas;
begin
  perform public.exigir_admin();
  if p_chave is null then raise exception 'Código de envio ausente. Recarregue a página e tente de novo.'; end if;
  select * into v_existe from public.saidas_pecas_prontas where chave_envio = p_chave;
  if found then return jsonb_build_object('id', v_existe.id, 'pedido_pronto', false, 'repetido', true); end if;

  select * into v_item from public.itens_venda where id = p_item_id;
  if not found then raise exception 'Item de pedido não encontrado.'; end if;
  select * into v_venda from public.vendas where id = v_item.venda_id for update;
  if v_venda.status_pedido in ('ENTREGUE', 'CANCELADO') then
    raise exception 'O pedido está % e não recebe peças.', case when v_venda.status_pedido = 'ENTREGUE' then 'entregue' else 'cancelado' end;
  end if;

  select * into v_lote from public.pecas_prontas where id = p_lote_id for update;
  if not found or exists (select 1 from public.producoes where id = v_lote.producao_id and situacao = 'ESTORNADO') then
    raise exception 'Peça pronta não encontrada.';
  end if;
  if v_item.produto_id is distinct from v_lote.produto_id then
    raise exception 'A peça pronta é de outro produto.';
  end if;
  if v_item.variacao_id is distinct from v_lote.variacao_id then
    raise exception 'A peça pronta é de outra combinação do produto (R119).';
  end if;
  if p_quantidade is null or p_quantidade < 1 then raise exception 'Informe quantas peças usar.'; end if;
  v_faltam := public.item_faltam(v_item.id);
  if v_faltam = 0 then raise exception 'Este item já está todo pronto.'; end if;
  if p_quantidade > v_faltam then raise exception 'O item precisa de só mais % peça(s).', v_faltam; end if;
  v_saldo := v_lote.quantidade - coalesce((select sum(quantidade) from public.saidas_pecas_prontas
                                            where lote_id = v_lote.id and situacao = 'ATIVO'), 0);
  if p_quantidade > v_saldo then raise exception 'Só há % peça(s) prontas nesta combinação.', v_saldo; end if;

  -- Custo: proporcional; a última peça do lote leva o restante (sem sobra de centavos)
  v_custo := case when p_quantidade = v_saldo
                  then v_lote.custo_total - coalesce((select sum(custo) from public.saidas_pecas_prontas
                                                       where lote_id = v_lote.id and situacao = 'ATIVO'), 0)
                  else round(p_quantidade * v_lote.custo_unitario, 2) end;

  -- Cores do item passam a ser as da peça
  if exists (select 1 from public.item_venda_partes where item_id = v_item.id) then
    for v_c in select e from jsonb_array_elements(v_lote.cores) e where e ->> 'parte' is not null loop
      update public.item_venda_partes
         set material_id = (v_c ->> 'material_id')::uuid, cor_descricao = left(v_c ->> 'cor', 80)
       where item_id = v_item.id and lower(trim(nome)) = lower(v_c ->> 'parte')
         and material_id is distinct from (v_c ->> 'material_id')::uuid;
    end loop;
    if exists (select 1 from public.item_venda_partes p where p.item_id = v_item.id
                and not exists (select 1 from jsonb_array_elements(v_lote.cores) e where lower(e ->> 'parte') = lower(trim(p.nome)))) then
      raise exception 'As partes da peça pronta não batem com as partes do item no pedido.';
    end if;
  elsif jsonb_array_length(v_lote.cores) = 1 and v_lote.cores -> 0 ->> 'parte' is null then
    update public.itens_venda
       set material_id = (v_lote.cores -> 0 ->> 'material_id')::uuid, cor_descricao = left(v_lote.cores -> 0 ->> 'cor', 80)
     where id = v_item.id and material_id is distinct from (v_lote.cores -> 0 ->> 'material_id')::uuid;
  end if;

  insert into public.saidas_pecas_prontas (lote_id, data, tipo, item_id, venda_id, quantidade, custo, chave_envio)
  values (v_lote.id, public.hoje(), 'PEDIDO', v_item.id, v_item.venda_id, p_quantidade, v_custo, p_chave)
  returning id into v_id;

  v_pronto := public.atualizar_pedido_pronto(v_item.venda_id);
  return jsonb_build_object('id', v_id, 'custo', v_custo, 'pedido_pronto', v_pronto);
end;
$$;


-- ---------------------------------------------------------------------
-- 5. Gravar combinações e ficha da combinação (R112, R113)
-- ---------------------------------------------------------------------
--   p_opcoes: [{"id": "..."?, "chave": "o1", "nome": "Tamanho",
--               "valores": [{"id": "..."?, "chave": "v1", "valor": "P"}, ...]}, ...]
--               até 3 opções; "chave" é qualquer texto que identifique o valor
--               nesta gravação (o id, para os que já existem)
--   p_combinacoes: [{"valores": ["v1", "v3"], "preco": "25.90" | null, "ativo": true}, ...]
--               todas as combinações dos valores, uma vez cada
--   Opções vazias = o produto deixa de ter combinações.
--   Combinação que já está em pedido, produção ou peça pronta não sai:
--   para não usar mais, desligue.
create or replace function public.salvar_variacoes_produto(p_produto_id uuid, p_opcoes jsonb, p_combinacoes jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c_uuid     constant text := '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
  v_opcoes   jsonb := coalesce(p_opcoes, '[]'::jsonb);
  v_combs    jsonb := coalesce(p_combinacoes, '[]'::jsonb);
  v_o        jsonb;
  v_v        jsonb;
  v_c        jsonb;
  v_n        integer;
  v_m        integer;
  v_nome     text;
  v_valor    text;
  v_txt      text;
  v_nomes    text[] := '{}';
  v_vals     text[];
  v_chaves   text[] := '{}';
  v_mapa     jsonb := '{}'::jsonb;    -- chave do valor → id gravado
  v_opc_ids  uuid[] := '{}';
  v_val_ids  uuid[] := '{}';
  v_oid      uuid;
  v_vid      uuid;
  v_total    integer := 1;
  v_ids      uuid[];
  v_chave    text;
  v_desc     text;
  v_preco    numeric;
  v_ativo    boolean;
  v_var_id   uuid;
  v_keep     text[] := '{}';
  v_vistas   text[] := '{}';
  v_r        record;
begin
  perform public.exigir_admin();
  perform 1 from public.produtos where id = p_produto_id for update;
  if not found then raise exception 'Produto não encontrado.'; end if;

  if jsonb_typeof(v_opcoes) <> 'array' or jsonb_typeof(v_combs) <> 'array' then
    raise exception 'Combinações em formato inválido.';
  end if;
  if jsonb_array_length(v_opcoes) > 3 then raise exception 'Cada produto pode ter até 3 opções.'; end if;

  -- Confere as opções e os valores
  for v_o, v_n in select e, o::integer from jsonb_array_elements(v_opcoes) with ordinality t(e, o) loop
    if jsonb_typeof(v_o) <> 'object' then raise exception 'Opção %: formato inválido.', v_n; end if;
    v_nome := trim(coalesce(v_o ->> 'nome', ''));
    if length(v_nome) = 0 then raise exception 'Opção %: informe o nome (ex.: Tamanho, Modelo, Cor).', v_n; end if;
    if length(v_nome) > 30 then raise exception 'Opção %: o nome pode ter até 30 caracteres.', v_n; end if;
    if lower(v_nome) = any (v_nomes) then raise exception 'Opção %: já existe uma opção "%".', v_n, v_nome; end if;
    v_nomes := v_nomes || lower(v_nome);
    v_txt := nullif(trim(coalesce(v_o ->> 'id', '')), '');
    if v_txt is not null and (v_txt !~ c_uuid
       or not exists (select 1 from public.produto_opcoes where id = v_txt::uuid and produto_id = p_produto_id)) then
      raise exception 'Opção %: identificador inválido.', v_n;
    end if;
    if jsonb_typeof(v_o -> 'valores') <> 'array' or jsonb_array_length(v_o -> 'valores') = 0 then
      raise exception 'Opção % (%): informe pelo menos um valor.', v_n, v_nome;
    end if;
    if jsonb_array_length(v_o -> 'valores') > 20 then raise exception 'Opção % (%): até 20 valores.', v_n, v_nome; end if;
    v_vals := '{}';
    for v_v, v_m in select e, o::integer from jsonb_array_elements(v_o -> 'valores') with ordinality t(e, o) loop
      v_valor := trim(coalesce(v_v ->> 'valor', ''));
      if length(v_valor) = 0 then raise exception 'Opção % (%), valor %: preencha o valor.', v_n, v_nome, v_m; end if;
      if length(v_valor) > 40 then raise exception 'Opção % (%), valor %: até 40 caracteres.', v_n, v_nome, v_m; end if;
      if lower(v_valor) = any (v_vals) then raise exception 'Opção % (%): o valor "%" aparece duas vezes.', v_n, v_nome, v_valor; end if;
      v_vals := v_vals || lower(v_valor);
      v_chave := coalesce(nullif(v_v ->> 'chave', ''), nullif(v_v ->> 'id', ''));
      if v_chave is null or v_chave = any (v_chaves) then raise exception 'Opção % (%), valor %: identificação repetida ou ausente.', v_n, v_nome, v_m; end if;
      v_chaves := v_chaves || v_chave;
      v_txt := nullif(trim(coalesce(v_v ->> 'id', '')), '');
      if v_txt is not null and (v_txt !~ c_uuid or not exists (
           select 1 from public.produto_opcao_valores ov join public.produto_opcoes op on op.id = ov.opcao_id
            where ov.id = v_txt::uuid and op.produto_id = p_produto_id)) then
        raise exception 'Opção % (%), valor %: identificador inválido.', v_n, v_nome, v_m;
      end if;
    end loop;
    v_total := v_total * jsonb_array_length(v_o -> 'valores');
  end loop;
  if jsonb_array_length(v_opcoes) = 0 then v_total := 0; end if;
  if v_total > 200 then raise exception 'São % combinações; o limite é 200. Diminua os valores.', v_total; end if;
  if jsonb_array_length(v_combs) <> v_total then
    raise exception 'Informe todas as combinações (% no total).', v_total;
  end if;

  -- Grava opções e valores (mantém os ids dos que já existem)
  for v_o, v_n in select e, o::integer from jsonb_array_elements(v_opcoes) with ordinality t(e, o) loop
    v_nome := trim(v_o ->> 'nome');
    v_oid := nullif(trim(coalesce(v_o ->> 'id', '')), '')::uuid;
    if v_oid is null then   -- nova, mas com o nome de uma que já existe: é a mesma
      select id into v_oid from public.produto_opcoes where produto_id = p_produto_id and lower(trim(nome)) = lower(v_nome);
    end if;
    if v_oid is null then
      insert into public.produto_opcoes (produto_id, ordem, nome) values (p_produto_id, v_n, v_nome) returning id into v_oid;
    else
      update public.produto_opcoes set ordem = v_n, nome = v_nome
       where id = v_oid and (ordem, nome) is distinct from (v_n::smallint, v_nome);
    end if;
    v_opc_ids := v_opc_ids || v_oid;
    for v_v, v_m in select e, o::integer from jsonb_array_elements(v_o -> 'valores') with ordinality t(e, o) loop
      v_valor := trim(v_v ->> 'valor');
      v_vid := nullif(trim(coalesce(v_v ->> 'id', '')), '')::uuid;
      if v_vid is null then   -- novo, mas com o texto de um que já existe na opção: é o mesmo
        select id into v_vid from public.produto_opcao_valores where opcao_id = v_oid and lower(trim(valor)) = lower(v_valor);
      end if;
      if v_vid is null then
        insert into public.produto_opcao_valores (opcao_id, ordem, valor) values (v_oid, v_m, v_valor) returning id into v_vid;
      else
        update public.produto_opcao_valores set opcao_id = v_oid, ordem = v_m, valor = v_valor
         where id = v_vid and (opcao_id, ordem, valor) is distinct from (v_oid, v_m::smallint, v_valor);
      end if;
      v_val_ids := v_val_ids || v_vid;
      v_mapa := v_mapa || jsonb_build_object(coalesce(nullif(v_v ->> 'chave', ''), v_v ->> 'id'), v_vid);
    end loop;
  end loop;

  -- Combinações: uma de cada, com um valor de cada opção
  for v_c, v_n in select e, o::integer from jsonb_array_elements(v_combs) with ordinality t(e, o) loop
    if jsonb_typeof(v_c) <> 'object' or jsonb_typeof(v_c -> 'valores') <> 'array'
       or jsonb_array_length(v_c -> 'valores') <> jsonb_array_length(v_opcoes) then
      raise exception 'Combinação %: escolha um valor de cada opção.', v_n;
    end if;
    v_ids := '{}';
    for v_m in 1 .. jsonb_array_length(v_opcoes) loop
      v_vid := (v_mapa ->> (v_c -> 'valores' ->> (v_m - 1)))::uuid;
      if v_vid is null or not exists (select 1 from public.produto_opcao_valores where id = v_vid and opcao_id = v_opc_ids[v_m]) then
        raise exception 'Combinação %: o valor da opção % não confere.', v_n, v_m;
      end if;
      v_ids := v_ids || v_vid;
    end loop;
    v_chave := (select string_agg(x::text, '|' order by x::text) from unnest(v_ids) x);
    if v_chave = any (v_vistas) then raise exception 'Combinação %: aparece duas vezes.', v_n; end if;
    v_vistas := v_vistas || v_chave;
    v_desc := (select string_agg(ov.valor, ' · ' order by op.ordem)
                 from unnest(v_ids) x join public.produto_opcao_valores ov on ov.id = x
                 join public.produto_opcoes op on op.id = ov.opcao_id);
    v_txt := nullif(trim(coalesce(v_c ->> 'preco', '')), '');
    if v_txt is not null and v_txt !~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' then
      raise exception 'Combinação % (%): preço inválido (R$ 0,00 ou mais, até 2 casas).', v_n, v_desc;
    end if;
    v_preco := v_txt::numeric;
    v_ativo := coalesce((v_c ->> 'ativo')::boolean, true);

    select id into v_var_id from public.produto_variacoes where produto_id = p_produto_id and chave = v_chave;
    if v_var_id is null then
      insert into public.produto_variacoes (produto_id, chave, descricao, preco, ativo, ordem)
      values (p_produto_id, v_chave, v_desc, v_preco, v_ativo, v_n) returning id into v_var_id;
      insert into public.produto_variacao_valores (variacao_id, valor_id) select v_var_id, x from unnest(v_ids) x;
    else
      update public.produto_variacoes set descricao = v_desc, preco = v_preco, ativo = v_ativo, ordem = v_n
       where id = v_var_id and (descricao, preco, ativo, ordem) is distinct from (v_desc, v_preco::numeric(12,2), v_ativo, v_n);
    end if;
    v_keep := v_keep || v_chave;
  end loop;

  -- Combinações que saíram: só se nunca foram usadas
  for v_r in select pv.id, pv.descricao from public.produto_variacoes pv
              where pv.produto_id = p_produto_id and pv.chave <> all (v_keep) loop
    if exists (select 1 from public.itens_venda where variacao_id = v_r.id)
       or exists (select 1 from public.producoes where variacao_id = v_r.id)
       or exists (select 1 from public.pecas_prontas where variacao_id = v_r.id) then
      raise exception 'A combinação "%" já está em pedido, produção ou peça pronta e não pode sair. Para não usar mais, desligue.', v_r.descricao;
    end if;
    delete from public.produto_variacoes where id = v_r.id;
  end loop;

  -- Valores e opções que saíram
  delete from public.produto_opcao_valores ov using public.produto_opcoes op
   where op.id = ov.opcao_id and op.produto_id = p_produto_id and ov.id <> all (v_val_ids);
  delete from public.produto_opcoes where produto_id = p_produto_id and id <> all (v_opc_ids);
end;
$$;

-- Ficha de consumo da combinação (R113): mesmas regras da ficha do produto
-- (R93). Partes e materiais vazios = a combinação usa a ficha do produto.
create or replace function public.salvar_ficha_variacao(p_variacao_id uuid, p_partes jsonb, p_materiais jsonb)
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

  perform 1 from public.produto_variacoes where id = p_variacao_id for update;
  if not found then raise exception 'Combinação não encontrada.'; end if;

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
    if lower(v_nome) = any (v_nomes) then raise exception 'Parte %: já existe uma parte "%" nesta combinação.', v_n, v_nome; end if;
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
         select 1 from public.variacao_materiais where variacao_id = p_variacao_id and material_id = v_mat_id) then
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
  delete from public.variacao_partes
   where variacao_id = p_variacao_id and lower(trim(nome)) <> all (v_nomes);
  for v_x, v_n in select e, o::integer from jsonb_array_elements(v_partes) with ordinality t(e, o) loop
    v_nome := trim(v_x ->> 'nome');
    v_g := (v_x ->> 'gramas')::numeric;
    v_purga := coalesce(v_x ->> 'purga_g', '0')::numeric;
    select * into v_atual from public.variacao_partes
     where variacao_id = p_variacao_id and lower(trim(nome)) = lower(v_nome);
    if found then
      update public.variacao_partes set ordem = v_n, nome = v_nome, gramas = v_g, purga_g = v_purga
       where id = v_atual.id
         and (ordem, nome, gramas, purga_g) is distinct from (v_n, v_nome, v_g::numeric(10,2), v_purga::numeric(10,2));
    else
      insert into public.variacao_partes (variacao_id, ordem, nome, gramas, purga_g)
      values (p_variacao_id, v_n, v_nome, v_g, v_purga);
    end if;
  end loop;

  -- Outros materiais
  delete from public.variacao_materiais where variacao_id = p_variacao_id and material_id <> all (v_ids);
  for v_x in select e from jsonb_array_elements(v_mats) e loop
    v_mat_id := (v_x ->> 'material_id')::uuid;
    v_qtd := (v_x ->> 'quantidade')::numeric;
    update public.variacao_materiais set quantidade = v_qtd
     where variacao_id = p_variacao_id and material_id = v_mat_id and quantidade is distinct from v_qtd::numeric(12,3);
    insert into public.variacao_materiais (variacao_id, material_id, quantidade)
    select p_variacao_id, v_mat_id, v_qtd
     where not exists (select 1 from public.variacao_materiais where variacao_id = p_variacao_id and material_id = v_mat_id);
  end loop;
end;
$$;


-- ---------------------------------------------------------------------
-- 6. Consultas trocadas (colunas novas no fim)
-- ---------------------------------------------------------------------
create or replace view public.vw_itens_producao with (security_invoker = true) as
select i.id as item_id, i.venda_id, v.numero, '#' || lpad(v.numero::text, greatest(4, length(v.numero::text)), '0') as numero_formatado,
       coalesce(c.nome, 'Shopee') as cliente, v.status_pedido, v.data as data_pedido, v.data_prometida,
       i.ordem, i.produto_id, i.descricao, i.quantidade, i.material_id, i.cor_descricao,
       coalesce(pr.pecas, 0)::integer as produzidas,
       coalesce(sp.pecas, 0)::integer as de_estoque,
       greatest(i.quantidade - coalesce(pr.pecas, 0) - coalesce(sp.pecas, 0), 0)::integer as faltam,
       exists (select 1 from public.item_venda_partes p where p.item_id = i.id) as tem_partes,
       not exists (select 1 from public.item_venda_partes p where p.item_id = i.id and p.material_id is null) as cores_definidas,
       i.variacao_id
  from public.itens_venda i
  join public.vendas v on v.id = i.venda_id
  left join public.clientes c on c.id = v.cliente_id
  left join lateral (select sum(p.pecas) as pecas from public.producoes p
                      where p.item_id = i.id and p.resultado = 'OK' and p.situacao = 'ATIVO') pr on true
  left join lateral (select sum(s.quantidade) as pecas from public.saidas_pecas_prontas s
                      where s.item_id = i.id and s.situacao = 'ATIVO') sp on true;

create or replace view public.vw_pecas_prontas with (security_invoker = true) as
select l.id as lote_id, l.produto_id, pr.nome as produto, l.cores, l.cores_chave, l.cores_descricao, l.data,
       l.quantidade, l.custo_total, l.custo_unitario,
       (l.quantidade - coalesce(s.usadas, 0))::integer as saldo,
       (l.custo_total - coalesce(s.custo, 0)) as custo_saldo,
       l.variacao_id, pv.descricao as variacao
  from public.pecas_prontas l
  join public.producoes p on p.id = l.producao_id and p.situacao = 'ATIVO'
  join public.produtos pr on pr.id = l.produto_id
  left join public.produto_variacoes pv on pv.id = l.variacao_id
  left join lateral (select sum(x.quantidade) as usadas, sum(x.custo) as custo from public.saidas_pecas_prontas x
                      where x.lote_id = l.id and x.situacao = 'ATIVO') s on true;


-- ---------------------------------------------------------------------
-- 7. Acesso: só a Admin lê; ninguém grava direto
-- ---------------------------------------------------------------------
alter table public.produto_opcoes enable row level security;
alter table public.produto_opcao_valores enable row level security;
alter table public.produto_variacoes enable row level security;
alter table public.produto_variacao_valores enable row level security;
alter table public.variacao_partes enable row level security;
alter table public.variacao_materiais enable row level security;

revoke all on public.produto_opcoes, public.produto_opcao_valores, public.produto_variacoes, public.produto_variacao_valores,
              public.variacao_partes, public.variacao_materiais from public, anon, authenticated;
grant select on public.produto_opcoes, public.produto_opcao_valores, public.produto_variacoes, public.produto_variacao_valores,
               public.variacao_partes, public.variacao_materiais to authenticated;

create policy produto_opcoes_select_admin on public.produto_opcoes for select to authenticated using (public.is_admin());
create policy produto_opcao_valores_select_admin on public.produto_opcao_valores for select to authenticated using (public.is_admin());
create policy produto_variacoes_select_admin on public.produto_variacoes for select to authenticated using (public.is_admin());
create policy produto_variacao_valores_select_admin on public.produto_variacao_valores for select to authenticated using (public.is_admin());
create policy variacao_partes_select_admin on public.variacao_partes for select to authenticated using (public.is_admin());
create policy variacao_materiais_select_admin on public.variacao_materiais for select to authenticated using (public.is_admin());

revoke all on function public.variacao_tem_ficha(uuid) from public, anon, authenticated;
revoke all on function public.tg_itens_venda_variacao() from public, anon, authenticated;
revoke all on function public.salvar_variacoes_produto(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.salvar_variacoes_produto(uuid, jsonb, jsonb) to authenticated;
revoke all on function public.salvar_ficha_variacao(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.salvar_ficha_variacao(uuid, jsonb, jsonb) to authenticated;
revoke all on function public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid, uuid) from public, anon;
grant execute on function public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid, uuid) to authenticated;

commit;

-- Pronto. Confira com sql/variacoes_verificacao.sql.
