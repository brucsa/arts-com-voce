-- =====================================================================
-- Arts com Você · Produção Essencial (Etapa 5) · Lote B · Passo 2 de 2
-- Especificação v1.8, R95–R100 (decisões PR3–PR11), aplicando R11–R18,
-- R21, R30 e R56.
--
-- Antes: rode sql/15_estoque_motivos_producao.sql sozinho.
--
-- O que este arquivo cria (só acréscimos):
--   · producoes e producao_consumos: cada produção (de um item de pedido,
--     para o estoque de peças prontas ou avulsa), OK ou falha, com o
--     material que saiu do estoque pelo custo médio e a energia (R95–R96);
--   · pecas_prontas e saidas_pecas_prontas: o estoque de peças prontas por
--     produto e cores, com o custo de cada peça; uso no pedido e baixa com
--     motivo (R98);
--   · embalagens_pedido: a embalagem que sai do estoque quando o pedido
--     fica Pronto (R97);
--   · ajustes_estoque: o ajuste de inventário com motivo (R99);
--   · consultas para as telas: itens a produzir, histórico, peças prontas,
--     perdas e custo do pedido (R100);
--   · funções (só a Admin): registrar_producao, estornar_producao,
--     usar_peca_pronta, baixar_peca_pronta, estornar_saida_peca,
--     ajustar_estoque;
--   · gatilhos: embalagem em Pronto; proteção dos itens de pedido que já
--     têm produção (não podem ser removidos nem trocar de produto).
--
-- O que NÃO muda:
--   · nenhuma função, consulta, permissão ou registro existente;
--   · pedidos, itens, cores, Caixa e comissão do Joca continuam iguais;
--     o custo de produção não entra no Caixa (R100).
--
-- Regras principais:
--   · Material sai pelo custo médio do momento (R12, R54); nunca negativo.
--   · Filamento é informado em gramas; insumo na unidade dele.
--   · Energia (R16) = potência (W) ÷ 1000 × horas × tarifa do kWh;
--     potência e tarifa precisam estar em Configurações.
--   · Produção OK de um pedido: quando todos os itens estiverem prontos
--     (produzidos ou com peça pronta), o pedido vai para Pronto.
--   · Falha: só filamento (sem insumos e embalagem); vira Perda de
--     produção com o motivo Falha de impressão (R17, R30).
--   · Embalagem: sai ao ir para Pronto pela ficha × quantidade do item;
--     se faltar no estoque, o status não muda e o aviso diz o que falta.
--   · Correção por estorno: o registro fica no histórico e os materiais
--     voltam pelo mesmo custo; só enquanto as peças não foram usadas.
--     O status do pedido não volta sozinho.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Conferência depois: sql/producao_verificacao.sql e as verificações gerais.
-- Tudo ou nada: se qualquer passo falhar, nada é criado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.producoes') is not null or to_regclass('public.pecas_prontas') is not null then
    raise exception 'A produção já está instalada. Nada foi alterado.';
  end if;
  if to_regclass('public.produto_partes') is null or to_regclass('public.item_venda_partes') is null then
    raise exception 'A ficha de consumo (sql/14) precisa estar instalada. Nada foi alterado.';
  end if;
  if (select count(*) from pg_enum where enumtypid = 'public.motivo_estoque'::regtype
        and enumlabel in ('PRODUCAO', 'FALHA', 'EMBALAGEM', 'AJUSTE')) <> 4 then
    raise exception 'Rode antes sql/15_estoque_motivos_producao.sql (motivos de estoque da produção). Nada foi alterado.';
  end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace
               and proname in ('registrar_producao', 'estornar_producao', 'usar_peca_pronta', 'baixar_peca_pronta',
                               'estornar_saida_peca', 'ajustar_estoque', 'baixar_material', 'atualizar_pedido_pronto',
                               'item_faltam', 'tg_vendas_embalagem', 'tg_itens_venda_producao_protege',
                               'tg_producao_protege')) then
    raise exception 'Já existe função da produção. Nada foi alterado.';
  end if;
  if exists (select 1 from public.movimentos_estoque where motivo::text in ('PRODUCAO', 'FALHA', 'EMBALAGEM', 'AJUSTE')) then
    raise exception 'Já existem movimentos de produção no estoque. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Tipos e tabelas
-- ---------------------------------------------------------------------
create type public.destino_producao as enum ('PEDIDO', 'ESTOQUE', 'AVULSA');
create type public.resultado_producao as enum ('OK', 'FALHA');
create type public.tipo_saida_peca as enum ('PEDIDO', 'SHOPEE', 'BRINDE', 'PERDA', 'OUTRO');

