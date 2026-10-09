-- =====================================================================
-- Arts com Você · Módulo "Pedidos da Shopee" (consulta)
--
-- Importa e guarda os pedidos da planilha que a Shopee exporta
-- (Meus Pedidos › Exportar), só para consulta.
--
-- O que este arquivo NÃO faz:
--   · não altera nenhuma tabela, função, permissão ou registro existente;
--   · não cria vendas, não mexe no Caixa, no estoque nem na comissão do Joca;
--   · não guarda dados pessoais do comprador (nome, usuário, telefone,
--     CPF, endereço, cidade, UF, CEP). A tela nem envia essas colunas, e o
--     banco recusa qualquer coluna fora da lista permitida.
--
-- Regras do módulo:
--   · Valor ausente na planilha fica vazio (a tela mostra "Não informado").
--     Nada é calculado nem estimado; o líquido não existe na planilha.
--   · Cada importação é tudo ou nada: se qualquer pedido falhar, nada muda.
--   · Itens nunca são apagados. Se os itens de um pedido já registrado não
--     baterem com os da planilha, os registrados ficam como estão e o
--     pedido recebe um aviso para conferência.
--   · Só a Admin lê e importa. O Joca e visitantes não acessam nada.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência: rodar sql/shopee_verificacao.sql.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Tabelas
-- ---------------------------------------------------------------------

-- Histórico de cada importação confirmada.
create table public.shopee_importacoes (
  id           uuid primary key default gen_random_uuid(),
  arquivo      text not null check (length(trim(arquivo)) > 0),
  linhas       integer not null check (linhas >= 0),
  novos        integer not null default 0 check (novos >= 0),
  atualizados  integer not null default 0 check (atualizados >= 0),
  iguais       integer not null default 0 check (iguais >= 0),
  com_erro     integer not null default 0 check (com_erro >= 0),
  com_aviso    integer not null default 0 check (com_aviso >= 0),
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid()
);

comment on table public.shopee_importacoes is
  'Pedidos da Shopee: uma linha por importação confirmada (quantidades de novos, atualizados, iguais, com erro e com aviso).';

-- Um registro por pedido da Shopee. Valores ficam vazios quando a planilha não informa.
create table public.shopee_pedidos (
  id                      uuid primary key default gen_random_uuid(),
  pedido_id               text not null unique check (length(trim(pedido_id)) > 0),

  status                  text,
  status_devolucao        text,
  rastreio                text,
  opcao_envio             text,
  metodo_envio            text,

  criado_em               timestamptz,
  pago_em                 timestamptz,
  envio_previsto          timestamptz,
  enviado_em              timestamptz,

  valor_total             numeric(12,2),
  desconto_vendedor_1     numeric(12,2),   -- 1ª coluna "Desconto do vendedor"
  desconto_vendedor_2     numeric(12,2),   -- 2ª coluna "Desconto do vendedor" (não somadas)
  cupom_vendedor          numeric(12,2),
  cupom_shopee            numeric(12,2),   -- coluna "Cupom"
  codigo_cupom            text,
  total_global            numeric(12,2),

  frete_comprador         numeric(12,2),   -- "Taxa de envio pagas pelo comprador"
  frete_estimado          numeric(12,2),   -- "Valor estimado do frete"
  desconto_frete          numeric(12,2),   -- "Desconto de Frete Aproximado"

  taxa_comissao           numeric(12,2),   -- "Taxa de comissão líquida"
  taxa_servico            numeric(12,2),   -- "Taxa de serviço líquida"
  taxa_transacao          numeric(12,2),
  taxa_envio_reversa      numeric(12,2),

  numero_produtos         integer,         -- "Número de produtos pedidos" (só informativo)

  colunas                 jsonb not null default '{}'::jsonb,  -- cópia das colunas permitidas (sem dados pessoais)
  aviso_itens             text,

  primeira_importacao_id  uuid references public.shopee_importacoes (id) on delete restrict,
  ultima_importacao_id    uuid references public.shopee_importacoes (id) on delete restrict,
  created_at              timestamptz not null default now(),
  created_by              uuid default auth.uid(),
  updated_at              timestamptz not null default now()
);

create index idx_shopee_pedidos_criado_em on public.shopee_pedidos (criado_em desc);

comment on table public.shopee_pedidos is
  'Pedidos da Shopee importados da planilha (só consulta). Valores vazios = não informados na planilha.';

