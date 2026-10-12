-- =====================================================================
-- Arts com Você · Pedidos Diretos Essencial · Lote P1-a (estrutura inicial)
-- Especificação v1.4, regras R76–R84, decisões P1–P6.
--
-- O que este arquivo cria (só acréscimos):
--   · os tipos status_pedido_direto, origem_pedido_direto e
--     status_financeiro_pedido (próprios do Essencial; P5);
--   · as tabelas clientes, vendas, itens_venda e historico_status_pedido;
--   · a consulta vw_pedidos;
--   · as funções salvar_cliente, definir_cliente_ativo, excluir_cliente,
--     salvar_pedido, mudar_status_pedido e cancelar_pedido (só a Admin);
--   · funções internas e gatilhos de proteção e de conferência.
--
-- O que este arquivo NÃO faz:
--   · não altera nenhuma tabela, função, permissão ou registro existente
--     (Catálogo, materiais, estoque, Caixa, gastos, Shopee, Joca,
--     configurações, perfis, auditoria);
--   · não movimenta Caixa nem estoque e não gera comissão (R76);
--   · não cria recebimentos nem devoluções (lote P1-b). Os campos de
--     resumo financeiro já existem e ficam em zero até o P1-b;
--   · não cria nada da futura Fase A1: a R58 continua preservada e a
--     lista de origens daqui é só a da R78 (P5).
--
-- Regras principais:
--   · Cliente obrigatório e ativo ao ser escolhido (P1, R77).
--   · Origem obrigatória: WhatsApp, Instagram, Pessoalmente ou Outro (P2, R78).
--   · Forma de pagamento combinada opcional, da lista existente; não é
--     recebimento (P3).
--   · Pelo menos 1 item por pedido, conferido pelo banco (P6). Quantidade
--     inteira ≥ 1; preço ≥ R$ 0,00 (R79).
--   · Nome, preço e cor copiados para o item (R79).
--   · Total = subtotal − desconto + frete, calculado pelo banco (R80).
--   · Número #0001 sequencial, sem lacunas e nunca reutilizado (R81).
--   · Quatro status ativos livres entre si; Cancelado definitivo, com
--     motivo (R82, R84). Edição só em Aguardando, Produzindo ou Pronto.
--   · editado_em marca só a edição dos dados do pedido (P4, N4).
--   · Só a Admin lê e grava. O Joca e visitantes não acessam nada (R76).
--
-- Limite técnico (não é regra de negócio): cada valor em reais vai até
-- R$ 9.999.999,99 (tamanho das colunas) e um pedido tem até 200 itens.
--
-- Instalação: Supabase → SQL Editor → colar → Run (uma vez).
-- Antes: sql/manutencao/pedidos_diretos_preinstalacao.sql e o retrato.
-- Conferência: sql/pedidos_diretos_verificacao.sql.
-- Tudo ou nada: se qualquer passo falhar, nada é criado.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Travas: não instala por cima de nada e confere o que precisa existir
-- ---------------------------------------------------------------------
do $$
declare
  v_nomes text;
