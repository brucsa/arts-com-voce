-- =====================================================================
-- Arts com Você · Desinstalar a descrição interna (desfaz sql/21)
--
-- Use só se precisar voltar atrás logo depois de instalar, ANTES de
-- escrever qualquer descrição interna: recusa se já houver alguma. Devolve
-- catalogo_publico à versão do sql/11 (sem o tempo de impressão) e tira a
-- coluna e a função do sql/21. Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if not exists (select 1 from pg_attribute where attrelid = 'public.produtos'::regclass
                   and attname = 'descricao_interna' and not attisdropped) then
    raise exception 'A descrição interna não está instalada. Nada foi alterado.';
  end if;
  if exists (select 1 from public.produtos where descricao_interna is not null) then
    raise exception 'Já existem descrições internas escritas. A desinstalação não é possível. Nada foi alterado.';
  end if;
end;
$$;

-- catalogo_publico: versão do sql/11
drop function public.catalogo_publico();
create function public.catalogo_publico()
returns table (id uuid, nome text, descricao text, preco numeric, sob_consulta boolean, foto_path text, cores text[])
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.nome, p.descricao,
         case when p.personalizado then null else p.preco_venda end,
         (p.personalizado or p.preco_venda is null),
         p.foto_path,
         coalesce((select array_agg(c.cor order by lower(c.cor))
                     from (select distinct on (lower(trim(m.variacao))) trim(m.variacao) as cor
                             from public.produto_cores pc
                             join public.materiais m on m.id = pc.material_id
                            where pc.produto_id = p.id and m.ativo and m.categoria = 'FILAMENTO'
                              and nullif(trim(m.variacao), '') is not null
                            order by lower(trim(m.variacao)), trim(m.variacao)) c), '{}')
    from public.produtos p
   where p.ativo and p.no_catalogo
   order by lower(p.nome), p.id;
$$;

revoke all on function public.catalogo_publico() from public;
grant execute on function public.catalogo_publico() to anon, authenticated;

drop function public.salvar_descricao_interna(uuid, text);
comment on column public.produtos.descricao is null;
alter table public.produtos drop column descricao_interna;

commit;

-- Pronto. Confira com as verificações gerais.
