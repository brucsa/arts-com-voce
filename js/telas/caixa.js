// Etapa 2 · Caixa (só Admin)
// Regras: R23, R42 a R45, R48.

import { supabase, configurado } from '../supabase.js';
import { cliqueForaDoDialogo } from '../ui/dialogo.js';
import { ok } from '../db.js';
import { esc, brl, dataBR, hojeISO, lerValor, paraCampo } from '../format.js';
import { abrirFormulario } from '../ui/formulario.js';
import { ORIGEM, ROTULO_FORMA, intervaloMes, mesAtual, nomeMes } from '../financeiro.js';

let mesExtrato = null;

export function telaCaixa(el) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">O caixa precisa do Supabase configurado.</p></section>';
    return;
  }
  mesExtrato = mesExtrato || mesAtual();
  carregar(el);
}

async function carregar(el) {
  const area = document.createElement('div');
  area.className = 'painel-area';
  area.innerHTML = '<p class="texto-secundario">Carregando…</p>';
  el.replaceChildren(area);
  try {
    await desenhar(area, () => carregar(el));
  } catch (e) {
    area.innerHTML = `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  }
}

async function desenhar(area, recarregar) {
  const sb = await supabase();
  const { inicio, fim } = intervaloMes(mesExtrato);

  const [resumo, aPagar, extrato] = await Promise.all([
    sb.from('vw_caixa_resumo').select('*').single().then(ok),
    sb.from('vw_gastos').select('*').eq('status', 'ATIVO').gt('valor_a_pagar', 0)
      .order('data').order('created_at').then(ok),
    sb.from('vw_extrato_caixa').select('*').gte('data', inicio).lte('data', fim)
      .order('data', { ascending: false }).order('seq', { ascending: false }).then(ok),
  ]);

  const negativo = v => (Number(v) < 0 ? 'valor-negativo' : '');

  area.innerHTML = `
    <div class="grade-metricas">
      <div class="metrica metrica-caixa">
        <p class="metrica-rotulo"><i class="ti ti-wallet" aria-hidden="true"></i> Saldo atual</p>
        <p class="metrica-valor ${negativo(resumo.saldo_atual)}">${brl(resumo.saldo_atual)}</p>
        <p class="metrica-nota">Dinheiro real disponível no caixa.</p>
      </div>
      <div class="metrica metrica-espera">
        <p class="metrica-rotulo"><i class="ti ti-clock" aria-hidden="true"></i> A pagar</p>
        <p class="metrica-valor">${brl(resumo.a_pagar)}</p>
        <p class="metrica-nota">Cartão, boletos e outros gastos ainda não pagos.</p>
      </div>
      <div class="metrica metrica-neutra">
        <p class="metrica-rotulo"><i class="ti ti-scale" aria-hidden="true"></i> Saldo livre</p>
        <p class="metrica-valor ${negativo(resumo.saldo_livre)}">${brl(resumo.saldo_livre)}</p>
        <p class="metrica-nota">Saldo atual − A pagar.</p>
      </div>
    </div>

    <div class="acoes-caixa">
      <button class="botao" data-aporte><i class="ti ti-arrow-down-circle" aria-hidden="true"></i> Aporte</button>
      <button class="botao" data-retirada><i class="ti ti-arrow-up-circle" aria-hidden="true"></i> Retirada</button>
      <button class="botao botao-primario" data-pagar><i class="ti ti-credit-card-pay" aria-hidden="true"></i> Registrar pagamento</button>
    </div>
    <p class="aviso aviso-ok" role="status" hidden></p>

    <section class="cartao">
      <h3>A pagar</h3>
      ${aPagar.length ? `<ul class="lista">${aPagar.map(g => `
        <li class="linha">
          <div class="linha-texto">
            <strong>${esc(g.descricao)}</strong>
            <span class="texto-secundario">${dataBR(g.data)} · ${ROTULO_FORMA[g.forma_pagamento]} · ${esc(g.categoria)}${Number(g.valor_pago) > 0 ? ` · pago ${brl(g.valor_pago)} de ${brl(g.valor)}` : ''}</span>
          </div>
          <span class="linha-valor">${brl(g.valor_a_pagar)}</span>
        </li>`).join('')}</ul>` : '<p class="texto-secundario vazio">Nada a pagar.</p>'}
    </section>

    <section class="cartao">
      <div class="cartao-topo">
        <h3>Extrato de ${esc(nomeMes(mesExtrato))}</h3>
        <label class="campo campo-compacto"><span class="sr-only">Mês do extrato</span>
          <input type="month" name="mes" value="${esc(mesExtrato)}" max="${mesAtual()}"></label>
      </div>
      ${extrato.length ? `<ul class="lista">${extrato.map(m => {
        const entrada = m.tipo === 'ENTRADA';
        const podeEstornar = m.origem !== 'ESTORNO' && !m.estornado;
        return `<li class="linha">
          <div class="linha-texto">
            <strong>${esc(m.descricao)} ${m.estornado ? '<span class="selo-p selo-inativo">Estornado</span>' : ''}</strong>
            <span class="texto-secundario">${dataBR(m.data)} · ${ORIGEM[m.origem]}${m.obs ? ` · ${esc(m.obs)}` : ''}</span>
            <span class="texto-secundario">Saldo depois: ${brl(m.saldo_apos)}</span>
          </div>
          <div class="linha-direita">
            <span class="linha-valor ${entrada ? 'valor-entrada' : 'valor-saida'}">${entrada ? '+' : '−'} ${brl(m.valor)}</span>
            ${podeEstornar ? `<div class="linha-acoes"><button class="botao botao-pequeno botao-perigo" data-estornar="${m.id}">Estornar</button></div>` : ''}
          </div>
        </li>`;
      }).join('')}</ul>` : '<p class="texto-secundario vazio">Nenhum movimento neste mês.</p>'}
    </section>`;

  const avisar = texto => {
    const p = document.querySelector('.painel-area .aviso-ok');
    if (p) { p.textContent = texto; p.hidden = false; setTimeout(() => { p.hidden = true; }, 4000); }
  };

  area.querySelector('[name="mes"]').addEventListener('change', e => {
    if (!e.target.value) return;
    mesExtrato = e.target.value;
    recarregar();
  });

  const formMovimento = (origem) => abrirFormulario({
    titulo: origem === 'APORTE' ? 'Aporte' : 'Retirada',
    textoSalvar: origem === 'APORTE' ? 'Registrar aporte' : 'Registrar retirada',
    valores: { data: hojeISO() },
    campos: [
      { nome: 'data', rotulo: 'Data', tipo: 'data', obrigatorio: true, maxData: hojeISO() },
      { nome: 'valor', rotulo: 'Valor (R$)', tipo: 'decimal', casas: 2, casasMin: 2, obrigatorio: true, maiorQueZero: true, placeholder: '0,00',
        dica: origem === 'APORTE'
          ? 'Dinheiro pessoal colocado na loja. Aumenta o caixa, mas não é faturamento.'
          : 'Dinheiro da loja para uso pessoal. Diminui o caixa, mas não é despesa.' },
      { nome: 'obs', rotulo: 'Observação', tipo: 'texto' },
    ],
    async aoSalvar(v) {
      await sb.rpc('registrar_movimento', { p_origem: origem, p_data: v.data, p_valor: v.valor, p_obs: v.obs }).then(ok);
      await recarregar();
      avisar(origem === 'APORTE' ? 'Aporte registrado.' : 'Retirada registrada.');
    },
  });

  area.querySelector('[data-aporte]').addEventListener('click', () => formMovimento('APORTE'));
  area.querySelector('[data-retirada]').addEventListener('click', () => formMovimento('RETIRADA'));
  area.querySelector('[data-pagar]').addEventListener('click', () => {
    if (!aPagar.length) { window.alert('Não há gastos a pagar.'); return; }
    abrirPagamentoMultiplo(aPagar, async (data, itens) => {
      await sb.rpc('registrar_pagamentos', { p_data: data, p_itens: itens }).then(ok);
      await recarregar();
      avisar(itens.length === 1 ? 'Pagamento registrado.' : `${itens.length} pagamentos registrados.`);
    });
  });

  area.querySelector('.lista [data-estornar]') && area.addEventListener('click', e => {
    const b = e.target.closest('[data-estornar]');
    if (!b) return;
    const m = extrato.find(x => x.id === b.dataset.estornar);
    abrirFormulario({
      titulo: `Estornar: ${m.descricao}`,
      textoSalvar: 'Estornar',
      valores: {},
      campos: [
        { nome: 'motivo', rotulo: 'Motivo do estorno', tipo: 'texto', obrigatorio: true, placeholder: 'Lançado errado',
          dica: `O movimento de ${brl(m.valor)} continua no extrato. O caixa recebe o estorno com a data de hoje.${m.origem === 'PAGAMENTO_GASTO' ? ' O gasto volta a ficar A pagar.' : ''}` },
      ],
      async aoSalvar(v) {
        await sb.rpc('estornar_movimento', { p_movimento_id: m.id, p_motivo: v.motivo }).then(ok);
        await recarregar();
        avisar('Estorno registrado.');
      },
    });
  });
}

// Pagamento de vários gastos na mesma data (fatura do cartão, boletos, parcelas).
function abrirPagamentoMultiplo(gastos, aoSalvar) {
  const dialog = document.createElement('dialog');
  dialog.className = 'folha folha-form';
  dialog.setAttribute('aria-labelledby', 'pag-titulo');
  dialog.innerHTML = `
    <form novalidate>
      <div class="folha-topo">
        <h2 id="pag-titulo">Registrar pagamento</h2>
        <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>
      <div class="campo">
        <label for="pag-data">Data do pagamento</label>
        <input type="date" id="pag-data" name="data" value="${hojeISO()}" max="${hojeISO()}">
        <small class="campo-dica">Os valores marcados saem do caixa nesta data.</small>
      </div>
      <fieldset class="itens-pagamento">
        <legend>Marque os gastos pagos e confira o valor de cada um</legend>
        ${gastos.map((g, i) => `
          <div class="item-pagamento">
            <label class="item-check">
              <input type="checkbox" name="sel" value="${i}">
              <span><strong>${esc(g.descricao)}</strong>
              <small>${dataBR(g.data)} · ${ROTULO_FORMA[g.forma_pagamento]} · falta ${brl(g.valor_a_pagar)}</small></span>
            </label>
            <input type="text" inputmode="decimal" class="item-valor" name="valor-${i}" value="${paraCampo(g.valor_a_pagar, 2, 2)}"
              aria-label="Valor pago de ${esc(g.descricao)}" disabled>
          </div>`).join('')}
      </fieldset>
      <p class="total-pagamento">Total: <strong data-total>${brl(0)}</strong></p>
      <p class="aviso aviso-erro" role="alert" hidden></p>
      <div class="form-acoes">
        <span class="espaco"></span>
        <button type="button" class="botao" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">Registrar</button>
      </div>
    </form>`;
  document.body.appendChild(dialog);

  const form = dialog.querySelector('form');
  const erro = dialog.querySelector('.aviso-erro');
  const fechar = () => { dialog.close(); dialog.remove(); };
  const marcados = () => [...form.querySelectorAll('[name="sel"]:checked')].map(c => Number(c.value));

  function atualizarTotal() {
    const total = marcados().reduce((t, i) => t + (lerValor(form.elements[`valor-${i}`].value) || 0), 0);
    dialog.querySelector('[data-total]').textContent = brl(total);
  }

  // O aviso de erro some enquanto a pessoa digita ou marca (evento input), e não no
  // "change" disparado ao sair do campo: se sumisse aí, o botão mudaria de lugar no
  // meio do clique em Registrar e o clique se perderia.
  form.addEventListener('change', e => {
    if (e.target.name === 'sel') form.elements[`valor-${e.target.value}`].disabled = !e.target.checked;
    atualizarTotal();
  });
  form.addEventListener('input', () => { erro.hidden = true; atualizarTotal(); });
  dialog.addEventListener('click', e => { if (cliqueForaDoDialogo(e, dialog) || e.target.closest('[data-fechar]')) fechar(); });
  dialog.addEventListener('cancel', e => { e.preventDefault(); fechar(); });

  form.addEventListener('submit', async e => {
    e.preventDefault();
    const data = form.elements.data.value;
    const mostrar = t => { erro.textContent = t; erro.hidden = false; };
    if (!data) return mostrar('Escolha a data do pagamento.');
    if (data > hojeISO()) return mostrar('A data do pagamento não pode ser no futuro.');
    const sel = marcados();
    if (!sel.length) return mostrar('Marque pelo menos um gasto.');
    const itens = [];
    for (const i of sel) {
      const v = lerValor(form.elements[`valor-${i}`].value);
      const g = gastos[i];
      if (!Number.isFinite(v) || v <= 0) return mostrar(`Valor inválido em "${g.descricao}".`);
      if (v > Number(g.valor_a_pagar)) return mostrar(`"${g.descricao}": o valor passa do que falta pagar (${brl(g.valor_a_pagar)}).`);
      itens.push({ lancamento_id: g.id, valor: v });
    }
    const botao = form.querySelector('[type="submit"]');
    botao.disabled = true; botao.textContent = 'Aguarde…';
    try {
      await aoSalvar(data, itens);
      fechar();
    } catch (err) {
      mostrar(err.message);
    } finally {
      botao.disabled = false; botao.textContent = 'Registrar';
    }
  });

  dialog.showModal();
}
