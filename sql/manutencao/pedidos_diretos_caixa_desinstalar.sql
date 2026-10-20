-- =====================================================================
-- Arts com Você · DESINSTALAR a integração Pedidos Diretos → Caixa
-- (desfaz sql/10_pedidos_diretos_caixa.sql)
--
-- ⚠ Só rodar com autorização específica da Bruna.
--
-- ⚠ SÓ FUNCIONA SEM MOVIMENTOS DE PEDIDO NO CAIXA: se o Caixa já tiver
--   qualquer movimento de recebimento ou reembolso de pedido (inclusive os
--   da migração), o roteiro recusa e nada é removido. Movimentos do Caixa
--   nunca são apagados.
--
-- O que faz: devolve as funções conferir_pedido, registrar_recebimento,
-- registrar_devolucao, estornar_recebimento, estornar_devolucao (versão do
-- P1-b, sql/08) e estornar_movimento (versão do Caixa, sql/04) ao conteúdo
-- anterior; remove as colunas de ligação e o código de envio, o gatilho e
-- as funções novas. As origens RECEBIMENTO e REEMBOLSO ficam (permanentes).
--
-- Tudo ou nada: se qualquer passo falhar, nada é removido.
-- =====================================================================

begin;

do $$
begin
  if not exists (select 1 from pg_attribute where attrelid = 'public.movimentos_caixa'::regclass
                    and attname = 'recebimento_id' and not attisdropped) then
    raise exception 'A integração com o Caixa não está instalada. Nada foi removido.';
  end if;
  if exists (select 1 from public.movimentos_caixa where origem::text in ('RECEBIMENTO', 'REEMBOLSO')) then
    raise exception 'O Caixa já tem movimentos de pedidos (% movimento(s)). Movimentos do Caixa nunca são apagados; este roteiro não pode ser usado. Nada foi removido.',
      (select count(*) from public.movimentos_caixa where origem::text in ('RECEBIMENTO', 'REEMBOLSO'));
  end if;
  if exists (select 1 from public.recebimentos_venda where chave_envio is not null)
     or exists (select 1 from public.devolucoes_venda where chave_envio is not null) then
    raise exception 'Já existem lançamentos registrados depois da integração. Nada foi removido.';
  end if;
end;
$$;

drop trigger trg_movimentos_caixa_conferir_pedido on public.movimentos_caixa;
drop function public.tg_movimentos_caixa_conferir_pedido();
drop function public.migrar_pedidos_para_caixa();
drop function public.registrar_recebimento(uuid, date, numeric, text, text, boolean, uuid);
drop function public.registrar_devolucao(uuid, date, numeric, text, text, uuid);

-- Funções de volta ao conteúdo anterior (cópia exata de sql/08 e sql/04)
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
    raise exception 'Conferência do pedido #%: o subtotal não bate com a soma dos itens. Nada foi gravado.',
      lpad(v_venda.numero::text, greatest(4, length(v_venda.numero::text)), '0');
  end if;

  select coalesce(sum(valor), 0) into v_rec
    from public.recebimentos_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  select coalesce(sum(valor), 0) into v_dev
    from public.devolucoes_venda where venda_id = p_venda_id and situacao = 'ATIVO';
  if v_venda.valor_recebido <> v_rec or v_venda.valor_devolvido <> v_dev then
    raise exception 'Conferência do pedido #%: o recebido ou o devolvido não bate com os lançamentos ativos. Nada foi gravado.',
      lpad(v_venda.numero::text, greatest(4, length(v_venda.numero::text)), '0');
  end if;
end;
$$;

