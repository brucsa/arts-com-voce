-- =====================================================================
-- Arts com Você · Desinstalar os repasses da Shopee (desfaz sql/19)
--
-- Use só se precisar voltar atrás logo depois de instalar, ANTES de
-- confirmar qualquer repasse ou dispensar qualquer aviso: recusa se já
-- houver algum. Devolve as seis funções trocadas às versões anteriores
-- (sql/07, 08, 10, 14 e 17) e tira as tabelas, consultas, gatilhos,
-- funções e a coluna nova do Caixa. A origem REPASSE_SHOPEE (sql/18) fica
-- na lista do Caixa, sem uso: o banco não remove valores de uma lista.
-- Não mexe nas vendas nem no Caixa. Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.repasses_shopee') is null then
    raise exception 'Os repasses da Shopee não estão instalados. Nada foi alterado.';
  end if;
  if exists (select 1 from public.repasses_shopee) or exists (select 1 from public.avisos_shopee_dispensados) then
    raise exception 'Já existem repasses confirmados ou avisos dispensados. A desinstalação não é possível. Nada foi alterado.';
  end if;
end;
$$;

-- Funções trocadas: versões anteriores (mesma assinatura e permissões)
-- recalcular_pedido: versão do sql/08
create or replace function public.recalcular_pedido(p_venda_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_soma  numeric(12,2);
  v_rec   numeric(12,2);
  v_dev   numeric(12,2);
begin
  select coalesce(sum(valor_item), 0) into v_soma from public.itens_venda where venda_id = p_venda_id;
  select coalesce(sum(valor), 0) into v_rec
    from public.recebimentos_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  select coalesce(sum(valor), 0) into v_dev
    from public.devolucoes_venda where venda_id = p_venda_id and situacao = 'ATIVO';

  update public.vendas
     set subtotal = v_soma,
         total = v_soma - desconto + frete,
         valor_recebido = v_rec,
         valor_devolvido = v_dev
   where id = p_venda_id
     and (subtotal, total, valor_recebido, valor_devolvido)
         is distinct from (v_soma, v_soma - desconto + frete, v_rec, v_dev);
end;
$$;
-- conferir_pedido: versão do sql/10
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
  v_rec    numeric(12,2);
  v_dev    numeric(12,2);
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
    raise exception 'Conferência do pedido %: o subtotal não bate com a soma dos itens. Nada foi gravado.',
      public.numero_pedido_texto(v_venda.numero);
  end if;

  select coalesce(sum(valor), 0) into v_rec
    from public.recebimentos_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  select coalesce(sum(valor), 0) into v_dev
    from public.devolucoes_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  if v_venda.valor_recebido <> v_rec or v_venda.valor_devolvido <> v_dev then
    raise exception 'Conferência do pedido %: o recebido ou o devolvido não bate com os lançamentos ativos. Nada foi gravado.',
      public.numero_pedido_texto(v_venda.numero);
  end if;

  -- Caixa: recebimentos
  if exists (
    select 1 from public.recebimentos_venda r
     where r.venda_id = p_venda_id
       and ((r.situacao = 'ATIVO' and not exists (
              select 1 from public.movimentos_caixa m
               where m.recebimento_id = r.id and m.origem = 'RECEBIMENTO' and m.tipo = 'ENTRADA'
                 and m.valor = r.valor and m.data = r.data
                 and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id)))
         or (r.situacao = 'ESTORNADO' and exists (
              select 1 from public.movimentos_caixa m
               where m.recebimento_id = r.id
                 and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id))))
  ) then
    raise exception 'Conferência do pedido %: um recebimento não bate com o Caixa. Nada foi gravado.',
      public.numero_pedido_texto(v_venda.numero);
  end if;

  -- Caixa: devoluções
  if exists (
    select 1 from public.devolucoes_venda d
     where d.venda_id = p_venda_id
       and ((d.situacao = 'ATIVO' and not exists (
              select 1 from public.movimentos_caixa m
               where m.devolucao_id = d.id and m.origem = 'REEMBOLSO' and m.tipo = 'SAIDA'
                 and m.valor = d.valor and m.data = d.data
                 and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id)))
         or (d.situacao = 'ESTORNADO' and exists (
              select 1 from public.movimentos_caixa m
               where m.devolucao_id = d.id
                 and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id))))
  ) then
    raise exception 'Conferência do pedido %: uma devolução não bate com o Caixa. Nada foi gravado.',
      public.numero_pedido_texto(v_venda.numero);
  end if;
