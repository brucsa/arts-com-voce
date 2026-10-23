// Etapa 2 · Gastos (só Admin): formulários e ações de despesas, investimentos e compras.
// Regras: R9, R22, R36, R37, R42 a R47, R49. Desde 23/10/2026 não existe mais a tela
// Gastos: tudo aparece no Caixa (A pagar e extrato), que usa as funções daqui.

import { supabase } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, dataBR, hojeISO } from '../format.js';
import { abrirFormulario } from '../ui/formulario.js';
import { FORMAS, ROTULO_FORMA, SITUACAO, pagoNaHora } from '../financeiro.js';
import { nomeMaterial, quantidade } from '../estoque-util.js';

const NATUREZA_ROT = { DESPESA: 'Despesa', INVESTIMENTO: 'Investimento', ESTOQUE: 'Estoque' };

// Campos do formulário de gasto (Despesa e Investimento; compras de estoque têm tela própria, R49).
function camposGasto(categorias, editando) {
  const lista = categorias.filter(c => c.natureza !== 'ESTOQUE' && (c.ativo || c.id === editando?.categoria_id));
  return [
    { nome: 'data', rotulo: 'Data do gasto', tipo: 'data', obrigatorio: true, maxData: hojeISO(),
      dica: 'Data da compra. É ela que conta no resultado do mês.',
      aoMudar: (v, anterior) => { if (v.data_pagamento === anterior) v.data_pagamento = v.data; }, recarrega: !editando },
    { nome: 'descricao', rotulo: 'Descrição', tipo: 'texto', obrigatorio: true, placeholder: 'Anúncio no Instagram' },
    { nome: 'categoria_id', rotulo: 'Categoria', tipo: 'select', obrigatorio: true,
      opcoes: [{ valor: '', rotulo: 'Escolha…' },
        ...lista.map(c => ({ valor: c.id, rotulo: `${NATUREZA_ROT[c.natureza]} · ${c.nome}${c.ativo ? '' : ' (inativa)'}` }))],
      dica: 'Filamento, embalagem e insumos entram por Estoque › Entrada de material.' },
    { nome: 'valor', rotulo: 'Valor (R$)', tipo: 'decimal', casas: 2, casasMin: 2, obrigatorio: true, maiorQueZero: true, placeholder: '0,00',
      dica: editando && Number(editando.valor_pago) > 0 && Number(editando.valor_pago) < Number(editando.valor)
        ? `Já pago: ${brl(editando.valor_pago)}. O valor não pode ficar abaixo disso.` : undefined },
    { nome: 'forma_pagamento', rotulo: 'Forma de pagamento', tipo: 'select', obrigatorio: true, recarrega: true,
      opcoes: FORMAS.map(f => ({ valor: f.valor, rotulo: f.rotulo })),
      aoMudar: v => { if (!editando) v.pago = pagoNaHora(v.forma_pagamento); } },
    ...(editando ? [] : [
      { nome: 'pago', rotulo: 'Já foi pago', tipo: 'checkbox', recarrega: true,
        dica: v => (v.pago
          ? 'O valor sai do caixa na data do pagamento.'
          : 'Fica "A pagar" e não mexe no caixa. Registre o pagamento quando a fatura ou o boleto for pago.') },
      { nome: 'data_pagamento', rotulo: 'Data do pagamento', tipo: 'data', obrigatorio: true, maxData: hojeISO(),
        oculto: v => !v.pago },
    ]),
    { nome: 'fornecedor', rotulo: 'Fornecedor', tipo: 'texto', placeholder: 'Loja ou pessoa' },
    { nome: 'obs', rotulo: 'Observação', tipo: 'texto' },
  ];
}

/** Abre o formulário de novo gasto. prefill permite já trazer valores (ex.: outros itens de um pedido, R51). */
export async function abrirNovoGasto(prefill = {}, aoSalvo = async () => {}) {
  const sb = await supabase();
  const categorias = await sb.from('categorias_lanc').select('id, nome, natureza, ativo').order('nome').then(ok);
  if (!categorias.some(c => c.ativo && c.natureza !== 'ESTOQUE')) {
    window.alert('Cadastre uma categoria de Despesa ou Investimento em Configurações.');
    return;
  }
  abrirFormulario({
    titulo: prefill.titulo || 'Novo gasto',
    valores: { data: hojeISO(), forma_pagamento: 'PIX', pago: true, data_pagamento: hojeISO(), ...prefill },
    campos: camposGasto(categorias, null),
    async aoSalvar(v) {
      await sb.rpc('registrar_gasto', {
        p_data: v.data, p_descricao: v.descricao, p_categoria_id: v.categoria_id, p_valor: v.valor,
        p_forma_pagamento: v.forma_pagamento, p_fornecedor: v.fornecedor, p_obs: v.obs,
        p_pago: v.pago, p_data_pagamento: v.pago ? v.data_pagamento : null,
      }).then(ok);
      await aoSalvo(v);
    },
  });
}

