-- =====================================================================
-- Arts com Você — Sistema de Gestão
-- Etapa 1 · Configurações
--
-- O que este script cria:
--   1. Parâmetros gerais (linha única) e o histórico de alterações
--   2. Canais de venda
--   3. Categorias de gastos (com natureza) e categorias de produtos
--   4. Materiais: filamentos, embalagens e insumos, com unidade de medida
--   5. Segurança: só a Admin lê e altera; o Joca não acessa nada daqui
--   6. Dados iniciais aprovados
--
-- Regras da especificação aplicadas: R2, R12, R16, R27, R34 a R39.
-- Como rodar: Supabase → SQL Editor → colar tudo → Run. Uma única vez.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Tipos
-- ---------------------------------------------------------------------
create type public.natureza_lancamento as enum ('DESPESA', 'ESTOQUE', 'INVESTIMENTO');
create type public.categoria_material  as enum ('FILAMENTO', 'EMBALAGEM', 'INSUMO');

-- Unidades de medida dos materiais (R34). Novas unidades entram com
--   alter type public.unidade_medida add value '...';
-- sem mudar tabelas nem regras.
create type public.unidade_medida as enum ('g', 'kg', 'un', 'ml', 'l', 'cm', 'm');


-- ---------------------------------------------------------------------
-- 2. Parâmetros gerais (linha única)
-- ---------------------------------------------------------------------
create table public.configuracoes (
  id                     smallint primary key default 1 check (id = 1),
  comissao_joca_pct      numeric(5,2)  not null default 10
                         check (comissao_joca_pct >= 0 and comissao_joca_pct <= 100),
  potencia_impressora_w  numeric(8,2)  check (potencia_impressora_w > 0),
  tarifa_kwh             numeric(10,5) check (tarifa_kwh > 0),
  alerta_repasse_dias    integer not null default 15
                         check (alerta_repasse_dias between 1 and 365),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

comment on table public.configuracoes is
  'Parâmetros gerais. Sempre uma única linha (id = 1). Alterações ficam em configuracoes_hist.';

insert into public.configuracoes (id) values (1);

create table public.configuracoes_hist (
  id              bigint generated always as identity primary key,
  campo           text not null,
  valor_anterior  text,
  valor_novo      text,
  usuario         uuid,
  quando          timestamptz not null default now()
);

create index idx_configuracoes_hist_quando on public.configuracoes_hist (quando desc);

-- Potência e tarifa começam vazias; depois de preenchidas não podem voltar a ficar vazias.
create or replace function public.tg_configuracoes_valida()
returns trigger
language plpgsql
as $$
begin
  if old.potencia_impressora_w is not null and new.potencia_impressora_w is null then
    raise exception 'A potência da impressora não pode ficar vazia.';
  end if;
  if old.tarifa_kwh is not null and new.tarifa_kwh is null then
    raise exception 'A tarifa de energia não pode ficar vazia.';
  end if;
  return new;
end;
$$;

-- Registra cada parâmetro alterado: valor anterior, novo, quem e quando.
create or replace function public.tg_configuracoes_hist()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.comissao_joca_pct is distinct from old.comissao_joca_pct then
    insert into public.configuracoes_hist (campo, valor_anterior, valor_novo, usuario)
    values ('comissao_joca_pct', old.comissao_joca_pct::text, new.comissao_joca_pct::text, auth.uid());
  end if;
  if new.potencia_impressora_w is distinct from old.potencia_impressora_w then
    insert into public.configuracoes_hist (campo, valor_anterior, valor_novo, usuario)
    values ('potencia_impressora_w', old.potencia_impressora_w::text, new.potencia_impressora_w::text, auth.uid());
  end if;
  if new.tarifa_kwh is distinct from old.tarifa_kwh then
    insert into public.configuracoes_hist (campo, valor_anterior, valor_novo, usuario)
    values ('tarifa_kwh', old.tarifa_kwh::text, new.tarifa_kwh::text, auth.uid());
  end if;
  if new.alerta_repasse_dias is distinct from old.alerta_repasse_dias then
    insert into public.configuracoes_hist (campo, valor_anterior, valor_novo, usuario)
    values ('alerta_repasse_dias', old.alerta_repasse_dias::text, new.alerta_repasse_dias::text, auth.uid());
  end if;
  return new;
end;
$$;

revoke all on function public.tg_configuracoes_hist() from public, anon, authenticated;

create trigger trg_configuracoes_valida
  before update on public.configuracoes
  for each row execute function public.tg_configuracoes_valida();

create trigger trg_configuracoes_updated_at
  before update on public.configuracoes
  for each row execute function public.tg_updated_at();

create trigger trg_configuracoes_hist
  after update on public.configuracoes
  for each row execute function public.tg_configuracoes_hist();

create trigger trg_configuracoes_auditoria
  after insert or update or delete on public.configuracoes
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 3. Canais de venda (R27)
-- ---------------------------------------------------------------------
create table public.canais (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null check (length(trim(nome)) > 0),
  usa_repasse  boolean not null default false,
  ordem        integer not null default 0,
  ativo        boolean not null default true,
  created_at   timestamptz not null default now(),
  created_by   uuid default auth.uid(),
  updated_at   timestamptz not null default now()
);

create unique index uq_canais_nome on public.canais (lower(trim(nome)));


-- ---------------------------------------------------------------------
-- 4. Categorias
-- ---------------------------------------------------------------------
-- Natureza (R22, R36): pode mudar enquanto a categoria nunca foi usada.
-- A trava após o primeiro lançamento entra junto com a tabela de
-- lançamentos, na Etapa 2.
create table public.categorias_lanc (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null check (length(trim(nome)) > 0),
  natureza    public.natureza_lancamento not null,
  ativo       boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  updated_at  timestamptz not null default now()
);

create unique index uq_categorias_lanc_nome on public.categorias_lanc (lower(trim(nome)));

create table public.categorias_produto (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null check (length(trim(nome)) > 0),
  ativo       boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid default auth.uid(),
  updated_at  timestamptz not null default now()
);

create unique index uq_categorias_produto_nome on public.categorias_produto (lower(trim(nome)));


-- ---------------------------------------------------------------------
-- 5. Materiais (R11, R12, R34)
--    Filamento: tipo (PLA, PETG…) + cor, sempre em gramas.
--    Embalagem: tipo (Caixa, Envelope…) + descrição/tamanho.
--    Insumo:    item (Parafuso, Ímã…) + especificação (M3x10, 10 mm…).
--    A marca fica no lote de compra (Etapa 3), não no material.
-- ---------------------------------------------------------------------
create table public.materiais (
  id              uuid primary key default gen_random_uuid(),
  categoria       public.categoria_material not null,
  tipo            text not null check (length(trim(tipo)) > 0),
  variacao        text,
  unidade         public.unidade_medida not null,
  estoque_minimo  numeric(12,3) check (estoque_minimo >= 0),
  ativo           boolean not null default true,
  created_at      timestamptz not null default now(),
  created_by      uuid default auth.uid(),
  updated_at      timestamptz not null default now(),
  constraint materiais_filamento_em_gramas_com_cor check (
    categoria <> 'FILAMENTO'
    or (unidade = 'g' and variacao is not null and length(trim(variacao)) > 0)
  )
);

create unique index uq_materiais
  on public.materiais (categoria, lower(trim(tipo)), lower(trim(coalesce(variacao, ''))));


-- ---------------------------------------------------------------------
-- 6. updated_at e auditoria dos cadastros
-- ---------------------------------------------------------------------
create trigger trg_canais_updated_at             before update on public.canais             for each row execute function public.tg_updated_at();
create trigger trg_categorias_lanc_updated_at    before update on public.categorias_lanc    for each row execute function public.tg_updated_at();
create trigger trg_categorias_produto_updated_at before update on public.categorias_produto for each row execute function public.tg_updated_at();
create trigger trg_materiais_updated_at          before update on public.materiais          for each row execute function public.tg_updated_at();

create trigger trg_canais_auditoria             after insert or update or delete on public.canais             for each row execute function public.tg_auditoria();
create trigger trg_categorias_lanc_auditoria    after insert or update or delete on public.categorias_lanc    for each row execute function public.tg_auditoria();
create trigger trg_categorias_produto_auditoria after insert or update or delete on public.categorias_produto for each row execute function public.tg_auditoria();
create trigger trg_materiais_auditoria          after insert or update or delete on public.materiais          for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 7. Segurança (RLS): só a Admin. O Joca não acessa nada daqui (R26).
--
--    Excluir x desativar (R37): a Admin pode excluir. Quando as próximas
--    etapas ligarem vendas, compras e produtos a estes cadastros (com
--    "on delete restrict"), o próprio banco vai recusar a exclusão de
--    qualquer cadastro já usado; nesse caso, só é possível desativar.
-- ---------------------------------------------------------------------
alter table public.configuracoes      enable row level security;
alter table public.configuracoes_hist enable row level security;
alter table public.canais             enable row level security;
alter table public.categorias_lanc    enable row level security;
alter table public.categorias_produto enable row level security;
alter table public.materiais          enable row level security;

revoke all on public.configuracoes, public.configuracoes_hist, public.canais,
              public.categorias_lanc, public.categorias_produto, public.materiais
  from anon, authenticated;

grant select, update on public.configuracoes      to authenticated;
grant select         on public.configuracoes_hist to authenticated;
grant select, insert, update, delete
  on public.canais, public.categorias_lanc, public.categorias_produto, public.materiais
  to authenticated;

create policy configuracoes_select_admin on public.configuracoes
  for select to authenticated using (public.is_admin());
create policy configuracoes_update_admin on public.configuracoes
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy configuracoes_hist_select_admin on public.configuracoes_hist
  for select to authenticated using (public.is_admin());

create policy canais_admin on public.canais
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy categorias_lanc_admin on public.categorias_lanc
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy categorias_produto_admin on public.categorias_produto
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy materiais_admin on public.materiais
  for all to authenticated using (public.is_admin()) with check (public.is_admin());


-- ---------------------------------------------------------------------
-- 8. Dados iniciais aprovados
--    Sem categoria de energia elétrica (R35).
--    Categorias de produtos e materiais começam vazias.
-- ---------------------------------------------------------------------
insert into public.canais (nome, usa_repasse, ordem) values
  ('Shopee',        true,  1),
  ('Mercado Livre', true,  2),
  ('Boca a Boca',   false, 3);

insert into public.categorias_lanc (nome, natureza) values
  ('Filamentos',            'ESTOQUE'),
  ('Embalagens',            'ESTOQUE'),
  ('Insumos',               'ESTOQUE'),   -- parafusos, ímãs, argolas… (R34)
  ('Impressora',            'INVESTIMENTO'),
  ('Ferramentas',           'INVESTIMENTO'),
  ('Peças e manutenção',    'DESPESA'),
  ('Projetos/arquivos 3D',  'DESPESA'),
  ('Lâmpadas',              'DESPESA'),
  ('Material de escritório','DESPESA'),
  ('Anúncios',              'DESPESA'),
  ('Taxas',                 'DESPESA'),
  ('Outros',                'DESPESA');


-- =====================================================================
-- Fim da Etapa 1.
-- Próximo passo: rodar sql/02_verificacao.sql (todas as linhas OK).
-- =====================================================================