begin
  -- Nomes que este arquivo cria precisam estar livres
  select string_agg(n, ', ') into v_nomes
    from unnest(array['clientes', 'vendas', 'itens_venda', 'historico_status_pedido', 'vw_pedidos']) n
   where to_regclass('public.' || n) is not null;
  if v_nomes is not null then
    raise exception 'Já existe no banco: %. Nada foi alterado.', v_nomes;
  end if;

  select string_agg(n, ', ') into v_nomes
    from unnest(array['status_pedido_direto', 'origem_pedido_direto', 'status_financeiro_pedido']) n
   where to_regtype('public.' || n) is not null;
  if v_nomes is not null then
    raise exception 'Já existe o tipo: %. Nada foi alterado.', v_nomes;
  end if;

  select string_agg(distinct p.proname, ', ') into v_nomes
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public'
     and p.proname in ('salvar_cliente', 'definir_cliente_ativo', 'excluir_cliente', 'salvar_pedido',
                       'mudar_status_pedido', 'cancelar_pedido', 'proximo_numero_pedido',
                       'recalcular_pedido', 'conferir_pedido', 'canal_boca_a_boca',
                       'tg_vendas_protege', 'tg_itens_venda_protege', 'tg_historico_status_imutavel',
                       'tg_vendas_conferir', 'tg_itens_venda_conferir');
  if v_nomes is not null then
    raise exception 'Já existe a função: %. Nada foi alterado.', v_nomes;
  end if;

  -- O que as etapas anteriores instalaram e este arquivo usa
  if to_regclass('public.canais') is null or to_regclass('public.materiais') is null
     or to_regclass('public.produtos') is null or to_regclass('public.produto_cores') is null then
    raise exception 'Faltam tabelas das etapas anteriores (canais, materiais, produtos ou produto_cores). Nada foi alterado.';
  end if;
  if to_regprocedure('public.exigir_admin()') is null or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.hoje()') is null or to_regprocedure('public.tg_auditoria()') is null
     or to_regprocedure('public.tg_updated_at()') is null or to_regtype('public.forma_pagamento') is null then
    raise exception 'Faltam funções ou tipos das etapas anteriores. Nada foi alterado.';
  end if;

  -- Canal Boca a Boca: exatamente um (R78)
  if (select count(*) from public.canais where lower(trim(nome)) = 'boca a boca') <> 1
     or exists (select 1 from public.canais where lower(trim(nome)) = 'boca a boca' and usa_repasse) then
    raise exception 'O canal "Boca a Boca" (sem repasse) não foi encontrado, está repetido ou está com repasse em Configurações › Canais. Nada foi alterado.';
  end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 1. Tipos próprios do Essencial (P5: não se misturam com a Fase A1)
-- ---------------------------------------------------------------------
create type public.status_pedido_direto as enum
  ('AGUARDANDO', 'PRODUZINDO', 'PRONTO', 'ENTREGUE', 'CANCELADO');

-- R78: lista fixa e exclusiva dos Pedidos Diretos Essencial (a R58 é outra regra).
create type public.origem_pedido_direto as enum
  ('WHATSAPP', 'INSTAGRAM', 'PESSOALMENTE', 'OUTRO');

create type public.status_financeiro_pedido as enum
  ('A_RECEBER', 'RECEBIDO', 'SEM_COBRANCA', 'CANCELADO');


-- ---------------------------------------------------------------------
-- 2. Tabelas
-- ---------------------------------------------------------------------

-- Clientes (R77, P1)
create table public.clientes (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null check (length(trim(nome)) between 1 and 150),
  contato     text check (contato is null or length(trim(contato)) between 1 and 200),
  ativo       boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  updated_at  timestamptz not null default now()
);

create index idx_clientes_nome on public.clientes (lower(trim(nome)));

comment on table public.clientes is
  'Clientes dos Pedidos Diretos Essencial (R77). Nome obrigatório, contato opcional. Cliente usado em pedido só é desativado.';