/** Depois de uma compra com outros itens no pedido (R51), oferece lançar o gasto da outra parte já calculado. */
export async function oferecerGastoDosOutros(resultado, cabecalho, aoSalvo) {
  const valor = Number(resultado?.valor_outros_final || 0);
  if (valor <= 0) return false;
  const quer = window.confirm(
    `Compra registrada.\n\nOs outros itens do pedido ficaram com ${brl(valor)} ` +
    '(valor deles mais a parte do frete, menos a parte do desconto).\n\nRegistrar agora esse gasto separado?');
  if (!quer) return false;
  await abrirNovoGasto({
    titulo: 'Gasto dos outros itens do pedido',
    data: cabecalho.data, valor, forma_pagamento: cabecalho.forma, pago: cabecalho.pago,
    data_pagamento: cabecalho.data_pagamento || cabecalho.data, fornecedor: cabecalho.fornecedor,
    descricao: `Outros itens do pedido${cabecalho.fornecedor ? ` (${cabecalho.fornecedor})` : ''}`,
  }, aoSalvo);
  return true;
}

/** Itens das compras de estoque de uma lista (R49): devolve uma função id → texto. */
export async function itensDasCompras(sb, gastos) {
  const ids = gastos.filter(g => g.eh_compra).map(g => g.id);
  const lotes = ids.length
    ? await sb.from('vw_lotes').select('lancamento_id, tipo, variacao, quantidade, unidade, status')
        .in('lancamento_id', ids).order('created_at').then(ok)
    : [];
  return id => lotes.filter(l => l.lancamento_id === id)
    .map(l => `${esc(nomeMaterial(l))} ${quantidade(l.quantidade, l.unidade)}`).join(' + ');
}

/** Lista de gastos ou compras com as ações Pagar, Editar e Cancelar. */
export function htmlListaGastos(gastos, itensDe, vazio) {
  if (!gastos.length) return `<p class="texto-secundario vazio">${vazio}</p>`;
  return `<ul class="lista lista-gastos">${gastos.map(g => {
    const s = SITUACAO[g.situacao];
    const cancelado = g.status === 'CANCELADO';
    return `<li class="linha linha-gasto ${cancelado ? 'inativo' : ''}">
      <div class="linha-texto">
        <strong>${esc(g.descricao)} <span class="selo-p ${s.classe}">${s.rotulo}</span></strong>
        <span class="texto-secundario">${dataBR(g.data)} · ${g.eh_compra ? 'Compra de estoque' : NATUREZA_ROT[g.natureza]} · ${esc(g.categoria)} · ${ROTULO_FORMA[g.forma_pagamento]}${g.fornecedor ? ` · ${esc(g.fornecedor)}` : ''}</span>
        ${g.eh_compra ? `<span class="texto-secundario">Itens: ${itensDe(g.id) || '—'}</span>` : ''}
        ${g.situacao === 'PAGO_EM_PARTE' ? `<span class="texto-secundario">Pago ${brl(g.valor_pago)} de ${brl(g.valor)}</span>` : ''}
        ${cancelado ? `<span class="texto-secundario">Cancelado em ${dataBR(g.cancelado_em)}: ${esc(g.motivo_cancelamento)}</span>` : ''}
      </div>
      <div class="linha-direita">
        <span class="linha-valor ${cancelado ? 'riscado' : ''}">${brl(g.valor)}</span>
        ${cancelado ? '' : `<div class="linha-acoes">
          ${Number(g.valor_a_pagar) > 0 ? `<button class="botao botao-pequeno" data-pagar="${g.id}">Pagar</button>` : ''}
          <button class="botao botao-pequeno" data-editar="${g.id}">Editar</button>
          <button class="botao botao-pequeno botao-perigo" data-cancelar="${g.id}">Cancelar</button>
        </div>`}
      </div>
    </li>`;
  }).join('')}</ul>`;
}

