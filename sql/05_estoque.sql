-- =====================================================================
-- Arts com Você — Sistema de Gestão
-- Etapa 3 · Estoque de materiais
--
-- O que este script cria:
--   1. Compras de estoque com itens (lotes), frete e desconto geral rateados
--   2. Estoque inicial (sem movimentar o caixa)
--   3. Movimentos de estoque e saldo por material, com custo médio
--   4. Cancelamento por estorno, só sem consumo posterior
--   5. Travas: categoria/unidade do material após o 1º movimento
--   6. Segurança: só a Admin lê; escrita só pelas funções
--
-- Regras aplicadas: R11, R12, R37, R40 a R46, R49 a R55.
-- Pré-requisito: Etapas 0, 1 e 2 instaladas.
-- Como rodar: Supabase → SQL Editor → colar tudo → Run. Uma única vez.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Tipos
-- ---------------------------------------------------------------------
-- Motivos das Etapas 5 e 6 (produção, purga, perda, embalagem, ajuste)
-- entram depois com: alter type public.motivo_estoque add value '...';
create type public.motivo_estoque as enum ('COMPRA', 'ESTOQUE_INICIAL', 'ESTORNO');
create type public.origem_lote as enum ('COMPRA', 'ESTOQUE_INICIAL');


-- ---------------------------------------------------------------------
-- 2. Tabelas
-- ---------------------------------------------------------------------
-- Cabeçalho da compra de estoque (1 para 1 com o lançamento).
create table public.compras_estoque (
  lancamento_id        uuid primary key references public.lancamentos (id) on delete restrict,
  frete_pedido         numeric(12,2) not null default 0 check (frete_pedido >= 0),
  desconto_pedido      numeric(12,2) not null default 0 check (desconto_pedido >= 0),
  valor_outros_itens   numeric(12,2) not null default 0 check (valor_outros_itens >= 0),
  frete_compra         numeric(12,2) not null default 0 check (frete_compra >= 0),
  desconto_compra      numeric(12,2) not null default 0 check (desconto_compra >= 0),
  created_at           timestamptz not null default now(),
  created_by           uuid default auth.uid()
);

comment on table public.compras_estoque is
  'Frete e desconto geral do pedido e a parte que ficou nesta compra (R50, R51). valor_outros_itens = itens do mesmo pedido lançados como gasto.';

-- Cada item de compra ou cada lançamento de estoque inicial.
create table public.lotes_material (
  id                   uuid primary key default gen_random_uuid(),
  origem               public.origem_lote not null,
  lancamento_id        uuid references public.lancamentos (id) on delete restrict,
  material_id          uuid not null references public.materiais (id) on delete restrict,
  data                 date not null,
  marca                text,
  quantidade           numeric(12,3) not null check (quantidade > 0),
  valor_item           numeric(12,2) not null check (valor_item > 0),
  frete_rateado        numeric(12,2) not null default 0 check (frete_rateado >= 0),
  desconto_rateado     numeric(12,2) not null default 0 check (desconto_rateado >= 0),
  custo_total          numeric(12,2) not null check (custo_total > 0),
  status               public.status_registro not null default 'ATIVO',
  cancelado_em         date,
  motivo_cancelamento  text,
  obs                  text,
  created_at           timestamptz not null default now(),
  created_by           uuid default auth.uid(),
  updated_at           timestamptz not null default now(),
  constraint lotes_origem_coerente check ((origem = 'COMPRA') = (lancamento_id is not null)),
  constraint lotes_custo_coerente check (custo_total = valor_item + frete_rateado - desconto_rateado)
);

create index idx_lotes_lancamento on public.lotes_material (lancamento_id);
create index idx_lotes_material on public.lotes_material (material_id);

create table public.movimentos_estoque (
  id                       uuid primary key default gen_random_uuid(),
  seq                      bigint generated always as identity unique,
  material_id              uuid not null references public.materiais (id) on delete restrict,
  data                     date not null,
  tipo                     public.tipo_movimento not null,
  motivo                   public.motivo_estoque not null,
  quantidade               numeric(12,3) not null check (quantidade > 0),
  valor                    numeric(12,2) not null check (valor >= 0),
  lote_id                  uuid references public.lotes_material (id) on delete restrict,
  movimento_estornado_id   uuid unique references public.movimentos_estoque (id) on delete restrict,
  obs                      text,
  created_at               timestamptz not null default now(),
  created_by               uuid default auth.uid(),
  constraint movimentos_estoque_estorno_coerente check ((motivo = 'ESTORNO') = (movimento_estornado_id is not null))
);