-- Pedidos diretos (R80–R84)
create table public.vendas (
  id                   uuid primary key default gen_random_uuid(),
  numero               integer not null unique check (numero > 0),
  data                 date not null,
  cliente_id           uuid not null references public.clientes (id) on delete restrict,
  canal_id             uuid not null references public.canais (id) on delete restrict,
  origem               public.origem_pedido_direto not null,
  data_prometida       date,
  forma_pagamento      public.forma_pagamento,
  observacao           text check (observacao is null or length(observacao) <= 2000),

  -- Valores (R80): calculados e gravados só pelas funções deste arquivo
  subtotal             numeric(12,2) not null default 0 check (subtotal >= 0),
  desconto             numeric(12,2) not null default 0 check (desconto >= 0),
  frete                numeric(12,2) not null default 0 check (frete >= 0),
  total                numeric(12,2) not null default 0 check (total >= 0),

  status_pedido        public.status_pedido_direto not null default 'AGUARDANDO',

  -- Resumo financeiro (R83). P1-a: sempre zero. P1-b: soma dos
  -- recebimentos e devoluções ativos, mantida só pelo banco.
  valor_recebido       numeric(12,2) not null default 0 check (valor_recebido >= 0),
  valor_devolvido      numeric(12,2) not null default 0 check (valor_devolvido >= 0),

  -- Saldo e status financeiro: calculados pelo próprio banco; ninguém grava.
  --   S = 0 em pedido cancelado ou com total zero; senão máx(0, T − R).
  --   A devolução não entra no saldo: nunca gera nova cobrança (F1).
  --   Prioridade: Cancelado → Sem cobrança (F2) → Recebido → A receber.
  saldo                numeric(12,2) generated always as (
                         case when status_pedido = 'CANCELADO' or total = 0 then 0
                              else greatest(total - valor_recebido, 0) end) stored,
  status_financeiro    public.status_financeiro_pedido generated always as (
                         case when status_pedido = 'CANCELADO' then 'CANCELADO'::public.status_financeiro_pedido
                              when total = 0 then 'SEM_COBRANCA'::public.status_financeiro_pedido
                              when valor_recebido >= total then 'RECEBIDO'::public.status_financeiro_pedido
                              else 'A_RECEBER'::public.status_financeiro_pedido end) stored,

  cancelado_em         timestamptz,
  motivo_cancelamento  text check (motivo_cancelamento is null or length(motivo_cancelamento) <= 500),

  editado_em           timestamptz,   -- P4: só a edição dos dados do pedido
  created_at           timestamptz not null default now(),
  created_by           uuid default auth.uid(),
  updated_at           timestamptz not null default now(),

  constraint vendas_desconto_ate_subtotal check (desconto <= subtotal),
  constraint vendas_total_calculado check (total = subtotal - desconto + frete),
  constraint vendas_prometida_depois_da_data check (data_prometida is null or data_prometida >= data),
  constraint vendas_cancelamento_completo check (
    (status_pedido = 'CANCELADO')
    = (cancelado_em is not null and coalesce(length(trim(motivo_cancelamento)), 0) > 0)),
  -- C1: dinheiro líquido L = R − D ≥ 0 e, fora do cancelado, L ≤ T.
  constraint vendas_liquido_c1 check (
    valor_recebido - valor_devolvido >= 0
    and (status_pedido = 'CANCELADO' or valor_recebido - valor_devolvido <= total))
);

create index idx_vendas_data on public.vendas (data desc, numero desc);
create index idx_vendas_cliente on public.vendas (cliente_id);
create index idx_vendas_status on public.vendas (status_pedido);

comment on table public.vendas is
  'Pedidos Diretos Essencial (R76–R84). Canal Boca a Boca. Nunca excluídos; Cancelado é definitivo. Não movimenta Caixa, estoque nem comissão.';

-- Itens do pedido (R79, P6)
create table public.itens_venda (
  id              uuid primary key default gen_random_uuid(),
  venda_id        uuid not null references public.vendas (id) on delete restrict,
  ordem           integer not null check (ordem >= 1),
  produto_id      uuid references public.produtos (id) on delete restrict,   -- vazio = personalizado
  descricao       text not null check (length(trim(descricao)) between 1 and 150),  -- nome copiado ou texto livre
  preco_unitario  numeric(12,2) not null check (preco_unitario >= 0),          -- copiado; R$ 0,00 = brinde
  quantidade      integer not null check (quantidade >= 1),
  valor_item      numeric(12,2) generated always as (round(quantidade * preco_unitario, 2)) stored,
  material_id     uuid references public.materiais (id) on delete restrict,  -- cor = filamento (opcional)
  cor_descricao   text check (cor_descricao is null or length(trim(cor_descricao)) between 1 and 80),  -- cópia da cor
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),
  updated_at      timestamptz not null default now(),

  -- A ordem pode trocar durante uma edição: a unicidade é conferida no fim.
  constraint itens_venda_ordem_unica unique (venda_id, ordem) deferrable initially deferred,
  -- Filamento escolhido sempre tem a cópia do nome da cor.
  constraint itens_venda_cor_copiada check (material_id is null or cor_descricao is not null),
  -- Item do catálogo não tem cor livre: ou uma cor do produto, ou nenhuma.
  constraint itens_venda_catalogo_sem_cor_livre check (
    produto_id is null or material_id is not null or cor_descricao is null)
);

create index idx_itens_venda_venda on public.itens_venda (venda_id, ordem);
create index idx_itens_venda_produto on public.itens_venda (produto_id);
create index idx_itens_venda_material on public.itens_venda (material_id);

