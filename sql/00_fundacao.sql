-- =====================================================================
-- Arts com Você — Sistema de Gestão
-- Etapa 0 · Fundação
--
-- O que este script cria:
--   1. Perfis de usuário (ADMIN e JOCA) ligados ao Supabase Auth
--   2. Funções de papel usadas pelas regras de segurança (RLS)
--   3. Gatilho padrão de updated_at
--   4. Tabela e gatilho de auditoria
--   5. Política de privilégios: o papel anônimo não acessa nada
--
-- Como rodar: Supabase → SQL Editor → colar tudo → Run.
-- Pode ser rodado uma única vez em um projeto novo.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Privilégios padrão
--    Por padrão o Supabase concede acesso às tabelas novas para os
--    papéis "anon" e "authenticated". Aqui removemos todo acesso do
--    "anon" (visitante não logado) para tudo que for criado no schema
--    public daqui em diante. O "authenticated" continua dependendo das
--    políticas de RLS de cada tabela.
-- ---------------------------------------------------------------------
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from anon, public;


-- ---------------------------------------------------------------------
-- 1. Perfis
-- ---------------------------------------------------------------------
create type public.papel_usuario as enum ('ADMIN', 'JOCA');

create table public.perfis (
  id          uuid primary key references auth.users (id) on delete restrict,
  nome        text not null check (length(trim(nome)) > 0),
  papel       public.papel_usuario not null,
  ativo       boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.perfis is
  'Um registro por usuário do Auth. Define se a pessoa é ADMIN (Bruna) ou JOCA.';


-- ---------------------------------------------------------------------
-- 2. Funções de papel
--    security definer: leem a tabela perfis sem depender do RLS dela,
--    evitando recursão nas políticas.
-- ---------------------------------------------------------------------
create or replace function public.papel_atual()
returns public.papel_usuario
language sql
stable
security definer
set search_path = public
as $$
  select p.papel
    from public.perfis p
   where p.id = auth.uid()
     and p.ativo
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.papel_atual() = 'ADMIN', false)
$$;

create or replace function public.is_joca()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.papel_atual() = 'JOCA', false)
$$;

revoke all on function public.papel_atual() from public, anon;
revoke all on function public.is_admin()    from public, anon;
revoke all on function public.is_joca()     from public, anon;
grant execute on function public.papel_atual() to authenticated;
grant execute on function public.is_admin()    to authenticated;
grant execute on function public.is_joca()     to authenticated;


-- ---------------------------------------------------------------------
-- 3. Gatilho padrão de updated_at
--    Toda tabela nova das próximas etapas usa:
--      create trigger trg_<tabela>_updated_at
--        before update on public.<tabela>
--        for each row execute function public.tg_updated_at();
-- ---------------------------------------------------------------------
create or replace function public.tg_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_perfis_updated_at
  before update on public.perfis
  for each row execute function public.tg_updated_at();


-- ---------------------------------------------------------------------
-- 4. Auditoria
--    Registra quem alterou o quê, com o antes e o depois.
--    Toda tabela relevante das próximas etapas usa:
--      create trigger trg_<tabela>_auditoria
--        after insert or update or delete on public.<tabela>
--        for each row execute function public.tg_auditoria();
-- ---------------------------------------------------------------------
create table public.auditoria (
  id           bigint generated always as identity primary key,
  tabela       text not null,
  registro_id  text,
  acao         text not null check (acao in ('INSERT', 'UPDATE', 'DELETE')),
  antes        jsonb,
  depois       jsonb,
  usuario      uuid,
  quando       timestamptz not null default now()
);

create index idx_auditoria_tabela_registro on public.auditoria (tabela, registro_id);
create index idx_auditoria_quando          on public.auditoria (quando desc);

comment on table public.auditoria is
  'Histórico de alterações. Preenchida apenas por gatilho; ninguém grava diretamente.';

create or replace function public.tg_auditoria()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_antes  jsonb;
  v_depois jsonb;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    v_antes := to_jsonb(old);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    v_depois := to_jsonb(new);
  end if;

  insert into public.auditoria (tabela, registro_id, acao, antes, depois, usuario)
  values (
    tg_table_name,
    coalesce(v_depois ->> 'id', v_antes ->> 'id'),
    tg_op,
    v_antes,
    v_depois,
    auth.uid()
  );

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.tg_auditoria() from public, anon, authenticated;

create trigger trg_perfis_auditoria
  after insert or update or delete on public.perfis
  for each row execute function public.tg_auditoria();


-- ---------------------------------------------------------------------
-- 5. Segurança (RLS)
-- ---------------------------------------------------------------------

-- perfis: cada pessoa lê o próprio perfil; o Admin lê todos e pode
-- editar nome/ativo. Criar e apagar perfis só pelo SQL Editor.
alter table public.perfis enable row level security;

revoke all on public.perfis from anon, authenticated;
grant select, update on public.perfis to authenticated;

create policy perfis_select_proprio_ou_admin
  on public.perfis
  for select
  to authenticated
  using (id = auth.uid() or public.is_admin());

create policy perfis_update_admin
  on public.perfis
  for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- O Admin não pode tirar o próprio papel de ADMIN nem se desativar
-- por engano (evita ficar trancada fora do sistema).
create or replace function public.tg_perfis_protege_admin()
returns trigger
language plpgsql
as $$
begin
  if old.id = auth.uid()
     and old.papel = 'ADMIN'
     and (new.papel <> 'ADMIN' or new.ativo = false) then
    raise exception 'Você não pode remover o seu próprio acesso de administradora.';
  end if;
  if new.id <> old.id then
    raise exception 'O id do perfil não pode ser alterado.';
  end if;
  return new;
end;
$$;

create trigger trg_perfis_protege_admin
  before update on public.perfis
  for each row execute function public.tg_perfis_protege_admin();

-- auditoria: só o Admin lê; ninguém grava pela API.
alter table public.auditoria enable row level security;

revoke all on public.auditoria from anon, authenticated;
grant select on public.auditoria to authenticated;

create policy auditoria_select_admin
  on public.auditoria
  for select
  to authenticated
  using (public.is_admin());


-- =====================================================================
-- Fim da Etapa 0.
-- Próximo passo: criar os dois usuários (veja sql/01_usuarios.sql).
-- =====================================================================
