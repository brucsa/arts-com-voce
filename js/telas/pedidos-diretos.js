// Pedidos Diretos Essencial (só Admin) · aba "Diretos" da tela Pedidos.
// Regras: especificação v1.4, R76–R84 (P1-a e P1-b instalados no banco).
// Toda gravação passa pelas funções do banco (salvar_cliente, salvar_pedido,
// mudar_status_pedido, cancelar_pedido, registrar_recebimento,
// registrar_devolucao, estornar_recebimento, estornar_devolucao). As regras
// valem no banco; aqui a tela só ajuda e mostra as mensagens dele.
// Não mexe no Caixa, no estoque nem na comissão do Joca.

import { supabase, configurado } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, dataBR, dataHoraBR, hojeISO, lerDecimal, paraCampo, arred2 } from '../format.js';
import { cliqueForaDoDialogo } from '../ui/dialogo.js';
import { abrirFormulario } from '../ui/formulario.js';
import { FORMAS, ROTULO_FORMA } from '../financeiro.js';

// ---------------------------------------------------------------- nomes
export const STATUS = {
  AGUARDANDO: { rotulo: 'Aguardando', classe: 'selo-pd-aguardando' },
  PRODUZINDO: { rotulo: 'Produzindo', classe: 'selo-pd-produzindo' },
  PRONTO: { rotulo: 'Pronto', classe: 'selo-pd-pronto' },
  ENTREGUE: { rotulo: 'Entregue', classe: 'selo-pd-entregue' },
  CANCELADO: { rotulo: 'Cancelado', classe: 'selo-pd-cancelado' },
};
const ATIVOS = ['AGUARDANDO', 'PRODUZINDO', 'PRONTO', 'ENTREGUE'];
const EDITAVEIS = ['AGUARDANDO', 'PRODUZINDO', 'PRONTO'];

// R78: lista exclusiva dos Pedidos Diretos Essencial.
export const ORIGENS = [
  { valor: 'WHATSAPP', rotulo: 'WhatsApp' },
  { valor: 'INSTAGRAM', rotulo: 'Instagram' },
  { valor: 'PESSOALMENTE', rotulo: 'Pessoalmente' },
  { valor: 'OUTRO', rotulo: 'Outro' },
];
const ROTULO_ORIGEM = Object.fromEntries(ORIGENS.map(o => [o.valor, o.rotulo]));

const FINANCEIRO = {
  A_RECEBER: { rotulo: 'A receber', classe: 'selo-despesa' },
  RECEBIDO: { rotulo: 'Recebido', classe: 'selo-ativo' },
  SEM_COBRANCA: { rotulo: 'Sem cobrança', classe: 'selo-inativo' },
  CANCELADO: { rotulo: 'Cancelado', classe: 'selo-inativo' },
};
const PRAZO = {
  ATRASADO: { rotulo: 'Atrasado', classe: 'selo-pd-atrasado' },
  VENCE_HOJE: { rotulo: 'Vence hoje', classe: 'selo-despesa' },
  VENCE_AMANHA: { rotulo: 'Vence amanhã', classe: 'selo-investimento' },
};

const selo = (mapa, chave) => (mapa[chave] ? `<span class="selo-p ${mapa[chave].classe}">${esc(mapa[chave].rotulo)}</span>` : '');
const normal = s => String(s || '').trim().toLocaleLowerCase('pt-BR').normalize('NFD').replace(/[̀-ͯ]/g, '');
const num = v => Number(v || 0);
const numeroPedido = n => `#${String(n).padStart(4, '0')}`;
const corDoFilamento = f => `${f.tipo} · ${f.variacao ?? f.cor}`;

const filtro = { busca: '', status: '' };

// ---------------------------------------------------------------- dados
async function carregarCadastros(sb) {
  const [clientes, produtos, filamentos] = await Promise.all([
    sb.from('clientes').select('id, nome, contato, ativo').order('nome').then(ok),
    sb.from('vw_produtos').select('id, nome, preco_venda, ativo, cores').order('nome').then(ok),
    sb.from('materiais').select('id, tipo, variacao, ativo').eq('categoria', 'FILAMENTO')
      .order('tipo').order('variacao').then(ok),
  ]);
  return { clientes, produtos, filamentos };
}

// ---------------------------------------------------------------- aba Diretos
/**
 * Desenha a lista de pedidos diretos em `el`.
 * opcoes.abrir: id de um pedido para abrir o detalhe logo depois de carregar.
 */
export function telaPedidosDiretos(el, opcoes = {}) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">Os pedidos diretos precisam do Supabase configurado.</p></section>';
    return;
  }
  carregar(el, opcoes.mensagem, opcoes.abrir);
}