create index idx_movimentos_estoque_material on public.movimentos_estoque (material_id, seq);

-- Saldo atual por material (mantido só pelas funções do banco).
create table public.saldos_material (
  material_id  uuid primary key references public.materiais (id) on delete restrict,
  quantidade   numeric(14,3) not null default 0 check (quantidade >= 0),
  valor        numeric(14,2) not null default 0 check (valor >= 0),
  updated_at   timestamptz not null default now(),
  constraint saldos_zerado_coerente check (quantidade > 0 or valor = 0)
);

comment on table public.saldos_material is 'Quantidade e valor em estoque por material. Custo médio = valor ÷ quantidade (R54).';


-- ---------------------------------------------------------------------
-- 3. updated_at e auditoria
-- ---------------------------------------------------------------------
create trigger trg_lotes_material_updated_at before update on public.lotes_material
  for each row execute function public.tg_updated_at();

create trigger trg_compras_estoque_auditoria after insert or update or delete on public.compras_estoque
  for each row execute function public.tg_auditoria();
create trigger trg_lotes_material_auditoria after insert or update or delete on public.lotes_material
  for each row execute function public.tg_auditoria();
create trigger trg_movimentos_estoque_auditoria after insert or update or delete on public.movimentos_estoque
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 4. Trava do material (R41 / R55)
-- ---------------------------------------------------------------------
create or replace function public.tg_materiais_trava()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.categoria is distinct from old.categoria or new.unidade is distinct from old.unidade)
     and exists (select 1 from public.movimentos_estoque where material_id = old.id) then
    raise exception 'A categoria e a unidade deste material não podem mudar porque ele já tem movimento de estoque.';
  end if;
  return new;
end;
$$;

create trigger trg_materiais_trava
  before update on public.materiais
  for each row execute function public.tg_materiais_trava();