comment on table public.itens_venda is
  'Itens dos Pedidos Diretos (R79). Nome, preço e cor copiados ao entrar; mudanças no catálogo ou em materiais não alteram o pedido.';

-- Histórico de status (R82): só aceita inclusão
create table public.historico_status_pedido (
  id               uuid primary key default gen_random_uuid(),
  venda_id         uuid not null references public.vendas (id) on delete restrict,
  status_anterior  public.status_pedido_direto,          -- vazio na criação do pedido
  status_novo      public.status_pedido_direto not null,
  motivo           text check (motivo is null or length(trim(motivo)) between 1 and 500),
  quem             uuid default auth.uid(),
  -- Horário real da gravação (não o início da transação): mantém a ordem
  -- certa mesmo quando duas mudanças entram em fila.
  quando           timestamptz not null default clock_timestamp(),

  constraint historico_status_mudou check (status_anterior is distinct from status_novo),
  constraint historico_status_cancelamento_com_motivo check (status_novo <> 'CANCELADO' or motivo is not null)
);

create index idx_historico_status_venda on public.historico_status_pedido (venda_id, quando);

comment on table public.historico_status_pedido is
  'Histórico das mudanças de status dos Pedidos Diretos (R82). Nenhuma linha é alterada ou apagada.';


-- ---------------------------------------------------------------------
-- 3. updated_at e auditoria (padrão das etapas anteriores)
-- ---------------------------------------------------------------------
create trigger trg_clientes_updated_at before update on public.clientes
  for each row execute function public.tg_updated_at();
create trigger trg_vendas_updated_at before update on public.vendas
  for each row execute function public.tg_updated_at();
create trigger trg_itens_venda_updated_at before update on public.itens_venda
  for each row execute function public.tg_updated_at();

create trigger trg_clientes_auditoria after insert or update or delete on public.clientes
  for each row execute function public.tg_auditoria();
create trigger trg_vendas_auditoria after insert or update or delete on public.vendas
  for each row execute function public.tg_auditoria();
create trigger trg_itens_venda_auditoria after insert or update or delete on public.itens_venda
  for each row execute function public.tg_auditoria();
create trigger trg_historico_status_pedido_auditoria after insert or update or delete on public.historico_status_pedido
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 4. Gatilhos de proteção (valem até para as funções)
-- ---------------------------------------------------------------------

-- Pedido: nunca excluído; número imutável; Cancelado definitivo;
-- Entregue e Cancelado sem edição dos dados (R82, R84).
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

create trigger trg_vendas_protege
  before update or delete on public.vendas
  for each row execute function public.tg_vendas_protege();

-- Itens: não mudam de pedido e não são incluídos, alterados ou removidos
-- quando o pedido está Entregue ou Cancelado.
create or replace function public.tg_itens_venda_protege()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_venda   uuid;
  v_status  public.status_pedido_direto;
begin
  if tg_op = 'DELETE' then
    v_venda := old.venda_id;
  else
    v_venda := new.venda_id;
  end if;

  if tg_op = 'UPDATE' and new.venda_id is distinct from old.venda_id then
    raise exception 'Um item não pode mudar de pedido.';
  end if;

  select status_pedido into v_status from public.vendas where id = v_venda;
  if v_status in ('ENTREGUE', 'CANCELADO') then
    raise exception 'Pedido entregue ou cancelado não pode ter itens alterados. Para corrigir um pedido entregue, volte o status para Pronto antes.';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger trg_itens_venda_protege
  before insert or update or delete on public.itens_venda
  for each row execute function public.tg_itens_venda_protege();

-- Histórico de status: nenhuma linha é alterada ou apagada.
create or replace function public.tg_historico_status_imutavel()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'O histórico de status não pode ser alterado nem apagado.';
end;
$$;

create trigger trg_historico_status_imutavel
  before update or delete on public.historico_status_pedido
  for each row execute function public.tg_historico_status_imutavel();


-- ---------------------------------------------------------------------
-- 5. Funções internas (fechadas para todos; usadas pelas funções da Admin)
-- ---------------------------------------------------------------------