end;
$$;
-- tg_movimentos_caixa_conferir_pedido: versão do sql/10
create or replace function public.tg_movimentos_caixa_conferir_pedido()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mov    public.movimentos_caixa := new;
  v_venda  uuid;
begin
  if v_mov.origem = 'ESTORNO' then
    select * into v_mov from public.movimentos_caixa where id = new.movimento_estornado_id;
  end if;
  if v_mov.recebimento_id is not null then
    select venda_id into v_venda from public.recebimentos_venda where id = v_mov.recebimento_id;
  elsif v_mov.devolucao_id is not null then
    select venda_id into v_venda from public.devolucoes_venda where id = v_mov.devolucao_id;
  end if;
  if v_venda is not null then
    perform public.conferir_pedido(v_venda);
  end if;
  return null;
end;
$$;
-- tg_vendas_protege: versão do sql/07
create or replace function public.tg_vendas_protege()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  -- Em Entregue e Cancelado só podem mudar: o status (pelas funções), o
  -- resumo financeiro (P1-b) e o updated_at técnico. Saldo e status
  -- financeiro são calculados pelo banco.
  v_livres text[] := array['status_pedido', 'valor_recebido', 'valor_devolvido',
                           'saldo', 'status_financeiro', 'updated_at'];
begin
  if tg_op = 'DELETE' then
    raise exception 'Pedidos não podem ser excluídos. Para desistir de um pedido, cancele-o com motivo.';
  end if;

  if new.id is distinct from old.id or new.numero is distinct from old.numero then
    raise exception 'O número do pedido não pode ser alterado.';
  end if;

  if old.status_pedido = 'CANCELADO' and new.status_pedido <> 'CANCELADO' then
    raise exception 'O pedido #% está cancelado. O cancelamento é definitivo.', lpad(old.numero::text, greatest(4, length(old.numero::text)), '0');
  end if;

  if old.status_pedido in ('ENTREGUE', 'CANCELADO') then
    if old.status_pedido <> 'CANCELADO' and new.status_pedido = 'CANCELADO' then
      v_livres := v_livres || array['cancelado_em', 'motivo_cancelamento'];
    end if;
    if (to_jsonb(new) - v_livres) is distinct from (to_jsonb(old) - v_livres) then
      raise exception 'Pedido entregue ou cancelado não pode ser editado. Para corrigir um pedido entregue, volte o status para Pronto antes.';
    end if;
  end if;

  return new;