create or replace function public.registrar_recebimento(
  p_venda_id         uuid,
  p_data             date,
  p_valor            numeric,
  p_forma_pagamento  text,
  p_observacao       text,
  p_confirmado       boolean
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda  public.vendas;
  v_obs    text := nullif(trim(coalesce(p_observacao, '')), '');
  v_id     uuid;
begin
  perform public.exigir_admin();

  if p_confirmado is not true then
    raise exception 'Confirme que o dinheiro foi recebido. Só pagamentos confirmados são registrados.';
  end if;

  select * into v_venda from public.vendas where id = p_venda_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if v_venda.status_pedido = 'CANCELADO' then
    raise exception 'Pedido cancelado não recebe novos pagamentos.';
  end if;
  if v_venda.total = 0 then
    raise exception 'Este pedido não tem cobrança (total R$ 0,00) e não recebe pagamentos.';
  end if;

  if p_valor is null or p_valor <= 0 then raise exception 'Informe um valor maior que zero.'; end if;
  if p_valor <> round(p_valor, 2) then raise exception 'O valor aceita até 2 casas decimais.'; end if;
  if p_valor > v_venda.saldo then
    raise exception 'O valor (R$ %) passa do saldo a receber (R$ %).',
      replace(to_char(p_valor, 'FM9999999990.00'), '.', ','), replace(to_char(v_venda.saldo, 'FM9999999990.00'), '.', ',');
  end if;

  if p_data is null then raise exception 'Informe a data do recebimento.'; end if;
  if p_data < v_venda.data then raise exception 'A data do recebimento não pode ser anterior à data do pedido.'; end if;
  if p_data > public.hoje() then raise exception 'A data do recebimento não pode ser futura.'; end if;

  if p_forma_pagamento is null
     or p_forma_pagamento not in (select unnest(enum_range(null::public.forma_pagamento))::text) then
    raise exception 'Escolha a forma de pagamento.';
  end if;
  if length(coalesce(v_obs, '')) > 500 then raise exception 'A observação pode ter até 500 caracteres.'; end if;

  insert into public.recebimentos_venda (venda_id, data, valor, forma_pagamento, observacao, confirmado_por)
  values (p_venda_id, p_data, p_valor, p_forma_pagamento::public.forma_pagamento, v_obs, auth.uid())
  returning id into v_id;

  perform public.recalcular_pedido(p_venda_id);
  perform public.conferir_pedido(p_venda_id);
  return v_id;
end;
$$;

create or replace function public.registrar_devolucao(
  p_venda_id         uuid,
  p_data             date,
  p_valor            numeric,
  p_forma_pagamento  text,
  p_motivo           text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda    public.vendas;
  v_liquido  numeric;
  v_motivo   text := trim(coalesce(p_motivo, ''));
  v_id       uuid;
begin
  perform public.exigir_admin();

  select * into v_venda from public.vendas where id = p_venda_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  v_liquido := v_venda.valor_recebido - v_venda.valor_devolvido;

  if p_valor is null or p_valor <= 0 then raise exception 'Informe um valor maior que zero.'; end if;
  if p_valor <> round(p_valor, 2) then raise exception 'O valor aceita até 2 casas decimais.'; end if;
  if v_liquido <= 0 then raise exception 'Não há valor recebido para devolver neste pedido.'; end if;
  if p_valor > v_liquido then
    raise exception 'A devolução (R$ %) passa do valor líquido recebido (R$ %).',
      replace(to_char(p_valor, 'FM9999999990.00'), '.', ','), replace(to_char(v_liquido, 'FM9999999990.00'), '.', ',');
  end if;

  if p_data is null then raise exception 'Informe a data da devolução.'; end if;
  if p_data < v_venda.data then raise exception 'A data da devolução não pode ser anterior à data do pedido.'; end if;
  if p_data > public.hoje() then raise exception 'A data da devolução não pode ser futura.'; end if;

  if p_forma_pagamento is null
     or p_forma_pagamento not in (select unnest(enum_range(null::public.forma_pagamento))::text) then
    raise exception 'Escolha a forma da devolução.';
  end if;
  if length(v_motivo) = 0 then raise exception 'Informe o motivo da devolução.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  insert into public.devolucoes_venda (venda_id, data, valor, forma_pagamento, motivo)
  values (p_venda_id, p_data, p_valor, p_forma_pagamento::public.forma_pagamento, v_motivo)
  returning id into v_id;

  perform public.recalcular_pedido(p_venda_id);
  perform public.conferir_pedido(p_venda_id);
  return v_id;
end;
$$;

create or replace function public.estornar_recebimento(p_recebimento_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda_id  uuid;
  v_venda     public.vendas;
  v_rec       public.recebimentos_venda;
  v_motivo    text := trim(coalesce(p_motivo, ''));
begin
  perform public.exigir_admin();

  if length(v_motivo) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  -- Trava primeiro o pedido, depois o lançamento (mesma ordem em todas as funções)
  select venda_id into v_venda_id from public.recebimentos_venda where id = p_recebimento_id;
  if v_venda_id is null then raise exception 'Recebimento não encontrado.'; end if;
  select * into v_venda from public.vendas where id = v_venda_id for update;
  select * into v_rec from public.recebimentos_venda where id = p_recebimento_id for update;

  if v_rec.situacao = 'ESTORNADO' then raise exception 'Este recebimento já foi estornado.'; end if;
  if v_venda.valor_recebido - v_rec.valor < v_venda.valor_devolvido then
    raise exception 'Estornar este recebimento deixaria as devoluções (R$ %) maiores que o recebido (R$ %). Estorne antes a devolução correspondente, se ela também foi lançada por engano.',
      replace(to_char(v_venda.valor_devolvido, 'FM9999999990.00'), '.', ','),
      replace(to_char(v_venda.valor_recebido - v_rec.valor, 'FM9999999990.00'), '.', ',');
  end if;

  update public.recebimentos_venda
     set situacao = 'ESTORNADO', estornado_em = now(), motivo_estorno = v_motivo
   where id = p_recebimento_id;

  perform public.recalcular_pedido(v_venda_id);
  perform public.conferir_pedido(v_venda_id);
end;
$$;

create or replace function public.estornar_devolucao(p_devolucao_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venda_id  uuid;
  v_venda     public.vendas;
  v_dev       public.devolucoes_venda;
  v_motivo    text := trim(coalesce(p_motivo, ''));
  v_liquido   numeric;
begin
  perform public.exigir_admin();

  if length(v_motivo) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  if length(v_motivo) > 500 then raise exception 'O motivo pode ter até 500 caracteres.'; end if;

  select venda_id into v_venda_id from public.devolucoes_venda where id = p_devolucao_id;
  if v_venda_id is null then raise exception 'Devolução não encontrada.'; end if;
  select * into v_venda from public.vendas where id = v_venda_id for update;
  select * into v_dev from public.devolucoes_venda where id = p_devolucao_id for update;

  if v_dev.situacao = 'ESTORNADO' then raise exception 'Esta devolução já foi estornada.'; end if;
  v_liquido := v_venda.valor_recebido - v_venda.valor_devolvido + v_dev.valor;
  if v_venda.status_pedido <> 'CANCELADO' and v_liquido > v_venda.total then
    raise exception 'Estornar esta devolução deixaria o valor líquido recebido (R$ %) acima do total do pedido (R$ %).',
      replace(to_char(v_liquido, 'FM9999999990.00'), '.', ','), replace(to_char(v_venda.total, 'FM9999999990.00'), '.', ',');
  end if;

  update public.devolucoes_venda
     set situacao = 'ESTORNADO', estornado_em = now(), motivo_estorno = v_motivo
   where id = p_devolucao_id;

  perform public.recalcular_pedido(v_venda_id);
  perform public.conferir_pedido(v_venda_id);
end;
$$;

create or replace function public.estornar_movimento(p_movimento_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mov public.movimentos_caixa;
begin
  perform public.exigir_admin();
  if p_motivo is null or length(trim(p_motivo)) = 0 then raise exception 'Informe o motivo do estorno.'; end if;
  select * into v_mov from public.movimentos_caixa where id = p_movimento_id for update;
  if not found then raise exception 'Movimento não encontrado.'; end if;
  if v_mov.origem = 'PAGAMENTO_GASTO' then
    perform public.estornar_pagamento_interno(v_mov.pagamento_id, trim(p_motivo), public.hoje());
    return;
  end if;
  if v_mov.origem not in ('APORTE', 'RETIRADA') then raise exception 'Este movimento não pode ser estornado.'; end if;
  if exists (select 1 from public.movimentos_caixa where movimento_estornado_id = p_movimento_id) then
    raise exception 'Este movimento já foi estornado.';
  end if;

  insert into public.movimentos_caixa (data, tipo, origem, valor, descricao, movimento_estornado_id, obs)
  values (public.hoje(),
          case when v_mov.tipo = 'ENTRADA' then 'SAIDA'::public.tipo_movimento else 'ENTRADA'::public.tipo_movimento end,
          'ESTORNO', v_mov.valor, 'Estorno: ' || v_mov.descricao, v_mov.id, trim(p_motivo));
end;
$$;

drop function public.numero_pedido_texto(integer);

alter table public.movimentos_caixa
  drop constraint movimentos_caixa_origem_pedido,
  drop column recebimento_id,
  drop column devolucao_id;
alter table public.recebimentos_venda drop column chave_envio;
alter table public.devolucoes_venda   drop column chave_envio;

-- Permissões como no P1-b e no Caixa
revoke all on function public.conferir_pedido(uuid) from public, anon, authenticated;
revoke all on function public.registrar_recebimento(uuid, date, numeric, text, text, boolean) from public, anon;
revoke all on function public.registrar_devolucao(uuid, date, numeric, text, text) from public, anon;
revoke all on function public.estornar_recebimento(uuid, text) from public, anon;
revoke all on function public.estornar_devolucao(uuid, text) from public, anon;
revoke all on function public.estornar_movimento(uuid, text) from public, anon;
grant execute on function public.registrar_recebimento(uuid, date, numeric, text, text, boolean) to authenticated;
grant execute on function public.registrar_devolucao(uuid, date, numeric, text, text) to authenticated;
grant execute on function public.estornar_recebimento(uuid, text) to authenticated;
grant execute on function public.estornar_devolucao(uuid, text) to authenticated;
grant execute on function public.estornar_movimento(uuid, text) to authenticated;

commit;