-- Número do próximo pedido (R81). A trava exclusiva faz os pedidos
-- criados ao mesmo tempo entrarem em fila; ela só é solta quando a
-- gravação termina. Se a gravação falhar, nada é consumido: o próximo
-- pedido recebe o mesmo número livre. Sem sequência (que pula números).
-- Precisa ser "volatile" (padrão): cada comando enxerga o que já foi gravado.
create or replace function public.proximo_numero_pedido()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_numero integer;
begin
  perform pg_advisory_xact_lock(hashtext('arts_com_voce.numero_pedido_direto'));
  select coalesce(max(numero), 0) + 1 into v_numero from public.vendas;
  return v_numero;
end;
$$;

-- Canal dos pedidos diretos (R78): sempre Boca a Boca.
create or replace function public.canal_boca_a_boca()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  select id into v_id from public.canais where lower(trim(nome)) = 'boca a boca';
  if v_id is null then
    raise exception 'O canal "Boca a Boca" não foi encontrado em Configurações › Canais. Confira o nome do canal.';
  end if;
  return v_id;
end;
$$;

-- Recalcula o resumo de valores a partir das fontes.
-- P1-a: subtotal = soma dos itens; total pela fórmula; recebido e
-- devolvido = 0 (ainda não existem lançamentos).
-- P1-b: esta função passa a somar os recebimentos e as devoluções ativos
-- (só o conteúdo dela muda; nenhuma tabela é recriada).
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

-- Conferência do pedido: pelo menos 1 item (P6), subtotal igual à soma
-- dos itens e resumo financeiro igual às fontes. Chamada no fim de cada
-- função e, de novo, pelos gatilhos de conferência no fim da gravação.
-- Se algo não bater, a gravação inteira é recusada.
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

-- Gatilhos de conferência, conferidos no fim da gravação (adiados).
-- "security definer" porque, no fim da gravação, eles rodam fora das
-- funções da Admin e precisam chamar a conferência interna (o mesmo
-- motivo do gatilho de auditoria).
create or replace function public.tg_vendas_conferir()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.conferir_pedido(new.id);
  return null;
end;
$$;

create or replace function public.tg_itens_venda_conferir()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform public.conferir_pedido(old.venda_id);
  else
    perform public.conferir_pedido(new.venda_id);
  end if;
  return null;
end;
$$;

create constraint trigger trg_vendas_conferir
  after insert or update on public.vendas
  deferrable initially deferred
  for each row execute function public.tg_vendas_conferir();

create constraint trigger trg_itens_venda_conferir
  after insert or update or delete on public.itens_venda
  deferrable initially deferred
  for each row execute function public.tg_itens_venda_conferir();


-- ---------------------------------------------------------------------
-- 6. Funções de gravação: clientes (só a Admin)
-- ---------------------------------------------------------------------

