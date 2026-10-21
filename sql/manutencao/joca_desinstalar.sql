-- =====================================================================
-- Arts com Você · Desinstalar a área do Joca (desfaz sql/13)
--
-- Use só se precisar voltar atrás, ANTES de qualquer pagamento ao Joca.
-- Recusa se houver pagamento ao Joca (o Caixa nunca apaga movimentos).
-- Remove as comissões, o percentual congelado dos pedidos, as funções e as
-- consultas da área do Joca e devolve estornar_movimento à versão da
-- integração com o Caixa (sql/10). Não mexe em pedidos nem no Caixa.
-- A origem PAGAMENTO_JOCA (sql/12) continua na lista: é permanente.
-- Tudo ou nada.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('public.comissoes_joca') is null then
    raise exception 'A área do Joca não está instalada. Nada foi alterado.';
  end if;
  if exists (select 1 from public.pagamentos_joca) or exists (select 1 from public.movimentos_caixa where origem::text = 'PAGAMENTO_JOCA') then
    raise exception 'Já existe pagamento ao Joca. A desinstalação não é possível, porque os movimentos do Caixa nunca são apagados. Nada foi alterado.';
  end if;
end;
$$;

drop trigger if exists trg_vendas_comissao_joca on public.vendas;
drop trigger if exists trg_movimentos_caixa_conferir_joca on public.movimentos_caixa;
alter table public.movimentos_caixa drop constraint movimentos_caixa_origem_joca, drop column pagamento_joca_id;

drop view if exists public.vw_joca_pedidos;
drop function if exists public.joca_resumo();
drop function if exists public.joca_extrato();
drop function if exists public.migrar_comissoes_joca();
drop function if exists public.registrar_pagamento_joca(date, numeric, text, text, uuid);
drop function if exists public.estornar_pagamento_joca(uuid, text);
drop function if exists public.joca_totais();

-- Tabelas: as proteções impedem apagar linhas, então saem inteiras.
drop table public.pagamentos_joca;
drop table public.comissoes_joca;
drop table public.comissao_joca_pedido;
drop type public.tipo_comissao_joca;

drop function if exists public.tg_vendas_comissao_joca();
drop function if exists public.sincronizar_comissao_joca(uuid, text);
drop function if exists public.percentual_joca_em(date);
drop function if exists public.conferir_pagamento_joca(uuid);
drop function if exists public.tg_pagamentos_joca_conferir();
drop function if exists public.tg_movimentos_caixa_conferir_joca();
drop function if exists public.tg_comissoes_joca_protege();
drop function if exists public.tg_pagamentos_joca_protege();

-- estornar_movimento volta à versão da integração com o Caixa (sql/10).
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
  if v_mov.origem in ('RECEBIMENTO', 'REEMBOLSO') then
    raise exception 'Este movimento vem de um Pedido Direto. Para corrigir, estorne o lançamento no próprio pedido (Pedidos › Diretos).';
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

revoke all on function public.estornar_movimento(uuid, text) from public, anon;
grant execute on function public.estornar_movimento(uuid, text) to authenticated;

-- O histórico da auditoria dessas tabelas fica guardado.

commit;
