// Módulo · Pedidos da Shopee (só Admin)
// Importa a planilha da Shopee com prévia e confirmação. A importação não cria
// vendas e não mexe no Caixa, no estoque nem na comissão do Joca (R70). Cada
// pedido pode virar venda por escolha da Admin, com "Registrar como venda"
// (R102, sql/17). No topo: "Repasses para confirmar" (R106) e os avisos de
// venda cancelada ou devolvida na Shopee (R109), do sql/19.

import { supabase, configurado } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, dataHoraBR, dataBR, hojeISO, lerDecimal } from '../format.js';
import { cliqueForaDoDialogo } from '../ui/dialogo.js';
import { abrirFormulario } from '../ui/formulario.js';
import { lerPlanilhaShopee, paraEnvio, centavos } from '../shopee-planilha.js';
import { abrirVendaShopee, vendasShopeeInstaladas } from './venda-shopee.js';

const NAO_INFORMADO = '<span class="nao-informado">Não informado</span>';
const filtro = { busca: '', status: '', mes: '' };

const real = v => (v == null || v === '' ? NAO_INFORMADO : brl(centavos(v) / 100));
const texto = v => (v == null || v === '' ? NAO_INFORMADO : esc(v));
const quando = v => (v ? esc(dataHoraBR(v)) : NAO_INFORMADO);

function classeStatus(s) {
  const t = String(s || '').toLowerCase();
  if (/cancel|devolu|reembols/.test(t)) return 'selo-despesa';
  if (/conclu|entregue/.test(t)) return 'selo-ativo';
  if (/envi|trânsito|transito|caminho|processando|a enviar/.test(t)) return 'selo-investimento';
  return 'selo-inativo';
}
const seloStatus = s => `<span class="selo-p ${classeStatus(s)}">${esc(s || 'Sem status')}</span>`;

/** Soma em centavos só dos valores informados; devolve também quantos faltaram. */
function somar(lista, campos) {
  let total = 0, faltou = 0;
  for (const p of lista) for (const c of campos) {
    const v = centavos(p[c]);
    if (v == null) faltou++; else total += v;
  }
  return { total, faltou };
}

/**
 * opcoes.mensagem: aviso para mostrar ao abrir (ex.: depois de importar pela tela Pedidos).
 * opcoes.aoRegistrarVenda(mensagem, id): depois de registrar uma venda (abre o pedido na aba Diretos).
 * opcoes.aoAbrirVenda(id): abre a venda na aba Diretos (avisos da Shopee).
 */
export function telaShopee(el, opcoes = {}) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">Pedidos da Shopee precisam do Supabase configurado.</p></section>';
    return;
  }
  carregar(el, opcoes.mensagem, opcoes);
}