-- Cadastra (p_id vazio) ou edita um cliente. Nomes repetidos são
-- permitidos; o aviso de repetidos é da tela, sem bloquear (R77).
create or replace function public.salvar_cliente(p_id uuid, p_nome text, p_contato text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id       uuid;
  v_contato  text := nullif(trim(coalesce(p_contato, '')), '');
begin
  perform public.exigir_admin();

  if p_nome is null or length(trim(p_nome)) = 0 then raise exception 'Informe o nome do cliente.'; end if;
  if length(trim(p_nome)) > 150 then raise exception 'O nome pode ter até 150 caracteres.'; end if;
  if length(coalesce(v_contato, '')) > 200 then raise exception 'O contato pode ter até 200 caracteres.'; end if;

  if p_id is null then
    insert into public.clientes (nome, contato) values (trim(p_nome), v_contato)
    returning id into v_id;
  else
    update public.clientes set nome = trim(p_nome), contato = v_contato
     where id = p_id
    returning id into v_id;
    if v_id is null then raise exception 'Cliente não encontrado.'; end if;
  end if;

  return v_id;
end;
$$;

-- Desativar ou reativar (sempre permitido). Cliente inativo não entra em
-- pedido novo; os pedidos antigos continuam com ele (R77).
create or replace function public.definir_cliente_ativo(p_id uuid, p_ativo boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.exigir_admin();
  if p_ativo is null then raise exception 'Informe se o cliente fica ativo ou inativo.'; end if;
  update public.clientes set ativo = p_ativo where id = p_id;
  if not found then raise exception 'Cliente não encontrado.'; end if;
end;
$$;

-- Excluir: só cliente sem pedidos. Cliente usado é recusado pela ligação
-- do banco (código 23503 → "Desative em vez de excluir").
create or replace function public.excluir_cliente(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.exigir_admin();
  delete from public.clientes where id = p_id;
  if not found then raise exception 'Cliente não encontrado.'; end if;
end;
$$;


-- ---------------------------------------------------------------------
-- 7. Funções de gravação: pedidos (só a Admin; tudo ou nada)
-- ---------------------------------------------------------------------

-- Cria (p_id vazio) ou edita um pedido, com todos os itens de uma vez.
--
-- p_itens: lista com pelo menos 1 item, na ordem de exibição. Cada item:
--   { "id": uuid do item (só ao editar um item que já existe),
--     "produto_id": uuid (item do catálogo) ou vazio (personalizado),
--     "descricao": texto (só no personalizado; no catálogo o nome é copiado),
--     "preco_unitario": número ≥ 0 com até 2 casas (a tela sugere o preço do catálogo),
--     "quantidade": inteiro ≥ 1,
--     "material_id": uuid do filamento (opcional),
--     "cor_texto": cor livre (só no personalizado, sem filamento) }
-- Itens que existiam e não vêm na lista são removidos (a auditoria guarda).
-- Item que já existe e não teve o produto ou a cor trocados mantém as
-- cópias de nome e cor, mesmo que o produto ou o filamento tenha sido
-- renomeado ou desativado depois.
--
-- Devolve {id, numero}.
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

-- Muda o status entre os quatro ativos, em qualquer direção (R82).
-- Cancelar é outra função, com motivo. Não altera editado_em (P4).
create or replace function public.mudar_status_pedido(p_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_atual  public.vendas;
  v_novo   public.status_pedido_direto;
begin
  perform public.exigir_admin();

  if p_status = 'CANCELADO' then
    raise exception 'Para cancelar, use "Cancelar pedido" e informe o motivo.';
  end if;
  if p_status is null or p_status not in ('AGUARDANDO', 'PRODUZINDO', 'PRONTO', 'ENTREGUE') then
    raise exception 'Status inválido. Use Aguardando, Produzindo, Pronto ou Entregue.';
  end if;
  v_novo := p_status::public.status_pedido_direto;

  select * into v_atual from public.vendas where id = p_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if v_atual.status_pedido = 'CANCELADO' then
    raise exception 'O pedido está cancelado. O cancelamento é definitivo.';
  end if;
  if v_atual.status_pedido = v_novo then
    raise exception 'O pedido já está com esse status.';
  end if;

  update public.vendas set status_pedido = v_novo where id = p_id;
  insert into public.historico_status_pedido (venda_id, status_anterior, status_novo)
  values (p_id, v_atual.status_pedido, v_novo);

  perform public.conferir_pedido(p_id);
end;
$$;

-- Cancela o pedido, a partir de qualquer status ativo, com motivo (R84).
-- Itens e valores ficam preservados e visíveis. Nada é devolvido nem
-- retido automaticamente.
create or replace function public.cancelar_pedido(p_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_atual   public.vendas;
  v_motivo  text := trim(coalesce(p_motivo, ''));
begin
  perform public.exigir_admin();

  if length(v_motivo) = 0 then raise exception 'Informe o motivo do cancelamento.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  select * into v_atual from public.vendas where id = p_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if v_atual.status_pedido = 'CANCELADO' then
    raise exception 'O pedido já está cancelado.';
  end if;

  update public.vendas
     set status_pedido = 'CANCELADO', cancelado_em = now(), motivo_cancelamento = v_motivo
   where id = p_id;
  insert into public.historico_status_pedido (venda_id, status_anterior, status_novo, motivo)
  values (p_id, v_atual.status_pedido, 'CANCELADO', v_motivo);

  perform public.conferir_pedido(p_id);
end;
$$;


-- ---------------------------------------------------------------------
-- 8. Consulta da lista de pedidos
-- ---------------------------------------------------------------------
create view public.vw_pedidos with (security_invoker = true) as
select v.id,
       v.numero,
       '#' || case when v.numero < 10000 then lpad(v.numero::text, 4, '0') else v.numero::text end as numero_formatado,
       v.data,
       v.cliente_id, c.nome as cliente_nome, c.contato as cliente_contato, c.ativo as cliente_ativo,
       v.origem, v.data_prometida, v.forma_pagamento, v.observacao,
       v.subtotal, v.desconto, v.frete, v.total,
       v.status_pedido,
       v.valor_recebido, v.valor_devolvido, (v.valor_recebido - v.valor_devolvido) as valor_liquido,
       v.saldo, v.status_financeiro,
       v.cancelado_em, v.motivo_cancelamento,
       (v.status_pedido in ('ENTREGUE', 'CANCELADO')) as edicao_bloqueada,
       -- Selos de prazo (R81): só em pedido não entregue e não cancelado
       case when v.data_prometida is null or v.status_pedido in ('ENTREGUE', 'CANCELADO') then null
            when v.data_prometida < public.hoje() then 'ATRASADO'
            when v.data_prometida = public.hoje() then 'VENCE_HOJE'
            when v.data_prometida = public.hoje() + 1 then 'VENCE_AMANHA'
       end as selo_prazo,
       (select count(*) from public.itens_venda i where i.venda_id = v.id) as quantidade_itens,
       v.editado_em, v.created_at, v.updated_at
  from public.vendas v
  join public.clientes c on c.id = v.cliente_id;


-- ---------------------------------------------------------------------
-- 9. Segurança: só a Admin lê; gravação só pelas funções acima
-- ---------------------------------------------------------------------
alter table public.clientes                enable row level security;
alter table public.vendas                  enable row level security;
alter table public.itens_venda             enable row level security;
alter table public.historico_status_pedido enable row level security;

revoke all on public.clientes, public.vendas, public.itens_venda, public.historico_status_pedido,
              public.vw_pedidos
  from public, anon, authenticated;
grant select on public.clientes, public.vendas, public.itens_venda, public.historico_status_pedido,
                public.vw_pedidos
  to authenticated;

create policy clientes_select_admin on public.clientes
  for select to authenticated using (public.is_admin());
create policy vendas_select_admin on public.vendas
  for select to authenticated using (public.is_admin());
create policy itens_venda_select_admin on public.itens_venda
  for select to authenticated using (public.is_admin());
create policy historico_status_pedido_select_admin on public.historico_status_pedido
  for select to authenticated using (public.is_admin());

-- Funções internas e de gatilho: fechadas para todos
revoke all on function public.proximo_numero_pedido() from public, anon, authenticated;
revoke all on function public.canal_boca_a_boca() from public, anon, authenticated;
revoke all on function public.recalcular_pedido(uuid) from public, anon, authenticated;
revoke all on function public.conferir_pedido(uuid) from public, anon, authenticated;
revoke all on function public.tg_vendas_protege() from public, anon, authenticated;
revoke all on function public.tg_itens_venda_protege() from public, anon, authenticated;
revoke all on function public.tg_historico_status_imutavel() from public, anon, authenticated;
revoke all on function public.tg_vendas_conferir() from public, anon, authenticated;
revoke all on function public.tg_itens_venda_conferir() from public, anon, authenticated;

-- Funções da Admin: visitante não executa; cada uma exige a Admin
revoke all on function public.salvar_cliente(uuid, text, text) from public, anon;
revoke all on function public.definir_cliente_ativo(uuid, boolean) from public, anon;
revoke all on function public.excluir_cliente(uuid) from public, anon;
revoke all on function public.salvar_pedido(uuid, date, uuid, text, date, text, numeric, numeric, text, jsonb) from public, anon;
revoke all on function public.mudar_status_pedido(uuid, text) from public, anon;
revoke all on function public.cancelar_pedido(uuid, text) from public, anon;

grant execute on function public.salvar_cliente(uuid, text, text) to authenticated;
grant execute on function public.definir_cliente_ativo(uuid, boolean) to authenticated;
grant execute on function public.excluir_cliente(uuid) to authenticated;
grant execute on function public.salvar_pedido(uuid, date, uuid, text, date, text, numeric, numeric, text, jsonb) to authenticated;
grant execute on function public.mudar_status_pedido(uuid, text) to authenticated;
grant execute on function public.cancelar_pedido(uuid, text) to authenticated;

commit;