/** Liga as ações da lista (R42 a R47, R49). */
export function ligarAcoesGastos(lista, { sb, gastos, categorias, recarregar, avisar }) {
  lista?.addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    const g = gastos.find(x => x.id === (b.dataset.editar || b.dataset.pagar || b.dataset.cancelar));
    if (!g) return;
    if (b.dataset.editar && g.eh_compra) {
      const travado = g.tem_pagamento;
      abrirFormulario({
        titulo: 'Editar compra de estoque',
        valores: { ...g },
        campos: [
          { nome: 'descricao', rotulo: 'Descrição', tipo: 'texto', obrigatorio: true },
          { nome: 'fornecedor', rotulo: 'Fornecedor', tipo: 'texto' },
          { nome: 'obs', rotulo: 'Observação', tipo: 'texto' },
          { nome: 'data', rotulo: 'Data da compra', tipo: 'data', obrigatorio: true, maxData: hojeISO(),
            fixo: () => (travado ? g.data : undefined),
            dica: travado ? 'Não muda: a compra já tem pagamento registrado.' : 'Também muda a data de entrada no estoque.' },
          { nome: 'forma_pagamento', rotulo: 'Forma de pagamento', tipo: 'select', obrigatorio: true,
            opcoes: FORMAS.map(f => ({ valor: f.valor, rotulo: f.rotulo })),
            fixo: () => (travado ? g.forma_pagamento : undefined),
            dica: travado ? 'Não muda: a compra já tem pagamento registrado.' : undefined },
        ],
        async aoSalvar(v) {
          await sb.rpc('editar_compra', {
            p_id: g.id, p_descricao: v.descricao, p_fornecedor: v.fornecedor, p_obs: v.obs,
            p_data: v.data, p_forma_pagamento: v.forma_pagamento,
          }).then(ok);
          await recarregar();
          avisar('Compra atualizada.');
        },
      });
      return;
    }

    if (b.dataset.editar) {
      abrirFormulario({
        titulo: 'Editar gasto',
        valores: { ...g, valor: Number(g.valor) },
        campos: camposGasto(categorias, g),
        async aoSalvar(v) {
          await sb.rpc('editar_gasto', {
            p_id: g.id, p_data: v.data, p_descricao: v.descricao, p_categoria_id: v.categoria_id, p_valor: v.valor,
            p_forma_pagamento: v.forma_pagamento, p_fornecedor: v.fornecedor, p_obs: v.obs,
          }).then(ok);
          await recarregar();
          avisar('Gasto atualizado.');
        },
      });
    }

    if (b.dataset.pagar) {
      abrirFormulario({
        titulo: `Pagar: ${g.descricao}`,
        textoSalvar: 'Registrar pagamento',
        valores: { data: hojeISO(), valor: Number(g.valor_a_pagar) },
        campos: [
          { nome: 'data', rotulo: 'Data do pagamento', tipo: 'data', obrigatorio: true, maxData: hojeISO(),
            dica: 'O valor sai do caixa nesta data.' },
          { nome: 'valor', rotulo: 'Valor pago (R$)', tipo: 'decimal', casas: 2, casasMin: 2, obrigatorio: true, maiorQueZero: true,
            dica: `Falta pagar ${brl(g.valor_a_pagar)} de ${brl(g.valor)}. Pode pagar só uma parte (parcela).` },
        ],
        async aoSalvar(v) {
          await sb.rpc('registrar_pagamentos', { p_data: v.data, p_itens: [{ lancamento_id: g.id, valor: v.valor }] }).then(ok);
          await recarregar();
          avisar('Pagamento registrado.');
        },
      });
    }

    if (b.dataset.cancelar) {
      abrirFormulario({
        titulo: `Cancelar: ${g.descricao}`,
        textoSalvar: g.eh_compra ? 'Cancelar compra' : 'Cancelar gasto',
        valores: {},
        campos: [
          { nome: 'motivo', rotulo: 'Motivo do cancelamento', tipo: 'texto', obrigatorio: true, placeholder: 'Compra devolvida',
            dica: (g.eh_compra ? 'Os itens saem do estoque (só é possível se o material ainda não foi usado depois desta compra). ' : '') +
              (Number(g.valor_pago) > 0
                ? `Os ${brl(g.valor_pago)} já pagos voltam ao caixa por estorno, com a data de hoje. O registro continua no histórico.`
                : 'O registro continua no histórico, marcado como cancelado.') },
        ],
        async aoSalvar(v) {
          await sb.rpc('cancelar_gasto', { p_id: g.id, p_motivo: v.motivo }).then(ok);
          await recarregar();
          avisar('Gasto cancelado.');
        },
      });
    }
  });
}