-- ---------------------------------------------------------------------
-- 5. Ajustes nas funções da Etapa 2
-- ---------------------------------------------------------------------
-- R46/R49: gasto comum continua sem natureza Estoque (mensagem atualizada).
create or replace function public.validar_gasto(
  p_data date, p_descricao text, p_categoria_id uuid, p_valor numeric, p_editando uuid default null
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cat public.categorias_lanc;
begin
  if p_data is null then raise exception 'Informe a data do gasto.'; end if;
  if p_data > public.hoje() then raise exception 'A data do gasto não pode ser no futuro.'; end if;
  if p_descricao is null or length(trim(p_descricao)) = 0 then raise exception 'Informe a descrição do gasto.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'O valor do gasto precisa ser maior que zero.'; end if;

  select * into v_cat from public.categorias_lanc where id = p_categoria_id;
  if not found then raise exception 'Escolha uma categoria.'; end if;

  if v_cat.natureza = 'ESTOQUE' then
    raise exception 'Compras de estoque são registradas pela opção "Nova compra de estoque", com os itens.';
  end if;

  if not v_cat.ativo and (p_editando is null or not exists (
      select 1 from public.lancamentos where id = p_editando and categoria_id = p_categoria_id)) then
    raise exception 'Esta categoria está inativa.';
  end if;
end;
$$;

revoke all on function public.validar_gasto(date, text, uuid, numeric, uuid) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 6. Funções internas de estoque
-- ---------------------------------------------------------------------
-- Registra um movimento e atualiza o saldo do material.
create or replace function public.movimentar_estoque(
  p_material_id uuid, p_data date, p_tipo public.tipo_movimento, p_motivo public.motivo_estoque,
  p_quantidade numeric, p_valor numeric, p_lote_id uuid, p_estornado_id uuid, p_obs text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_saldo public.saldos_material;
begin
  insert into public.saldos_material (material_id) values (p_material_id) on conflict (material_id) do nothing;
  select * into v_saldo from public.saldos_material where material_id = p_material_id for update;

  if p_tipo = 'SAIDA' and (v_saldo.quantidade < p_quantidade or v_saldo.valor < p_valor) then
    raise exception 'Estoque insuficiente para esta operação.';
  end if;

  insert into public.movimentos_estoque (material_id, data, tipo, motivo, quantidade, valor, lote_id, movimento_estornado_id, obs)
  values (p_material_id, p_data, p_tipo, p_motivo, p_quantidade, p_valor, p_lote_id, p_estornado_id, p_obs)
  returning id into v_id;

  update public.saldos_material
     set quantidade = quantidade + case when p_tipo = 'ENTRADA' then p_quantidade else -p_quantidade end,
         valor      = valor      + case when p_tipo = 'ENTRADA' then p_valor      else -p_valor      end,
         updated_at = now()
   where material_id = p_material_id;

  return v_id;
end;
$$;

-- Houve consumo (saída que não é estorno) do material depois da entrada deste lote?
create or replace function public.lote_tem_consumo_posterior(p_lote_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.movimentos_estoque e
      join public.movimentos_estoque s on s.material_id = e.material_id and s.seq > e.seq
     where e.lote_id = p_lote_id and e.tipo = 'ENTRADA' and e.motivo <> 'ESTORNO'
       and s.tipo = 'SAIDA' and s.motivo <> 'ESTORNO'
  )
$$;

-- Estorna a entrada de um lote (devolve exatamente o que entrou).
create or replace function public.estornar_lote_interno(p_lote_id uuid, p_motivo text, p_data date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lote public.lotes_material;
  v_mov  public.movimentos_estoque;
  v_nome text;
begin
  select * into v_lote from public.lotes_material where id = p_lote_id for update;
  if not found then raise exception 'Lote não encontrado.'; end if;
  if v_lote.status <> 'ATIVO' then raise exception 'Este lançamento de estoque já foi cancelado.'; end if;

  if public.lote_tem_consumo_posterior(p_lote_id) then
    select tipo || coalesce(' ' || variacao, '') into v_nome from public.materiais where id = v_lote.material_id;
    raise exception 'Não é possível cancelar: o material % já foi usado depois deste lançamento.', v_nome;
  end if;

  select * into v_mov from public.movimentos_estoque
   where lote_id = p_lote_id and tipo = 'ENTRADA' and motivo <> 'ESTORNO';

  perform public.movimentar_estoque(v_lote.material_id, p_data, 'SAIDA', 'ESTORNO',
                                    v_mov.quantidade, v_mov.valor, p_lote_id, v_mov.id, p_motivo);

  update public.lotes_material
     set status = 'CANCELADO', cancelado_em = p_data, motivo_cancelamento = p_motivo
   where id = p_lote_id;
end;
$$;

-- Valida um material para entrada de estoque.
create or replace function public.material_para_entrada(p_material_id uuid)
returns public.materiais
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_mat public.materiais;
begin
  select * into v_mat from public.materiais where id = p_material_id;
  if not found then raise exception 'Escolha o material.'; end if;
  if not v_mat.ativo then raise exception 'O material % está inativo.', v_mat.tipo || coalesce(' ' || v_mat.variacao, ''); end if;
  return v_mat;
end;
$$;


-- ---------------------------------------------------------------------
-- 7. Funções usadas pelo sistema (só Admin)
-- ---------------------------------------------------------------------

-- Nova compra de estoque (R49 a R51).
-- p_itens: [{"material_id": "...", "quantidade": 1000, "valor": 89.90, "marca": "..."}, ...]
-- Devolve: lancamento_id, valor da compra e a parte de frete/desconto dos outros itens do pedido.
create or replace function public.registrar_compra(
  p_data date, p_categoria_id uuid, p_fornecedor text, p_forma_pagamento public.forma_pagamento, p_obs text,
  p_pago boolean, p_data_pagamento date,
  p_frete numeric, p_desconto numeric, p_valor_outros numeric,
  p_itens jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cat public.categorias_lanc;
  v_mat public.materiais;
  v_item jsonb;
  v_n int;
  v_i int := 0;
  v_soma numeric := 0;
  v_base numeric;
  v_frete numeric := coalesce(p_frete, 0);
  v_desc numeric := coalesce(p_desconto, 0);
  v_outros numeric := coalesce(p_valor_outros, 0);
  v_frete_compra numeric;
  v_desc_compra numeric;
  v_fr numeric; v_ds numeric;
  v_fr_acum numeric := 0; v_ds_acum numeric := 0;
  v_qtd numeric; v_val numeric;
  v_lanc uuid;
  v_lote uuid;
  v_valor_compra numeric;
  v_nomes text[] := '{}';
begin
  perform public.exigir_admin();

  if p_data is null then raise exception 'Informe a data da compra.'; end if;
  if p_data > public.hoje() then raise exception 'A data da compra não pode ser no futuro.'; end if;
  if v_frete < 0 or v_desc < 0 or v_outros < 0 then raise exception 'Frete, desconto e outros itens não podem ser negativos.'; end if;

  select * into v_cat from public.categorias_lanc where id = p_categoria_id;
  if not found then raise exception 'Escolha a categoria da compra.'; end if;
  if v_cat.natureza <> 'ESTOQUE' then raise exception 'A categoria da compra precisa ser de Estoque.'; end if;
  if not v_cat.ativo then raise exception 'Esta categoria está inativa.'; end if;

  v_n := coalesce(jsonb_array_length(p_itens), 0);
  if v_n = 0 then raise exception 'Adicione pelo menos um item à compra.'; end if;

  -- Valida itens e soma.
  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_mat := public.material_para_entrada((v_item ->> 'material_id')::uuid);
    v_qtd := (v_item ->> 'quantidade')::numeric;
    v_val := (v_item ->> 'valor')::numeric;
    if v_qtd is null or v_qtd <= 0 then raise exception 'Informe a quantidade de %.', v_mat.tipo || coalesce(' ' || v_mat.variacao, ''); end if;
    if v_val is null or v_val <= 0 then raise exception 'Informe o valor pago por %.', v_mat.tipo || coalesce(' ' || v_mat.variacao, ''); end if;
    v_soma := v_soma + v_val;
    v_nomes := v_nomes || (v_mat.tipo || coalesce(' ' || v_mat.variacao, ''));
  end loop;

  -- Rateio do frete e do desconto geral entre esta compra e os outros itens do pedido (R50, R51).
  v_base := v_soma + v_outros;
  v_frete_compra := round(v_frete * v_soma / v_base, 2);
  v_desc_compra  := round(v_desc  * v_soma / v_base, 2);
  if v_desc > v_base then raise exception 'O desconto não pode ser maior que o valor dos itens do pedido.'; end if;

  v_valor_compra := v_soma + v_frete_compra - v_desc_compra;
  if v_valor_compra <= 0 then raise exception 'O valor da compra ficou zerado ou negativo. Confira o desconto.'; end if;

  insert into public.lancamentos (data, descricao, categoria_id, valor, forma_pagamento, fornecedor, obs)
  values (p_data, left('Compra: ' || array_to_string(v_nomes, ', '), 200), p_categoria_id, v_valor_compra,
          p_forma_pagamento, nullif(trim(p_fornecedor), ''), nullif(trim(p_obs), ''))
  returning id into v_lanc;

  insert into public.compras_estoque (lancamento_id, frete_pedido, desconto_pedido, valor_outros_itens, frete_compra, desconto_compra)
  values (v_lanc, v_frete, v_desc, v_outros, v_frete_compra, v_desc_compra);

  -- Cria os lotes; o último item fica com a diferença de arredondamento.
  for v_item in select * from jsonb_array_elements(p_itens) loop
    v_i := v_i + 1;
    v_qtd := (v_item ->> 'quantidade')::numeric;
    v_val := (v_item ->> 'valor')::numeric;
    if v_i < v_n then
      v_fr := round(v_frete_compra * v_val / v_soma, 2);
      v_ds := round(v_desc_compra  * v_val / v_soma, 2);
    else
      v_fr := v_frete_compra - v_fr_acum;
      v_ds := v_desc_compra  - v_ds_acum;
    end if;
    v_fr_acum := v_fr_acum + v_fr;
    v_ds_acum := v_ds_acum + v_ds;

    if v_val + v_fr - v_ds <= 0 then
      raise exception 'Com o desconto rateado, um item ficaria com custo zero ou negativo. Confira o desconto.';
    end if;

    insert into public.lotes_material (origem, lancamento_id, material_id, data, marca, quantidade,
                                       valor_item, frete_rateado, desconto_rateado, custo_total)
    values ('COMPRA', v_lanc, (v_item ->> 'material_id')::uuid, p_data, nullif(trim(v_item ->> 'marca'), ''), v_qtd,
            v_val, v_fr, v_ds, v_val + v_fr - v_ds)
    returning id into v_lote;

    perform public.movimentar_estoque((v_item ->> 'material_id')::uuid, p_data, 'ENTRADA', 'COMPRA',
                                      v_qtd, v_val + v_fr - v_ds, v_lote, null, null);
  end loop;

  if p_pago then
    perform public.inserir_pagamento(v_lanc, coalesce(p_data_pagamento, p_data), v_valor_compra);
  end if;

  return jsonb_build_object(
    'lancamento_id', v_lanc,
    'valor_compra', v_valor_compra,
    'frete_compra', v_frete_compra,
    'desconto_compra', v_desc_compra,
    'frete_outros', v_frete - v_frete_compra,
    'desconto_outros', v_desc - v_desc_compra,
    'valor_outros_final', v_outros + (v_frete - v_frete_compra) - (v_desc - v_desc_compra)
  );
end;
$$;

-- Estoque inicial (R40, R52): não movimenta o caixa.
create or replace function public.registrar_estoque_inicial(
  p_material_id uuid, p_data date, p_quantidade numeric, p_custo_total numeric, p_marca text, p_obs text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lote uuid;
begin
  perform public.exigir_admin();
  perform public.material_para_entrada(p_material_id);
  if p_data is null then raise exception 'Informe a data.'; end if;
  if p_data > public.hoje() then raise exception 'A data não pode ser no futuro.'; end if;
  if p_quantidade is null or p_quantidade <= 0 then raise exception 'Informe a quantidade disponível.'; end if;
  if p_custo_total is null or p_custo_total <= 0 then raise exception 'Informe o custo dessa quantidade.'; end if;

  insert into public.lotes_material (origem, material_id, data, marca, quantidade, valor_item, custo_total, obs)
  values ('ESTOQUE_INICIAL', p_material_id, p_data, nullif(trim(p_marca), ''), p_quantidade, p_custo_total, p_custo_total,
          nullif(trim(p_obs), ''))
  returning id into v_lote;

  perform public.movimentar_estoque(p_material_id, p_data, 'ENTRADA', 'ESTOQUE_INICIAL',
                                    p_quantidade, p_custo_total, v_lote, null, null);
  return v_lote;
end;
$$;

create or replace function public.cancelar_estoque_inicial(p_lote_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.exigir_admin();
  if p_motivo is null or length(trim(p_motivo)) = 0 then raise exception 'Informe o motivo do cancelamento.'; end if;
  if not exists (select 1 from public.lotes_material where id = p_lote_id and origem = 'ESTOQUE_INICIAL') then
    raise exception 'Lançamento de estoque inicial não encontrado.';
  end if;
  perform public.estornar_lote_interno(p_lote_id, trim(p_motivo), public.hoje());
end;
$$;

-- Dados administrativos do lote (marca e observação) podem ser corrigidos (R53).
create or replace function public.editar_lote(p_lote_id uuid, p_marca text, p_obs text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.exigir_admin();
  update public.lotes_material
     set marca = nullif(trim(p_marca), ''), obs = nullif(trim(p_obs), '')
   where id = p_lote_id and status = 'ATIVO';
  if not found then raise exception 'Lançamento não encontrado ou cancelado.'; end if;
end;
$$;

-- Editar compra (R53): descrição, fornecedor e observação sempre;
-- data e forma de pagamento só enquanto não houver pagamento registrado.
create or replace function public.editar_compra(
  p_id uuid, p_descricao text, p_fornecedor text, p_obs text, p_data date, p_forma_pagamento public.forma_pagamento
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lanc public.lancamentos;
  v_tem_pagamento boolean;
  v_lote record;
begin
  perform public.exigir_admin();
  select * into v_lanc from public.lancamentos where id = p_id for update;
  if not found or not exists (select 1 from public.compras_estoque where lancamento_id = p_id) then
    raise exception 'Compra não encontrada.';
  end if;
  if v_lanc.status <> 'ATIVO' then raise exception 'Compra cancelada não pode ser editada.'; end if;
  if p_descricao is null or length(trim(p_descricao)) = 0 then raise exception 'Informe a descrição.'; end if;

  v_tem_pagamento := exists (select 1 from public.pagamentos_lancamento where lancamento_id = p_id);

  if (p_data is distinct from v_lanc.data or p_forma_pagamento is distinct from v_lanc.forma_pagamento) then
    if v_tem_pagamento then
      raise exception 'A data e a forma de pagamento não podem mudar porque esta compra já tem pagamento registrado.';
    end if;
    if p_data is null or p_data > public.hoje() then raise exception 'Informe uma data válida, que não seja no futuro.'; end if;
    for v_lote in select id from public.lotes_material where lancamento_id = p_id loop
      if public.lote_tem_consumo_posterior(v_lote.id) then
        raise exception 'A data não pode mudar porque o material desta compra já foi usado.';
      end if;
    end loop;
    update public.lotes_material set data = p_data where lancamento_id = p_id;
    update public.movimentos_estoque m set data = p_data
      from public.lotes_material l
     where m.lote_id = l.id and l.lancamento_id = p_id and m.motivo = 'COMPRA';
  end if;

  update public.lancamentos
     set descricao = trim(p_descricao), fornecedor = nullif(trim(p_fornecedor), ''), obs = nullif(trim(p_obs), ''),
         data = p_data, forma_pagamento = p_forma_pagamento
   where id = p_id;
end;
$$;

-- Cancelar gasto (Etapa 2) passa a tratar compras: o estoque volta por
-- estorno, desde que não haja consumo posterior (R53); depois, os
-- pagamentos voltam ao caixa por estorno (R45).
create or replace function public.cancelar_gasto(p_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lanc public.lancamentos;
  v_pag record;
  v_lote record;
begin
  perform public.exigir_admin();
  if p_motivo is null or length(trim(p_motivo)) = 0 then raise exception 'Informe o motivo do cancelamento.'; end if;
  select * into v_lanc from public.lancamentos where id = p_id for update;
  if not found then raise exception 'Gasto não encontrado.'; end if;
  if v_lanc.status <> 'ATIVO' then raise exception 'Este gasto já está cancelado.'; end if;

  for v_lote in select id from public.lotes_material where lancamento_id = p_id and status = 'ATIVO' order by created_at loop
    perform public.estornar_lote_interno(v_lote.id, 'Compra cancelada: ' || trim(p_motivo), public.hoje());
  end loop;

  for v_pag in select id from public.pagamentos_lancamento where lancamento_id = p_id and status = 'ATIVO' loop
    perform public.estornar_pagamento_interno(v_pag.id, 'Gasto cancelado: ' || trim(p_motivo), public.hoje());
  end loop;

  update public.lancamentos
     set status = 'CANCELADO', cancelado_em = public.hoje(), motivo_cancelamento = trim(p_motivo)
   where id = p_id;
end;
$$;


-- ---------------------------------------------------------------------
-- 8. Consultas prontas
-- ---------------------------------------------------------------------
create view public.vw_estoque with (security_invoker = true) as
select m.id as material_id, m.categoria, m.tipo, m.variacao, m.unidade, m.estoque_minimo, m.ativo,
       coalesce(s.quantidade, 0) as quantidade,
       coalesce(s.valor, 0) as valor,
       case when coalesce(s.quantidade, 0) > 0 then s.valor / s.quantidade end as custo_medio,
       (m.estoque_minimo is not null and coalesce(s.quantidade, 0) < m.estoque_minimo) as estoque_baixo,
       exists (select 1 from public.movimentos_estoque x where x.material_id = m.id) as tem_movimento
  from public.materiais m
  left join public.saldos_material s on s.material_id = m.id;

create view public.vw_lotes with (security_invoker = true) as
select l.id, l.origem, l.lancamento_id, l.material_id, m.categoria, m.tipo, m.variacao, m.unidade,
       l.data, l.marca, l.quantidade, l.valor_item, l.frete_rateado, l.desconto_rateado, l.custo_total,
       l.custo_total / l.quantidade as custo_unitario,
       l.status, l.cancelado_em, l.motivo_cancelamento, l.obs, l.created_at,
       public.lote_tem_consumo_posterior(l.id) as tem_consumo_posterior
  from public.lotes_material l
  join public.materiais m on m.id = l.material_id;

-- vw_gastos ganha "eh_compra" (colunas novas sempre no fim).
create or replace view public.vw_gastos with (security_invoker = true) as
select l.id, l.data, l.descricao, l.categoria_id, c.nome as categoria, c.natureza,
       l.valor, l.forma_pagamento, l.fornecedor, l.obs, l.status, l.cancelado_em, l.motivo_cancelamento,
       coalesce(p.pago, 0) as valor_pago,
       case when l.status = 'CANCELADO' then 0 else l.valor - coalesce(p.pago, 0) end as valor_a_pagar,
       case
         when l.status = 'CANCELADO' then 'CANCELADO'
         when coalesce(p.pago, 0) = 0 then 'A_PAGAR'
         when coalesce(p.pago, 0) < l.valor then 'PAGO_EM_PARTE'
         else 'PAGO'
       end as situacao,
       l.created_at,
       exists (select 1 from public.compras_estoque ce where ce.lancamento_id = l.id) as eh_compra,
       exists (select 1 from public.pagamentos_lancamento pp where pp.lancamento_id = l.id) as tem_pagamento
  from public.lancamentos l
  join public.categorias_lanc c on c.id = l.categoria_id
  left join (
    select lancamento_id, sum(valor) as pago
      from public.pagamentos_lancamento where status = 'ATIVO'
     group by lancamento_id
  ) p on p.lancamento_id = l.id;


-- ---------------------------------------------------------------------
-- 9. Segurança
-- ---------------------------------------------------------------------
alter table public.compras_estoque    enable row level security;
alter table public.lotes_material     enable row level security;
alter table public.movimentos_estoque enable row level security;
alter table public.saldos_material    enable row level security;

revoke all on public.compras_estoque, public.lotes_material, public.movimentos_estoque, public.saldos_material
  from anon, authenticated;
revoke all on public.vw_estoque, public.vw_lotes from anon, authenticated;

grant select on public.compras_estoque, public.lotes_material, public.movimentos_estoque, public.saldos_material
  to authenticated;
grant select on public.vw_estoque, public.vw_lotes to authenticated;
grant select on public.vw_gastos to authenticated;
revoke all on public.vw_gastos from anon;

create policy compras_estoque_select_admin on public.compras_estoque
  for select to authenticated using (public.is_admin());
create policy lotes_material_select_admin on public.lotes_material
  for select to authenticated using (public.is_admin());
create policy movimentos_estoque_select_admin on public.movimentos_estoque
  for select to authenticated using (public.is_admin());
create policy saldos_material_select_admin on public.saldos_material
  for select to authenticated using (public.is_admin());

-- Internas: ninguém chama pela API (a usada dentro das views fica liberada só para leitura).
revoke all on function public.movimentar_estoque(uuid, date, public.tipo_movimento, public.motivo_estoque, numeric, numeric, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.estornar_lote_interno(uuid, text, date) from public, anon, authenticated;
revoke all on function public.material_para_entrada(uuid) from public, anon, authenticated;
revoke all on function public.tg_materiais_trava() from public, anon, authenticated;
revoke all on function public.lote_tem_consumo_posterior(uuid) from public, anon;
grant execute on function public.lote_tem_consumo_posterior(uuid) to authenticated;

-- Do sistema: só logados (e cada uma exige a Admin).
revoke all on function public.registrar_compra(date, uuid, text, public.forma_pagamento, text, boolean, date, numeric, numeric, numeric, jsonb) from public, anon;
revoke all on function public.registrar_estoque_inicial(uuid, date, numeric, numeric, text, text) from public, anon;
revoke all on function public.cancelar_estoque_inicial(uuid, text) from public, anon;
revoke all on function public.editar_lote(uuid, text, text) from public, anon;
revoke all on function public.editar_compra(uuid, text, text, text, date, public.forma_pagamento) from public, anon;
revoke all on function public.cancelar_gasto(uuid, text) from public, anon;

grant execute on function public.registrar_compra(date, uuid, text, public.forma_pagamento, text, boolean, date, numeric, numeric, numeric, jsonb) to authenticated;
grant execute on function public.registrar_estoque_inicial(uuid, date, numeric, numeric, text, text) to authenticated;
grant execute on function public.cancelar_estoque_inicial(uuid, text) to authenticated;
grant execute on function public.editar_lote(uuid, text, text) to authenticated;
grant execute on function public.editar_compra(uuid, text, text, text, date, public.forma_pagamento) to authenticated;
grant execute on function public.cancelar_gasto(uuid, text) to authenticated;


-- =====================================================================
-- Fim da Etapa 3.
-- Próximo passo: rodar sql/02_verificacao.sql (todas as linhas OK).
-- =====================================================================