-- Itens de cada pedido. A chave identifica o item sem depender do SKU
-- (que costuma vir vazio): produto + variação + SKU + ocorrência.
create table public.shopee_pedido_itens (
  id               uuid primary key default gen_random_uuid(),
  pedido_ref       uuid not null references public.shopee_pedidos (id) on delete restrict,
  chave            text not null check (length(chave) > 0),
  produto          text not null check (length(trim(produto)) > 0),
  variacao         text,
  sku              text,
  sku_principal    text,
  quantidade       integer,
  qtd_devolvida    integer,
  preco_original   numeric(12,2),
  preco_acordado   numeric(12,2),
  subtotal         numeric(12,2),
  colunas          jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now(),
  created_by       uuid default auth.uid(),
  updated_at       timestamptz not null default now(),
  constraint uq_shopee_item unique (pedido_ref, chave)
);

comment on table public.shopee_pedido_itens is
  'Itens dos pedidos da Shopee. Nunca são apagados por uma importação.';


-- ---------------------------------------------------------------------
-- 2. updated_at e auditoria (mesmo padrão das etapas anteriores)
-- ---------------------------------------------------------------------
create trigger trg_shopee_pedidos_updated_at before update on public.shopee_pedidos
  for each row execute function public.tg_updated_at();
create trigger trg_shopee_pedido_itens_updated_at before update on public.shopee_pedido_itens
  for each row execute function public.tg_updated_at();

create trigger trg_shopee_importacoes_auditoria after insert or update or delete on public.shopee_importacoes
  for each row execute function public.tg_auditoria();
create trigger trg_shopee_pedidos_auditoria after insert or update or delete on public.shopee_pedidos
  for each row execute function public.tg_auditoria();
