-- =====================================================================
-- Arts com Você · DESINSTALAR o P1-b dos Pedidos Diretos (pagamentos e
-- devoluções) e voltar ao P1-a
--
-- ⚠ Só rodar com autorização específica da Bruna.
--
-- ⚠ SÓ REMOVE SEM LANÇAMENTOS: se existir qualquer recebimento ou
--   devolução (ativo ou estornado), o roteiro recusa e nada é removido.
--
-- Remove SOMENTE o que sql/08_pedidos_diretos_pagamentos.sql criou e
-- devolve às funções recalcular_pedido, conferir_pedido e salvar_pedido
-- exatamente o conteúdo do P1-a (sql/07_pedidos_diretos_essencial.sql).
-- Clientes, pedidos, itens e histórico de status ficam como estão.
-- Nada das outras etapas é tocado.
--
-- Tudo ou nada: se qualquer passo falhar, nada é removido.
-- Antes e depois: rodar o retrato (sql/manutencao/shopee_retrato.sql).
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.recebimentos_venda') is null or to_regclass('public.devolucoes_venda') is null then
    raise exception 'O P1-b (pagamentos e devoluções) não está instalado. Nada foi removido.';
  end if;
  if exists (
    select 1 from pg_constraint
     where contype = 'f'
       and confrelid in ('public.recebimentos_venda'::regclass, 'public.devolucoes_venda'::regclass)
  ) then
    raise exception 'Outra tabela do sistema já usa os recebimentos ou as devoluções. Nada foi removido.';
  end if;
  if exists (select 1 from public.recebimentos_venda) or exists (select 1 from public.devolucoes_venda) then
    raise exception 'Já existem recebimentos ou devoluções registrados (% recebimento(s), % devolução(ões)). Este roteiro só remove o P1-b sem lançamentos. Nada foi removido.',
      (select count(*) from public.recebimentos_venda), (select count(*) from public.devolucoes_venda);
  end if;
end;
$$;

-- 1. Funções do P1-a de volta ao conteúdo original (cópia exata do 07)
create or replace function public.recalcular_pedido(p_venda_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_soma numeric(12,2);
begin
  select coalesce(sum(valor_item), 0) into v_soma from public.itens_venda where venda_id = p_venda_id;

  update public.vendas
     set subtotal = v_soma,
         total = v_soma - desconto + frete,
         valor_recebido = 0,
         valor_devolvido = 0
   where id = p_venda_id
     and (subtotal, total, valor_recebido, valor_devolvido)
         is distinct from (v_soma, v_soma - desconto + frete, 0::numeric, 0::numeric);
end;
$$;

create or replace function public.conferir_pedido(p_venda_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda  public.vendas;
  v_itens  integer;
  v_soma   numeric(12,2);
begin
  select * into v_venda from public.vendas where id = p_venda_id;
  if not found then
    return;
  end if;

  select count(*), coalesce(sum(valor_item), 0) into v_itens, v_soma
    from public.itens_venda where venda_id = p_venda_id;

  if v_itens = 0 then
    raise exception 'O pedido precisa ter pelo menos um item (do catálogo ou personalizado). Nada foi gravado.';
  end if;
  if v_venda.subtotal <> v_soma then
    raise exception 'Conferência do pedido #%: o subtotal não bate com a soma dos itens. Nada foi gravado.',
      lpad(v_venda.numero::text, greatest(4, length(v_venda.numero::text)), '0');
  end if;

  -- P1-a: ainda não há recebimentos nem devoluções. No P1-b, esta parte
  -- passa a comparar com a soma dos lançamentos ativos.
  if v_venda.valor_recebido <> 0 or v_venda.valor_devolvido <> 0 then
    raise exception 'Conferência do pedido #%: recebimentos e devoluções ainda não existem nesta etapa. Nada foi gravado.',
      lpad(v_venda.numero::text, greatest(4, length(v_venda.numero::text)), '0');
  end if;
end;
$$;

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
  v_norm      jsonb := '[]'::jsonb;
  v_x         jsonb;
  v_linhas    integer;
  v_mudou     boolean := false;   -- P4: editado_em só quando algo mudou
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
  -- P1-b: com recebimentos ou devoluções, a data também não poderá ficar
  -- depois do primeiro lançamento.
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

    v_troca_prod := not v_tem_old or v_old.produto_id is distinct from v_prod_id;
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
      'preco_unitario', v_preco, 'quantidade', v_qtd, 'material_id', v_mat_id, 'cor_descricao', v_cor));
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
             cor_descricao = v_x ->> 'cor_descricao'
       where id = (v_x ->> 'id')::uuid
         and (ordem, produto_id, descricao, preco_unitario, quantidade, material_id, cor_descricao)
             is distinct from ((v_x ->> 'ordem')::integer, (v_x ->> 'produto_id')::uuid, v_x ->> 'descricao',
                               (v_x ->> 'preco_unitario')::numeric, (v_x ->> 'quantidade')::integer,
                               (v_x ->> 'material_id')::uuid, v_x ->> 'cor_descricao');
      get diagnostics v_linhas = row_count;
      v_mudou := v_mudou or v_linhas > 0;
    else
      insert into public.itens_venda (venda_id, ordem, produto_id, descricao, preco_unitario, quantidade,
                                      material_id, cor_descricao)
      values (v_id, (v_x ->> 'ordem')::integer, (v_x ->> 'produto_id')::uuid, v_x ->> 'descricao',
              (v_x ->> 'preco_unitario')::numeric, (v_x ->> 'quantidade')::integer,
              (v_x ->> 'material_id')::uuid, v_x ->> 'cor_descricao');
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

-- 2. Funções do P1-b
drop function public.registrar_recebimento(uuid, date, numeric, text, text, boolean);
drop function public.registrar_devolucao(uuid, date, numeric, text, text);
drop function public.estornar_recebimento(uuid, text);
drop function public.estornar_devolucao(uuid, text);

-- 3. Tabelas (sem "cascade": se algo inesperado depender delas, o banco
--    recusa e nada é removido), funções de gatilho e tipo
drop table public.recebimentos_venda;
drop table public.devolucoes_venda;
drop function public.tg_lancamentos_pedido_protege();
drop function public.tg_lancamentos_pedido_conferir();
drop type public.situacao_lancamento_pedido;

commit;
