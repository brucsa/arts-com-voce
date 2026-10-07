-- =====================================================================
-- Arts com Você — Etapa 0 · Vincular os usuários aos perfis
--
-- ANTES DE RODAR: troque o e-mail em v_email_admin pelo e-mail da conta da Bruna.
--
-- Liga a conta da Bruna ao papel ADMIN e a outra conta ao papel JOCA.
-- O e-mail do Joca não precisa ser digitado: o script usa a única
-- conta que não é a da Bruna, e para com erro se houver mais ou
-- menos de 2 contas no Auth.
--
-- Pode ser rodado de novo sem duplicar nada.
-- =====================================================================

do $$
declare
  v_email_admin constant text := 'TROQUE-PELO-EMAIL-DA-ADMIN@exemplo.com';
  v_total  int;
  v_admin  uuid;
  v_joca   uuid;
begin
  select count(*) into v_total from auth.users;
  if v_total <> 2 then
    raise exception 'Esperava 2 contas no Authentication, encontrei %. Nada foi alterado.', v_total;
  end if;

  select id into v_admin from auth.users where lower(email) = v_email_admin;
  if v_admin is null then
    raise exception 'Não encontrei a conta % no Authentication. Nada foi alterado.', v_email_admin;
  end if;

  select id into v_joca from auth.users where id <> v_admin;

  insert into public.perfis (id, nome, papel) values (v_admin, 'Bruna', 'ADMIN')
  on conflict (id) do nothing;

  insert into public.perfis (id, nome, papel) values (v_joca, 'Joca', 'JOCA')
  on conflict (id) do nothing;
end
$$;

-- Conferência: deve listar Bruna = ADMIN e Joca = JOCA, ambos ativos.
-- O e-mail do Joca aparece mascarado.
select p.nome,
       p.papel,
       p.ativo,
       case when p.papel = 'ADMIN' then u.email
            else left(u.email, 2) || '•••@' || split_part(u.email, '@', 2)
       end as email
  from public.perfis p
  join auth.users u on u.id = p.id
 order by p.papel;
