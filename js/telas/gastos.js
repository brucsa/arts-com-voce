// Etapa 2 · Gastos e compras (só Admin)
// Regras: R9, R22, R36, R37, R42 a R47.

import { supabase, configurado } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, dataBR, hojeISO } from '../format.js';
import { abrirFormulario } from '../ui/formulario.js';
import { FORMAS, ROTULO_FORMA, SITUACAO, pagoNaHora, intervaloMes, mesAtual } from '../financeiro.js';
import { abrirNovaCompra } from './compra.js';
import { nomeMaterial, quantidade } from '../estoque-util.js';

const NATUREZA_ROT = { DESPESA: 'Despesa', INVESTIMENTO: 'Investimento', ESTOQUE: 'Estoque' };
const filtro = { mes: null, natureza: '', categoria: '' };

export function telaGastos(el) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">Gastos precisam do Supabase configurado.</p></section>';
    return;
  }
  filtro.mes = filtro.mes || mesAtual();
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
      dica: 'Filamento, embalagem e insumos entram pela opção "Nova compra de estoque".' },
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

async function desenhar(area, recarregar) {
  const sb = await supabase();
  const { inicio, fim } = intervaloMes(filtro.mes);

  let consulta = sb.from('vw_gastos').select('*')
    .gte('data', inicio).lte('data', fim)
    .order('data', { ascending: false }).order('created_at', { ascending: false });
  if (filtro.natureza) consulta = consulta.eq('natureza', filtro.natureza);
  if (filtro.categoria) consulta = consulta.eq('categoria_id', filtro.categoria);

  const [gastos, categorias] = await Promise.all([
    consulta.then(ok),
    sb.from('categorias_lanc').select('id, nome, natureza, ativo').order('nome').then(ok),
  ]);

  const ativos = gastos.filter(g => g.status === 'ATIVO');
  const soma = nat => ativos.filter(g => g.natureza === nat).reduce((t, g) => t + Number(g.valor), 0);
  const aPagar = ativos.reduce((t, g) => t + Number(g.valor_a_pagar), 0);

  // Itens das compras de estoque da lista (R49).
  const idsCompras = gastos.filter(g => g.eh_compra).map(g => g.id);
  const lotes = idsCompras.length
    ? await sb.from('vw_lotes').select('lancamento_id, tipo, variacao, quantidade, unidade, status')
        .in('lancamento_id', idsCompras).order('created_at').then(ok)
    : [];
  const itensDe = id => lotes.filter(l => l.lancamento_id === id)
    .map(l => `${esc(nomeMaterial(l))} ${quantidade(l.quantidade, l.unidade)}`).join(' + ');

  area.innerHTML = `
    <section class="cartao filtros">
      <label class="campo campo-compacto"><span>Mês</span>
        <input type="month" name="mes" value="${esc(filtro.mes)}" max="${mesAtual()}"></label>
      <label class="campo campo-compacto"><span>Natureza</span>
        <select name="natureza">
          <option value="">Todas</option>
          <option value="DESPESA" ${filtro.natureza === 'DESPESA' ? 'selected' : ''}>Despesa</option>
          <option value="INVESTIMENTO" ${filtro.natureza === 'INVESTIMENTO' ? 'selected' : ''}>Investimento</option>
          <option value="ESTOQUE" ${filtro.natureza === 'ESTOQUE' ? 'selected' : ''}>Estoque (compras)</option>
        </select></label>
      <label class="campo campo-compacto"><span>Categoria</span>
        <select name="categoria">
          <option value="">Todas</option>
          ${categorias.map(c => `<option value="${c.id}" ${filtro.categoria === c.id ? 'selected' : ''}>${esc(c.nome)}</option>`).join('')}
        </select></label>
    </section>

    <div class="grade-metricas">
      <div class="metrica metrica-neutra"><p class="metrica-rotulo">Despesas</p><p class="metrica-valor">${brl(soma('DESPESA'))}</p></div>
      <div class="metrica metrica-neutra"><p class="metrica-rotulo">Investimentos</p><p class="metrica-valor">${brl(soma('INVESTIMENTO'))}</p></div>
      <div class="metrica metrica-neutra"><p class="metrica-rotulo">Compras de estoque</p><p class="metrica-valor">${brl(soma('ESTOQUE'))}</p>
        <p class="metrica-nota">Não é despesa: vira custo quando o material é usado.</p></div>
      <div class="metrica metrica-espera"><p class="metrica-rotulo">Ainda a pagar</p><p class="metrica-valor">${brl(aPagar)}</p></div>
    </div>

    <section class="cartao">
      <div class="cartao-topo">
        <h3>Gastos e compras do mês</h3>
        <div class="botoes-topo">
          <button class="botao" data-nova-compra><i class="ti ti-shopping-cart-plus" aria-hidden="true"></i> Nova compra de estoque</button>
          <button class="botao botao-primario" data-novo><i class="ti ti-plus" aria-hidden="true"></i> Novo gasto</button>
        </div>
      </div>
      <p class="aviso aviso-ok" role="status" hidden></p>
      ${gastos.length ? `<ul class="lista">${gastos.map(g => {
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
      }).join('')}</ul>` : '<p class="texto-secundario vazio">Nenhum gasto neste mês.</p>'}
    </section>`;

  // Filtros
  area.querySelector('.filtros').addEventListener('change', e => {
    if (e.target.name === 'mes' && !e.target.value) return;
    filtro[e.target.name] = e.target.value;
    recarregar();
  });

  const avisar = texto => {
    const p = document.querySelector('.painel-area .aviso-ok');
    if (p) { p.textContent = texto; p.hidden = false; setTimeout(() => { p.hidden = true; }, 4000); }
  };

  area.querySelector('[data-novo]').addEventListener('click', () => {
    abrirNovoGasto({}, async v => {
      if (v.data.slice(0, 7) !== filtro.mes) filtro.mes = v.data.slice(0, 7);
      await recarregar();
      avisar(v.pago ? 'Gasto registrado e pago.' : 'Gasto registrado como A pagar.');
    });
  });

  area.querySelector('[data-nova-compra]').addEventListener('click', () => {
    abrirNovaCompra({
      async aoConcluir(resultado, cab) {
        if (cab.data.slice(0, 7) !== filtro.mes) filtro.mes = cab.data.slice(0, 7);
        await recarregar();
        avisar(cab.pago ? 'Compra registrada e paga. O estoque já foi atualizado.' : 'Compra registrada como A pagar. O estoque já foi atualizado.');
        await oferecerGastoDosOutros(resultado, cab, async () => { await recarregar(); avisar('Compra e gasto dos outros itens registrados.'); });
      },
    });
  });

  area.querySelector('.lista')?.addEventListener('click', e => {
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