-- Cada produção registrada (R95, R96).
create table public.producoes (
  id                   uuid primary key default gen_random_uuid(),
  seq                  bigint generated always as identity unique,
  data                 date not null,
  destino              public.destino_producao not null,
  resultado            public.resultado_producao not null,
  item_id              uuid references public.itens_venda (id) on delete restrict,
  venda_id             uuid references public.vendas (id) on delete restrict,
  produto_id           uuid references public.produtos (id) on delete restrict,
  descricao            text not null check (length(trim(descricao)) between 1 and 200),
  pecas                integer check (pecas is null or pecas >= 1),
  percentual_impresso  numeric(5,2) check (percentual_impresso is null or (percentual_impresso > 0 and percentual_impresso <= 100)),
  tempo_min            integer not null check (tempo_min >= 0),
  potencia_w           numeric(8,2) not null check (potencia_w > 0),
  tarifa_kwh           numeric(10,5) not null check (tarifa_kwh > 0),
  custo_filamento      numeric(12,2) not null default 0 check (custo_filamento >= 0),
  custo_insumos        numeric(12,2) not null default 0 check (custo_insumos >= 0),
  custo_energia        numeric(12,2) not null default 0 check (custo_energia >= 0),
  custo_total          numeric(12,2) not null default 0 check (custo_total >= 0),
  cores                jsonb not null default '[]'::jsonb,   -- [{parte, material_id, cor}] (peças do estoque)
  obs                  text check (obs is null or length(obs) <= 500),
  situacao             public.situacao_lancamento_pedido not null default 'ATIVO',
  estornado_em         timestamptz,
  motivo_estorno       text,
  chave_envio          uuid not null unique,
  created_at           timestamptz not null default now(),
  created_by           uuid default auth.uid(),
  updated_at           timestamptz not null default now(),
  constraint producoes_pedido_coerente check ((destino = 'PEDIDO') = (item_id is not null) and (item_id is null) = (venda_id is null)),
  constraint producoes_estoque_com_produto check (destino <> 'ESTOQUE' or produto_id is not null),
  constraint producoes_pecas_coerente check ((resultado = 'OK' and destino <> 'AVULSA') = (pecas is not null)),
  constraint producoes_falha_coerente check ((resultado = 'FALHA') = (percentual_impresso is not null)),
  constraint producoes_custo_coerente check (custo_total = custo_filamento + custo_insumos + custo_energia),
  constraint producoes_estorno_coerente check ((situacao = 'ESTORNADO') = (estornado_em is not null and motivo_estorno is not null))
);

create index idx_producoes_item on public.producoes (item_id);
create index idx_producoes_venda on public.producoes (venda_id);
create index idx_producoes_data on public.producoes (data, seq);

comment on table public.producoes is
  'Produção Essencial (R95–R96): OK ou falha, de pedido, para estoque ou avulsa. Corrigida só por estorno.';

-- Material de cada produção: filamento (peça + purga) e insumos.
create table public.producao_consumos (
  id                    uuid primary key default gen_random_uuid(),
  producao_id           uuid not null references public.producoes (id) on delete restrict,
  ordem                 integer not null check (ordem >= 1),
  material_id           uuid not null references public.materiais (id) on delete restrict,
  parte                 text check (parte is null or length(trim(parte)) between 1 and 60),
  quantidade_peca       numeric(12,3) not null check (quantidade_peca >= 0),   -- na unidade do material
  quantidade_purga      numeric(12,3) not null default 0 check (quantidade_purga >= 0),
  quantidade            numeric(12,3) not null check (quantidade > 0),
  valor                 numeric(12,2) not null check (valor >= 0),
  movimento_id          uuid not null unique references public.movimentos_estoque (id) on delete restrict,
  movimento_estorno_id  uuid unique references public.movimentos_estoque (id) on delete restrict,
  created_at            timestamptz not null default now(),
  unique (producao_id, ordem),
  constraint producao_consumos_soma check (quantidade = quantidade_peca + quantidade_purga)
);

create index idx_producao_consumos_material on public.producao_consumos (material_id);

-- Lote de peças prontas: uma produção OK para o estoque (R98, R21).
create table public.pecas_prontas (
  id               uuid primary key default gen_random_uuid(),
  producao_id      uuid not null unique references public.producoes (id) on delete restrict,
  produto_id       uuid not null references public.produtos (id) on delete restrict,
  cores            jsonb not null default '[]'::jsonb,   -- [{parte, material_id, cor}]
  cores_chave      text not null,                         -- para juntar a mesma combinação
  cores_descricao  text not null,
  quantidade       integer not null check (quantidade >= 1),
  custo_total      numeric(12,2) not null check (custo_total >= 0),
  custo_unitario   numeric(12,4) not null check (custo_unitario >= 0),
  data             date not null,
  created_at       timestamptz not null default now()
);

create index idx_pecas_prontas_produto on public.pecas_prontas (produto_id, cores_chave);

-- Saídas de peças prontas: uso num pedido ou baixa com motivo (R98, R30).
create table public.saidas_pecas_prontas (
  id              uuid primary key default gen_random_uuid(),
  seq             bigint generated always as identity unique,
  lote_id         uuid not null references public.pecas_prontas (id) on delete restrict,
  data            date not null,
  tipo            public.tipo_saida_peca not null,
  item_id         uuid references public.itens_venda (id) on delete restrict,
  venda_id        uuid references public.vendas (id) on delete restrict,
  quantidade      integer not null check (quantidade >= 1),
  custo           numeric(12,2) not null check (custo >= 0),
  obs             text check (obs is null or length(obs) <= 500),
  situacao        public.situacao_lancamento_pedido not null default 'ATIVO',
  estornado_em    timestamptz,
  motivo_estorno  text,
  chave_envio     uuid not null unique,
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),
  updated_at      timestamptz not null default now(),
  constraint saidas_pecas_pedido_coerente check ((tipo = 'PEDIDO') = (item_id is not null) and (item_id is null) = (venda_id is null)),
  constraint saidas_pecas_motivo check (tipo not in ('PERDA', 'OUTRO') or obs is not null),
  constraint saidas_pecas_estorno_coerente check ((situacao = 'ESTORNADO') = (estornado_em is not null and motivo_estorno is not null))
);

create index idx_saidas_pecas_lote on public.saidas_pecas_prontas (lote_id);
create index idx_saidas_pecas_item on public.saidas_pecas_prontas (item_id);