end;
$$;
-- salvar_venda_shopee: versão do sql/17
create or replace function public.salvar_venda_shopee(
  p_id               uuid,
  p_shopee_ref       uuid,
  p_data             date,
  p_desconto         numeric,
  p_taxa             numeric,
  p_frete_comprador  numeric,
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
  v_sp        public.shopee_pedidos;
  v_id        uuid;
  v_numero    integer;
  v_desconto  numeric := coalesce(p_desconto, 0);
  v_taxa      numeric := coalesce(p_taxa, 0);
  v_frete     numeric := coalesce(p_frete_comprador, 0);
  v_obs       text := nullif(trim(coalesce(p_observacao, '')), '');
  v_subtotal  numeric := 0;
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
  v_desc      text;
  v_cor       text;
  v_qtd       integer;
  v_preco     numeric;
  v_troca     boolean;
  v_norm      jsonb := '[]'::jsonb;
  v_x         jsonb;
  v_linhas    integer;
  v_mudou     boolean := false;
begin
  perform public.exigir_admin();

  -- Pedido da Shopee
  if p_shopee_ref is null then raise exception 'Escolha o pedido da Shopee.'; end if;
  select * into v_sp from public.shopee_pedidos where id = p_shopee_ref for update;
  if not found then raise exception 'Pedido da Shopee não encontrado. Importe a planilha de novo.'; end if;

  if p_id is null then
    select * into v_atual from public.vendas where shopee_pedido_ref = p_shopee_ref;
    if found then
      raise exception 'O pedido % da Shopee já virou o pedido %.', v_sp.pedido_id, public.numero_pedido_texto(v_atual.numero);
    end if;
    if lower(coalesce(v_sp.status, '')) ~ 'cancel' then
      raise exception 'O pedido % está cancelado na Shopee e não vira venda.', v_sp.pedido_id;
    end if;
  else
    select * into v_atual from public.vendas where id = p_id for update;
    if not found then raise exception 'Pedido não encontrado.'; end if;
    if v_atual.shopee_pedido_ref is distinct from p_shopee_ref then
      raise exception 'Este pedido não é a venda do pedido % da Shopee.', v_sp.pedido_id;
    end if;
    if v_atual.status_pedido in ('ENTREGUE', 'CANCELADO') then
      raise exception 'Pedido entregue ou cancelado não pode ser editado. Para corrigir um pedido entregue, volte o status para Pronto antes.';
    end if;
  end if;

  -- Data da venda (R9): real, nunca futura
  if p_data is null then raise exception 'Informe a data da venda.'; end if;
  if p_data > public.hoje() then raise exception 'A data da venda não pode ser futura.'; end if;
  if length(coalesce(v_obs, '')) > 2000 then raise exception 'A observação pode ter até 2.000 caracteres.'; end if;

  -- Valores (R105)
  if v_desconto < 0 or v_taxa < 0 or v_frete < 0 then raise exception 'Desconto, taxa e frete não podem ser negativos.'; end if;
  if v_desconto <> round(v_desconto, 2) or v_taxa <> round(v_taxa, 2) or v_frete <> round(v_frete, 2) then
    raise exception 'Desconto, taxa e frete aceitam até 2 casas decimais.';
  end if;
  if greatest(v_desconto, v_taxa, v_frete) > c_limite then raise exception 'Valor acima do limite do sistema (R$ 9.999.999,99).'; end if;

  -- Itens: pelo menos 1
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'A venda precisa ter pelo menos um item.';
  end if;
  if jsonb_array_length(p_itens) > 200 then raise exception 'Uma venda pode ter até 200 itens.'; end if;

  for v_item, v_n in select e, o::integer from jsonb_array_elements(p_itens) with ordinality t(e, o) loop
    if jsonb_typeof(v_item) <> 'object' then raise exception 'Item %: formato inválido.', v_n; end if;

    v_iid := null; v_tem_old := false;
    v_txt := nullif(trim(coalesce(v_item ->> 'id', '')), '');
    if v_txt is not null then
      if v_txt !~ c_uuid or p_id is null then raise exception 'Item %: identificador inválido.', v_n; end if;
      v_iid := v_txt::uuid;
      if v_iid = any (v_ids) then raise exception 'Item %: aparece duas vezes na lista.', v_n; end if;
      select * into v_old from public.itens_venda where id = v_iid and venda_id = p_id;
      if not found then raise exception 'Item %: não pertence a esta venda.', v_n; end if;
      v_tem_old := true;
      v_ids := v_ids || v_iid;
    end if;

    v_txt := v_item ->> 'quantidade';
    if v_txt is null or v_txt !~ '^[0-9]{1,6}$' or v_txt::integer < 1 then
      raise exception 'Item %: a quantidade precisa ser um número inteiro, no mínimo 1.', v_n;
    end if;
    v_qtd := v_txt::integer;
    v_txt := v_item ->> 'preco_unitario';
    if v_txt is null or v_txt !~ '^[0-9]{1,10}(\.[0-9]{1,2})?$' then
      raise exception 'Item %: informe o preço (R$ 0,00 ou mais, até 2 casas decimais).', v_n;
    end if;
    v_preco := v_txt::numeric;
    if v_preco > c_limite or v_qtd * v_preco > c_limite then
      raise exception 'Item %: valor acima do limite do sistema (R$ 9.999.999,99).', v_n;
    end if;

    v_txt := nullif(trim(coalesce(v_item ->> 'produto_id', '')), '');
    if v_txt is not null and v_txt !~ c_uuid then raise exception 'Item %: produto inválido.', v_n; end if;
    v_prod_id := v_txt::uuid;
    v_txt := nullif(trim(coalesce(v_item ->> 'material_id', '')), '');
    if v_txt is not null and v_txt !~ c_uuid then raise exception 'Item %: cor inválida.', v_n; end if;
    v_mat_id := v_txt::uuid;

    v_troca := not v_tem_old or v_old.produto_id is distinct from v_prod_id;
    if v_prod_id is not null then
      -- Ligado ao catálogo (R102): nome do produto copiado; só produto ativo ao entrar
      if v_troca then
        select * into v_prod from public.produtos where id = v_prod_id;
        if not found then raise exception 'Item %: produto não encontrado.', v_n; end if;
        if not v_prod.ativo then raise exception 'Item %: o produto "%" está inativo.', v_n, v_prod.nome; end if;
        v_desc := v_prod.nome;
      else
        v_desc := v_old.descricao;
      end if;
      if v_mat_id is null then
        v_cor := null;
      elsif v_troca or v_old.material_id is distinct from v_mat_id then
        if not exists (select 1 from public.produto_cores where produto_id = v_prod_id and material_id = v_mat_id) then
          raise exception 'Item %: a cor escolhida não é uma das cores do produto.', v_n;
        end if;
        select * into v_mat from public.materiais where id = v_mat_id;
        v_cor := left(v_mat.tipo || ' · ' || v_mat.variacao, 80);
      else
        v_cor := v_old.cor_descricao;
      end if;
    else
      -- Sem ligação: o nome vem da planilha (como item personalizado)
      v_desc := left(trim(coalesce(v_item ->> 'descricao', '')), 150);
      if length(v_desc) = 0 then raise exception 'Item %: informe a descrição do item.', v_n; end if;
      if v_mat_id is not null then
        if v_troca or v_old.material_id is distinct from v_mat_id then
          select * into v_mat from public.materiais where id = v_mat_id;
          if not found or v_mat.categoria <> 'FILAMENTO' then raise exception 'Item %: a cor precisa ser um filamento.', v_n; end if;
          if not v_mat.ativo then raise exception 'Item %: o filamento % · % está inativo.', v_n, v_mat.tipo, v_mat.variacao; end if;
          v_cor := left(v_mat.tipo || ' · ' || v_mat.variacao, 80);
        else
          v_cor := v_old.cor_descricao;
        end if;
      else
        v_cor := null;
      end if;
    end if;

    v_subtotal := v_subtotal + round(v_qtd * v_preco, 2);
    v_norm := v_norm || jsonb_build_array(jsonb_build_object(
      'id', v_iid, 'ordem', v_n, 'produto_id', v_prod_id, 'descricao', v_desc,
      'preco_unitario', v_preco, 'quantidade', v_qtd, 'material_id', v_mat_id, 'cor_descricao', v_cor));
  end loop;

  if v_subtotal > c_limite then raise exception 'O subtotal passa do limite do sistema (R$ 9.999.999,99).'; end if;
  if v_desconto > v_subtotal then raise exception 'O desconto do vendedor não pode passar do valor dos produtos.'; end if;
  if v_taxa > v_subtotal - v_desconto then
    raise exception 'A taxa da Shopee não pode passar do valor dos produtos menos o desconto.';
  end if;

  if p_id is null then
    v_numero := public.proximo_numero_pedido();
    insert into public.vendas (numero, data, cliente_id, canal_id, origem, observacao, subtotal, desconto, frete, total,
                               shopee_pedido_ref, taxa_plataforma, frete_comprador)
    values (v_numero, p_data, null, public.canal_shopee(), null, v_obs, v_subtotal, v_desconto, 0, v_subtotal - v_desconto,
            p_shopee_ref, v_taxa, v_frete)
    returning id into v_id;
    insert into public.historico_status_pedido (venda_id, status_anterior, status_novo)
    values (v_id, null, 'AGUARDANDO');
  else
    v_id := p_id;
    v_numero := v_atual.numero;
    update public.vendas
       set data = p_data, observacao = v_obs, subtotal = v_subtotal, desconto = v_desconto, total = v_subtotal - v_desconto,
           taxa_plataforma = v_taxa, frete_comprador = v_frete
     where id = v_id
       and (data, observacao, subtotal, desconto, taxa_plataforma, frete_comprador)
           is distinct from (p_data, v_obs, v_subtotal::numeric(12,2), v_desconto::numeric(12,2),
                             v_taxa::numeric(12,2), v_frete::numeric(12,2));
    get diagnostics v_linhas = row_count;
    v_mudou := v_linhas > 0;
  end if;

  delete from public.itens_venda where venda_id = v_id and id <> all (v_ids);
  get diagnostics v_linhas = row_count;
  v_mudou := v_mudou or v_linhas > 0;

  for v_x in select e from jsonb_array_elements(v_norm) e loop
    if v_x ->> 'id' is not null then
      update public.itens_venda
         set ordem = (v_x ->> 'ordem')::integer, produto_id = (v_x ->> 'produto_id')::uuid, descricao = v_x ->> 'descricao',
             preco_unitario = (v_x ->> 'preco_unitario')::numeric, quantidade = (v_x ->> 'quantidade')::integer,
             material_id = (v_x ->> 'material_id')::uuid, cor_descricao = v_x ->> 'cor_descricao'
       where id = (v_x ->> 'id')::uuid
         and (ordem, produto_id, descricao, preco_unitario, quantidade, material_id, cor_descricao)
             is distinct from ((v_x ->> 'ordem')::integer, (v_x ->> 'produto_id')::uuid, v_x ->> 'descricao',
                               (v_x ->> 'preco_unitario')::numeric, (v_x ->> 'quantidade')::integer,
                               (v_x ->> 'material_id')::uuid, v_x ->> 'cor_descricao');
      get diagnostics v_linhas = row_count;
      v_mudou := v_mudou or v_linhas > 0;
    else
      insert into public.itens_venda (venda_id, ordem, produto_id, descricao, preco_unitario, quantidade, material_id, cor_descricao)
      values (v_id, (v_x ->> 'ordem')::integer, (v_x ->> 'produto_id')::uuid, v_x ->> 'descricao',
              (v_x ->> 'preco_unitario')::numeric, (v_x ->> 'quantidade')::integer,
              (v_x ->> 'material_id')::uuid, v_x ->> 'cor_descricao');
      v_mudou := true;
    end if;
  end loop;

  if p_id is not null and v_mudou then
    update public.vendas set editado_em = now() where id = v_id;
  end if;

  perform public.recalcular_pedido(v_id);
  perform public.conferir_pedido(v_id);
  return jsonb_build_object('id', v_id, 'numero', v_numero);
end;
$$;
-- definir_cores_partes: versão do sql/14
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

drop view public.vw_avisos_shopee;
drop view public.vw_repasses_shopee_pendentes;
drop function public.dispensar_aviso_shopee(uuid, text);
drop function public.estornar_repasse_shopee(uuid, text);
drop function public.confirmar_repasse_shopee(uuid, date, numeric, text, boolean, uuid);
drop function public.exigir_venda_sem_repasse(uuid);

alter table public.movimentos_caixa
  drop constraint movimentos_caixa_origem_repasse_shopee,
  drop column repasse_shopee_id;

drop table public.avisos_shopee_dispensados;
drop table public.repasses_shopee;
drop function public.tg_repasses_shopee_protege();
drop function public.tg_avisos_shopee_protege();

commit;

-- Pronto. Confira com as verificações gerais.