async function carregar(el, mensagem, abrirId) {
  const area = document.createElement('div');
  area.className = 'painel-area';
  area.innerHTML = '<p class="texto-secundario">Carregando…</p>';
  el.replaceChildren(area);
  try {
    await desenhar(area, (msg, id) => carregar(el, msg, id), mensagem, abrirId);
  } catch (e) {
    area.innerHTML = `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  }
}

async function desenhar(area, recarregar, mensagem, abrirId) {
  const sb = await supabase();
  const [pedidos, cadastros] = await Promise.all([
    sb.from('vw_pedidos').select('*').order('numero', { ascending: false }).then(ok),
    carregarCadastros(sb),
  ]);
  const ctx = { sb, ...cadastros, recarregar };

  area.innerHTML = `
    <section class="cartao filtros filtros-produtos">
      <label class="campo campo-compacto"><span>Buscar por cliente ou número</span>
        <input type="search" name="busca" value="${esc(filtro.busca)}" placeholder="Ex.: Ana ou 12" autocomplete="off"></label>
      <label class="campo campo-compacto"><span>Status</span>
        <select name="status">
          <option value="">Todos</option>
          <option value="ANDAMENTO" ${filtro.status === 'ANDAMENTO' ? 'selected' : ''}>Em andamento</option>
          ${Object.entries(STATUS).map(([k, s]) => `<option value="${k}" ${filtro.status === k ? 'selected' : ''}>${s.rotulo}</option>`).join('')}
        </select></label>
      <div class="filtros-acao">
        <button type="button" class="botao botao-primario" data-novo>
          <i class="ti ti-plus" aria-hidden="true"></i> Novo pedido</button>
      </div>
    </section>
    <p class="aviso aviso-ok" role="status" ${mensagem ? '' : 'hidden'}>${esc(mensagem || '')}</p>
    <p class="texto-secundario contagem-produtos" data-contagem aria-live="polite"></p>
    <div data-lista></div>`;

  const listaEl = area.querySelector('[data-lista]');
  const contagemEl = area.querySelector('[data-contagem]');

  function mostrar() {
    const termo = normal(filtro.busca);
    const termoNumero = termo.replace(/^#/, '').replace(/^0+(?=\d)/, '');
    const lista = pedidos.filter(p => {
      if (filtro.status === 'ANDAMENTO' && !EDITAVEIS.includes(p.status_pedido)) return false;
      if (filtro.status && filtro.status !== 'ANDAMENTO' && p.status_pedido !== filtro.status) return false;
      if (!termo) return true;
      return normal(p.cliente_nome).includes(termo) || (/^\d+$/.test(termoNumero) && String(p.numero) === termoNumero);
    });
    contagemEl.textContent = pedidos.length ? `${lista.length} de ${pedidos.length} pedido(s)` : '';

    if (!pedidos.length) {
      listaEl.innerHTML = `<section class="cartao vazio-produtos">
        <i class="ti ti-clipboard-list" aria-hidden="true"></i>
        <h3>Nenhum pedido direto ainda</h3>
        <p class="texto-secundario">Cadastre o primeiro com o botão <strong>Novo pedido</strong>.</p>
      </section>`;
      return;
    }
    if (!lista.length) {
      listaEl.innerHTML = '<p class="texto-secundario vazio">Nenhum pedido encontrado com esse filtro.</p>';
      return;
    }
    listaEl.innerHTML = `<section class="cartao cartao-pedidos"><ul class="lista">${lista.map(linhaPedido).join('')}</ul></section>`;
  }

  area.querySelector('.filtros').addEventListener('input', e => {
    if (!e.target.name) return;
    filtro[e.target.name] = e.target.value;
    mostrar();
  });
  area.querySelector('[data-novo]').addEventListener('click', () => abrirFormularioPedido(ctx, null));
  listaEl.addEventListener('click', e => {
    const b = e.target.closest('[data-pedido]');
    if (b) abrirDetalhe(ctx, b.dataset.pedido);
  });
  mostrar();
  if (abrirId) abrirDetalhe(ctx, abrirId);
}

function textoSaldo(p) {
  if (p.status_pedido === 'CANCELADO') return '';   // o selo de status já diz "Cancelado"
  if (p.status_financeiro === 'A_RECEBER') {
    return `<span class="valor-alerta">Falta ${brl(p.saldo)}</span>`;
  }
  return selo(FINANCEIRO, p.status_financeiro);
}

function linhaPedido(p) {
  const prazo = p.data_prometida ? ` · Prazo ${dataBR(p.data_prometida)}` : '';
  return `<li class="linha linha-pedido">
    <button type="button" class="pedido-botao" data-pedido="${p.id}">
      <span class="linha-texto">
        <strong>${esc(p.numero_formatado)} · ${esc(p.cliente_nome)}</strong>
        <span class="texto-secundario">${dataBR(p.data)} · ${p.quantidade_itens} item(ns)${prazo}</span>
        <span class="pedido-selos">${selo(STATUS, p.status_pedido)} ${selo(PRAZO, p.selo_prazo)}</span>
      </span>
      <span class="linha-direita pedido-valores">
        <strong class="linha-valor">${brl(p.total)}</strong>
        <span class="pedido-saldo">${textoSaldo(p)}</span>
      </span>
    </button>
  </li>`;
}

// ---------------------------------------------------------------- folhas
function abrirFolha(html, { rotulo, larga = true }) {
  const dialog = document.createElement('dialog');
  dialog.className = `folha folha-form${larga ? ' folha-produto' : ''}`;
  dialog.setAttribute('aria-labelledby', rotulo);
  dialog.innerHTML = html;
  document.body.appendChild(dialog);
  const fechar = () => { dialog.close(); dialog.remove(); };
  dialog.addEventListener('click', e => {
    if (cliqueForaDoDialogo(e, dialog) || e.target.closest('[data-fechar]')) fechar();
  });
  dialog.addEventListener('cancel', e => { e.preventDefault(); fechar(); });
  dialog.showModal();
  return { dialog, fechar };
}

/** Pede um motivo obrigatório (cancelamento e estornos), com o botão "Voltar". */
function abrirMotivo({ titulo, explicacao, rotulo = 'Motivo', textoSalvar, aoSalvar }) {
  const { dialog, fechar } = abrirFolha(`
    <form novalidate>
      <div class="folha-topo">
        <h2 id="motivo-titulo">${esc(titulo)}</h2>
        <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>
      <p class="texto-secundario">${explicacao}</p>
      <div class="campo"><label for="m-motivo">${esc(rotulo)}</label>
        <textarea id="m-motivo" name="motivo" rows="3" maxlength="500" required></textarea>
        <small class="campo-erro" hidden data-erro-campo></small></div>
      <p class="aviso aviso-erro" role="alert" hidden></p>
      <div class="form-acoes">
        <span class="espaco"></span>
        <button type="button" class="botao" data-fechar>Voltar</button>
        <button type="submit" class="botao botao-primario">${esc(textoSalvar)}</button>
      </div>
    </form>`, { rotulo: 'motivo-titulo', larga: false });
  const form = dialog.querySelector('form');
  const erro = dialog.querySelector('.aviso-erro');
  const erroCampo = dialog.querySelector('[data-erro-campo]');
  form.motivo.focus();
  form.addEventListener('submit', async e => {
    e.preventDefault();
    const motivo = form.motivo.value.trim();
    erro.hidden = true;
    if (!motivo) { erroCampo.textContent = 'Informe o motivo.'; erroCampo.hidden = false; return; }
    erroCampo.hidden = true;
    const botao = form.querySelector('[type=submit]');
    botao.disabled = true;
    try {
      await aoSalvar(motivo);
      fechar();
    } catch (err) {
      erro.textContent = err.message; erro.hidden = false; botao.disabled = false;
    }
  });
}

// ---------------------------------------------------------------- detalhe
async function abrirDetalhe(ctx, id) {
  const { sb, recarregar } = ctx;
  let p, itens, historico, recebimentos, devolucoes;
  try {
    [[p], itens, historico, recebimentos, devolucoes] = await Promise.all([
      sb.from('vw_pedidos').select('*').eq('id', id).then(ok),
      sb.from('itens_venda').select('*').eq('venda_id', id).order('ordem').then(ok),
      sb.from('historico_status_pedido').select('*').eq('venda_id', id).order('quando').then(ok),
      sb.from('recebimentos_venda').select('*').eq('venda_id', id).order('data').order('confirmado_em').then(ok),
      sb.from('devolucoes_venda').select('*').eq('venda_id', id).order('data').order('created_at').then(ok),
    ]);
  } catch (e) {
    window.alert(e.message);
    return;
  }
  if (!p) return;

  const cancelado = p.status_pedido === 'CANCELADO';
  const liquido = num(p.valor_liquido);
  const podeReceber = !cancelado && num(p.total) > 0 && num(p.saldo) > 0;
  const podeDevolver = liquido > 0;
  const linha = (rotulo, valor, classe = '') => (valor ? `<div class="linha-dado ${classe}"><span>${rotulo}</span><strong>${valor}</strong></div>` : '');

  const itensHtml = itens.map(i => `
    <li class="linha">
      <span class="linha-texto">
        <strong>${i.quantidade} × ${esc(i.descricao)}</strong>
        <span class="texto-secundario">${i.cor_descricao ? `${esc(i.cor_descricao)} · ` : ''}${i.produto_id ? 'Do catálogo' : 'Personalizado'} · ${num(i.preco_unitario) === 0 ? 'Brinde' : `${brl(i.preco_unitario)} cada`}</span>
      </span>
      <strong class="linha-valor">${brl(i.valor_item)}</strong>
    </li>`).join('');

  const lancamentos = [
    ...recebimentos.map(r => ({ ...r, tipo: 'recebimento' })),
    ...devolucoes.map(d => ({ ...d, tipo: 'devolucao' })),
  ].sort((a, b) => (a.data === b.data ? String(a.created_at).localeCompare(String(b.created_at)) : a.data.localeCompare(b.data)));

  const pagamentosHtml = lancamentos.length ? lancamentos.map(l => {
    const estornado = l.situacao === 'ESTORNADO';
    const nome = l.tipo === 'recebimento' ? 'Recebimento' : 'Devolução';
    const extra = l.tipo === 'devolucao' ? ` · ${esc(l.motivo)}` : (l.observacao ? ` · ${esc(l.observacao)}` : '');
    return `<li class="linha ${estornado ? 'inativo' : ''}">
      <span class="linha-texto">
        <strong>${nome} ${estornado ? '<span class="selo-p selo-inativo">Estornado</span>' : ''}</strong>
        <span class="texto-secundario">${dataBR(l.data)} · ${esc(ROTULO_FORMA[l.forma_pagamento] || l.forma_pagamento)}${extra}</span>
        ${estornado ? `<span class="texto-secundario">Estornado em ${dataHoraBR(l.estornado_em)}: ${esc(l.motivo_estorno)}</span>` : ''}
      </span>
      <span class="linha-direita">
        <strong class="linha-valor ${estornado ? 'riscado' : (l.tipo === 'devolucao' ? 'valor-saida' : 'valor-entrada')}">${l.tipo === 'devolucao' ? '− ' : ''}${brl(l.valor)}</strong>
        ${estornado ? '' : `<button type="button" class="botao botao-pequeno" data-estornar="${l.tipo}:${l.id}">Estornar</button>`}
      </span>
    </li>`;
  }).join('') : '<li class="texto-secundario vazio">Nenhum pagamento registrado.</li>';

  const historicoHtml = historico.map(h => `
    <li><span>${h.status_anterior
      ? `${esc(STATUS[h.status_anterior].rotulo)} → <strong>${esc(STATUS[h.status_novo].rotulo)}</strong>`
      : `Pedido criado em <strong>${esc(STATUS[h.status_novo].rotulo)}</strong>`}${h.motivo ? ` · ${esc(h.motivo)}` : ''}</span>
      <span class="historico-quando">${dataHoraBR(h.quando)}</span></li>`).join('');

  const statusHtml = cancelado
    ? `<p class="aviso aviso-atencao">Pedido cancelado em ${dataHoraBR(p.cancelado_em)}: ${esc(p.motivo_cancelamento)}. O cancelamento é definitivo.</p>`
    : `<div class="status-escolha" role="group" aria-label="Mudar status">
        ${ATIVOS.map(s => `<button type="button" class="botao botao-pequeno ${s === p.status_pedido ? 'status-atual' : ''}"
          data-status="${s}" aria-pressed="${s === p.status_pedido}" ${s === p.status_pedido ? 'disabled' : ''}>${STATUS[s].rotulo}</button>`).join('')}
      </div>
      ${p.status_pedido === 'ENTREGUE' ? '<p class="campo-dica">Pedido entregue não pode ser editado. Para corrigir, volte o status para Pronto. Pagamentos continuam podendo ser registrados.</p>' : ''}`;

  const { dialog, fechar } = abrirFolha(`
    <div class="folha-topo">
      <h2 id="det-pedido">Pedido ${esc(p.numero_formatado)}</h2>
      <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
    </div>
    <p class="pedido-selos">${selo(STATUS, p.status_pedido)} ${cancelado ? '' : selo(FINANCEIRO, p.status_financeiro)} ${selo(PRAZO, p.selo_prazo)}</p>
    <p class="aviso aviso-erro" role="alert" hidden></p>

    <div class="detalhe-produto">
      <div class="detalhe-dados">
        ${linha('Cliente', `${esc(p.cliente_nome)}${p.cliente_ativo ? '' : ' (inativo)'}`)}
        ${linha('Contato', esc(p.cliente_contato || ''))}
        ${linha('Data do pedido', dataBR(p.data))}
        ${linha('Prazo de entrega', p.data_prometida ? dataBR(p.data_prometida) : '')}
        ${linha('Origem', esc(ROTULO_ORIGEM[p.origem] || p.origem))}
        ${linha('Forma combinada', p.forma_pagamento ? esc(ROTULO_FORMA[p.forma_pagamento]) : '')}
        ${p.observacao ? `<p class="detalhe-titulo">Observação</p><p class="detalhe-descricao">${esc(p.observacao)}</p>` : ''}
      </div>
      <div class="detalhe-dados">
        ${linha('Subtotal', brl(p.subtotal))}
        ${num(p.desconto) ? linha('Desconto', `− ${brl(p.desconto)}`) : ''}
        ${num(p.frete) ? linha('Frete', brl(p.frete)) : ''}
        ${linha('Total', brl(p.total), 'linha-destaque')}
        ${linha('Recebido', brl(p.valor_recebido))}
        ${num(p.valor_devolvido) ? linha('Devolvido', `− ${brl(p.valor_devolvido)}`) : ''}
        ${linha('Saldo a receber', brl(p.saldo), 'linha-destaque')}
        <p class="campo-dica">Valores ainda fora do Caixa. Não lance estes recebimentos no Caixa como aporte.</p>
      </div>
    </div>

    <p class="detalhe-titulo">Itens</p>
    <ul class="lista">${itensHtml}</ul>

    <p class="detalhe-titulo">Status</p>
    ${statusHtml}

    <div class="form-acoes acoes-pedido">
      ${podeReceber ? '<button type="button" class="botao botao-primario" data-receber><i class="ti ti-cash" aria-hidden="true"></i> Registrar recebimento</button>' : ''}
      ${podeDevolver ? '<button type="button" class="botao" data-devolver><i class="ti ti-arrow-back-up" aria-hidden="true"></i> Registrar devolução</button>' : ''}
      ${EDITAVEIS.includes(p.status_pedido) ? '<button type="button" class="botao" data-editar><i class="ti ti-pencil" aria-hidden="true"></i> Editar pedido</button>' : ''}
      ${cancelado ? '' : '<button type="button" class="botao botao-perigo" data-cancelar>Cancelar pedido</button>'}
    </div>

    <p class="detalhe-titulo">Pagamentos e devoluções</p>
    <ul class="lista">${pagamentosHtml}</ul>

    <p class="detalhe-titulo">Histórico de status</p>
    <ul class="historico">${historicoHtml}</ul>
    <p class="campo-dica nota-rodape">Criado em ${dataHoraBR(p.created_at)}${p.editado_em ? ` · Última edição em ${dataHoraBR(p.editado_em)}` : ''}</p>
  `, { rotulo: 'det-pedido' });

  const erro = dialog.querySelector('.aviso-erro');
  const falhar = msg => { erro.textContent = msg; erro.hidden = false; erro.scrollIntoView({ block: 'nearest' }); };
  const depois = async msg => { fechar(); await recarregar(msg, p.id); };

  dialog.querySelectorAll('[data-status]').forEach(b => b.addEventListener('click', async () => {
    dialog.querySelectorAll('[data-status]').forEach(x => { x.disabled = true; });
    try {
      await sb.rpc('mudar_status_pedido', { p_id: p.id, p_status: b.dataset.status }).then(ok);
      await depois(`Pedido ${p.numero_formatado}: status mudou para ${STATUS[b.dataset.status].rotulo}.`);
    } catch (err) {
      falhar(err.message);
      dialog.querySelectorAll('[data-status]').forEach(x => { x.disabled = x.dataset.status === p.status_pedido; });
    }
  }));

  dialog.querySelector('[data-editar]')?.addEventListener('click', () => {
    fechar();
    abrirFormularioPedido(ctx, { pedido: p, itens });
  });

  dialog.querySelector('[data-cancelar]')?.addEventListener('click', () => abrirMotivo({
    titulo: `Cancelar pedido ${p.numero_formatado}`,
    explicacao: 'O cancelamento é definitivo. Itens, valores, pagamentos e históricos ficam guardados. '
      + 'Nada é devolvido nem retido automaticamente: se houver devolução de dinheiro, registre-a depois.',
    rotulo: 'Motivo do cancelamento',
    textoSalvar: 'Cancelar pedido',
    async aoSalvar(motivo) {
      await sb.rpc('cancelar_pedido', { p_id: p.id, p_motivo: motivo }).then(ok);
      await depois(`Pedido ${p.numero_formatado} cancelado.`);
    },
  }));

  dialog.querySelector('[data-receber]')?.addEventListener('click', () => abrirFormulario({
    titulo: `Registrar recebimento · ${p.numero_formatado}`,
    textoSalvar: 'Registrar recebimento',
    valores: { data: hojeISO(), valor: num(p.saldo), forma: p.forma_pagamento || 'PIX', confirmado: false },
    campos: [
      { nome: 'valor', rotulo: 'Valor recebido (R$)', tipo: 'decimal', casas: 2, casasMin: 2, obrigatorio: true, maiorQueZero: true,
        dica: `Saldo a receber: ${brl(p.saldo)}. Sinal e pagamento parcial são aceitos.` },
      { nome: 'data', rotulo: 'Data do recebimento', tipo: 'data', obrigatorio: true, maxData: hojeISO(),
        dica: `Entre ${dataBR(p.data)} (data do pedido) e hoje.` },
      { nome: 'forma', rotulo: 'Forma de pagamento', tipo: 'select', obrigatorio: true,
        opcoes: FORMAS.map(f => ({ valor: f.valor, rotulo: f.rotulo })) },
      { nome: 'observacao', rotulo: 'Observação', tipo: 'texto', placeholder: 'Ex.: sinal' },
      { nome: 'confirmado', rotulo: 'Confirmo que este valor já foi recebido', tipo: 'checkbox',
        dica: 'Só registre dinheiro que realmente entrou.' },
    ],
    async aoSalvar(v) {
      if (!v.confirmado) throw new Error('Marque a confirmação: só registre valores realmente recebidos.');
      await sb.rpc('registrar_recebimento', {
        p_venda_id: p.id, p_data: v.data, p_valor: v.valor, p_forma_pagamento: v.forma,
        p_observacao: v.observacao, p_confirmado: true,
      }).then(ok);
      await depois(`Recebimento de ${brl(v.valor)} registrado no pedido ${p.numero_formatado}.`);
    },
  }));

  dialog.querySelector('[data-devolver]')?.addEventListener('click', () => abrirFormulario({
    titulo: `Registrar devolução · ${p.numero_formatado}`,
    textoSalvar: 'Registrar devolução',
    valores: { data: hojeISO(), forma: p.forma_pagamento || 'PIX' },
    campos: [
      { nome: 'valor', rotulo: 'Valor devolvido ao cliente (R$)', tipo: 'decimal', casas: 2, casasMin: 2, obrigatorio: true, maiorQueZero: true,
        dica: `Até ${brl(liquido)} (o que já foi recebido, menos devoluções). A devolução não gera nova cobrança.` },
      { nome: 'data', rotulo: 'Data da devolução', tipo: 'data', obrigatorio: true, maxData: hojeISO() },
      { nome: 'forma', rotulo: 'Forma da devolução', tipo: 'select', obrigatorio: true,
        opcoes: FORMAS.map(f => ({ valor: f.valor, rotulo: f.rotulo })) },
      { nome: 'motivo', rotulo: 'Motivo', tipo: 'texto', obrigatorio: true, placeholder: 'Ex.: desconto combinado depois do pagamento' },
    ],
    async aoSalvar(v) {
      await sb.rpc('registrar_devolucao', {
        p_venda_id: p.id, p_data: v.data, p_valor: v.valor, p_forma_pagamento: v.forma, p_motivo: v.motivo,
      }).then(ok);
      await depois(`Devolução de ${brl(v.valor)} registrada no pedido ${p.numero_formatado}.`);
    },
  }));

  dialog.querySelectorAll('[data-estornar]').forEach(b => b.addEventListener('click', () => {
    const [tipo, lid] = b.dataset.estornar.split(':');
    const l = lancamentos.find(x => x.id === lid && x.tipo === tipo);
    const nome = tipo === 'recebimento' ? 'recebimento' : 'devolução';
    abrirMotivo({
      titulo: `Estornar ${nome} de ${brl(l.valor)}`,
      explicacao: `Use só para corrigir um lançamento feito por engano (${dataBR(l.data)}). `
        + 'O registro continua visível no histórico e deixa de contar nos valores do pedido.',
      rotulo: 'Motivo do estorno',
      textoSalvar: 'Estornar',
      async aoSalvar(motivo) {
        if (tipo === 'recebimento') {
          await sb.rpc('estornar_recebimento', { p_recebimento_id: lid, p_motivo: motivo }).then(ok);
        } else {
          await sb.rpc('estornar_devolucao', { p_devolucao_id: lid, p_motivo: motivo }).then(ok);
        }
        await depois(`Estorno registrado no pedido ${p.numero_formatado}.`);
      },
    });
  }));
}

// ---------------------------------------------------------------- formulário do pedido
/**
 * Abre o formulário de novo pedido (sem "existente") ou de edição.
 * Usado pela aba Diretos e pelo atalho "Novo pedido" do botão ＋.
 */
export async function abrirNovoPedido({ aoConcluir } = {}) {
  const sb = await supabase();
  const cadastros = await carregarCadastros(sb);
  abrirFormularioPedido({ sb, ...cadastros, recarregar: async (msg, id) => aoConcluir?.(msg, id) }, null);
}

function abrirFormularioPedido(ctx, existente) {
  const { sb, clientes, produtos, filamentos, recarregar } = ctx;
  const p = existente?.pedido || null;
  const editando = !!p;
  const hoje = hojeISO();

  const clientesOpcoes = clientes.filter(c => c.ativo || c.id === p?.cliente_id);
  const opcaoCliente = c => `<option value="${c.id}" ${c.id === p?.cliente_id ? 'selected' : ''}>${esc(c.nome)}${c.contato ? ` · ${esc(c.contato)}` : ''}${c.ativo ? '' : ' (inativo)'}</option>`;

  const { dialog, fechar } = abrirFolha(`
    <form novalidate>
      <div class="folha-topo">
        <h2 id="form-pedido">${editando ? `Editar pedido ${esc(p.numero_formatado)}` : 'Novo pedido'}</h2>
        <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>
      ${editando ? '' : '<p class="campo-dica nota-form">O número do pedido é criado automaticamente ao salvar.</p>'}

      <div class="form-produto">
        <fieldset class="itens-compra">
          <legend>Cliente</legend>
          <div class="campo"><label for="pd-cliente">Cliente</label>
            <select id="pd-cliente" name="cliente">
              <option value="">Escolha o cliente</option>
              ${clientesOpcoes.map(opcaoCliente).join('')}
              <option value="__novo">+ Cadastrar novo cliente</option>
            </select>
            <small class="campo-erro" data-erro="cliente" hidden></small></div>
          <div class="grade-dois" data-novo-cliente hidden>
            <div class="campo"><label for="pd-cli-nome">Nome do cliente</label>
              <input type="text" id="pd-cli-nome" name="cliNome" maxlength="150" autocomplete="off">
              <small class="campo-erro" data-erro="cliNome" hidden></small></div>
            <div class="campo"><label for="pd-cli-contato">Contato <em>(opcional)</em></label>
              <input type="text" id="pd-cli-contato" name="cliContato" maxlength="200" autocomplete="off" placeholder="Telefone, @ ou e-mail"></div>
            <small class="campo-dica campo-aviso-nome" data-aviso-cliente hidden></small>
          </div>
        </fieldset>

        <div class="grade-produto">
          <div class="campo"><label for="pd-origem">Origem</label>
            <select id="pd-origem" name="origem">
              <option value="">Escolha a origem</option>
              ${ORIGENS.map(o => `<option value="${o.valor}" ${o.valor === p?.origem ? 'selected' : ''}>${o.rotulo}</option>`).join('')}
            </select>
            <small class="campo-erro" data-erro="origem" hidden></small></div>
          <div class="campo"><label for="pd-forma">Forma de pagamento combinada <em>(opcional)</em></label>
            <select id="pd-forma" name="forma">
              <option value="">Não combinada</option>
              ${FORMAS.map(f => `<option value="${f.valor}" ${f.valor === p?.forma_pagamento ? 'selected' : ''}>${f.rotulo}</option>`).join('')}
            </select>
            <small class="campo-dica">Não é pagamento: os recebimentos são registrados depois, no pedido.</small></div>
          <div class="campo"><label for="pd-data">Data do pedido</label>
            <input type="date" id="pd-data" name="data" value="${esc(p?.data || hoje)}" max="${hoje}">
            <small class="campo-erro" data-erro="data" hidden></small></div>
          <div class="campo"><label for="pd-prazo">Prazo de entrega <em>(opcional)</em></label>
            <input type="date" id="pd-prazo" name="prazo" value="${esc(p?.data_prometida || '')}">
            <small class="campo-erro" data-erro="prazo" hidden></small></div>
        </div>

        <fieldset class="itens-compra">
          <legend>Itens</legend>
          <div class="itens-pedido" data-itens></div>
          <small class="campo-erro" data-erro="itens" hidden></small>
          <div><button type="button" class="botao botao-pequeno" data-add-item><i class="ti ti-plus" aria-hidden="true"></i> Adicionar item</button></div>
        </fieldset>

        <div class="grade-dois">
          <div class="campo"><label for="pd-desconto">Desconto (R$)</label>
            <input type="text" inputmode="decimal" id="pd-desconto" name="desconto" value="${num(p?.desconto) ? paraCampo(p.desconto, 2, 2) : ''}" placeholder="0,00" autocomplete="off">
            <small class="campo-erro" data-erro="desconto" hidden></small></div>
          <div class="campo"><label for="pd-frete">Frete (R$)</label>
            <input type="text" inputmode="decimal" id="pd-frete" name="frete" value="${num(p?.frete) ? paraCampo(p.frete, 2, 2) : ''}" placeholder="0,00" autocomplete="off">
            <small class="campo-erro" data-erro="frete" hidden></small></div>
        </div>

        <div class="resumo-compra" data-resumo aria-live="polite"></div>

        <div class="campo"><label for="pd-obs">Observações <em>(opcional)</em></label>
          <textarea id="pd-obs" name="obs" rows="3" maxlength="2000">${esc(p?.observacao || '')}</textarea></div>
      </div>

      <p class="aviso aviso-erro" role="alert" hidden></p>
      <div class="form-acoes">
        <span class="espaco"></span>
        <button type="button" class="botao" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">${editando ? 'Salvar alterações' : 'Salvar pedido'}</button>
      </div>
    </form>`, { rotulo: 'form-pedido' });

  const form = dialog.querySelector('form');
  const itensEl = dialog.querySelector('[data-itens]');
  const resumoEl = dialog.querySelector('[data-resumo]');
  const erroGeral = dialog.querySelector('.aviso-erro');
  const novoClienteEl = dialog.querySelector('[data-novo-cliente]');
  const avisoCliente = dialog.querySelector('[data-aviso-cliente]');

  const erroCampo = (nome, texto) => {
    const el = dialog.querySelector(`[data-erro="${nome}"]`);
    if (el) { el.textContent = texto || ''; el.hidden = !texto; }
  };

  // ---- cliente novo e aviso de repetidos (R77: avisa, não bloqueia)
  function atualizarCliente() {
    const novo = form.cliente.value === '__novo';
    novoClienteEl.hidden = !novo;
    if (novo) form.cliNome.focus();
    avisarRepetido();
  }
  function avisarRepetido() {
    const nome = normal(form.cliNome.value);
    const contato = normal(form.cliContato.value);
    const iguais = form.cliente.value === '__novo' ? clientes.filter(c =>
      (nome && normal(c.nome) === nome) || (contato && normal(c.contato) === contato)) : [];
    avisoCliente.hidden = !iguais.length;
    avisoCliente.textContent = iguais.length
      ? `Já existe cliente com esse nome ou contato: ${iguais.map(c => c.nome + (c.contato ? ` (${c.contato})` : '') + (c.ativo ? '' : ' — inativo')).join(', ')}. Se for a mesma pessoa, escolha na lista.`
      : '';
  }
  form.cliente.addEventListener('change', atualizarCliente);
  form.cliNome.addEventListener('input', avisarRepetido);
  form.cliContato.addEventListener('input', avisarRepetido);

  // ---- itens
  const produtoPorId = id => produtos.find(x => x.id === id);
  const filamentoPorId = id => filamentos.find(x => x.id === id);

  function htmlItem(item = {}) {
    // Item já salvo: é do catálogo só se tiver produto. Item novo: começa no
    // catálogo quando há produto ativo; senão, como personalizado.
    const catalogo = item.id ? !!item.produto_id : produtos.some(x => x.ativo);
    const prod = produtoPorId(item.produto_id);
    const produtosOpcoes = produtos.filter(x => x.ativo || x.id === item.produto_id);
    const coresProduto = prod ? prod.cores : [];
    const corAtualFora = item.material_id && catalogo && !coresProduto.some(c => c.material_id === item.material_id);
    const filamentosOpcoes = filamentos.filter(f => f.ativo || f.id === item.material_id);
    const corTextoLivre = !catalogo && !item.material_id && item.cor_descricao;
    return `
      <div class="item-compra item-pedido" data-item ${item.id ? `data-id="${item.id}"` : ''}>
        <div class="campo"><label>Tipo</label>
          <select data-tipo>
            <option value="catalogo" ${catalogo ? 'selected' : ''}>Do catálogo</option>
            <option value="personalizado" ${catalogo ? '' : 'selected'}>Personalizado</option>
          </select></div>

        <div class="campo" data-so="catalogo" ${catalogo ? '' : 'hidden'}><label>Produto</label>
          <select data-produto>
            <option value="">Escolha o produto</option>
            ${produtosOpcoes.map(x => `<option value="${x.id}" ${x.id === item.produto_id ? 'selected' : ''}>${esc(x.nome)}${x.ativo ? '' : ' (inativo)'}</option>`).join('')}
          </select></div>
        <div class="campo" data-so="catalogo" ${catalogo ? '' : 'hidden'}><label>Cor <em>(opcional)</em></label>
          <select data-cor-catalogo>
            <option value="">Sem cor definida</option>
            ${corAtualFora ? `<option value="${item.material_id}" selected>${esc(item.cor_descricao)} (cor anterior)</option>` : ''}
            ${coresProduto.map(c => `<option value="${c.material_id}" ${c.material_id === item.material_id ? 'selected' : ''}>${esc(corDoFilamento(c))}${c.ativo ? '' : ' (inativo)'}</option>`).join('')}
          </select></div>

        <div class="campo" data-so="personalizado" ${catalogo ? 'hidden' : ''}><label>Descrição</label>
          <input type="text" data-descricao maxlength="150" value="${esc(!catalogo ? item.descricao || '' : '')}" placeholder="Ex.: Chaveiro com nome" autocomplete="off"></div>
        <div class="campo" data-so="personalizado" ${catalogo ? 'hidden' : ''}><label>Cor <em>(opcional)</em></label>
          <select data-cor-personalizado>
            <option value="">Sem cor definida</option>
            ${filamentosOpcoes.map(f => `<option value="${f.id}" ${!catalogo && f.id === item.material_id ? 'selected' : ''}>${esc(corDoFilamento(f))}${f.ativo ? '' : ' (inativo)'}</option>`).join('')}
            <option value="__texto" ${corTextoLivre ? 'selected' : ''}>Outra cor (escrever)</option>
          </select>
          <input type="text" data-cor-texto maxlength="80" value="${esc(corTextoLivre ? item.cor_descricao : '')}" placeholder="Ex.: dourado" autocomplete="off" ${corTextoLivre ? '' : 'hidden'}
            aria-label="Cor escrita"></div>

        <div class="campo"><label>Quantidade</label>
          <input type="text" inputmode="numeric" data-qtd value="${item.quantidade ?? 1}" autocomplete="off"></div>
        <div class="campo"><label>Preço unitário (R$)</label>
          <input type="text" inputmode="decimal" data-preco value="${item.preco_unitario != null ? paraCampo(item.preco_unitario, 2, 2) : ''}" placeholder="0,00" autocomplete="off"></div>

        <div class="item-compra-rodape">
          <span class="texto-secundario" data-valor-item></span>
          <button type="button" class="botao-texto" data-remover><i class="ti ti-trash" aria-hidden="true"></i> Remover item</button>
        </div>
        <small class="campo-erro" data-erro-item hidden></small>
      </div>`;
  }

  function adicionarItem(item) {
    itensEl.insertAdjacentHTML('beforeend', htmlItem(item));
    atualizarResumo();
  }

  /** Lê um item da tela. Devolve { item, erro, valor }. */
  function lerItem(el, n) {
    const tipo = el.querySelector('[data-tipo]').value;
    const qtdTxt = el.querySelector('[data-qtd]').value.trim();
    const precoTxt = el.querySelector('[data-preco]').value.trim();
    const qtd = /^\d{1,6}$/.test(qtdTxt) ? Number(qtdTxt) : NaN;
    const preco = precoTxt === '' ? NaN : lerDecimal(precoTxt, 2);
    const item = { quantidade: qtd, preco_unitario: preco };
    if (el.dataset.id) item.id = el.dataset.id;
    let erro = '';
    if (tipo === 'catalogo') {
      item.produto_id = el.querySelector('[data-produto]').value || null;
      item.material_id = el.querySelector('[data-cor-catalogo]').value || null;
      if (!item.produto_id) erro = `Item ${n}: escolha o produto.`;
    } else {
      item.descricao = el.querySelector('[data-descricao]').value.trim();
      const cor = el.querySelector('[data-cor-personalizado]').value;
      if (cor === '__texto') item.cor_texto = el.querySelector('[data-cor-texto]').value.trim() || null;
      else item.material_id = cor || null;
      if (!item.descricao) erro = `Item ${n}: descreva o item personalizado.`;
    }
    if (!erro && (!Number.isFinite(qtd) || qtd < 1)) erro = `Item ${n}: a quantidade precisa ser um número inteiro, no mínimo 1.`;
    if (!erro && (!Number.isFinite(preco) || preco < 0)) erro = `Item ${n}: informe o preço unitário (R$ 0,00 para brinde).`;
    const valor = Number.isFinite(qtd) && Number.isFinite(preco) ? arred2(qtd * preco) : null;
    return { item, erro, valor };
  }

  const lerValorCampo = nome => {
    const t = form[nome].value.trim();
    return t === '' ? 0 : lerDecimal(t, 2);
  };

  function atualizarResumo() {
    let subtotal = 0;
    [...itensEl.querySelectorAll('[data-item]')].forEach((el, i) => {
      const { valor } = lerItem(el, i + 1);
      el.querySelector('[data-valor-item]').textContent = valor != null ? `Valor do item: ${brl(valor)}` : '';
      subtotal = arred2(subtotal + (valor || 0));
    });
    const desconto = lerValorCampo('desconto');
    const frete = lerValorCampo('frete');
    const total = arred2(subtotal - (Number.isFinite(desconto) ? desconto : 0) + (Number.isFinite(frete) ? frete : 0));
    resumoEl.innerHTML = `
      <div><span>Subtotal</span><strong>${brl(subtotal)}</strong></div>
      ${Number.isFinite(desconto) && desconto ? `<div><span>Desconto</span><strong>− ${brl(desconto)}</strong></div>` : ''}
      ${Number.isFinite(frete) && frete ? `<div><span>Frete</span><strong>${brl(frete)}</strong></div>` : ''}
      <div class="resumo-total"><span>Total</span><strong>${brl(total)}</strong></div>
      ${editando && num(p.valor_recebido) ? `<div class="resumo-outros"><span>Já recebido (líquido)</span><span>${brl(p.valor_liquido)}</span></div>` : ''}`;
    return { subtotal, desconto, frete, total };
  }

  itensEl.addEventListener('change', e => {
    const el = e.target.closest('[data-item]');
    if (!el) return;
    if (e.target.matches('[data-tipo]')) {
      const catalogo = e.target.value === 'catalogo';
      el.querySelectorAll('[data-so="catalogo"]').forEach(x => { x.hidden = !catalogo; });
      el.querySelectorAll('[data-so="personalizado"]').forEach(x => { x.hidden = catalogo; });
    }
    if (e.target.matches('[data-produto]')) {
      // Troca de produto: cores do novo produto e preço do catálogo como sugestão (R79).
      const prod = produtoPorId(e.target.value);
      const corSel = el.querySelector('[data-cor-catalogo]');
      corSel.innerHTML = '<option value="">Sem cor definida</option>' + (prod ? prod.cores.map(c =>
        `<option value="${c.material_id}">${esc(corDoFilamento(c))}${c.ativo ? '' : ' (inativo)'}</option>`).join('') : '');
      el.querySelector('[data-preco]').value = prod && prod.preco_venda != null ? paraCampo(prod.preco_venda, 2, 2) : '';
    }
    if (e.target.matches('[data-cor-personalizado]')) {
      const texto = el.querySelector('[data-cor-texto]');
      texto.hidden = e.target.value !== '__texto';
      if (!texto.hidden) texto.focus();
    }
    atualizarResumo();
  });
  // Ao mexer num item, o aviso de erro dele some (volta a ser conferido ao salvar).
  const limparErroItem = e => { const el = e.target.closest('[data-item]')?.querySelector('[data-erro-item]'); if (el) el.hidden = true; };
  itensEl.addEventListener('input', e => { limparErroItem(e); atualizarResumo(); erroGeral.hidden = true; });
  itensEl.addEventListener('change', limparErroItem);
  itensEl.addEventListener('click', e => {
    const b = e.target.closest('[data-remover]');
    if (!b) return;
    b.closest('[data-item]').remove();
    atualizarResumo();
  });
  dialog.querySelector('[data-add-item]').addEventListener('click', () => {
    adicionarItem({});
    itensEl.lastElementChild.querySelector('select, input')?.focus();
  });
  form.desconto.addEventListener('input', atualizarResumo);
  form.frete.addEventListener('input', atualizarResumo);
  form.addEventListener('input', () => { erroGeral.hidden = true; });

  // Itens existentes ou um item vazio para começar
  if (existente?.itens?.length) existente.itens.forEach(adicionarItem);
  else adicionarItem({});

  // ---- salvar
  form.addEventListener('submit', async e => {
    e.preventDefault();
    erroGeral.hidden = true;
    ['cliente', 'cliNome', 'origem', 'data', 'prazo', 'itens', 'desconto', 'frete'].forEach(n => erroCampo(n, ''));
    let valido = true;
    const falta = (nome, texto) => { erroCampo(nome, texto); valido = false; };

    const clienteEscolhido = form.cliente.value;
    const novoCliente = clienteEscolhido === '__novo';
    if (!clienteEscolhido) falta('cliente', 'Escolha o cliente ou cadastre um novo.');
    if (novoCliente && !form.cliNome.value.trim()) falta('cliNome', 'Informe o nome do cliente.');
    if (!form.origem.value) falta('origem', 'Escolha a origem do pedido.');
    const data = form.data.value;
    const prazo = form.prazo.value || null;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(data)) falta('data', 'Escolha a data do pedido.');
    else if (data > hojeISO()) falta('data', 'A data do pedido não pode ser futura.');
    if (prazo && data && prazo < data) falta('prazo', 'O prazo não pode ser antes da data do pedido.');

    const blocos = [...itensEl.querySelectorAll('[data-item]')];
    if (!blocos.length) falta('itens', 'O pedido precisa ter pelo menos um item (do catálogo ou personalizado).');
    const itens = [];
    blocos.forEach((el, i) => {
      const { item, erro } = lerItem(el, i + 1);
      const campoErro = el.querySelector('[data-erro-item]');
      campoErro.textContent = erro; campoErro.hidden = !erro;
      if (erro) valido = false;
      itens.push(item);
    });

    const { subtotal } = atualizarResumo();
    const desconto = lerValorCampo('desconto');
    const frete = lerValorCampo('frete');
    if (!Number.isFinite(desconto) || desconto < 0) falta('desconto', 'Digite um valor válido, como 10,00.');
    else if (desconto > subtotal) falta('desconto', 'O desconto não pode passar do subtotal dos itens.');
    if (!Number.isFinite(frete) || frete < 0) falta('frete', 'Digite um valor válido, como 15,00.');
    if (!valido) {
      erroGeral.textContent = 'Confira os campos destacados.';
      erroGeral.hidden = false;
      return;
    }

    const botao = form.querySelector('[type=submit]');
    const textoBotao = botao.textContent;
    form.querySelectorAll('button').forEach(b => { b.disabled = true; });
    botao.textContent = 'Salvando…';
    try {
      let clienteId = clienteEscolhido;
      if (novoCliente) {
        clienteId = await sb.rpc('salvar_cliente', {
          p_id: null, p_nome: form.cliNome.value.trim(), p_contato: form.cliContato.value.trim() || null,
        }).then(ok);
        // Se o pedido falhar a seguir, o cliente já cadastrado fica escolhido (sem duplicar).
        const novo = { id: clienteId, nome: form.cliNome.value.trim(), contato: form.cliContato.value.trim() || null, ativo: true };
        clientes.push(novo);
        form.cliente.querySelector('option[value="__novo"]').insertAdjacentHTML('beforebegin', opcaoCliente(novo));
        form.cliente.value = clienteId;
        atualizarCliente();
      }
      const r = await sb.rpc('salvar_pedido', {
        p_id: p?.id ?? null,
        p_data: data,
        p_cliente_id: clienteId,
        p_origem: form.origem.value,
        p_data_prometida: prazo,
        p_forma_pagamento: form.forma.value || null,
        p_desconto: desconto,
        p_frete: frete,
        p_observacao: form.obs.value.trim() || null,
        p_itens: itens,
      }).then(ok);
      fechar();
      await recarregar(editando ? `Pedido ${numeroPedido(r.numero)} atualizado.` : `Pedido ${numeroPedido(r.numero)} cadastrado.`, r.id);
    } catch (err) {
      erroGeral.textContent = err.message;
      erroGeral.hidden = false;
      form.querySelectorAll('button').forEach(b => { b.disabled = false; });
      botao.textContent = textoBotao;
    }
  });

  atualizarCliente();
  if (!editando) form.cliente.focus();
}