async function carregar(el, mensagem, opcoes = {}) {
  const area = document.createElement('div');
  area.className = 'painel-area';
  area.innerHTML = '<p class="texto-secundario">Carregando…</p>';
  el.replaceChildren(area);
  try {
    await desenhar(area, (msg) => carregar(el, msg, opcoes), mensagem, opcoes);
  } catch (e) {
    area.innerHTML = `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  }
}

/** Lê a planilha, mostra a prévia e importa ao confirmar. Usada também pela tela Pedidos (R111). */
export async function importarPlanilhaShopee(arquivo, aoConcluir) {
  const sb = await supabase();
  const lido = await lerPlanilhaShopee(arquivo);
  const envio = paraEnvio(lido.pedidos);
  const previa = envio.length
    ? await sb.rpc('importar_pedidos_shopee', {
        p_arquivo: arquivo.name, p_linhas: lido.linhas, p_com_erro: 0, p_pedidos: envio, p_confirmar: false,
      }).then(ok)
    : { novos: 0, atualizados: 0, iguais: 0, com_aviso: 0, pedidos: [] };
  abrirPrevia({ sb, arquivo, lido, envio, previa, aoConcluir });
}

async function desenhar(area, recarregar, mensagem, opcoes = {}) {
  const sb = await supabase();
  // Vendas já registradas a partir dos pedidos (R102). Antes do sql/17 não existem.
  const comVendas = await vendasShopeeInstaladas(sb);
  const vendaDe = comVendas ? Object.fromEntries((await sb.from('vendas').select('id, numero, shopee_pedido_ref')
    .not('shopee_pedido_ref', 'is', null).then(ok)).map(v => [v.shopee_pedido_ref, v])) : {};
  const cancelado = p => /cancel/i.test(p.status || '');
  const registrar = async p => {
    try {
      await abrirVendaShopee(sb, { shopee: p, aoConcluir: async (msg, id) => {
        if (opcoes.aoRegistrarVenda) await opcoes.aoRegistrarVenda(msg, id); else await recarregar(msg);
      } });
    } catch (e) { window.alert(e.message); }
  };
  const todos = await sb.from('shopee_pedidos')
    .select('*, itens:shopee_pedido_itens(*)')
    .order('criado_em', { ascending: false, nullsFirst: false })
    .order('pedido_id')
    .then(ok);

  const statusLista = [...new Set(todos.map(p => p.status).filter(Boolean))].sort();
  const notaFalta = n => (n ? `<p class="metrica-nota">${n} valor(es) não informado(s) na planilha ficaram de fora.</p>` : '');

  area.innerHTML = `
    <div data-repasses></div>
    <section class="cartao filtros">
      <label class="campo campo-compacto"><span>Buscar</span>
        <input type="search" name="busca" value="${esc(filtro.busca)}" placeholder="Pedido, produto ou rastreio"></label>
      <label class="campo campo-compacto"><span>Status</span>
        <select name="status"><option value="">Todos</option>
          ${statusLista.map(s => `<option ${filtro.status === s ? 'selected' : ''}>${esc(s)}</option>`).join('')}
        </select></label>
      <label class="campo campo-compacto"><span>Mês do pedido</span>
        <input type="month" name="mes" value="${esc(filtro.mes)}"></label>
    </section>

    <div class="grade-metricas" data-metricas></div>

    <section class="cartao">
      <div class="cartao-topo">
        <h3>Pedidos importados</h3>
        <div class="botoes-topo">
          <label class="botao botao-primario" data-escolher>
            <i class="ti ti-file-upload" aria-hidden="true"></i> Importar planilha
            <input type="file" accept=".xlsx" hidden data-arquivo>
          </label>
        </div>
      </div>
      <p class="texto-secundario nota-topo">Na Shopee: Meus Pedidos › Exportar › baixe o arquivo em Histórico de Relatórios e escolha aqui.
        ${comVendas ? 'A importação não cria vendas nem mexe no Caixa. Para um pedido entrar nos seus pedidos, use “Registrar como venda”.'
          : 'Só consulta: nada vai para o Caixa, o estoque, as vendas ou a comissão do Joca.'}</p>
      <p class="aviso aviso-ok" role="status" ${mensagem ? '' : 'hidden'}>${esc(mensagem || '')}</p>
      <p class="aviso aviso-erro" role="alert" hidden data-erro></p>
      <div data-lista></div>
    </section>`;

  // Filtros: só redesenham a lista (sem recarregar do banco).
  const metricasEl = area.querySelector('[data-metricas]');
  const listaEl = area.querySelector('[data-lista]');
  function mostrar() {
    const busca = filtro.busca.trim().toLowerCase();
    const pedidos = todos.filter(p => {
      if (filtro.status && p.status !== filtro.status) return false;
      if (filtro.mes && !(p.criado_em && dataBR(p.criado_em).slice(3) === `${filtro.mes.slice(5, 7)}/${filtro.mes.slice(0, 4)}`)) return false;
      if (!busca) return true;
      return [p.pedido_id, p.rastreio, ...p.itens.flatMap(i => [i.produto, i.variacao])]
        .some(v => String(v || '').toLowerCase().includes(busca));
    });
    const totalGlobal = somar(pedidos, ['total_global']);
    const taxas = somar(pedidos, ['taxa_comissao', 'taxa_servico', 'taxa_transacao', 'taxa_envio_reversa']);
    metricasEl.innerHTML = `
      <div class="metrica metrica-neutra"><p class="metrica-rotulo">Pedidos</p><p class="metrica-valor">${pedidos.length}</p></div>
      <div class="metrica metrica-neutra"><p class="metrica-rotulo">Pago pelos compradores</p>
        <p class="metrica-valor">${brl(totalGlobal.total / 100)}</p>${notaFalta(totalGlobal.faltou)}</div>
      <div class="metrica metrica-neutra"><p class="metrica-rotulo">Taxas da Shopee</p>
        <p class="metrica-valor">${brl(taxas.total / 100)}</p>${notaFalta(taxas.faltou)}</div>
      <div class="metrica metrica-neutra"><p class="metrica-rotulo">Líquido</p>
        <p class="metrica-valor metrica-nao-informado">Não informado</p>
        <p class="metrica-nota">A planilha de pedidos da Shopee não traz o valor líquido.</p></div>`;
    listaEl.innerHTML = pedidos.length ? `<ul class="lista">${pedidos.map(p => `
        <li class="linha linha-gasto">
          <div class="linha-texto">
            <strong>Pedido ${esc(p.pedido_id)} ${seloStatus(p.status)}${p.aviso_itens ? ' <span class="selo-p selo-despesa">Conferir itens</span>' : ''}</strong>
            <span class="texto-secundario">${p.criado_em ? esc(dataHoraBR(p.criado_em)) : 'Data não informada'}${p.rastreio ? ` · Rastreio ${esc(p.rastreio)}` : ''}</span>
            <span class="texto-secundario">${p.itens.map(i => `${esc(i.produto)}${i.variacao ? ` (${esc(i.variacao)})` : ''}${i.quantidade != null ? ` ×${esc(i.quantidade)}` : ''}`).join(' + ')}</span>
          </div>
          <div class="linha-direita">
            <span class="linha-valor">${real(p.total_global)}</span>
            <div class="linha-acoes">
              ${vendaDe[p.id] ? `<span class="selo-p selo-ativo">Venda #${String(vendaDe[p.id].numero).padStart(4, '0')}</span>`
                : comVendas && !cancelado(p) ? `<button class="botao botao-pequeno botao-primario" data-registrar="${esc(p.pedido_id)}">Registrar como venda</button>` : ''}
              <button class="botao botao-pequeno" data-ver="${esc(p.pedido_id)}">Detalhes</button></div>
          </div>
        </li>`).join('')}</ul>`
      : `<p class="texto-secundario vazio">${todos.length ? 'Nenhum pedido com esses filtros.' : 'Nenhum pedido importado ainda.'}</p>`;
  }
  mostrar();
  await desenharRepasses(sb, area.querySelector('[data-repasses]'), recarregar, opcoes);

  const filtros = area.querySelector('.filtros');
  filtros.addEventListener('change', e => {
    if (e.target.name === 'busca') return;
    filtro[e.target.name] = e.target.value;
    mostrar();
  });
  filtros.querySelector('[name=busca]').addEventListener('input', e => { filtro.busca = e.target.value; mostrar(); });
  listaEl.addEventListener('click', e => {
    const r = e.target.closest('[data-registrar]');
    if (r) { registrar(todos.find(p => p.pedido_id === r.dataset.registrar)); return; }
    const b = e.target.closest('[data-ver]');
    if (b) {
      const p = todos.find(x => x.pedido_id === b.dataset.ver);
      abrirDetalhe(p, { venda: vendaDe[p.id], podeRegistrar: comVendas && !cancelado(p) && !vendaDe[p.id], registrar });
    }
  });

  const erroEl = area.querySelector('[data-erro]');
  const input = area.querySelector('[data-arquivo]');
  input.addEventListener('change', async () => {
    const arquivo = input.files[0];
    input.value = '';
    if (!arquivo) return;
    erroEl.hidden = true;
    try {
      await importarPlanilhaShopee(arquivo, recarregar);
    } catch (e) {
      erroEl.textContent = `${e.message || 'Não foi possível ler a planilha.'}${/Nada foi importado/.test(e.message || '') ? '' : ' Nada foi importado.'}`;
      erroEl.hidden = false;
    }
  });
}

// ---------------------------------------------------------------- repasses e avisos (sql/19)

/** Código de envio: repetir o mesmo envio não grava duas vezes. */
function novaChave() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
const num = v => Number(v || 0);

/** Repasses para confirmar (R106) e avisos de cancelado ou devolvido (R109). Antes do sql/19, nada aparece. */
async function desenharRepasses(sb, el, recarregar, opcoes) {
  const [pend, av] = await Promise.all([
    sb.from('vw_repasses_shopee_pendentes').select('*').order('data').order('numero'),
    sb.from('vw_avisos_shopee').select('*').order('numero'),
  ]);
  if (pend.error || av.error) { el.remove(); return; }
  const pendentes = pend.data, avisos = av.data;
  if (!pendentes.length && !avisos.length) { el.remove(); return; }

  el.innerHTML = `
    ${avisos.length ? `<section class="cartao cartao-avisos-shopee">
      <div class="cartao-topo"><h3>Avisos da Shopee (${avisos.length})</h3></div>
      <p class="texto-secundario nota-topo">A planilha mostra estas vendas como canceladas ou devolvidas na Shopee. Você decide:
        cancelar a venda (devolução total), editar tirando os itens devolvidos (devolução parcial) ou manter como está.</p>
      <ul class="lista">${avisos.map(a => `
        <li class="linha">
          <div class="linha-texto">
            <strong>Venda ${esc(a.numero_formatado)} · Pedido ${esc(a.pedido_shopee)}
              <span class="selo-p selo-despesa">${a.tipo === 'CANCELADO' ? 'Cancelado na Shopee' : 'Devolução na Shopee'}</span></strong>
            <span class="texto-secundario">Status na Shopee: ${esc(a.status_shopee || 'sem status')}${a.status_devolucao ? ` · Devolução: ${esc(a.status_devolucao)}` : ''}</span>
            ${a.tem_repasse ? '<span class="texto-secundario">O repasse já foi confirmado: para cancelar ou editar, estorne o repasse antes, no detalhe da venda.</span>' : ''}
          </div>
          <div class="linha-direita"><div class="linha-acoes">
            ${opcoes.aoAbrirVenda ? `<button type="button" class="botao botao-pequeno botao-primario" data-abrir-venda="${a.venda_id}">Abrir venda</button>` : ''}
            <button type="button" class="botao botao-pequeno" data-manter="${a.venda_id}">Manter como está</button>
          </div></div>
        </li>`).join('')}</ul>
    </section>` : ''}
    ${pendentes.length ? `<section class="cartao">
      <div class="cartao-topo"><h3>Repasses para confirmar (${pendentes.length})</h3></div>
      <p class="texto-secundario nota-topo">Vendas com o pedido Concluído na Shopee. Confira o repasse na Shopee e confirme:
        só então o valor entra no Caixa e a comissão do Joca fica disponível.</p>
      <ul class="lista">${pendentes.map(r => `
        <li class="linha">
          <div class="linha-texto">
            <strong>Venda ${esc(r.numero_formatado)} · Pedido ${esc(r.pedido_shopee)}</strong>
            <span class="texto-secundario">Faturamento ${brl(r.faturamento)} − taxa ${brl(r.taxa_plataforma)} · data sugerida ${esc(dataBR(r.data_sugerida))}</span>
          </div>
          <div class="linha-direita">
            <span class="linha-valor">${brl(r.repasse_estimado)}</span>
            <div class="linha-acoes"><button type="button" class="botao botao-pequeno botao-primario" data-confirmar="${r.venda_id}">Confirmar repasse</button></div>
          </div>
        </li>`).join('')}</ul>
    </section>` : ''}`;

  el.addEventListener('click', e => {
    const c = e.target.closest('[data-confirmar]');
    if (c) { abrirConfirmarRepasse(sb, pendentes.find(r => r.venda_id === c.dataset.confirmar), recarregar); return; }
    const v = e.target.closest('[data-abrir-venda]');
    if (v) { opcoes.aoAbrirVenda?.(v.dataset.abrirVenda); return; }
    const m = e.target.closest('[data-manter]');
    if (m) abrirManterVenda(sb, avisos.find(a => a.venda_id === m.dataset.manter), recarregar);
  });
}

function abrirConfirmarRepasse(sb, r, recarregar) {
  const chave = novaChave();
  const fat = num(r.faturamento);
  abrirFormulario({
    titulo: `Confirmar repasse · Venda ${r.numero_formatado}`,
    textoSalvar: 'Confirmar repasse',
    valores: { valor: num(r.repasse_estimado), data: r.data_sugerida, observacao: '', confirmado: false },
    campos: [
      { nome: 'valor', rotulo: 'Valor do repasse (R$)', tipo: 'decimal', casas: 2, casasMin: 2, obrigatorio: true, maiorQueZero: true, recarrega: true,
        dica: v => {
          // Enquanto edita, o campo guarda o texto digitado (ex.: "50,00").
          const valor = typeof v.valor === 'number' ? v.valor : lerDecimal(String(v.valor ?? ''), 2);
          const taxa = Math.round((fat - valor) * 100) / 100;
          return `Estimado: ${brl(r.repasse_estimado)} (faturamento ${brl(fat)} − taxa ${brl(r.taxa_plataforma)}). `
            + (valor > 0 && valor <= fat && Math.abs(valor - num(r.repasse_estimado)) >= 0.005
              ? `Com este valor, a taxa da Shopee da venda passa a ser ${brl(taxa)}.` : 'Se caiu outro valor, digite o que caiu: a taxa da venda é ajustada.');
        } },
      { nome: 'data', rotulo: 'Data do repasse', tipo: 'data', obrigatorio: true, maxData: hojeISO(),
        dica: `Sugerida: o dia da importação da planilha. Entre ${dataBR(r.data)} (data da venda) e hoje.` },
      { nome: 'observacao', rotulo: 'Observação', tipo: 'texto' },
      { nome: 'confirmado', rotulo: 'Conferi este repasse na Shopee', tipo: 'checkbox',
        dica: 'Só confirme o que já apareceu na sua carteira da Shopee.' },
    ],
    async aoSalvar(v) {
      if (!v.confirmado) throw new Error('Marque a confirmação: só confirme repasses conferidos na Shopee.');
      await sb.rpc('confirmar_repasse_shopee', {
        p_venda_id: r.venda_id, p_data: v.data, p_valor: v.valor, p_observacao: v.observacao, p_confirmado: true, p_chave: chave,
      }).then(ok);
      await recarregar(`Repasse de ${brl(v.valor)} da venda ${r.numero_formatado} confirmado e lançado no Caixa.`);
    },
  });
}

function abrirManterVenda(sb, a, recarregar) {
  abrirFormulario({
    titulo: `Manter a venda ${a.numero_formatado} como está`,
    textoSalvar: 'Manter como está',
    campos: [
      { nome: 'motivo', rotulo: 'Motivo', tipo: 'texto', obrigatorio: true, placeholder: 'Ex.: devolução recusada pela Shopee',
        dica: 'O aviso some e fica registrado. Se o status do pedido mudar de novo na planilha, o aviso volta.' },
    ],
    async aoSalvar(v) {
      await sb.rpc('dispensar_aviso_shopee', { p_venda_id: a.venda_id, p_motivo: v.motivo }).then(ok);
      await recarregar(`Venda ${a.numero_formatado} mantida como está.`);
    },
  });
}

// ---------------------------------------------------------------- prévia

function abrirPrevia({ sb, arquivo, lido, envio, previa, aoConcluir }) {
  const comErro = lido.pedidos.filter(p => p.erros.length);
  const situacao = Object.fromEntries(previa.pedidos.map(p => [p.pedido_id, p]));
  const aImportar = previa.novos + previa.atualizados;
  const avisos = [
    ...lido.avisosArquivo,
    ...lido.pedidos.flatMap(p => p.avisos.map(a => `Pedido ${p.pedido_id}: ${a}`)),
    ...previa.pedidos.filter(p => p.aviso).map(p => `Pedido ${p.pedido_id}: ${p.aviso}`),
  ];
  const erros = [
    ...lido.errosArquivo,
    ...comErro.flatMap(p => p.erros.map(e => `Pedido ${p.pedido_id} (não será importado): ${e}`)),
  ];
  const ROT = { novo: 'Novo', atualizado: 'Atualizado', igual: 'Igual' };
  const NOMES = {
    status: 'status', status_devolucao: 'devolução', rastreio: 'rastreio', opcao_envio: 'envio', metodo_envio: 'envio',
    criado_em: 'data', pago_em: 'pagamento', envio_previsto: 'envio previsto', enviado_em: 'data de envio',
    itens: 'itens', 'outras colunas': 'outras colunas', 'conferência dos itens': 'conferência dos itens',
  };
  const alterados = p => [...new Set((p.alterados || []).map(a => NOMES[a] || 'valores'))].join(', ');

  const dialog = document.createElement('dialog');
  dialog.className = 'folha folha-larga';
  dialog.setAttribute('aria-labelledby', 'previa-titulo');
  dialog.innerHTML = `
    <div class="folha-topo">
      <h2 id="previa-titulo">Prévia da importação</h2>
      <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
    </div>
    <p class="texto-secundario">${esc(arquivo.name)} · ${lido.linhas} linha(s) · ${lido.pedidos.length} pedido(s). Nada foi gravado ainda.</p>
    <div class="grade-metricas grade-previa">
      <div class="metrica metrica-recebido"><p class="metrica-rotulo">Novos</p><p class="metrica-valor">${previa.novos}</p></div>
      <div class="metrica metrica-disponivel"><p class="metrica-rotulo">Atualizados</p><p class="metrica-valor">${previa.atualizados}</p></div>
      <div class="metrica metrica-neutra"><p class="metrica-rotulo">Iguais</p><p class="metrica-valor">${previa.iguais}</p></div>
      <div class="metrica metrica-espera"><p class="metrica-rotulo">Com erro</p><p class="metrica-valor">${comErro.length}</p></div>
    </div>
    ${erros.length ? `<div class="aviso aviso-erro"><strong>Erros</strong><ul class="lista-aviso">${erros.map(e => `<li>${esc(e)}</li>`).join('')}</ul></div>` : ''}
    ${avisos.length ? `<div class="aviso aviso-atencao"><strong>Para conferir</strong><ul class="lista-aviso">${avisos.map(a => `<li>${esc(a)}</li>`).join('')}</ul></div>` : ''}
    ${envio.length ? `<ul class="lista">${envio.map(p => {
      const s = situacao[p.pedido_id] || {};
      return `<li class="linha"><div class="linha-texto">
          <strong>Pedido ${esc(p.pedido_id)} <span class="selo-p ${s.situacao === 'novo' ? 'selo-ativo' : s.situacao === 'atualizado' ? 'selo-investimento' : 'selo-inativo'}">${ROT[s.situacao] || ''}</span></strong>
          <span class="texto-secundario">${esc(p.dados.status || 'Sem status')} · ${p.itens.length} item(ns)${s.situacao === 'atualizado' && alterados(s) ? ` · muda: ${esc(alterados(s))}` : ''}</span>
        </div><span class="linha-valor">${real(p.dados.total_global)}</span></li>`;
    }).join('')}</ul>` : ''}
    <p class="aviso aviso-erro" role="alert" hidden data-erro-folha></p>
    <div class="form-acoes form-acoes-folha">
      <button type="button" class="botao" data-fechar>Cancelar</button>
      <button type="button" class="botao botao-primario" data-confirmar ${aImportar ? '' : 'disabled'}>
        ${aImportar ? `Importar ${aImportar} pedido(s)` : 'Nada novo para importar'}</button>
    </div>`;

  document.body.append(dialog);
  dialog.addEventListener('close', () => dialog.remove());
  dialog.addEventListener('click', e => {
    if (cliqueForaDoDialogo(e, dialog) || e.target.closest('[data-fechar]')) dialog.close();
  });

  const botao = dialog.querySelector('[data-confirmar]');
  const erroFolha = dialog.querySelector('[data-erro-folha]');
  botao.addEventListener('click', async () => {
    botao.disabled = true;
    botao.textContent = 'Importando…';
    erroFolha.hidden = true;
    try {
      const r = await sb.rpc('importar_pedidos_shopee', {
        p_arquivo: arquivo.name, p_linhas: lido.linhas, p_com_erro: comErro.length, p_pedidos: envio, p_confirmar: true,
      }).then(ok);
      dialog.close();
      await aoConcluir(`Importação concluída: ${r.novos} novo(s), ${r.atualizados} atualizado(s), ${r.iguais} igual(is)` +
        `${comErro.length ? `, ${comErro.length} com erro (não importados)` : ''}.`);
    } catch (e) {
      // Nada foi gravado: a importação é tudo ou nada.
      erroFolha.textContent = `${e.message} Nada foi gravado; os pedidos já registrados continuam como estavam.`;
      erroFolha.hidden = false;
      botao.disabled = false;
      botao.textContent = `Importar ${aImportar} pedido(s)`;
    }
  });
  dialog.showModal();
}

// ---------------------------------------------------------------- detalhe

function abrirDetalhe(p, { venda = null, podeRegistrar = false, registrar } = {}) {
  if (!p) return;
  const linha = (rotulo, valor) => `<li class="linha linha-dado"><span>${rotulo}</span><strong>${valor}</strong></li>`;
  const dialog = document.createElement('dialog');
  dialog.className = 'folha folha-larga';
  dialog.setAttribute('aria-labelledby', 'detalhe-titulo');
  dialog.innerHTML = `
    <div class="folha-topo">
      <h2 id="detalhe-titulo">Pedido ${esc(p.pedido_id)}</h2>
      <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
    </div>
    <p>${seloStatus(p.status)}${p.status_devolucao ? ` <span class="selo-p selo-despesa">${esc(p.status_devolucao)}</span>` : ''}</p>
    ${p.aviso_itens ? `<p class="aviso aviso-atencao">${esc(p.aviso_itens)}</p>` : ''}

    <h3 class="detalhe-titulo">Itens</h3>
    <ul class="lista">${p.itens.map(i => `
      <li class="linha linha-gasto"><div class="linha-texto">
        <strong>${esc(i.produto)}</strong>
        <span class="texto-secundario">${i.variacao ? `${esc(i.variacao)} · ` : ''}Quantidade ${texto(i.quantidade)}${Number(i.qtd_devolvida) > 0 ? ` · Devolvida ${esc(i.qtd_devolvida)}` : ''}${i.sku ? ` · SKU ${esc(i.sku)}` : ''}</span>
        <span class="texto-secundario">Preço original ${real(i.preco_original)} · Preço acordado ${real(i.preco_acordado)}</span>
      </div><span class="linha-valor">${real(i.subtotal)}</span></li>`).join('')}</ul>

    <h3 class="detalhe-titulo">Valores</h3>
    <ul class="lista">
      ${linha('Valor total dos produtos', real(p.valor_total))}
      ${linha('Desconto do vendedor (1ª coluna)', real(p.desconto_vendedor_1))}
      ${linha('Desconto do vendedor (2ª coluna)', real(p.desconto_vendedor_2))}
      ${linha('Cupom do vendedor', real(p.cupom_vendedor))}
      ${linha('Cupom da Shopee', real(p.cupom_shopee))}
      ${linha('Código do cupom', texto(p.codigo_cupom))}
      ${linha('Total pago pelo comprador (Total global)', real(p.total_global))}
    </ul>

    <h3 class="detalhe-titulo">Taxas da Shopee</h3>
    <ul class="lista">
      ${linha('Comissão', real(p.taxa_comissao))}
      ${linha('Serviço', real(p.taxa_servico))}
      ${linha('Transação', real(p.taxa_transacao))}
      ${linha('Envio reverso', real(p.taxa_envio_reversa))}
      ${linha('Líquido', NAO_INFORMADO)}
    </ul>

    <h3 class="detalhe-titulo">Envio</h3>
    <ul class="lista">
      ${linha('Rastreio', texto(p.rastreio))}
      ${linha('Opção de envio', texto(p.opcao_envio))}
      ${linha('Método de envio', texto(p.metodo_envio))}
      ${linha('Frete pago pelo comprador', real(p.frete_comprador))}
      ${linha('Frete estimado', real(p.frete_estimado))}
      ${linha('Desconto de frete', real(p.desconto_frete))}
      ${linha('Pedido criado em', quando(p.criado_em))}
      ${linha('Pago em', quando(p.pago_em))}
      ${linha('Envio previsto até', quando(p.envio_previsto))}
      ${linha('Enviado em', quando(p.enviado_em))}
    </ul>
    <p class="texto-secundario nota">Última atualização no sistema: ${esc(dataHoraBR(p.updated_at))}.</p>
    ${venda ? `<p class="aviso aviso-ok">Este pedido já é a venda #${String(venda.numero).padStart(4, '0')} nos seus pedidos (aba Diretos).</p>` : ''}
    ${podeRegistrar ? '<div class="form-acoes"><span class="espaco"></span><button type="button" class="botao botao-primario" data-registrar-detalhe>Registrar como venda</button></div>' : ''}`;

  document.body.append(dialog);
  dialog.addEventListener('close', () => dialog.remove());
  dialog.addEventListener('click', e => {
    if (cliqueForaDoDialogo(e, dialog) || e.target.closest('[data-fechar]')) dialog.close();
  });
  dialog.querySelector('[data-registrar-detalhe]')?.addEventListener('click', () => { dialog.close(); registrar(p); });
  dialog.showModal();
}