create trigger trg_shopee_pedido_itens_auditoria after insert or update or delete on public.shopee_pedido_itens
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 3. Importação (tudo ou nada)
--
-- p_pedidos: lista montada pela tela, já sem dados pessoais:
--   [{ "pedido_id": "...", "dados": {campo: "texto" | null, ...},
--      "colunas": {...}, "itens": [{ "chave": "...", "dados": {...}, "colunas": {...} }] }]
-- Valores em texto exato ("79.50"), datas em ISO com fuso ("2026-10-07T15:40:00-03:00").
--
-- p_confirmar = false → só compara e devolve a prévia (não grava nada).
-- p_confirmar = true  → grava e devolve o resultado.
-- ---------------------------------------------------------------------
create or replace function public.importar_pedidos_shopee(
  p_arquivo text, p_linhas integer, p_com_erro integer, p_pedidos jsonb, p_confirmar boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Campos que a planilha pode preencher. Qualquer outra chave enviada é ignorada.
  c_campos_pedido constant text[] := array[
    'status', 'status_devolucao', 'rastreio', 'opcao_envio', 'metodo_envio',
    'criado_em', 'pago_em', 'envio_previsto', 'enviado_em',
    'valor_total', 'desconto_vendedor_1', 'desconto_vendedor_2', 'cupom_vendedor', 'cupom_shopee',
    'codigo_cupom', 'total_global', 'frete_comprador', 'frete_estimado', 'desconto_frete',
    'taxa_comissao', 'taxa_servico', 'taxa_transacao', 'taxa_envio_reversa', 'numero_produtos'];
  c_campos_item constant text[] := array[
    'produto', 'variacao', 'sku', 'sku_principal', 'quantidade', 'qtd_devolvida',
    'preco_original', 'preco_acordado', 'subtotal'];
  c_aviso_itens constant text :=
    'Os itens desta planilha não batem com os já registrados (por exemplo, nome do produto alterado na Shopee). '
    'Os itens registrados foram mantidos como estavam. Confira na Shopee.';

  -- Colunas que podem ser guardadas na cópia "colunas" (nenhuma tem dado
  -- pessoal do comprador). Qualquer outra chave recusa a importação inteira,
  -- mesmo que a função seja chamada diretamente, sem passar pela tela.
  -- Mesmas listas de js/shopee-planilha.js (OUTRAS_PEDIDO e COLUNAS_PERMITIDAS).
  c_colunas_pedido constant text[] := array[
    'Hot Listing', 'Incentivo Shopee para ação comercial', 'Ajuste por participação em ação comercial',
    'Peso total do pedido', 'Coin Cashback Voucher Amount Sponsored by Seller', 'Incentivo de cupom',
    'Ajuste por pagamento via PIX', 'Indicador da Leve Mais por Menos', 'Desconto Shopee da Leve Mais por Menos',
    'Desconto da Leve Mais por Menos do vendedor', 'Compensar Moedas Shopee', 'Total descontado Cartão de Crédito',
    'Taxa de Serviço Instantâneo pago pelo comprador', 'Taxa de comissão bruta', 'Taxa de serviço bruta'];
  -- No item, uma coluna que aparece repetida na planilha vem como "Nome (1ª)", "Nome (2ª)".
  c_colunas_item constant text[] := array[
    'ID do pedido', 'Status do pedido', 'Status da Devolução / Reembolso', 'Número de rastreamento',
    'Opção de envio', 'Método de envio', 'Data de criação do pedido', 'Hora do pagamento do pedido',
    'Data prevista de envio', 'Tempo de Envio', 'Valor Total', 'Desconto do vendedor', 'Cupom do vendedor',
    'Cupom', 'Código do Cupom', 'Total global', 'Taxa de envio pagas pelo comprador', 'Valor estimado do frete',
    'Desconto de Frete Aproximado', 'Taxa de comissão líquida', 'Taxa de serviço líquida', 'Taxa de transação',
    'Taxa de Envio Reversa', 'Número de produtos pedidos', 'Nome do Produto', 'Nome da variação',
    'Número de referência SKU', 'Nº de referência do SKU principal', 'Quantidade', 'Returned quantity',
    'Preço original', 'Preço acordado', 'Subtotal do produto',
    'Hot Listing', 'Incentivo Shopee para ação comercial', 'Ajuste por participação em ação comercial',
    'Peso total do pedido', 'Coin Cashback Voucher Amount Sponsored by Seller', 'Incentivo de cupom',
    'Ajuste por pagamento via PIX', 'Indicador da Leve Mais por Menos', 'Desconto Shopee da Leve Mais por Menos',
    'Desconto da Leve Mais por Menos do vendedor', 'Compensar Moedas Shopee', 'Total descontado Cartão de Crédito',
    'Taxa de Serviço Instantâneo pago pelo comprador', 'Taxa de comissão bruta', 'Taxa de serviço bruta',
    'Peso total SKU'];

  v_col        text;
  v_imp        uuid;
  v_p          jsonb;
  v_i          jsonb;
  v_id_pedido  text;
  v_dados      jsonb;
  v_novo       public.shopee_pedidos;
  v_atual      public.shopee_pedidos;
  v_novo_j     jsonb;
  v_atual_j    jsonb;
  v_item_novo  public.shopee_pedido_itens;
  v_item_atual public.shopee_pedido_itens;
  v_chaves_pl  text[];
  v_chaves_bd  text[];
  v_alterados  text[];
  v_itens_ok   boolean;
  v_itens_mud  boolean;
  v_situacao   text;
  v_aviso      text;
  v_resultado  jsonb := '[]'::jsonb;
  n_novos      integer := 0;
  n_atual      integer := 0;
  n_iguais     integer := 0;
  n_aviso      integer := 0;
begin
  perform public.exigir_admin();

  if p_pedidos is null or jsonb_typeof(p_pedidos) <> 'array' then
    raise exception 'A lista de pedidos está vazia ou em formato inválido.';
  end if;
  if jsonb_array_length(p_pedidos) > 5000 then
    raise exception 'A planilha tem pedidos demais para uma importação (máximo 5.000). Exporte um período menor.';
  end if;
  if p_arquivo is null or length(trim(p_arquivo)) = 0 then raise exception 'Informe o nome do arquivo.'; end if;
  if exists (select 1 from jsonb_array_elements(p_pedidos) e
              where jsonb_typeof(e) <> 'object' or length(trim(coalesce(e ->> 'pedido_id', ''))) = 0) then
    raise exception 'Há um pedido sem número na lista.';
  end if;
  if (select count(*) from jsonb_array_elements(p_pedidos) e)
     <> (select count(distinct trim(e ->> 'pedido_id')) from jsonb_array_elements(p_pedidos) e) then
    raise exception 'A lista tem o mesmo pedido mais de uma vez.';
  end if;

  -- Validação completa, IGUAL na prévia e na gravação: tudo o que a gravação
  -- exige é conferido aqui antes, para que um pedido não apareça como válido
  -- na prévia e falhe só ao confirmar.
  for v_p in select e from jsonb_array_elements(p_pedidos) e loop
    v_id_pedido := trim(v_p ->> 'pedido_id');

    if jsonb_typeof(coalesce(v_p -> 'dados', '{}'::jsonb)) <> 'object'
       or jsonb_typeof(coalesce(v_p -> 'colunas', '{}'::jsonb)) <> 'object' then
      raise exception 'O pedido % está em formato inválido.', v_id_pedido;
    end if;
    v_col := null;
    select key into v_col from jsonb_each(coalesce(v_p -> 'colunas', '{}'::jsonb))
     where not (key = any (c_colunas_pedido)) or jsonb_typeof(value) <> 'string'
     order by key limit 1;
    if v_col is not null then
      raise exception 'O pedido % traz a coluna "%", que não pode ser guardada.', v_id_pedido, v_col;
    end if;
    begin
      select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_dados
        from jsonb_each(coalesce(v_p -> 'dados', '{}'::jsonb)) where key = any (c_campos_pedido);
      v_novo := jsonb_populate_record(null::public.shopee_pedidos, v_dados);
    exception when others then
      raise exception 'O pedido % tem um valor em formato inválido (%).', v_id_pedido, sqlerrm;
    end;

    if jsonb_typeof(coalesce(v_p -> 'itens', '[]'::jsonb)) <> 'array'
       or jsonb_array_length(coalesce(v_p -> 'itens', '[]'::jsonb)) = 0 then
      raise exception 'O pedido % não tem itens na planilha.', v_id_pedido;
    end if;
    for v_i in select e from jsonb_array_elements(v_p -> 'itens') e loop
      if jsonb_typeof(v_i) <> 'object'
         or jsonb_typeof(coalesce(v_i -> 'dados', '{}'::jsonb)) <> 'object'
         or jsonb_typeof(coalesce(v_i -> 'colunas', '{}'::jsonb)) <> 'object' then
        raise exception 'O pedido % tem um item em formato inválido.', v_id_pedido;
      end if;
      if coalesce(length(v_i ->> 'chave'), 0) = 0 then
        raise exception 'O pedido % tem um item sem identificação.', v_id_pedido;
      end if;
      v_col := null;
      select key into v_col from jsonb_each(coalesce(v_i -> 'colunas', '{}'::jsonb))
       where not (key = any (c_colunas_item) or regexp_replace(key, ' \([1-9]ª\)$', '') = any (c_colunas_item))
          or jsonb_typeof(value) <> 'string'
       order by key limit 1;
      if v_col is not null then
        raise exception 'O pedido % traz a coluna "%", que não pode ser guardada.', v_id_pedido, v_col;
      end if;
      begin
        select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_dados
          from jsonb_each(coalesce(v_i -> 'dados', '{}'::jsonb)) where key = any (c_campos_item);
        v_item_novo := jsonb_populate_record(null::public.shopee_pedido_itens, v_dados);
      exception when others then
        raise exception 'O pedido % tem um valor em formato inválido (%).', v_id_pedido, sqlerrm;
      end;
      if length(trim(coalesce(v_item_novo.produto, ''))) = 0 then
        raise exception 'O pedido % tem um item sem "Nome do Produto".', v_id_pedido;
      end if;
    end loop;
    if (select count(*) from jsonb_array_elements(v_p -> 'itens') i)
       <> (select count(distinct i ->> 'chave') from jsonb_array_elements(v_p -> 'itens') i) then
      raise exception 'O pedido % tem itens repetidos na lista.', v_id_pedido;
    end if;
  end loop;

  if p_confirmar then
    -- Uma importação por vez.
    perform pg_advisory_xact_lock(hashtext('importar_pedidos_shopee'));
    insert into public.shopee_importacoes (arquivo, linhas, com_erro)
    values (left(trim(p_arquivo), 200), greatest(coalesce(p_linhas, 0), 0), greatest(coalesce(p_com_erro, 0), 0))
    returning id into v_imp;
  end if;

  for v_p in select e from jsonb_array_elements(p_pedidos) e loop
    v_id_pedido := trim(v_p ->> 'pedido_id');

    -- Só os campos permitidos; o banco converte texto em número e data.
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_dados
      from jsonb_each(coalesce(v_p -> 'dados', '{}'::jsonb)) where key = any (c_campos_pedido);
    v_novo := jsonb_populate_record(null::public.shopee_pedidos, v_dados);

    select * into v_atual from public.shopee_pedidos where pedido_id = v_id_pedido for update;

    -- Itens da planilha (já validados acima).
    select coalesce(array_agg(i ->> 'chave' order by i ->> 'chave'), '{}') into v_chaves_pl
      from jsonb_array_elements(v_p -> 'itens') i;

    v_aviso := null;

    if v_atual.id is null then
      -- Pedido novo.
      v_situacao := 'novo';
      v_alterados := '{}';
      n_novos := n_novos + 1;
      if p_confirmar then
        v_novo.id := gen_random_uuid();
        v_novo.pedido_id := v_id_pedido;
        v_novo.colunas := coalesce(v_p -> 'colunas', '{}'::jsonb);
        v_novo.primeira_importacao_id := v_imp;
        v_novo.ultima_importacao_id := v_imp;
        v_novo.created_at := now();
        v_novo.created_by := auth.uid();
        v_novo.updated_at := now();
        insert into public.shopee_pedidos select v_novo.*;
        for v_i in select e from jsonb_array_elements(v_p -> 'itens') e loop
          select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_dados
            from jsonb_each(coalesce(v_i -> 'dados', '{}'::jsonb)) where key = any (c_campos_item);
          v_item_novo := jsonb_populate_record(null::public.shopee_pedido_itens, v_dados);
          insert into public.shopee_pedido_itens
            (pedido_ref, chave, produto, variacao, sku, sku_principal, quantidade, qtd_devolvida,
             preco_original, preco_acordado, subtotal, colunas)
          values (v_novo.id, v_i ->> 'chave', v_item_novo.produto, v_item_novo.variacao, v_item_novo.sku,
                  v_item_novo.sku_principal, v_item_novo.quantidade, v_item_novo.qtd_devolvida,
                  v_item_novo.preco_original, v_item_novo.preco_acordado, v_item_novo.subtotal,
                  coalesce(v_i -> 'colunas', '{}'::jsonb));
        end loop;
      end if;
    else
      -- Pedido já registrado: compara campo a campo.
      select to_jsonb(v_novo) into v_novo_j;
      select to_jsonb(v_atual) into v_atual_j;
      select coalesce(array_agg(k order by k), '{}') into v_alterados
        from unnest(c_campos_pedido) k where (v_novo_j -> k) is distinct from (v_atual_j -> k);
      if coalesce(v_p -> 'colunas', '{}'::jsonb) is distinct from v_atual.colunas then
        v_alterados := array_append(v_alterados, 'outras colunas');
      end if;

      select coalesce(array_agg(chave order by chave), '{}') into v_chaves_bd
        from public.shopee_pedido_itens where pedido_ref = v_atual.id;
      v_itens_ok := (v_chaves_bd = v_chaves_pl);
      v_itens_mud := false;

      if v_itens_ok then
        for v_i in select e from jsonb_array_elements(v_p -> 'itens') e loop
          select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into v_dados
            from jsonb_each(coalesce(v_i -> 'dados', '{}'::jsonb)) where key = any (c_campos_item);
          v_item_novo := jsonb_populate_record(null::public.shopee_pedido_itens, v_dados);
          select * into v_item_atual from public.shopee_pedido_itens
           where pedido_ref = v_atual.id and chave = v_i ->> 'chave' for update;
          if (v_item_novo.produto, v_item_novo.variacao, v_item_novo.sku, v_item_novo.sku_principal,
              v_item_novo.quantidade, v_item_novo.qtd_devolvida, v_item_novo.preco_original,
              v_item_novo.preco_acordado, v_item_novo.subtotal, coalesce(v_i -> 'colunas', '{}'::jsonb))
             is distinct from
             (v_item_atual.produto, v_item_atual.variacao, v_item_atual.sku, v_item_atual.sku_principal,
              v_item_atual.quantidade, v_item_atual.qtd_devolvida, v_item_atual.preco_original,
              v_item_atual.preco_acordado, v_item_atual.subtotal, v_item_atual.colunas) then
            v_itens_mud := true;
            if p_confirmar then
              update public.shopee_pedido_itens
                 set produto = v_item_novo.produto, variacao = v_item_novo.variacao, sku = v_item_novo.sku,
                     sku_principal = v_item_novo.sku_principal, quantidade = v_item_novo.quantidade,
                     qtd_devolvida = v_item_novo.qtd_devolvida, preco_original = v_item_novo.preco_original,
                     preco_acordado = v_item_novo.preco_acordado, subtotal = v_item_novo.subtotal,
                     colunas = coalesce(v_i -> 'colunas', '{}'::jsonb)
               where id = v_item_atual.id;
            end if;
          end if;
        end loop;
        if v_itens_mud then v_alterados := array_append(v_alterados, 'itens'); end if;
      else
        v_aviso := c_aviso_itens;
      end if;
      -- O aviso de conferência aparece ou some conforme os itens batem ou não.
      if v_aviso is distinct from v_atual.aviso_itens then
        v_alterados := array_append(v_alterados, 'conferência dos itens');
      end if;

      if cardinality(v_alterados) = 0 then
        v_situacao := 'igual';
        n_iguais := n_iguais + 1;
      else
        v_situacao := 'atualizado';
        n_atual := n_atual + 1;
        if p_confirmar then
          update public.shopee_pedidos
             set status = v_novo.status, status_devolucao = v_novo.status_devolucao, rastreio = v_novo.rastreio,
                 opcao_envio = v_novo.opcao_envio, metodo_envio = v_novo.metodo_envio,
                 criado_em = v_novo.criado_em, pago_em = v_novo.pago_em,
                 envio_previsto = v_novo.envio_previsto, enviado_em = v_novo.enviado_em,
                 valor_total = v_novo.valor_total, desconto_vendedor_1 = v_novo.desconto_vendedor_1,
                 desconto_vendedor_2 = v_novo.desconto_vendedor_2, cupom_vendedor = v_novo.cupom_vendedor,
                 cupom_shopee = v_novo.cupom_shopee, codigo_cupom = v_novo.codigo_cupom,
                 total_global = v_novo.total_global, frete_comprador = v_novo.frete_comprador,
                 frete_estimado = v_novo.frete_estimado, desconto_frete = v_novo.desconto_frete,
                 taxa_comissao = v_novo.taxa_comissao, taxa_servico = v_novo.taxa_servico,
                 taxa_transacao = v_novo.taxa_transacao, taxa_envio_reversa = v_novo.taxa_envio_reversa,
                 numero_produtos = v_novo.numero_produtos,
                 colunas = coalesce(v_p -> 'colunas', '{}'::jsonb),
                 aviso_itens = v_aviso,
                 ultima_importacao_id = v_imp
           where id = v_atual.id;
        end if;
      end if;
    end if;

    if v_aviso is not null then n_aviso := n_aviso + 1; end if;
    v_resultado := v_resultado || jsonb_build_object(
      'pedido_id', v_id_pedido, 'situacao', v_situacao,
      'alterados', to_jsonb(v_alterados), 'aviso', v_aviso);
  end loop;

  if p_confirmar then
    update public.shopee_importacoes
       set novos = n_novos, atualizados = n_atual, iguais = n_iguais, com_aviso = n_aviso
     where id = v_imp;
  end if;

  return jsonb_build_object(
    'importacao_id', v_imp, 'confirmado', p_confirmar,
    'novos', n_novos, 'atualizados', n_atual, 'iguais', n_iguais, 'com_aviso', n_aviso,
    'pedidos', v_resultado);
end;
$$;


-- ---------------------------------------------------------------------
-- 4. Segurança: só a Admin lê; gravação só pela função acima
-- ---------------------------------------------------------------------
alter table public.shopee_importacoes  enable row level security;
alter table public.shopee_pedidos      enable row level security;
alter table public.shopee_pedido_itens enable row level security;

revoke all on public.shopee_importacoes, public.shopee_pedidos, public.shopee_pedido_itens from public, anon, authenticated;
grant select on public.shopee_importacoes, public.shopee_pedidos, public.shopee_pedido_itens to authenticated;

create policy shopee_importacoes_select_admin on public.shopee_importacoes
  for select to authenticated using (public.is_admin());
create policy shopee_pedidos_select_admin on public.shopee_pedidos
  for select to authenticated using (public.is_admin());
create policy shopee_pedido_itens_select_admin on public.shopee_pedido_itens
  for select to authenticated using (public.is_admin());

revoke all on function public.importar_pedidos_shopee(text, integer, integer, jsonb, boolean) from public, anon;
grant execute on function public.importar_pedidos_shopee(text, integer, integer, jsonb, boolean) to authenticated;

commit;