-- Embalagens baixadas quando o pedido fica Pronto (R97, R15).
create table public.embalagens_pedido (
  id            uuid primary key default gen_random_uuid(),
  venda_id      uuid not null references public.vendas (id) on delete restrict,
  item_id       uuid not null references public.itens_venda (id) on delete restrict,
  material_id   uuid not null references public.materiais (id) on delete restrict,
  data          date not null,
  quantidade    numeric(12,3) not null check (quantidade > 0),
  valor         numeric(12,2) not null check (valor >= 0),
  movimento_id  uuid not null unique references public.movimentos_estoque (id) on delete restrict,
  created_at    timestamptz not null default now(),
  created_by    uuid default auth.uid()
);

create index idx_embalagens_pedido_venda on public.embalagens_pedido (venda_id);

-- Ajuste de inventário (R99, R56).
create table public.ajustes_estoque (
  id                 uuid primary key default gen_random_uuid(),
  seq                bigint generated always as identity unique,
  material_id        uuid not null references public.materiais (id) on delete restrict,
  data               date not null,
  quantidade_antes   numeric(14,3) not null,
  quantidade_contada numeric(14,3) not null check (quantidade_contada >= 0),
  diferenca          numeric(14,3) not null check (diferenca <> 0),
  valor              numeric(12,2) not null check (valor >= 0),
  motivo             text not null check (length(trim(motivo)) between 1 and 500),
  movimento_id       uuid not null unique references public.movimentos_estoque (id) on delete restrict,
  chave_envio        uuid not null unique,
  created_at         timestamptz not null default now(),
  created_by         uuid default auth.uid(),
  constraint ajustes_diferenca_coerente check (diferenca = quantidade_contada - quantidade_antes)
);

create index idx_ajustes_material on public.ajustes_estoque (material_id, seq);

create trigger trg_producoes_updated_at before update on public.producoes
  for each row execute function public.tg_updated_at();
create trigger trg_saidas_pecas_prontas_updated_at before update on public.saidas_pecas_prontas
  for each row execute function public.tg_updated_at();
create trigger trg_producoes_auditoria after insert or update or delete on public.producoes
  for each row execute function public.tg_auditoria();
create trigger trg_producao_consumos_auditoria after insert or update or delete on public.producao_consumos
  for each row execute function public.tg_auditoria();
create trigger trg_pecas_prontas_auditoria after insert or update or delete on public.pecas_prontas
  for each row execute function public.tg_auditoria();
create trigger trg_saidas_pecas_prontas_auditoria after insert or update or delete on public.saidas_pecas_prontas
  for each row execute function public.tg_auditoria();
create trigger trg_embalagens_pedido_auditoria after insert or update or delete on public.embalagens_pedido
  for each row execute function public.tg_auditoria();
create trigger trg_ajustes_estoque_auditoria after insert or update or delete on public.ajustes_estoque
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 2. Proteções
-- ---------------------------------------------------------------------
-- Nada é apagado; produções e saídas só mudam de ATIVO para ESTORNADO;
-- consumos só ganham o movimento de estorno; o resto não muda.
create or replace function public.tg_producao_protege()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Os registros de produção, peças prontas, embalagens e ajustes não são apagados. Para corrigir, use o estorno.';
  end if;
  -- Na mesma gravação que criou a produção, os custos são preenchidos no fim.
  if tg_table_name = 'producoes' then
    if old.created_at = now() and old.situacao = 'ATIVO' and new.situacao = 'ATIVO'
       and (to_jsonb(new) - array['custo_filamento', 'custo_insumos', 'custo_energia', 'custo_total', 'cores', 'updated_at'])
           = (to_jsonb(old) - array['custo_filamento', 'custo_insumos', 'custo_energia', 'custo_total', 'cores', 'updated_at']) then
      return new;
    end if;
  end if;
  if tg_table_name in ('producoes', 'saidas_pecas_prontas') then
    if old.situacao = 'ESTORNADO' then raise exception 'Este registro já foi estornado.'; end if;
    if (to_jsonb(new) - array['situacao', 'estornado_em', 'motivo_estorno', 'updated_at'])
       is distinct from (to_jsonb(old) - array['situacao', 'estornado_em', 'motivo_estorno', 'updated_at']) then
      raise exception 'Este registro não pode ser alterado. Para corrigir, estorne e registre de novo.';
    end if;
  elsif tg_table_name = 'producao_consumos' then
    if old.movimento_estorno_id is not null
       or (to_jsonb(new) - 'movimento_estorno_id') is distinct from (to_jsonb(old) - 'movimento_estorno_id') then
      raise exception 'O consumo de uma produção não pode ser alterado.';
    end if;
  else
    raise exception 'Este registro não pode ser alterado.';
  end if;
  return new;
end;
$$;

create trigger trg_producoes_protege before update or delete on public.producoes
  for each row execute function public.tg_producao_protege();
create trigger trg_producao_consumos_protege before update or delete on public.producao_consumos
  for each row execute function public.tg_producao_protege();
create trigger trg_pecas_prontas_protege before update or delete on public.pecas_prontas
  for each row execute function public.tg_producao_protege();
create trigger trg_saidas_pecas_prontas_protege before update or delete on public.saidas_pecas_prontas
  for each row execute function public.tg_producao_protege();
create trigger trg_embalagens_pedido_protege before update or delete on public.embalagens_pedido
  for each row execute function public.tg_producao_protege();
