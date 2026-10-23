// Etapa 5 · Produção Essencial (só Admin) · grupo "Mais".
// Regras: especificação v1.8, R95–R100 (aplica R11–R18, R21, R30, R56).
// Grava só pelas funções do banco: registrar_producao, estornar_producao,
// usar_peca_pronta, baixar_peca_pronta e estornar_saida_peca. O material sai
// do estoque pelo custo médio, no próprio banco. Nada entra no Caixa.
// Combinações (sql/22, R116, R119): a produção para o estoque escolhe a
// combinação, a ficha dela (se tiver) preenche o material e a peça pronta só
// vai para item da mesma combinação. Antes do sql/22, como sempre.

import { supabase, configurado } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, dataBR, hojeISO, lerDecimal, paraCampo, arred2 } from '../format.js';
import { cliqueForaDoDialogo } from '../ui/dialogo.js';
import { abrirFormulario } from '../ui/formulario.js';
import { carregarVariacoes, combinacaoTexto } from './variacoes.js';

const ABERTOS = ['AGUARDANDO', 'PRODUZINDO', 'PRONTO'];
const DESTINO = { PEDIDO: 'Item de pedido', ESTOQUE: 'Estoque de peças prontas', AVULSA: 'Avulsa' };
const TIPO_SAIDA = { PEDIDO: 'Usada no pedido', SHOPEE: 'Shopee', BRINDE: 'Brinde', PERDA: 'Perda', OUTRO: 'Outro' };
const nomeMat = m => `${m.tipo}${m.variacao ? ` · ${m.variacao}` : ''}`;
const qtdTexto = (v, un) => `${paraCampo(v, 0, 3)} ${un}`;
const plural = (n, um, varios) => `${n} ${n === 1 ? um : varios}`;
const mesAtual = () => hojeISO().slice(0, 7);
/** Lote de peças prontas serve para o item: mesmo produto e mesma combinação (R119). */
const loteServe = (l, i) => l.produto_id === i.produto_id && (l.variacao_id || null) === (i.variacao_id || null);
const nomeLote = l => `${l.produto}${l.variacao ? ` · ${combinacaoTexto(l.variacao)}` : ''}`;

/** Código de envio: o mesmo formulário enviado de novo não registra duas vezes. */
export function novaChave() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/** A produção está instalada no banco? (antes do sql/16 as tabelas não existem) */
export async function producaoInstalada(sb) {
  const { error } = await sb.from('producoes').select('id').limit(1);
  return !error;
}

// ---------------------------------------------------------------- dados
/** Tudo que o formulário de produção e o uso de peças prontas precisam. */
export async function carregarDados(sb) {
  const [itens, partesItens, produtos, partes, outros, estoque, cfg, lotes] = await Promise.all([
    sb.from('vw_itens_producao').select('*').in('status_pedido', ABERTOS).order('numero').order('ordem').then(ok),
    sb.from('item_venda_partes').select('item_id, ordem, nome, gramas, purga_g, material_id, cor_descricao').order('ordem').then(ok),
    sb.from('produtos').select('id, nome, ativo, tempo_impressao_min').order('nome').then(ok),
    sb.from('produto_partes').select('produto_id, ordem, nome, gramas, purga_g').order('ordem').then(ok),
    sb.from('produto_materiais').select('produto_id, material_id, quantidade').then(ok),
    sb.from('vw_estoque').select('material_id, categoria, tipo, variacao, unidade, ativo, quantidade, custo_medio').order('tipo').order('variacao').then(ok),
    sb.from('configuracoes').select('potencia_impressora_w, tarifa_kwh').eq('id', 1).then(ok),
    sb.from('vw_pecas_prontas').select('*').gt('saldo', 0).order('produto').order('data').then(ok),
  ]);
  const mat = Object.fromEntries(estoque.map(m => [m.material_id, m]));
  itens.forEach(i => { i.partes = partesItens.filter(p => p.item_id === i.item_id); });
  produtos.forEach(p => {
    p.partes = partes.filter(x => x.produto_id === p.id);
    p.outros = outros.filter(x => x.produto_id === p.id).map(x => ({ ...x, material: mat[x.material_id] })).filter(x => x.material);
  });
  const comVariacoes = await carregarVariacoes(sb, produtos);
  produtos.forEach(p => p.variacoes.forEach(v => {
    v.outros = v.outros.map(x => ({ ...x, material: mat[x.material_id] })).filter(x => x.material);
  }));
  return { itens, produtos, estoque, mat, cfg: cfg[0] || {}, lotes, comVariacoes };
}

// ---------------------------------------------------------------- tela
export function telaProducao(el) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">A produção precisa do Supabase configurado.</p></section>';
    return;
  }
  carregar(el);
}

