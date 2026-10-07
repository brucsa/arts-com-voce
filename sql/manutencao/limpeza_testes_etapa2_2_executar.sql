-- =====================================================================
-- Arts com Você — Manutenção única, antes do uso real do financeiro
-- Limpeza dos testes da Etapa 2 · PARTE 2: EXECUTAR
--
-- Apaga SOMENTE o histórico financeiro do roteiro de testes da Etapa 2:
--   gastos "TESTE" cancelados, seus pagamentos, os movimentos de caixa
--   (aporte, retirada, pagamentos e estornos) e os registros de
--   auditoria dessas três tabelas.
--
-- NÃO toca em: parâmetros, histórico de parâmetros, canais, categorias,
-- materiais, perfis/usuários nem na auditoria deles.
--
-- Tudo acontece num único bloco: se qualquer conferência falhar,
-- NADA é apagado (o banco desfaz tudo automaticamente).
--
-- Esta é uma exceção única à regra R45 ("nada é apagado"), aprovada
-- para começar a operação real com o histórico limpo. Depois do início
-- do uso real, não rode este script.
-- =====================================================================

do $$
declare
  v_gastos      int;
  v_pagamentos  int;
  v_movimentos  int;
  v_auditoria   int;
  v_saldo       numeric;
  v_a_pagar     numeric;
  v_problema    text;
  -- Para conferir que nada fora do financeiro foi tocado:
  v_antes_config  bigint;
  v_antes_outros  text;
  v_depois_outros text;
begin
  -- ---------------------------------------------------------------- 1. Conferências ANTES
  select saldo_atual, a_pagar into v_saldo, v_a_pagar from public.vw_caixa_resumo;
  if coalesce(v_saldo, 0) <> 0 or coalesce(v_a_pagar, 0) <> 0 then
    raise exception 'Limpeza cancelada: o caixa não está zerado (saldo %, a pagar %). Nada foi apagado.', v_saldo, v_a_pagar;
  end if;

  select string_agg(descricao || ' (' || status || ')', ', ') into v_problema
    from public.lancamentos
   where descricao not ilike '%TESTE%' or status <> 'CANCELADO';
  if v_problema is not null then
    raise exception 'Limpeza cancelada: existem gastos que não são TESTE cancelados: %. Nada foi apagado.', v_problema;
  end if;

  select string_agg(origem || ' de R$ ' || replace(to_char(valor, 'FM999999990.00'), '.', ',') || ' em ' || to_char(data, 'DD/MM/YYYY'), ', ') into v_problema
    from public.movimentos_caixa m
   where m.origem in ('APORTE', 'RETIRADA')
     and not exists (select 1 from public.movimentos_caixa e where e.movimento_estornado_id = m.id);
  if v_problema is not null then
    raise exception 'Limpeza cancelada: existe aporte/retirada sem estorno, que pode ser dinheiro real: %. Nada foi apagado.', v_problema;
  end if;

  -- Todo movimento precisa ser: aporte/retirada estornado, pagamento de gasto TESTE, ou estorno de um desses.
  select string_agg(m.origem || ' de R$ ' || replace(to_char(m.valor, 'FM999999990.00'), '.', ','), ', ') into v_problema
    from public.movimentos_caixa m
   where not (
         (m.origem in ('APORTE', 'RETIRADA'))
      or (m.origem = 'PAGAMENTO_GASTO' and exists (
            select 1 from public.pagamentos_lancamento p join public.lancamentos l on l.id = p.lancamento_id
             where p.id = m.pagamento_id and l.descricao ilike '%TESTE%'))
      or (m.origem = 'ESTORNO' and m.movimento_estornado_id is not null)
   );
  if v_problema is not null then
    raise exception 'Limpeza cancelada: movimentos que não são do teste: %. Nada foi apagado.', v_problema;
  end if;

  -- Fotografia do que NÃO pode mudar.
  select count(*) into v_antes_config from public.configuracoes_hist;
  select concat_ws('|',
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.configuracoes t),
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.canais t),
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.categorias_lanc t),
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.categorias_produto t),
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.materiais t),
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.perfis t),
           (select count(*)::text from public.auditoria
             where tabela not in ('lancamentos', 'pagamentos_lancamento', 'movimentos_caixa')))
    into v_antes_outros;

  select count(*) into v_gastos from public.lancamentos;
  select count(*) into v_pagamentos from public.pagamentos_lancamento;
  select count(*) into v_movimentos from public.movimentos_caixa;

  -- ---------------------------------------------------------------- 2. Apagar (ordem das dependências)
  delete from public.movimentos_caixa where origem = 'ESTORNO';        -- estornos apontam para outros movimentos
  delete from public.movimentos_caixa;                                  -- pagamentos, aportes e retiradas
  delete from public.pagamentos_lancamento;
  delete from public.lancamentos;
  -- Auditoria só destas três tabelas (inclui as linhas geradas pelos DELETEs acima).
  delete from public.auditoria
   where tabela in ('lancamentos', 'pagamentos_lancamento', 'movimentos_caixa');
  get diagnostics v_auditoria = row_count;

  -- ---------------------------------------------------------------- 3. Conferências DEPOIS
  if exists (select 1 from public.lancamentos)
     or exists (select 1 from public.pagamentos_lancamento)
     or exists (select 1 from public.movimentos_caixa) then
    raise exception 'Limpeza desfeita: sobrou algum registro financeiro. Nada foi apagado.';
  end if;

  select saldo_atual, a_pagar into v_saldo, v_a_pagar from public.vw_caixa_resumo;
  if coalesce(v_saldo, 0) <> 0 or coalesce(v_a_pagar, 0) <> 0 then
    raise exception 'Limpeza desfeita: o caixa não ficou zerado. Nada foi apagado.';
  end if;

  select concat_ws('|',
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.configuracoes t),
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.canais t),
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.categorias_lanc t),
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.categorias_produto t),
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.materiais t),
           (select md5(coalesce(string_agg(t::text, ',' order by t.id), '')) from public.perfis t),
           (select count(*)::text from public.auditoria
             where tabela not in ('lancamentos', 'pagamentos_lancamento', 'movimentos_caixa')))
    into v_depois_outros;

  if v_depois_outros is distinct from v_antes_outros
     or (select count(*) from public.configuracoes_hist) <> v_antes_config then
    raise exception 'Limpeza desfeita: algum dado fora do financeiro mudaria. Nada foi apagado.';
  end if;

  raise notice 'Limpeza concluída: % gastos, % pagamentos, % movimentos de caixa e % registros de auditoria removidos. Saldo R$ 0,00 e A pagar R$ 0,00. Configurações, canais, categorias, materiais e usuários intactos.',
    v_gastos, v_pagamentos, v_movimentos, v_auditoria;
end
$$;

-- Resultado final para conferir na tela (deve mostrar zeros).
select (select count(*) from public.lancamentos)           as gastos,
       (select count(*) from public.pagamentos_lancamento) as pagamentos,
       (select count(*) from public.movimentos_caixa)      as movimentos_caixa,
       saldo_atual, a_pagar, saldo_livre
  from public.vw_caixa_resumo;