create trigger trg_ajustes_estoque_protege before update or delete on public.ajustes_estoque
  for each row execute function public.tg_producao_protege();

-- Item de pedido com produção ou peça pronta (mesmo estornada, o histórico
-- aponta para ele): não pode ser removido nem trocar de produto.
create or replace function public.tg_itens_venda_producao_protege()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.produto_id is not distinct from old.produto_id then
    return new;
  end if;
  if exists (select 1 from public.producoes where item_id = old.id)
     or exists (select 1 from public.saidas_pecas_prontas where item_id = old.id) then
    raise exception 'O item "%" já tem produção ou peça pronta registrada e não pode ser removido nem trocar de produto. Para mudar a quantidade ou o preço, edite o item.', old.descricao;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger trg_itens_venda_producao_protege
  before update of produto_id or delete on public.itens_venda
  for each row execute function public.tg_itens_venda_producao_protege();


-- ---------------------------------------------------------------------
-- 3. Funções internas
-- ---------------------------------------------------------------------
-- Tira um material do estoque pelo custo médio do momento (R12, R54).
-- Devolve o movimento e o valor. Recusa com o nome do material e o saldo.
create or replace function public.baixar_material(
  p_material_id uuid, p_quantidade numeric, p_data date, p_motivo public.motivo_estoque, p_obs text,
  out movimento_id uuid, out valor numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mat   public.materiais;
  v_saldo public.saldos_material;
begin
  select * into v_mat from public.materiais where id = p_material_id;
  insert into public.saldos_material (material_id) values (p_material_id) on conflict (material_id) do nothing;
  select * into v_saldo from public.saldos_material where material_id = p_material_id for update;
  if v_saldo.quantidade < p_quantidade then
    raise exception 'Estoque insuficiente de %: tem % %, precisa de % %. Registre a compra ou faça o ajuste de inventário em Estoque.',
      v_mat.tipo || coalesce(' · ' || v_mat.variacao, ''),
      replace(rtrim(to_char(v_saldo.quantidade, 'FM9999999990.999'), '.'), '.', ','), v_mat.unidade,
      replace(rtrim(to_char(p_quantidade, 'FM9999999990.999'), '.'), '.', ','), v_mat.unidade;
  end if;
  valor := case when p_quantidade = v_saldo.quantidade then v_saldo.valor
                else least(round(p_quantidade * v_saldo.valor / v_saldo.quantidade, 2), v_saldo.valor) end;
  movimento_id := public.movimentar_estoque(p_material_id, p_data, 'SAIDA', p_motivo, p_quantidade, valor, null, null, p_obs);
end;
$$;

-- Quantas peças do item ainda faltam (produzidas OK + peças prontas usadas).
create or replace function public.item_faltam(p_item_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select greatest(i.quantidade
           - coalesce((select sum(p.pecas) from public.producoes p
                        where p.item_id = i.id and p.resultado = 'OK' and p.situacao = 'ATIVO'), 0)
           - coalesce((select sum(s.quantidade) from public.saidas_pecas_prontas s
                        where s.item_id = i.id and s.situacao = 'ATIVO'), 0), 0)::integer
    from public.itens_venda i where i.id = p_item_id
$$;

-- Pedido Aguardando ou Produzindo com todos os itens prontos vai para Pronto.
-- Devolve true quando mudou.
create or replace function public.atualizar_pedido_pronto(p_venda_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda public.vendas;
begin
  select * into v_venda from public.vendas where id = p_venda_id for update;
  if v_venda.status_pedido not in ('AGUARDANDO', 'PRODUZINDO') then return false; end if;
  if exists (select 1 from public.itens_venda i where i.venda_id = p_venda_id and public.item_faltam(i.id) > 0) then
    return false;
  end if;
  update public.vendas set status_pedido = 'PRONTO' where id = p_venda_id;
  insert into public.historico_status_pedido (venda_id, status_anterior, status_novo, motivo)
  values (p_venda_id, v_venda.status_pedido, 'PRONTO', 'Todos os itens prontos (produção)');
  perform public.conferir_pedido(p_venda_id);
  return true;
end;
$$;

-- Embalagem (R97, R15): quando o pedido fica Pronto pela primeira vez, as
-- embalagens da ficha × quantidade de cada item saem do estoque.
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
      join public.produto_materiais pm on pm.produto_id = i.produto_id
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

create trigger trg_vendas_embalagem
  after update of status_pedido on public.vendas
  for each row when (new.status_pedido = 'PRONTO' and old.status_pedido is distinct from 'PRONTO')
  execute function public.tg_vendas_embalagem();


-- ---------------------------------------------------------------------
-- 4. Funções de gravação (só a Admin; tudo ou nada)
-- ---------------------------------------------------------------------

-- Registra uma produção (R95, R96).
--   p_destino:   PEDIDO (p_item_id), ESTOQUE (p_produto_id) ou AVULSA (p_descricao)
--   p_resultado: OK ou FALHA (p_percentual = quanto chegou a imprimir)
--   p_pecas:     peças boas (OK de pedido ou de estoque)
--   p_consumos:  [{"material_id": "...", "parte": "Flor", "peca": 12, "purga": 2}, ...]
--                filamento em gramas; insumo na unidade dele (purga 0)
create or replace function public.registrar_producao(
  p_data date, p_destino text, p_resultado text, p_item_id uuid, p_produto_id uuid, p_descricao text,
  p_pecas integer, p_percentual numeric, p_tempo_min integer, p_consumos jsonb, p_obs text, p_chave uuid
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
  elsif v_destino = 'ESTOQUE' then
    if p_item_id is not null then raise exception 'Produção para o estoque não tem item de pedido.'; end if;
    select * into v_prod from public.produtos where id = p_produto_id;
    if not found then raise exception 'Escolha o produto.'; end if;
    if v_result = 'OK' and (p_pecas is null or p_pecas < 1 or p_pecas > 10000) then
      raise exception 'Informe quantas peças ficaram prontas.';
    end if;
    v_desc := v_prod.nome;
  else
    if p_item_id is not null then raise exception 'Produção avulsa não tem item de pedido.'; end if;
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
                                percentual_impresso, tempo_min, potencia_w, tarifa_kwh, obs, chave_envio)
  values (p_data, v_destino, v_result, v_item.id, v_item.venda_id, p_produto_id, v_desc,
          case when v_result = 'OK' and v_destino <> 'AVULSA' then p_pecas end,
          p_percentual, p_tempo_min, v_cfg.potencia_impressora_w, v_cfg.tarifa_kwh, v_obs, p_chave)
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
    select count(*) into v_partes from public.produto_partes where produto_id = p_produto_id;
    if v_partes > 0 and exists (
         select 1 from public.produto_partes pp where pp.produto_id = p_produto_id
          and not exists (select 1 from jsonb_array_elements(v_cores) c where lower(c ->> 'parte') = lower(trim(pp.nome)))) then
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
                                      custo_total, custo_unitario, data)
    select v_id, p_produto_id, p.cores,
           (select string_agg(coalesce(lower(c ->> 'parte'), '') || '=' || (c ->> 'material_id'), '|' order by lower(c ->> 'parte'), c ->> 'material_id')
              from jsonb_array_elements(p.cores) c),
           (select string_agg(case when c ->> 'parte' is null then c ->> 'cor' else (c ->> 'parte') || ': ' || (c ->> 'cor') end,
                              ' · ' order by c ->> 'parte' nulls last, c ->> 'cor')
              from jsonb_array_elements(p.cores) c),
           p_pecas, v_total, round(v_total / p_pecas, 4), p_data
      from public.producoes p where p.id = v_id;
  end if;

  if v_destino = 'PEDIDO' and v_result = 'OK' then
    v_pronto := public.atualizar_pedido_pronto(v_item.venda_id);
  end if;

  return jsonb_build_object('id', v_id, 'custo_total', v_total, 'pedido_pronto', v_pronto);
end;
$$;

-- Estorna uma produção (R99): os materiais voltam pelo mesmo custo.
-- Peças do estoque: só se nenhuma foi usada. Pedido: não pode estar
-- entregue ou cancelado. O status do pedido não volta sozinho.
create or replace function public.estornar_producao(p_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_p      public.producoes;
  v_c      public.producao_consumos;
  v_mov    public.movimentos_estoque;
  v_est    uuid;
  v_motivo text := trim(coalesce(p_motivo, ''));
  v_status public.status_pedido_direto;
begin
  perform public.exigir_admin();
  if length(v_motivo) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  select * into v_p from public.producoes where id = p_id for update;
  if not found then raise exception 'Produção não encontrada.'; end if;
  if v_p.situacao = 'ESTORNADO' then raise exception 'Esta produção já foi estornada.'; end if;

  if v_p.venda_id is not null then
    select status_pedido into v_status from public.vendas where id = v_p.venda_id for update;
    if v_status in ('ENTREGUE', 'CANCELADO') then
      raise exception 'O pedido já está % e a produção dele não pode ser estornada.',
        case when v_status = 'ENTREGUE' then 'entregue' else 'cancelado' end;
    end if;
  end if;
  if exists (select 1 from public.saidas_pecas_prontas s join public.pecas_prontas l on l.id = s.lote_id
              where l.producao_id = p_id and s.situacao = 'ATIVO') then
    raise exception 'Peças desta produção já foram usadas ou baixadas. Estorne essas saídas antes.';
  end if;

  for v_c in select * from public.producao_consumos where producao_id = p_id order by ordem loop
    select * into v_mov from public.movimentos_estoque where id = v_c.movimento_id;
    v_est := public.movimentar_estoque(v_c.material_id, public.hoje(), 'ENTRADA', 'ESTORNO', v_mov.quantidade, v_mov.valor,
                                       null, v_mov.id, 'Estorno da produção: ' || v_motivo);
    update public.producao_consumos set movimento_estorno_id = v_est where id = v_c.id;
  end loop;

  update public.producoes set situacao = 'ESTORNADO', estornado_em = now(), motivo_estorno = v_motivo where id = p_id;
end;
$$;

-- Usa peças prontas num item de pedido (R98): as cores do item passam a
-- ser as da peça; o estoque de prontas diminui; o pedido leva o custo.
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

-- Baixa manual de peças prontas com motivo (R98): Shopee, brinde, perda ou outro.
create or replace function public.baixar_peca_pronta(
  p_lote_id uuid, p_quantidade integer, p_tipo text, p_obs text, p_data date, p_chave uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lote   public.pecas_prontas;
  v_saldo  integer;
  v_custo  numeric;
  v_obs    text := nullif(trim(coalesce(p_obs, '')), '');
  v_id     uuid;
  v_existe public.saidas_pecas_prontas;
begin
  perform public.exigir_admin();
  if p_chave is null then raise exception 'Código de envio ausente. Recarregue a página e tente de novo.'; end if;
  select * into v_existe from public.saidas_pecas_prontas where chave_envio = p_chave;
  if found then return jsonb_build_object('id', v_existe.id, 'repetido', true); end if;

  if p_tipo is null or p_tipo not in ('SHOPEE', 'BRINDE', 'PERDA', 'OUTRO') then
    raise exception 'Escolha o motivo da baixa: Shopee, brinde, perda ou outro.';
  end if;
  if p_tipo in ('PERDA', 'OUTRO') and v_obs is null then
    raise exception 'Descreva o motivo (ex.: peça quebrou, ficou manchada).';
  end if;
  if length(coalesce(v_obs, '')) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;
  if p_data is null or p_data > public.hoje() then raise exception 'Informe a data (hoje ou antes).'; end if;

  select * into v_lote from public.pecas_prontas where id = p_lote_id for update;
  if not found or exists (select 1 from public.producoes where id = v_lote.producao_id and situacao = 'ESTORNADO') then
    raise exception 'Peça pronta não encontrada.';
  end if;
  if p_data < v_lote.data then raise exception 'A data não pode ser antes da produção das peças.'; end if;
  if p_quantidade is null or p_quantidade < 1 then raise exception 'Informe quantas peças baixar.'; end if;
  v_saldo := v_lote.quantidade - coalesce((select sum(quantidade) from public.saidas_pecas_prontas
                                            where lote_id = v_lote.id and situacao = 'ATIVO'), 0);
  if p_quantidade > v_saldo then raise exception 'Só há % peça(s) prontas nesta combinação.', v_saldo; end if;
  v_custo := case when p_quantidade = v_saldo
                  then v_lote.custo_total - coalesce((select sum(custo) from public.saidas_pecas_prontas
                                                       where lote_id = v_lote.id and situacao = 'ATIVO'), 0)
                  else round(p_quantidade * v_lote.custo_unitario, 2) end;

  insert into public.saidas_pecas_prontas (lote_id, data, tipo, quantidade, custo, obs, chave_envio)
  values (v_lote.id, p_data, p_tipo::public.tipo_saida_peca, p_quantidade, v_custo, v_obs, p_chave)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'custo', v_custo);
end;
$$;

-- Estorna uma saída de peças prontas (uso no pedido ou baixa): as peças
-- voltam ao estoque de prontas. As cores do item e o status não voltam.
create or replace function public.estornar_saida_peca(p_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_s      public.saidas_pecas_prontas;
  v_motivo text := trim(coalesce(p_motivo, ''));
  v_status public.status_pedido_direto;
begin
  perform public.exigir_admin();
  if length(v_motivo) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;
  select * into v_s from public.saidas_pecas_prontas where id = p_id for update;
  if not found then raise exception 'Saída de peça pronta não encontrada.'; end if;
  if v_s.situacao = 'ESTORNADO' then raise exception 'Esta saída já foi estornada.'; end if;
  if v_s.venda_id is not null then
    select status_pedido into v_status from public.vendas where id = v_s.venda_id for update;
    if v_status in ('ENTREGUE', 'CANCELADO') then
      raise exception 'O pedido já está % e a peça usada nele não pode voltar ao estoque.',
        case when v_status = 'ENTREGUE' then 'entregue' else 'cancelado' end;
    end if;
  end if;
  update public.saidas_pecas_prontas set situacao = 'ESTORNADO', estornado_em = now(), motivo_estorno = v_motivo where id = p_id;
end;
$$;

-- Ajuste de inventário (R99, R56): depois de pesar ou contar, corrige o
-- saldo com motivo. Sobra entra pelo custo médio; falta sai como perda.
create or replace function public.ajustar_estoque(
  p_material_id uuid, p_quantidade_contada numeric, p_motivo text, p_data date, p_chave uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mat     public.materiais;
  v_saldo   public.saldos_material;
  v_motivo  text := trim(coalesce(p_motivo, ''));
  v_dif     numeric;
  v_custo   numeric;
  v_valor   numeric;
  v_mov     uuid;
  v_r       record;
  v_id      uuid;
  v_existe  public.ajustes_estoque;
begin
  perform public.exigir_admin();
  if p_chave is null then raise exception 'Código de envio ausente. Recarregue a página e tente de novo.'; end if;
  select * into v_existe from public.ajustes_estoque where chave_envio = p_chave;
  if found then return jsonb_build_object('id', v_existe.id, 'repetido', true); end if;

  select * into v_mat from public.materiais where id = p_material_id;
  if not found then raise exception 'Material não encontrado.'; end if;
  if p_quantidade_contada is null or p_quantidade_contada < 0 or p_quantidade_contada <> round(p_quantidade_contada, 3) then
    raise exception 'Informe a quantidade contada ou pesada (zero ou mais, até 3 casas decimais).';
  end if;
  if length(v_motivo) = 0 then raise exception 'Informe o motivo do ajuste (ex.: pesei o rolo, contei as embalagens).'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;
  if p_data is null or p_data > public.hoje() then raise exception 'Informe a data do ajuste (hoje ou antes).'; end if;

  insert into public.saldos_material (material_id) values (p_material_id) on conflict (material_id) do nothing;
  select * into v_saldo from public.saldos_material where material_id = p_material_id for update;
  v_dif := p_quantidade_contada - v_saldo.quantidade;
  if v_dif = 0 then raise exception 'O saldo já é esse. Nada a ajustar.'; end if;

  if v_dif > 0 then
    -- Sobra: entra pelo custo médio; sem saldo, pelo custo do último lote ativo
    if v_saldo.quantidade > 0 then
      v_custo := v_saldo.valor / v_saldo.quantidade;
    else
      select l.custo_total / l.quantidade into v_custo from public.lotes_material l
       where l.material_id = p_material_id and l.status = 'ATIVO' order by l.data desc, l.created_at desc limit 1;
      if v_custo is null then
        raise exception 'Este material ainda não tem custo de referência. Registre a entrada como compra ou estoque inicial.';
      end if;
    end if;
    v_valor := round(v_dif * v_custo, 2);
    v_mov := public.movimentar_estoque(p_material_id, p_data, 'ENTRADA', 'AJUSTE', v_dif, v_valor, null, null,
                                       'Ajuste de inventário: ' || v_motivo);
  else
    select * into v_r from public.baixar_material(p_material_id, -v_dif, p_data, 'AJUSTE', 'Ajuste de inventário: ' || v_motivo);
    v_valor := v_r.valor; v_mov := v_r.movimento_id;
  end if;

  insert into public.ajustes_estoque (material_id, data, quantidade_antes, quantidade_contada, diferenca, valor, motivo,
                                      movimento_id, chave_envio)
  values (p_material_id, p_data, v_saldo.quantidade, p_quantidade_contada, v_dif, v_valor, v_motivo, v_mov, p_chave)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'diferenca', v_dif, 'valor', v_valor);
end;
$$;


-- ---------------------------------------------------------------------
-- 5. Consultas das telas (respeitam o acesso de quem consulta)
-- ---------------------------------------------------------------------
-- Itens de pedidos em aberto: quanto já está pronto e quanto falta.
create view public.vw_itens_producao with (security_invoker = true) as
select i.id as item_id, i.venda_id, v.numero, '#' || lpad(v.numero::text, greatest(4, length(v.numero::text)), '0') as numero_formatado,
       c.nome as cliente, v.status_pedido, v.data as data_pedido, v.data_prometida,
       i.ordem, i.produto_id, i.descricao, i.quantidade, i.material_id, i.cor_descricao,
       coalesce(pr.pecas, 0)::integer as produzidas,
       coalesce(sp.pecas, 0)::integer as de_estoque,
       greatest(i.quantidade - coalesce(pr.pecas, 0) - coalesce(sp.pecas, 0), 0)::integer as faltam,
       exists (select 1 from public.item_venda_partes p where p.item_id = i.id) as tem_partes,
       not exists (select 1 from public.item_venda_partes p where p.item_id = i.id and p.material_id is null) as cores_definidas
  from public.itens_venda i
  join public.vendas v on v.id = i.venda_id
  join public.clientes c on c.id = v.cliente_id
  left join lateral (select sum(p.pecas) as pecas from public.producoes p
                      where p.item_id = i.id and p.resultado = 'OK' and p.situacao = 'ATIVO') pr on true
  left join lateral (select sum(s.quantidade) as pecas from public.saidas_pecas_prontas s
                      where s.item_id = i.id and s.situacao = 'ATIVO') sp on true;

-- Estoque de peças prontas (lotes ativos com saldo).
create view public.vw_pecas_prontas with (security_invoker = true) as
select l.id as lote_id, l.produto_id, pr.nome as produto, l.cores, l.cores_chave, l.cores_descricao, l.data,
       l.quantidade, l.custo_total, l.custo_unitario,
       (l.quantidade - coalesce(s.usadas, 0))::integer as saldo,
       (l.custo_total - coalesce(s.custo, 0)) as custo_saldo
  from public.pecas_prontas l
  join public.producoes p on p.id = l.producao_id and p.situacao = 'ATIVO'
  join public.produtos pr on pr.id = l.produto_id
  left join lateral (select sum(x.quantidade) as usadas, sum(x.custo) as custo from public.saidas_pecas_prontas x
                      where x.lote_id = l.id and x.situacao = 'ATIVO') s on true;

-- Perdas de produção com motivo (R17, R30): falhas, peças perdidas e
-- faltas no ajuste de inventário. Só registros ativos.
create view public.vw_perdas with (security_invoker = true) as
select p.data, 'FALHA'::text as origem, 'Falha de impressão'::text as motivo,
       p.descricao || ' (' || replace(to_char(p.percentual_impresso, 'FM990.##'), '.', ',') || '% impresso)' as descricao,
       p.custo_total as valor, p.id as registro_id
  from public.producoes p where p.resultado = 'FALHA' and p.situacao = 'ATIVO'
union all
select s.data, 'PECA_PRONTA', 'Produto danificado', pr.nome || ' · ' || l.cores_descricao || ' · ' || s.quantidade || ' peça(s): ' || s.obs,
       s.custo, s.id
  from public.saidas_pecas_prontas s
  join public.pecas_prontas l on l.id = s.lote_id
  join public.produtos pr on pr.id = l.produto_id
 where s.tipo = 'PERDA' and s.situacao = 'ATIVO'
union all
select a.data, 'AJUSTE', 'Ajuste de inventário', m.tipo || coalesce(' · ' || m.variacao, '') || ': ' || a.motivo, a.valor, a.id
  from public.ajustes_estoque a join public.materiais m on m.id = a.material_id
 where a.diferenca < 0;

-- Custo e lucro estimado de cada pedido (R100, só a Admin).
-- Lucro = (produtos − desconto, na proporção do que não foi devolvido)
--         − custo de produção − comissão do Joca. Frete fora.
create view public.vw_pedido_custos with (security_invoker = true) as
select v.id as venda_id,
       coalesce(pr.custo, 0)::numeric(12,2) as custo_producao,
       coalesce(sp.custo, 0)::numeric(12,2) as custo_pecas_prontas,
       coalesce(em.custo, 0)::numeric(12,2) as custo_embalagem,
       (coalesce(pr.custo, 0) + coalesce(sp.custo, 0) + coalesce(em.custo, 0))::numeric(12,2) as custo_total,
       coalesce(cj.valor, 0)::numeric(12,2) as comissao_joca,
       case when v.status_pedido = 'CANCELADO' or v.total <= 0 then 0::numeric(12,2)
            else round((v.subtotal - v.desconto) * greatest(v.total - v.valor_devolvido, 0) / v.total, 2) end as receita,
       (case when v.status_pedido = 'CANCELADO' or v.total <= 0 then 0
             else round((v.subtotal - v.desconto) * greatest(v.total - v.valor_devolvido, 0) / v.total, 2) end
        - coalesce(pr.custo, 0) - coalesce(sp.custo, 0) - coalesce(em.custo, 0) - coalesce(cj.valor, 0))::numeric(12,2) as lucro_estimado,
       exists (select 1 from public.itens_venda i where i.venda_id = v.id and public.item_faltam(i.id) > 0) as falta_produzir
  from public.vendas v
  left join lateral (select sum(p.custo_total) as custo from public.producoes p
                      where p.venda_id = v.id and p.resultado = 'OK' and p.situacao = 'ATIVO') pr on true
  left join lateral (select sum(s.custo) as custo from public.saidas_pecas_prontas s
                      where s.venda_id = v.id and s.situacao = 'ATIVO') sp on true
  left join lateral (select sum(e.valor) as custo from public.embalagens_pedido e where e.venda_id = v.id) em on true
  left join lateral (select sum(k.valor) as valor from public.comissoes_joca k where k.venda_id = v.id) cj on true;


-- ---------------------------------------------------------------------
-- 6. Acesso: só a Admin lê; ninguém grava direto
-- ---------------------------------------------------------------------
alter table public.producoes enable row level security;
alter table public.producao_consumos enable row level security;
alter table public.pecas_prontas enable row level security;
alter table public.saidas_pecas_prontas enable row level security;
alter table public.embalagens_pedido enable row level security;
alter table public.ajustes_estoque enable row level security;

revoke all on public.producoes, public.producao_consumos, public.pecas_prontas, public.saidas_pecas_prontas,
              public.embalagens_pedido, public.ajustes_estoque from public, anon, authenticated;
revoke all on public.vw_itens_producao, public.vw_pecas_prontas, public.vw_perdas, public.vw_pedido_custos
  from public, anon, authenticated;
grant select on public.producoes, public.producao_consumos, public.pecas_prontas, public.saidas_pecas_prontas,
               public.embalagens_pedido, public.ajustes_estoque to authenticated;
grant select on public.vw_itens_producao, public.vw_pecas_prontas, public.vw_perdas, public.vw_pedido_custos to authenticated;

create policy producoes_select_admin on public.producoes for select to authenticated using (public.is_admin());
create policy producao_consumos_select_admin on public.producao_consumos for select to authenticated using (public.is_admin());
create policy pecas_prontas_select_admin on public.pecas_prontas for select to authenticated using (public.is_admin());
create policy saidas_pecas_prontas_select_admin on public.saidas_pecas_prontas for select to authenticated using (public.is_admin());
create policy embalagens_pedido_select_admin on public.embalagens_pedido for select to authenticated using (public.is_admin());
create policy ajustes_estoque_select_admin on public.ajustes_estoque for select to authenticated using (public.is_admin());

-- Internas: ninguém executa direto
revoke all on function public.tg_producao_protege() from public, anon, authenticated;
revoke all on function public.tg_itens_venda_producao_protege() from public, anon, authenticated;
revoke all on function public.tg_vendas_embalagem() from public, anon, authenticated;
revoke all on function public.baixar_material(uuid, numeric, date, public.motivo_estoque, text) from public, anon, authenticated;
revoke all on function public.atualizar_pedido_pronto(uuid) from public, anon, authenticated;
-- item_faltam é usada pelas consultas (security_invoker): o usuário logado executa; os dados seguem o RLS.
revoke all on function public.item_faltam(uuid) from public, anon;
grant execute on function public.item_faltam(uuid) to authenticated;

-- Gravação: usuário logado (as funções exigem a Admin)
revoke all on function public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid) from public, anon;
revoke all on function public.estornar_producao(uuid, text) from public, anon;
revoke all on function public.usar_peca_pronta(uuid, uuid, integer, uuid) from public, anon;
revoke all on function public.baixar_peca_pronta(uuid, integer, text, text, date, uuid) from public, anon;
revoke all on function public.estornar_saida_peca(uuid, text) from public, anon;
revoke all on function public.ajustar_estoque(uuid, numeric, text, date, uuid) from public, anon;
grant execute on function public.registrar_producao(date, text, text, uuid, uuid, text, integer, numeric, integer, jsonb, text, uuid) to authenticated;
grant execute on function public.estornar_producao(uuid, text) to authenticated;
grant execute on function public.usar_peca_pronta(uuid, uuid, integer, uuid) to authenticated;
grant execute on function public.baixar_peca_pronta(uuid, integer, text, text, date, uuid) to authenticated;
grant execute on function public.estornar_saida_peca(uuid, text) to authenticated;
grant execute on function public.ajustar_estoque(uuid, numeric, text, date, uuid) to authenticated;

commit;

-- Pronto. Confira com sql/producao_verificacao.sql.