async function carregar(el, mensagem) {
  const area = document.createElement('div');
  area.className = 'painel-area';
  area.innerHTML = '<p class="texto-secundario">Carregando…</p>';
  el.replaceChildren(area);
  try {
    await desenhar(area, msg => carregar(el, msg), mensagem);
  } catch (e) {
    area.innerHTML = `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  }
}

async function desenhar(area, recarregar, mensagem) {
  const sb = await supabase();
  if (!(await producaoInstalada(sb))) {
    area.innerHTML = '<section class="cartao"><p class="texto-secundario">A produção aparece aqui depois da instalação no banco.</p></section>';
    return;
  }
  const inicioMes = `${mesAtual()}-01`;
  const [dados, historico, saidas, perdas] = await Promise.all([
    carregarDados(sb),
    sb.from('producoes').select('*').order('seq', { ascending: false }).limit(40).then(ok),
    sb.from('saidas_pecas_prontas').select('*, lote:pecas_prontas(produto_id, cores_descricao)').order('seq', { ascending: false }).limit(20).then(ok),
    sb.from('vw_perdas').select('*').gte('data', inicioMes).order('data', { ascending: false }).then(ok),
  ]);
  const { itens, produtos, lotes } = dados;
  const nomeProduto = id => produtos.find(p => p.id === id)?.nome || 'Produto';
  const aFazer = itens.filter(i => i.faltam > 0 && i.status_pedido !== 'PRONTO');
  const pecasProntas = lotes.reduce((t, l) => t + l.saldo, 0);
  const totalPerdas = perdas.reduce((t, p) => arred2(t + Number(p.valor)), 0);
  const lotesDe = i => lotes.filter(l => loteServe(l, i));

  area.innerHTML = `
    <div class="grade-metricas">
      <div class="metrica metrica-espera">
        <p class="metrica-rotulo"><i class="ti ti-printer" aria-hidden="true"></i> A produzir</p>
        <p class="metrica-valor">${aFazer.reduce((t, i) => t + i.faltam, 0)}</p>
        <p class="metrica-nota">${aFazer.length ? `${plural(aFazer.length, 'item', 'itens')} de pedidos em aberto` : 'Nenhum item esperando produção.'}</p>
      </div>
      <div class="metrica metrica-disponivel">
        <p class="metrica-rotulo"><i class="ti ti-box" aria-hidden="true"></i> Peças prontas</p>
        <p class="metrica-valor">${pecasProntas}</p>
        <p class="metrica-nota">No estoque, para usar em pedidos.</p>
      </div>
      <div class="metrica ${totalPerdas ? 'metrica-perda' : 'metrica-neutra'}">
        <p class="metrica-rotulo"><i class="ti ti-alert-triangle" aria-hidden="true"></i> Perdas do mês</p>
        <p class="metrica-valor">${brl(totalPerdas)}</p>
        <p class="metrica-nota">Falhas, peças perdidas e faltas no inventário.</p>
      </div>
    </div>

    <div class="acoes-caixa">
      <button class="botao botao-primario" data-registrar><i class="ti ti-printer" aria-hidden="true"></i> Registrar produção</button>
    </div>
    <p class="aviso aviso-ok" role="status" ${mensagem ? '' : 'hidden'}>${esc(mensagem || '')}</p>

    <section class="cartao">
      <h3>Itens a produzir</h3>
      ${aFazer.length ? `<ul class="lista">${aFazer.map(i => `
        <li class="linha">
          <div class="linha-texto">
            <strong>${esc(i.numero_formatado)} · ${esc(i.cliente)}</strong>
            <span>${i.quantidade} × ${esc(i.descricao)}</span>
            <span class="texto-secundario">${textoCores(i)}${i.data_prometida ? ` · Prazo ${dataBR(i.data_prometida)}` : ''}</span>
          </div>
          <div class="linha-direita">
            <span class="selo-p selo-despesa">Falta ${i.faltam}</span>
            <div class="linha-acoes">
              ${i.produto_id && lotesDe(i).length ? `<button class="botao botao-pequeno" data-usar="${i.item_id}">Usar peça pronta</button>` : ''}
              <button class="botao botao-pequeno botao-primario" data-produzir="${i.item_id}">Registrar</button>
            </div>
          </div>
        </li>`).join('')}</ul>` : '<p class="texto-secundario vazio">Nenhum item de pedido esperando produção.</p>'}
    </section>

    <section class="cartao">
      <h3>Peças prontas</h3>
      ${lotes.length ? `<ul class="lista">${lotes.map(l => `
        <li class="linha">
          <div class="linha-texto">
            <strong>${esc(nomeLote(l))}</strong>
            <span class="texto-secundario">${esc(l.cores_descricao)}</span>
            <span class="texto-secundario">Produzidas em ${dataBR(l.data)} · ${brl(l.custo_unitario)} cada</span>
          </div>
          <div class="linha-direita">
            <span class="linha-valor">${plural(l.saldo, 'peça', 'peças')}</span>
            <button class="botao botao-pequeno" data-baixar="${l.lote_id}">Baixar</button>
          </div>
        </li>`).join('')}</ul>` : '<p class="texto-secundario vazio">Nenhuma peça pronta no estoque.</p>'}
      ${saidas.length ? `<details class="detalhes-secao"><summary>Saídas recentes de peças prontas</summary>
        <ul class="lista">${saidas.map(s => `
          <li class="linha ${s.situacao === 'ESTORNADO' ? 'inativo' : ''}">
            <div class="linha-texto">
              <strong>${esc(TIPO_SAIDA[s.tipo])} · ${plural(s.quantidade, 'peça', 'peças')} ${s.situacao === 'ESTORNADO' ? '<span class="selo-p selo-inativo">Estornada</span>' : ''}</strong>
              <span class="texto-secundario">${dataBR(s.data)} · ${esc(nomeProduto(s.lote?.produto_id))} · ${esc(s.lote?.cores_descricao || '')}${s.obs ? ` · ${esc(s.obs)}` : ''}</span>
            </div>
            <div class="linha-direita">
              <span class="linha-valor">${brl(s.custo)}</span>
              ${s.situacao === 'ATIVO' ? `<button class="botao botao-pequeno" data-estornar-saida="${s.id}">Estornar</button>` : ''}
            </div>
          </li>`).join('')}</ul></details>` : ''}
    </section>

    <section class="cartao">
      <h3>Perdas do mês</h3>
      ${perdas.length ? `<ul class="lista">${perdas.map(p => `
        <li class="linha">
          <div class="linha-texto"><strong>${esc(p.motivo)}</strong><span class="texto-secundario">${dataBR(p.data)} · ${esc(p.descricao)}</span></div>
          <span class="linha-valor">${brl(p.valor)}</span>
        </li>`).join('')}
        <li class="linha linha-total"><strong>Total</strong><strong class="linha-valor">${brl(totalPerdas)}</strong></li></ul>`
        : '<p class="texto-secundario vazio">Nenhuma perda neste mês.</p>'}
    </section>

    <section class="cartao">
      <h3>Histórico de produções</h3>
      ${historico.length ? `<ul class="lista">${historico.map(h => `
        <li class="linha ${h.situacao === 'ESTORNADO' ? 'inativo' : ''}">
          <button type="button" class="linha-botao" data-producao="${h.id}">
            <span class="linha-texto">
              <strong>${esc(h.descricao)}</strong>
              <span class="texto-secundario">${dataBR(h.data)} · ${esc(DESTINO[h.destino])}${h.pecas ? ` · ${plural(h.pecas, 'peça', 'peças')}` : ''}</span>
              <span class="pedido-selos">${seloResultado(h)}</span>
            </span>
            <strong class="linha-valor">${brl(h.custo_total)}</strong>
          </button>
        </li>`).join('')}</ul>` : '<p class="texto-secundario vazio">Nenhuma produção registrada ainda.</p>'}
    </section>`;

  const depois = msg => recarregar(msg);
  area.querySelector('[data-registrar]').addEventListener('click', () => abrirRegistroProducao(sb, { dados, aoConcluir: depois }));
  area.querySelectorAll('[data-produzir]').forEach(b => b.addEventListener('click', () =>
    abrirRegistroProducao(sb, { dados, itemId: b.dataset.produzir, aoConcluir: depois })));
  area.querySelectorAll('[data-usar]').forEach(b => b.addEventListener('click', () =>
    abrirUsarPecaPronta(sb, { dados, itemId: b.dataset.usar, aoConcluir: depois })));
  area.querySelectorAll('[data-baixar]').forEach(b => b.addEventListener('click', () =>
    abrirBaixaPeca(sb, lotes.find(l => l.lote_id === b.dataset.baixar), depois)));
  area.querySelectorAll('[data-estornar-saida]').forEach(b => b.addEventListener('click', () => abrirFormulario({
    titulo: 'Estornar saída de peças prontas',
    textoSalvar: 'Estornar',
    campos: [{ nome: 'motivo', rotulo: 'Motivo do estorno', tipo: 'texto', obrigatorio: true, placeholder: 'Ex.: baixei errado',
      dica: 'As peças voltam para o estoque de prontas. O registro fica no histórico.' }],
    async aoSalvar(v) {
      if (!v.motivo?.trim()) throw new Error('Informe o motivo do estorno.');
      await sb.rpc('estornar_saida_peca', { p_id: b.dataset.estornarSaida, p_motivo: v.motivo.trim() }).then(ok);
      await depois('Saída estornada. As peças voltaram para o estoque de prontas.');
    },
  })));
  area.querySelectorAll('[data-producao]').forEach(b => b.addEventListener('click', () =>
    abrirDetalheProducao(sb, historico.find(h => h.id === b.dataset.producao), dados, depois)));
}

function seloResultado(h) {
  if (h.situacao === 'ESTORNADO') return '<span class="selo-p selo-inativo">Estornada</span>';
  if (h.resultado === 'FALHA') return `<span class="selo-p selo-pd-atrasado">Falha · ${paraCampo(h.percentual_impresso, 0, 2)}% impresso</span>`;
  return '<span class="selo-p selo-ativo">OK</span>';
}

function textoCores(i) {
  if (i.partes?.length) {
    return i.partes.map(p => `${esc(p.nome)}: ${p.cor_descricao ? esc(p.cor_descricao) : '<em>cor a definir</em>'}`).join(' · ');
  }
  return i.cor_descricao ? esc(i.cor_descricao) : (i.produto_id ? 'Do catálogo' : 'Personalizado');
}

// ---------------------------------------------------------------- folha
function abrirFolha(html, rotulo) {
  const dialog = document.createElement('dialog');
  dialog.className = 'folha folha-form folha-producao';
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

// ---------------------------------------------------------------- registrar produção
/**
 * Formulário de produção (R95–R96). opcoes: { dados?, itemId?, aoConcluir(msg) }.
 * Os números vêm da ficha × peças e podem ser ajustados (consumo real).
 */
export async function abrirRegistroProducao(sb, { dados, itemId = null, aoConcluir }) {
  if (!dados) dados = await carregarDados(sb);
  const { itens, produtos, estoque, mat, cfg, comVariacoes } = dados;
  const itensAbertos = itens.filter(i => i.faltam > 0 && ['AGUARDANDO', 'PRODUZINDO'].includes(i.status_pedido) || i.item_id === itemId);
  const produtosAtivos = produtos.filter(p => p.ativo);
  const semEnergia = !cfg.potencia_impressora_w || !cfg.tarifa_kwh;
  const chave = novaChave();

  const { dialog, fechar } = abrirFolha(`
    <form novalidate>
      <div class="folha-topo">
        <h2 id="form-producao">Registrar produção</h2>
        <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>
      ${semEnergia ? '<p class="aviso aviso-erro">Preencha a potência da impressora e a tarifa de energia em Configurações antes de registrar produções.</p>' : ''}
      <div class="grade-form">
        <div class="campo"><label for="pr-destino">Para onde vai</label>
          <select id="pr-destino" name="destino">
            ${Object.entries(DESTINO).map(([v, r]) => `<option value="${v}" ${v === (itemId || itensAbertos.length ? 'PEDIDO' : 'ESTOQUE') ? 'selected' : ''}>${r}</option>`).join('')}
          </select></div>
        <div class="campo"><label for="pr-resultado">Resultado</label>
          <select id="pr-resultado" name="resultado">
            <option value="OK">OK, peças boas</option>
            <option value="FALHA">Falha de impressão</option>
          </select></div>
      </div>

      <div class="campo" data-so="PEDIDO"><label for="pr-item">Item do pedido</label>
        <select id="pr-item" name="itemPedido">
          <option value="">Escolha o item</option>
          ${itensAbertos.map(i => `<option value="${i.item_id}" ${i.item_id === itemId ? 'selected' : ''}>${esc(i.numero_formatado)} · ${esc(i.cliente)} · ${i.quantidade} × ${esc(i.descricao)} (falta ${i.faltam})</option>`).join('')}
        </select>
        <small class="campo-dica" data-cores-item></small></div>
      <div class="campo" data-so="ESTOQUE" hidden><label for="pr-produto">Produto</label>
        <select id="pr-produto" name="produto">
          <option value="">Escolha o produto</option>
          ${produtosAtivos.map(p => `<option value="${p.id}">${esc(p.nome)}</option>`).join('')}
        </select></div>
      ${comVariacoes ? `<div class="campo" data-campo-variacao hidden><label for="pr-variacao">Combinação</label>
        <select id="pr-variacao" name="variacao"></select>
        <small class="campo-dica">As peças prontas ficam separadas por combinação e só vão para pedidos da mesma combinação.</small></div>` : ''}
      <div class="campo" data-so="AVULSA" hidden><label for="pr-desc">Descrição</label>
        <input type="text" id="pr-desc" name="descricao" maxlength="200" placeholder="Ex.: teste de calibração, brinde" autocomplete="off">
        <small class="campo-dica">Os materiais saem do estoque. Não gera peça pronta e não é perda.</small></div>

      <div class="grade-form">
        <div class="campo" data-pecas><label for="pr-pecas" data-rotulo-pecas>Peças prontas</label>
          <input type="text" inputmode="numeric" id="pr-pecas" name="pecas" value="1" autocomplete="off"></div>
        <div class="campo" data-so-falha hidden><label for="pr-pct">Quanto chegou a imprimir (%)</label>
          <input type="text" inputmode="decimal" id="pr-pct" name="pct" placeholder="Ex.: 60" autocomplete="off"></div>
        <div class="campo"><label for="pr-data">Data</label>
          <input type="date" id="pr-data" name="data" value="${hojeISO()}" max="${hojeISO()}"></div>
      </div>
      <fieldset class="itens-compra">
        <legend>Tempo de impressão</legend>
        <div class="grade-dois">
          <div class="campo"><label for="pr-h">Horas</label><input type="text" inputmode="numeric" id="pr-h" name="horas" placeholder="0" autocomplete="off"></div>
          <div class="campo"><label for="pr-m">Minutos</label><input type="text" inputmode="numeric" id="pr-m" name="minutos" placeholder="0 a 59" autocomplete="off"></div>
        </div>
      </fieldset>

      <fieldset class="itens-compra">
        <legend>Material usado</legend>
        <p class="campo-dica" data-dica-material></p>
        <div class="ficha-lista" data-linhas></div>
        <button type="button" class="botao-texto ficha-adicionar" data-add-linha><i class="ti ti-plus" aria-hidden="true"></i> Adicionar material</button>
      </fieldset>

      <div class="resumo-compra" data-resumo aria-live="polite"></div>
      <div class="campo"><label for="pr-obs">Observação <em>(opcional)</em></label>
        <input type="text" id="pr-obs" name="obs" maxlength="500" autocomplete="off"></div>

      <p class="aviso aviso-erro" role="alert" data-erro hidden></p>
      <div class="form-acoes">
        <span class="espaco"></span>
        <button type="button" class="botao" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">Registrar</button>
      </div>
    </form>`, 'form-producao');

  const form = dialog.querySelector('form');
  const linhasEl = dialog.querySelector('[data-linhas]');
  const erroEl = dialog.querySelector('[data-erro]');
  const resumoEl = dialog.querySelector('[data-resumo]');
  const f = form.elements;

  const atual = () => {
    const a = {
      destino: f.destino.value,
      falha: f.resultado.value === 'FALHA',
      item: itens.find(i => i.item_id === f.itemPedido.value) || null,
      produto: f.destino.value === 'PEDIDO'
        ? produtos.find(p => p.id === itens.find(i => i.item_id === f.itemPedido.value)?.produto_id) || null
        : f.destino.value === 'ESTOQUE' ? produtos.find(p => p.id === f.produto.value) || null : null,
    };
    // Combinação: a do item do pedido, ou a escolhida para o estoque.
    const vid = a.destino === 'PEDIDO' ? a.item?.variacao_id : a.destino === 'ESTOQUE' ? f.variacao?.value : null;
    a.variacao = vid ? a.produto?.variacoes?.find(v => v.id === vid) || null : null;
    // Ficha que vale: a da combinação, se tiver; senão a do produto (R113).
    a.ficha = a.variacao?.temFicha ? a.variacao : a.produto;
    return a;
  };
  /** Combinações ligadas do produto escolhido para o estoque. */
  function ajustarVariacao() {
    const caixa = dialog.querySelector('[data-campo-variacao]');
    if (!caixa) return;
    const p = f.destino.value === 'ESTOQUE' ? produtos.find(x => x.id === f.produto.value) : null;
    const vs = (p?.variacoes || []).filter(v => v.ativo);
    caixa.hidden = !vs.length;
    f.variacao.innerHTML = '<option value="">Escolha a combinação</option>'
      + vs.map(v => `<option value="${v.id}">${esc(combinacaoTexto(v.descricao))}</option>`).join('');
  }

  /** Materiais que podem entrar numa linha (filamento; insumo fora da falha; embalagem só na avulsa). */
  const opcoesMaterial = (a, escolhido) => estoque.filter(m => (m.ativo || m.material_id === escolhido)
    && (m.categoria === 'FILAMENTO' || (!a.falha && m.categoria === 'INSUMO') || (!a.falha && a.destino === 'AVULSA' && m.categoria === 'EMBALAGEM')));

  function linhaHtml(l, a) {
    const m = mat[l.material_id];
    const fixa = !!l.fixa;   // cor da parte escolhida no pedido
    const filamento = !m || m.categoria === 'FILAMENTO';
    return `<div class="ficha-linha linha-consumo" data-linha ${l.parte ? `data-parte="${esc(l.parte)}"` : ''}>
      <label class="campo campo-compacto ficha-nome"><span>${l.parte ? esc(l.parte) : 'Material'}</span>
        ${fixa ? `<input type="text" value="${esc(m ? nomeMat(m) : '')}" readonly tabindex="-1" class="campo-fixo"><input type="hidden" data-material value="${l.material_id}">`
          : `<select data-material>
              <option value="">Escolha</option>
              ${opcoesMaterial(a, l.material_id).map(o => `<option value="${o.material_id}" ${o.material_id === l.material_id ? 'selected' : ''}>${o.categoria === 'FILAMENTO' ? '' : (o.categoria === 'INSUMO' ? 'Insumo · ' : 'Embalagem · ')}${esc(nomeMat(o))}${o.ativo ? '' : ' (inativo)'}</option>`).join('')}
            </select>`}</label>
      <label class="campo campo-compacto"><span data-rotulo-qtd>${filamento ? 'Peça (g)' : `Quantidade (${esc(m.unidade)})`}</span>
        <input type="text" inputmode="decimal" data-peca value="${l.peca != null ? paraCampo(l.peca, 0, 3) : ''}" placeholder="0" autocomplete="off"></label>
      <label class="campo campo-compacto" ${filamento ? '' : 'data-sem-purga'}><span>Purga (g)</span>
        <input type="text" inputmode="decimal" data-purga value="${l.purga ? paraCampo(l.purga, 0, 3) : ''}" placeholder="0" autocomplete="off" ${filamento ? '' : 'disabled'}></label>
      ${l.parte ? '<span></span>' : '<button type="button" class="botao-icone" data-remover-linha aria-label="Remover material"><i class="ti ti-trash" aria-hidden="true"></i></button>'}
    </div>`;
  }

  /** Lê as linhas de material da tela. */
  function lerLinhas() {
    return [...linhasEl.querySelectorAll('[data-linha]')].map(el => ({
      parte: el.dataset.parte || null,
      material_id: el.querySelector('[data-material]').value || null,
      peca: lerDecimal(el.querySelector('[data-peca]').value || '0', 3),
      purga: el.querySelector('[data-purga]').disabled ? 0 : lerDecimal(el.querySelector('[data-purga]').value || '0', 3),
      fixa: el.querySelector('input[data-material]') ? true : false,
    }));
  }

  /** Preenche o material pela ficha × peças (falha: × percentual). Mantém cores já escolhidas. */
  function preencher() {
    const a = atual();
    const anteriores = Object.fromEntries(lerLinhas().filter(l => l.parte).map(l => [l.parte, l.material_id]));
    const pecas = Math.max(1, Number(f.pecas.value) || 1);
    const pct = a.falha ? (lerDecimal(f.pct.value || '0', 2) || 0) / 100 : 1;
    const fator = pecas * pct;
    let linhas = [];
    let dica = '';
    if (a.destino === 'PEDIDO' && a.item?.partes?.length) {
      linhas = a.item.partes.map(p => ({ parte: p.nome, material_id: p.material_id, fixa: true,
        peca: arred2(Number(p.gramas) * fator), purga: arred2(Number(p.purga_g) * fator) }));
      dica = 'As cores vêm do pedido. Os gramas vêm da ficha × peças: ajuste se gastou diferente.';
    } else if (a.destino === 'ESTOQUE' && a.ficha?.partes?.length) {
      linhas = a.ficha.partes.map(p => ({ parte: p.nome, material_id: anteriores[p.nome] || null,
        peca: arred2(Number(p.gramas) * fator), purga: arred2(Number(p.purga_g) * fator) }));
      dica = 'Escolha a cor de cada parte (as peças prontas ficam separadas pelas cores). Os gramas vêm da ficha × peças.';
    } else {
      linhas = [{ material_id: a.destino === 'PEDIDO' ? a.item?.material_id || null : null, peca: null, purga: 0 }];
      dica = a.produto || a.item ? 'Este produto não tem ficha: informe o filamento e os gramas usados.' : 'Informe o filamento e os gramas usados.';
    }
    if (!a.falha && a.ficha) {
      a.ficha.outros.filter(o => o.material.categoria === 'INSUMO').forEach(o =>
        linhas.push({ material_id: o.material_id, peca: arred2(Number(o.quantidade) * pecas * 1000) / 1000, purga: 0 }));
    }
    if (a.falha) dica += ' Na falha só sai filamento, na proporção do que imprimiu.';
    linhasEl.innerHTML = linhas.map(l => linhaHtml(l, a)).join('');
    dialog.querySelector('[data-dica-material]').textContent = dica;
    if (a.produto?.tempo_impressao_min) {
      const min = Math.round(a.produto.tempo_impressao_min * fator);
      f.horas.value = Math.floor(min / 60) || ''; f.minutos.value = min % 60 || (Math.floor(min / 60) ? '0' : '');
    }
    resumir();
  }

  function minutos() {
    const h = f.horas.value.trim(), m = f.minutos.value.trim();
    if ((h && !/^\d+$/.test(h)) || (m && !/^\d+$/.test(m))) return NaN;
    if (Number(m) > 59) return NaN;
    return (Number(h) || 0) * 60 + (Number(m) || 0);
  }

  function resumir() {
    let fil = 0, ins = 0;
    lerLinhas().forEach(l => {
      const m = mat[l.material_id];
      if (!m || !Number.isFinite(l.peca) || !Number.isFinite(l.purga)) return;
      const v = (l.peca + l.purga) * Number(m.custo_medio || 0);
      if (m.categoria === 'FILAMENTO') fil += v; else ins += v;
    });
    const min = minutos();
    const energia = semEnergia || !Number.isFinite(min) ? 0 : arred2(Number(cfg.potencia_impressora_w) / 1000 * min / 60 * Number(cfg.tarifa_kwh));
    const total = arred2(arred2(fil) + arred2(ins) + energia);
    const a = atual();
    const pecas = Number(f.pecas.value) || 0;
    resumoEl.innerHTML = `
      <div><span>Filamento</span><strong>${brl(fil)}</strong></div>
      ${ins ? `<div><span>Insumos</span><strong>${brl(ins)}</strong></div>` : ''}
      <div><span>Energia</span><strong>${semEnergia ? '—' : brl(energia)}</strong></div>
      <div class="resumo-total"><span>${a.falha ? 'Perda estimada' : 'Custo estimado'}</span><strong>${brl(total)}</strong></div>
      ${!a.falha && a.destino !== 'AVULSA' && pecas > 1 ? `<div class="resumo-outros"><span>Por peça</span><span>${brl(total / pecas)}</span></div>` : ''}
      <div class="resumo-outros"><span>Pelo custo médio de hoje; o valor exato é calculado ao registrar.</span></div>`;
  }

  function ajustarCampos() {
    const a = atual();
    dialog.querySelectorAll('[data-so]').forEach(x => { x.hidden = x.dataset.so !== a.destino; });
    dialog.querySelector('[data-so-falha]').hidden = !a.falha;
    dialog.querySelector('[data-pecas]').hidden = a.destino === 'AVULSA';
    dialog.querySelector('[data-rotulo-pecas]').textContent = a.falha ? 'Peças na impressão' : 'Peças prontas';
    const cores = dialog.querySelector('[data-cores-item]');
    cores.innerHTML = a.item ? textoCores(a.item) : '';
    if (a.destino === 'PEDIDO' && a.item) f.pecas.value = String(a.item.faltam || 1);
    form.querySelector('[type=submit]').textContent = a.falha ? 'Registrar falha' : 'Registrar';
  }

  form.addEventListener('change', e => {
    erroEl.hidden = true;
    if (['destino', 'produto'].includes(e.target.name)) ajustarVariacao();
    if (['destino', 'resultado', 'itemPedido', 'produto', 'variacao'].includes(e.target.name)) { ajustarCampos(); preencher(); return; }
    if (e.target.matches('[data-material]')) {
      // Troca de material numa linha livre: ajusta rótulo e purga (insumo não tem purga).
      const el = e.target.closest('[data-linha]');
      const m = mat[e.target.value];
      const filamento = !m || m.categoria === 'FILAMENTO';
      el.querySelector('[data-rotulo-qtd]').textContent = filamento ? 'Peça (g)' : `Quantidade (${m.unidade})`;
      const purga = el.querySelector('[data-purga]');
      purga.disabled = !filamento; if (!filamento) purga.value = '';
    }
    resumir();
  });
  form.addEventListener('input', e => {
    erroEl.hidden = true;
    if (e.target.name === 'pecas' || e.target.name === 'pct') { preencher(); return; }
    resumir();
  });
  dialog.querySelector('[data-add-linha]').addEventListener('click', () => {
    linhasEl.insertAdjacentHTML('beforeend', linhaHtml({ material_id: null, peca: null, purga: 0 }, atual()));
    linhasEl.lastElementChild.querySelector('select')?.focus();
  });
  linhasEl.addEventListener('click', e => {
    const b = e.target.closest('[data-remover-linha]');
    if (!b) return;
    b.closest('[data-linha]').remove();
    resumir();
  });

  form.addEventListener('submit', async e => {
    e.preventDefault();
    const falhar = msg => { erroEl.textContent = msg; erroEl.hidden = false; };
    const a = atual();
    try {
      if (a.destino === 'PEDIDO' && !a.item) throw new Error('Escolha o item do pedido.');
      if (a.destino === 'ESTOQUE' && !a.produto) throw new Error('Escolha o produto.');
      if (a.destino === 'ESTOQUE' && a.produto.variacoes?.length && !a.variacao) throw new Error('Escolha a combinação.');
      if (a.destino === 'AVULSA' && !f.descricao.value.trim()) throw new Error('Descreva a produção avulsa (ex.: teste de calibração, brinde).');
      const pecas = a.destino === 'AVULSA' ? null : Number(f.pecas.value);
      if (a.destino !== 'AVULSA' && !(Number.isInteger(pecas) && pecas >= 1)) throw new Error(a.falha ? 'Informe quantas peças estavam na impressão.' : 'Informe quantas peças ficaram prontas.');
      let pct = null;
      if (a.falha) {
        pct = lerDecimal(f.pct.value, 2);
        if (!Number.isFinite(pct) || pct <= 0 || pct > 100) throw new Error('Informe quanto chegou a imprimir antes da falha (de 1% a 100%).');
      }
      const data = f.data.value;
      if (!/^\d{4}-\d{2}-\d{2}$/.test(data)) throw new Error('Informe a data da produção.');
      if (data > hojeISO()) throw new Error('A data da produção não pode ser futura.');
      const min = minutos();
      if (!Number.isFinite(min)) throw new Error('Tempo: use números inteiros, com minutos de 0 a 59.');
      const linhas = lerLinhas();
      if (!linhas.length) throw new Error('Informe o material usado.');
      linhas.forEach((l, i) => {
        const rot = l.parte ? `Parte ${l.parte}` : `Material ${i + 1}`;
        if (!l.material_id) throw new Error(`${rot}: escolha o ${l.parte ? 'filamento' : 'material'}.`);
        if (!Number.isFinite(l.peca) || !Number.isFinite(l.purga) || l.peca < 0 || l.purga < 0 || l.peca + l.purga <= 0) {
          throw new Error(`${rot}: informe a quantidade usada.`);
        }
      });
      const botao = form.querySelector('[type=submit]');
      botao.disabled = true; botao.textContent = 'Registrando…';
      try {
        const r = await sb.rpc('registrar_producao', {
          p_data: data, p_destino: a.destino, p_resultado: a.falha ? 'FALHA' : 'OK',
          p_item_id: a.destino === 'PEDIDO' ? a.item.item_id : null,
          p_produto_id: a.destino === 'ESTOQUE' ? a.produto.id : null,
          p_descricao: a.destino === 'AVULSA' ? f.descricao.value.trim() : null,
          p_pecas: a.falha || a.destino === 'AVULSA' ? null : pecas,
          p_percentual: pct, p_tempo_min: min,
          p_consumos: linhas.map(l => ({ material_id: l.material_id, parte: l.parte, peca: String(l.peca), purga: String(l.purga) })),
          p_obs: f.obs.value.trim() || null, p_chave: chave,
          // Combinação só depois do sql/22 (antes, a função não tem este parâmetro).
          ...(comVariacoes ? { p_variacao_id: a.destino === 'ESTOQUE' ? a.variacao?.id || null : null } : {}),
        }).then(ok);
        fechar();
        const msg = a.falha ? `Falha registrada como perda de produção (${brl(r.custo_total)}).`
          : `Produção registrada (custo ${brl(r.custo_total)}).${r.pedido_pronto ? ` O pedido ${a.item.numero_formatado} está Pronto: todos os itens ficaram prontos.` : ''}${a.destino === 'ESTOQUE' ? ' As peças entraram nas peças prontas.' : ''}`;
        await aoConcluir?.(msg);
      } catch (err) {
        botao.disabled = false; botao.textContent = a.falha ? 'Registrar falha' : 'Registrar';
        throw err;
      }
    } catch (err) { falhar(err.message); }
  });

  ajustarVariacao();
  ajustarCampos();
  preencher();
}

// ---------------------------------------------------------------- peças prontas
/** Usar peças prontas num item de pedido (R98). */
export async function abrirUsarPecaPronta(sb, { dados, itemId, aoConcluir }) {
  if (!dados) dados = await carregarDados(sb);
  const item = dados.itens.find(i => i.item_id === itemId);
  if (!item) { window.alert('Item não encontrado.'); return; }
  const lotes = dados.lotes.filter(l => loteServe(l, item) && l.saldo > 0);
  if (!lotes.length) { window.alert(item.variacao_id ? 'Não há peças prontas desta combinação.' : 'Não há peças prontas deste produto.'); return; }
  const chave = novaChave();
  abrirFormulario({
    titulo: 'Usar peça pronta',
    textoSalvar: 'Usar no pedido',
    valores: { lote: lotes[0].lote_id, quantidade: Math.min(item.faltam, lotes[0].saldo) },
    campos: [
      { nome: 'lote', rotulo: 'Peças prontas', tipo: 'select', obrigatorio: true,
        opcoes: lotes.map(l => ({ valor: l.lote_id, rotulo: `${l.cores_descricao} · ${plural(l.saldo, 'pronta', 'prontas')} · ${brl(l.custo_unitario)} cada` })),
        dica: `${item.numero_formatado} · ${item.quantidade} × ${item.descricao} (falta ${item.faltam}). As cores do item passam a ser as da peça.` },
      { nome: 'quantidade', rotulo: 'Quantas peças', tipo: 'inteiro', obrigatorio: true },
    ],
    async aoSalvar(v) {
      const qtd = Number(v.quantidade);
      const lote = lotes.find(l => l.lote_id === v.lote);
      if (!Number.isInteger(qtd) || qtd < 1) throw new Error('Informe quantas peças usar.');
      if (qtd > item.faltam) throw new Error(`O item precisa de só mais ${item.faltam} peça(s).`);
      if (qtd > lote.saldo) throw new Error(`Só há ${lote.saldo} peça(s) nesta combinação.`);
      const r = await sb.rpc('usar_peca_pronta', { p_item_id: item.item_id, p_lote_id: lote.lote_id, p_quantidade: qtd, p_chave: chave }).then(ok);
      await aoConcluir?.(`${plural(qtd, 'peça pronta usada', 'peças prontas usadas')} no pedido ${item.numero_formatado}.${r.pedido_pronto ? ' O pedido está Pronto.' : ''}`);
    },
  });
}

/** Baixa manual de peças prontas com motivo (R98, R30). */
function abrirBaixaPeca(sb, lote, aoConcluir) {
  if (!lote) return;
  const chave = novaChave();
  abrirFormulario({
    titulo: `Baixar peças · ${lote.produto}`,
    textoSalvar: 'Baixar',
    valores: { quantidade: 1, tipo: 'SHOPEE', data: hojeISO() },
    campos: [
      { nome: 'quantidade', rotulo: 'Quantas peças', tipo: 'inteiro', obrigatorio: true, dica: `${lote.cores_descricao} · ${plural(lote.saldo, 'pronta', 'prontas')}` },
      { nome: 'tipo', rotulo: 'Motivo', tipo: 'select', obrigatorio: true, recarrega: true,
        opcoes: [{ valor: 'SHOPEE', rotulo: 'Venda na Shopee' }, { valor: 'BRINDE', rotulo: 'Brinde' },
                 { valor: 'PERDA', rotulo: 'Perda (quebrou, manchou…)' }, { valor: 'OUTRO', rotulo: 'Outro' }] },
      { nome: 'obs', rotulo: v => (['PERDA', 'OUTRO'].includes(v.tipo) ? 'Descreva o motivo' : 'Observação'), tipo: 'texto',
        obrigatorio: false, placeholder: 'Ex.: peça quebrou', dica: v => (v.tipo === 'PERDA' ? 'Entra nas perdas de produção.' : '') },
      { nome: 'data', rotulo: 'Data', tipo: 'data', obrigatorio: true, maxData: hojeISO() },
    ],
    async aoSalvar(v) {
      const qtd = Number(v.quantidade);
      if (!Number.isInteger(qtd) || qtd < 1) throw new Error('Informe quantas peças baixar.');
      if (qtd > lote.saldo) throw new Error(`Só há ${lote.saldo} peça(s) nesta combinação.`);
      if (['PERDA', 'OUTRO'].includes(v.tipo) && !v.obs?.trim()) throw new Error('Descreva o motivo (ex.: peça quebrou, ficou manchada).');
      await sb.rpc('baixar_peca_pronta', { p_lote_id: lote.lote_id, p_quantidade: qtd, p_tipo: v.tipo,
        p_obs: v.obs?.trim() || null, p_data: v.data, p_chave: chave }).then(ok);
      await aoConcluir(`${plural(qtd, 'peça baixada', 'peças baixadas')} (${TIPO_SAIDA[v.tipo]}).`);
    },
  });
}

// ---------------------------------------------------------------- detalhe
async function abrirDetalheProducao(sb, h, dados, aoConcluir) {
  if (!h) return;
  let consumos;
  try {
    consumos = await sb.from('producao_consumos').select('*').eq('producao_id', h.id).order('ordem').then(ok);
  } catch (e) { window.alert(e.message); return; }
  const linha = (rotulo, valor) => (valor ? `<div class="linha-dado"><span>${rotulo}</span><strong>${valor}</strong></div>` : '');
  const horas = `${Math.floor(h.tempo_min / 60)}h${String(h.tempo_min % 60).padStart(2, '0')}`;
  const { dialog, fechar } = abrirFolha(`
    <div class="folha-topo">
      <h2 id="det-producao">${esc(h.descricao)}</h2>
      <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
    </div>
    <p class="pedido-selos">${seloResultado(h)}</p>
    <div class="detalhe-dados">
      ${linha('Data', dataBR(h.data))}
      ${linha('Para onde', esc(DESTINO[h.destino]))}
      ${linha('Peças', h.pecas ? String(h.pecas) : '')}
      ${linha('Tempo', horas)}
      ${linha('Filamento', brl(h.custo_filamento))}
      ${Number(h.custo_insumos) ? linha('Insumos', brl(h.custo_insumos)) : ''}
      ${linha('Energia', brl(h.custo_energia))}
      ${linha(h.resultado === 'FALHA' ? 'Perda' : 'Custo total', brl(h.custo_total))}
      ${h.pecas > 1 ? linha('Por peça', brl(h.custo_total / h.pecas)) : ''}
      ${h.obs ? linha('Observação', esc(h.obs)) : ''}
      ${h.situacao === 'ESTORNADO' ? linha('Estornada', esc(h.motivo_estorno)) : ''}
    </div>
    <p class="detalhe-titulo">Material</p>
    <ul class="lista">${consumos.map(c => {
      const m = dados.mat[c.material_id];
      return `<li class="linha"><span class="linha-texto"><strong>${c.parte ? `${esc(c.parte)}: ` : ''}${esc(m ? nomeMat(m) : 'Material')}</strong>
        <span class="texto-secundario">${qtdTexto(c.quantidade_peca, m?.unidade || '')}${Number(c.quantidade_purga) ? ` + ${qtdTexto(c.quantidade_purga, m?.unidade || '')} de purga` : ''}</span></span>
        <span class="linha-valor">${brl(c.valor)}</span></li>`;
    }).join('')}</ul>
    <p class="aviso aviso-erro" role="alert" hidden></p>
    <div class="form-acoes">
      <span class="espaco"></span>
      ${h.situacao === 'ATIVO' ? '<button type="button" class="botao botao-perigo" data-estornar>Estornar</button>' : ''}
      <button type="button" class="botao" data-fechar>Fechar</button>
    </div>`, 'det-producao');
  dialog.querySelector('[data-estornar]')?.addEventListener('click', () => {
    fechar();
    abrirFormulario({
      titulo: 'Estornar produção',
      textoSalvar: 'Estornar',
      campos: [{ nome: 'motivo', rotulo: 'Motivo do estorno', tipo: 'texto', obrigatorio: true, placeholder: 'Ex.: registrei errado',
        dica: 'Os materiais voltam ao estoque pelo mesmo custo. O registro fica no histórico. O status do pedido não volta sozinho.' }],
      async aoSalvar(v) {
        if (!v.motivo?.trim()) throw new Error('Informe o motivo do estorno.');
        await sb.rpc('estornar_producao', { p_id: h.id, p_motivo: v.motivo.trim() }).then(ok);
        await aoConcluir('Produção estornada. Os materiais voltaram ao estoque.');
      },
    });
  });
}
