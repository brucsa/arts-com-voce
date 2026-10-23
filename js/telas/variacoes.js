// Variações de produto (Lote D1, sql/22, R112–R116): opções, combinações com
// preço e liga/desliga, e a ficha de consumo opcional de cada combinação.
// Antes do sql/22 as tabelas não existem: carregarVariacoes devolve false e
// as telas seguem como antes, sem variações.

import { ok } from '../db.js';
import { esc, brl, lerDecimal, paraCampo, dinheiroCampo } from '../format.js';
import { cliqueForaDoDialogo } from '../ui/dialogo.js';

const MAX_OPCOES = 3;
const MAX_VALORES = 20;
const MAX_COMBINACOES = 200;

/** Carrega opções, combinações e fichas das combinações e prende em cada produto. */
export async function carregarVariacoes(sb, produtos) {
  const [opc, val, vars, vv, partes, mats] = await Promise.all([
    sb.from('produto_opcoes').select('id, produto_id, ordem, nome').order('ordem'),
    sb.from('produto_opcao_valores').select('id, opcao_id, ordem, valor').order('ordem'),
    sb.from('produto_variacoes').select('id, produto_id, descricao, preco, ativo, ordem').order('ordem'),
    sb.from('produto_variacao_valores').select('variacao_id, valor_id'),
    sb.from('variacao_partes').select('variacao_id, ordem, nome, gramas, purga_g').order('ordem'),
    sb.from('variacao_materiais').select('variacao_id, material_id, quantidade'),
  ]);
  if ([opc, val, vars, vv, partes, mats].some(r => r.error)) {
    produtos.forEach(p => Object.assign(p, { opcoes: [], variacoes: [] }));
    return false;
  }
  produtos.forEach(p => {
    p.opcoes = opc.data.filter(o => o.produto_id === p.id)
      .map(o => ({ ...o, valores: val.data.filter(v => v.opcao_id === o.id) }));
    p.variacoes = vars.data.filter(v => v.produto_id === p.id).map(v => {
      const ps = partes.data.filter(x => x.variacao_id === v.id);
      const ms = mats.data.filter(x => x.variacao_id === v.id);
      return { ...v, valores: vv.data.filter(x => x.variacao_id === v.id).map(x => x.valor_id),
               partes: ps, outros: ms, temFicha: ps.length > 0 || ms.length > 0 };
    });
  });
  return true;
}

/** Preço do produto com combinações (R114): "a partir de" o menor preço das ligadas. */
export function precoVariacoes(p) {
  const ligadas = (p.variacoes || []).filter(v => v.ativo);
  if (!ligadas.length) return null;
  const precos = ligadas.filter(v => v.preco != null).map(v => Number(v.preco));
  if (!precos.length) return { texto: 'Sob consulta', minimo: null };
  return { texto: `a partir de ${brl(Math.min(...precos))}`, minimo: Math.min(...precos) };
}

/** Combinações no detalhe do produto. */
export function htmlCombinacoesDetalhe(p, comFicha) {
  if (!p.variacoes?.length) return '';
  return `<p class="detalhe-titulo">Combinações <span class="texto-secundario">(${p.opcoes.map(o => esc(o.nome)).join(' × ')})</span></p>
    <ul class="lista-combinacoes">${p.variacoes.map(v => `
      <li class="${v.ativo ? '' : 'inativo'}">
        <span class="combinacao-nome">${esc(v.descricao)}${v.ativo ? '' : ' <span class="selo-p selo-inativo">Desligada</span>'}</span>
        <strong>${v.preco == null ? 'Sob consulta' : brl(v.preco)}</strong>
        ${comFicha ? `<button type="button" class="botao botao-pequeno" data-ficha-variacao="${v.id}">
          ${v.temFicha ? 'Ficha própria' : 'Ficha do produto'}</button>` : ''}
      </li>`).join('')}</ul>`;
}

// ---------------------------------------------------------------- editor no formulário do produto
let seq = 0;
/** "29,9" → "R$ 29,90"; texto que não é valor fica como está (o erro aparece ao salvar). */
const emReais = t => { const v = lerDecimal(t, 2); return String(t ?? '').trim() && Number.isFinite(v) && v >= 0 ? dinheiroCampo(v) : String(t ?? '').trim(); };
const novaChave = () => `n${Date.now().toString(36)}${(seq++).toString(36)}`;
const chaveComb = chaves => [...chaves].sort().join('|');

/**
 * Editor de opções e combinações dentro do formulário do produto.
 * Devolve { ler(): { opcoes, combinacoes } | lança Error, mudou(): boolean }.
 */
export function montarEditorVariacoes(el, p, precoPadrao) {
  // Estado: opções com valores (id quando já existe; chave para as novas)
  let opcoes = (p?.opcoes || []).map(o => ({ id: o.id, chave: o.id, nome: o.nome,
    valores: o.valores.map(v => ({ id: v.id, chave: v.id, valor: v.valor })) }));
  // Preço e liga/desliga de cada combinação, pela chave dos valores
  const combs = new Map((p?.variacoes || []).map(v => [chaveComb(v.valores), {
    preco: v.preco == null ? '' : dinheiroCampo(v.preco), ativo: v.ativo, usada: false }]));
  const original = JSON.stringify(payload(true));

  function combinacoes() {
    const listas = opcoes.map(o => o.valores.filter(v => v.valor.trim()));
    if (!opcoes.length || listas.some(l => !l.length)) return [];
    let res = [[]];
    for (const l of listas) res = res.flatMap(r => l.map(v => [...r, v]));
    return res;
  }

  // Duas áreas: as opções e as combinações. Ao sair de um valor só as
  // combinações são redesenhadas, para não perder o clique em outro botão.
  el.innerHTML = '<div data-area-opcoes></div><div data-area-combinacoes></div>';
  const areaOpcoes = el.querySelector('[data-area-opcoes]');
  const areaComb = el.querySelector('[data-area-combinacoes]');
  function desenhar() { desenharOpcoes(); desenharCombinacoes(); }
  function desenharOpcoes() {
    areaOpcoes.innerHTML = `
      ${opcoes.map((o, i) => `
        <div class="opcao-variacao" data-opcao="${i}">
          <div class="opcao-topo">
            <label class="campo campo-compacto"><span>Opção ${i + 1}</span>
              <input type="text" data-nome-opcao maxlength="30" value="${esc(o.nome)}" placeholder="Ex.: Cor da flor" autocomplete="off"></label>
            <button type="button" class="botao-icone" data-tirar-opcao aria-label="Tirar a opção ${esc(o.nome || i + 1)}"><i class="ti ti-trash" aria-hidden="true"></i></button>
          </div>
          <div class="valores-opcao">
            ${o.valores.map((v, j) => `<span class="valor-opcao">
              <input type="text" data-valor="${j}" maxlength="40" value="${esc(v.valor)}" placeholder="Ex.: Rosa claro" autocomplete="off" aria-label="Valor ${j + 1} de ${esc(o.nome || `opção ${i + 1}`)}">
              <button type="button" class="botao-icone" data-tirar-valor="${j}" aria-label="Tirar o valor ${esc(v.valor || j + 1)}"><i class="ti ti-x" aria-hidden="true"></i></button></span>`).join('')}
            ${o.valores.length < MAX_VALORES ? '<button type="button" class="botao-texto" data-add-valor><i class="ti ti-plus" aria-hidden="true"></i> Valor</button>' : ''}
          </div>
        </div>`).join('')}
      ${opcoes.length < MAX_OPCOES ? `<button type="button" class="botao-texto ficha-adicionar" data-add-opcao><i class="ti ti-plus" aria-hidden="true"></i> ${opcoes.length ? 'Adicionar opção' : 'Adicionar variações (ex.: Cor da flor, Tamanho)'}</button>` : ''}`;
  }
  function desenharCombinacoes() {
    const lista = combinacoes();
    areaComb.innerHTML = `
      ${lista.length ? `<p class="ficha-subtitulo">Combinações (${lista.length})</p>
        <p class="campo-dica">Cada combinação tem o preço dela; vazio = sob consulta. Desmarque para não oferecer.</p>
        <div class="lista-combinacoes-form">${lista.map(c => {
          const k = chaveComb(c.map(v => v.chave));
          const st = combs.get(k) || { preco: emReais(precoPadrao()), ativo: true };
          combs.set(k, st);
          return `<div class="linha-combinacao" data-comb="${esc(k)}">
            <span class="combinacao-nome">${c.map(v => esc(v.valor.trim())).join(' · ')}</span>
            <label class="campo campo-compacto"><span>Preço (R$)</span>
              <input type="text" inputmode="decimal" data-dinheiro data-preco-comb value="${esc(st.preco)}" placeholder="R$ 0,00" autocomplete="off"></label>
            <label class="campo-check-inline"><input type="checkbox" data-ativa-comb ${st.ativo ? 'checked' : ''}> Ligada</label>
          </div>`;
        }).join('')}</div>` : ''}
      ${lista.length > MAX_COMBINACOES ? `<p class="campo-erro">São ${lista.length} combinações; o limite é ${MAX_COMBINACOES}.</p>` : ''}`;
  }

  el.addEventListener('click', e => {
    const op = e.target.closest('[data-opcao]');
    const i = op ? Number(op.dataset.opcao) : -1;
    if (e.target.closest('[data-add-opcao]')) {
      opcoes.push({ chave: novaChave(), nome: '', valores: [{ chave: novaChave(), valor: '' }] });
      desenhar(); el.querySelector(`[data-opcao="${opcoes.length - 1}"] [data-nome-opcao]`)?.focus();
    } else if (e.target.closest('[data-tirar-opcao]')) {
      opcoes.splice(i, 1); desenhar();
    } else if (e.target.closest('[data-add-valor]')) {
      opcoes[i].valores.push({ chave: novaChave(), valor: '' }); desenhar();
      el.querySelector(`[data-opcao="${i}"] [data-valor="${opcoes[i].valores.length - 1}"]`)?.focus();
    } else if (e.target.closest('[data-tirar-valor]')) {
      opcoes[i].valores.splice(Number(e.target.closest('[data-tirar-valor]').dataset.tirarValor), 1); desenhar();
    }
  });
  el.addEventListener('input', e => {
    const op = e.target.closest('[data-opcao]');
    if (e.target.matches('[data-nome-opcao]')) opcoes[Number(op.dataset.opcao)].nome = e.target.value;
    else if (e.target.matches('[data-valor]')) {
      opcoes[Number(op.dataset.opcao)].valores[Number(e.target.dataset.valor)].valor = e.target.value;
      // O nome das combinações acompanha o valor (sem redesenhar enquanto digita)
      el.querySelectorAll('[data-comb]').forEach(row => {
        const ks = row.dataset.comb.split('|');
        const nomes = opcoes.map(o => o.valores.find(v => ks.includes(v.chave))?.valor.trim() || '');
        row.querySelector('.combinacao-nome').textContent = nomes.join(' · ');
      });
    } else if (e.target.matches('[data-preco-comb]')) combs.get(e.target.closest('[data-comb]').dataset.comb).preco = e.target.value;
  });
  el.addEventListener('change', e => {
    if (e.target.matches('[data-ativa-comb]')) combs.get(e.target.closest('[data-comb]').dataset.comb).ativo = e.target.checked;
    if (e.target.matches('[data-preco-comb]')) {
      e.target.value = emReais(e.target.value);
      combs.get(e.target.closest('[data-comb]').dataset.comb).preco = e.target.value;
    }
    // Valor apagado ou preenchido muda as combinações: redesenha ao sair do campo
    if (e.target.matches('[data-valor]')) desenharCombinacoes();
  });

  function payload(semValidar = false) {
    const ops = opcoes.map((o, i) => {
      const nome = o.nome.trim();
      if (!semValidar && !nome) throw new Error(`Variações: dê nome à opção ${i + 1} (ex.: Tamanho, Cor).`);
      const valores = o.valores.filter(v => v.valor.trim());
      if (!semValidar && !valores.length) throw new Error(`Variações: a opção "${nome}" precisa de pelo menos um valor.`);
      return { id: o.id || null, chave: o.chave, nome,
               valores: valores.map(v => ({ id: v.id || null, chave: v.chave, valor: v.valor.trim() })) };
    });
    const lista = combinacoes();
    if (!semValidar && lista.length > MAX_COMBINACOES) throw new Error(`Variações: são ${lista.length} combinações; o limite é ${MAX_COMBINACOES}.`);
    const cs = lista.map(c => {
      const k = chaveComb(c.map(v => v.chave));
      const st = combs.get(k) || { preco: '', ativo: true };
      const t = String(st.preco ?? '').trim();
      const preco = t === '' ? null : lerDecimal(t, 2);
      if (!semValidar && preco != null && (!Number.isFinite(preco) || preco < 0)) {
        throw new Error(`Variações: preço inválido na combinação ${c.map(v => v.valor.trim()).join(' · ')}.`);
      }
      return { valores: c.map(v => v.chave), preco: preco == null || !Number.isFinite(preco) ? null : String(preco), ativo: !!st.ativo };
    });
    return { opcoes: ops, combinacoes: cs };
  }

  desenhar();
  return {
    ler: () => payload(false),
    mudou: () => JSON.stringify(payload(true)) !== original,
  };
}

// ---------------------------------------------------------------- ficha da combinação
/**
 * Ficha de consumo de uma combinação (R113). Começa com a ficha própria ou,
 * se não tiver, com a do produto (para ajustar). "Usar a do produto" apaga a
 * ficha própria.
 */
export function abrirFichaVariacao({ sb, p, v, materiais, aoConcluir }) {
  const base = v.temFicha ? v : p;
  const dialog = document.createElement('dialog');
  dialog.className = 'folha folha-form';
  dialog.setAttribute('aria-labelledby', 'ficha-var-titulo');
  const opcoesMat = atual => materiais.filter(m => m.ativo || m.id === atual).map(m =>
    `<option value="${m.id}" ${m.id === atual ? 'selected' : ''}>${m.categoria === 'EMBALAGEM' ? 'Embalagem' : 'Insumo'} · ${esc(m.tipo)}${m.variacao ? ` · ${esc(m.variacao)}` : ''} (${esc(m.unidade)})${m.ativo ? '' : ' (inativo)'}</option>`).join('');
  const linhaParte = (x = {}) => `<div class="ficha-linha" data-parte>
    <label class="campo campo-compacto ficha-nome"><span>Parte</span><input type="text" data-nome maxlength="60" value="${esc(x.nome || '')}" autocomplete="off"></label>
    <label class="campo campo-compacto"><span>Peça (g)</span><input type="text" inputmode="decimal" data-g value="${x.gramas != null ? paraCampo(x.gramas, 0, 2) : ''}" autocomplete="off"></label>
    <label class="campo campo-compacto"><span>Purga (g)</span><input type="text" inputmode="decimal" data-purga value="${Number(x.purga_g) ? paraCampo(x.purga_g, 0, 2) : ''}" autocomplete="off"></label>
    <button type="button" class="botao-icone" data-remover-linha aria-label="Remover parte"><i class="ti ti-trash" aria-hidden="true"></i></button></div>`;
  const linhaOutro = (x = {}) => `<div class="ficha-linha ficha-linha-outro" data-outro>
    <label class="campo campo-compacto ficha-nome"><span>Material</span><select data-material><option value="">Escolha</option>${opcoesMat(x.material_id)}</select></label>
    <label class="campo campo-compacto"><span>Quantidade</span><input type="text" inputmode="decimal" data-qtd value="${x.quantidade != null ? paraCampo(x.quantidade, 0, 3) : ''}" autocomplete="off"></label>
    <button type="button" class="botao-icone" data-remover-linha aria-label="Remover material"><i class="ti ti-trash" aria-hidden="true"></i></button></div>`;
  dialog.innerHTML = `
    <form novalidate>
      <div class="folha-topo">
        <h2 id="ficha-var-titulo">Ficha · ${esc(p.nome)} · ${esc(v.descricao)}</h2>
        <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>
      <p class="campo-dica">${v.temFicha ? 'Esta combinação tem ficha própria.'
        : 'Esta combinação usa a ficha do produto. Ajuste abaixo e salve para ela ter a ficha dela.'}
        A produção e os pedidos desta combinação usam esta ficha.</p>
      <p class="ficha-subtitulo">Partes impressas</p>
      <div class="ficha-lista" data-partes>${(base.partes || []).map(linhaParte).join('')}</div>
      <button type="button" class="botao-texto ficha-adicionar" data-add-parte><i class="ti ti-plus" aria-hidden="true"></i> Adicionar parte</button>
      <p class="ficha-subtitulo">Outros materiais</p>
      <div class="ficha-lista" data-outros>${(base.outros || []).map(linhaOutro).join('')}</div>
      <button type="button" class="botao-texto ficha-adicionar" data-add-outro><i class="ti ti-plus" aria-hidden="true"></i> Adicionar material</button>
      <p class="aviso aviso-erro" role="alert" hidden></p>
      <div class="form-acoes">
        ${v.temFicha ? '<button type="button" class="botao" data-usar-produto>Usar a ficha do produto</button>' : ''}
        <span class="espaco"></span>
        <button type="button" class="botao" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">Salvar ficha</button>
      </div>
    </form>`;
  document.body.appendChild(dialog);
  const fechar = () => { dialog.close(); dialog.remove(); };
  dialog.addEventListener('click', e => {
    if (cliqueForaDoDialogo(e, dialog) || e.target.closest('[data-fechar]')) { fechar(); return; }
    if (e.target.closest('[data-add-parte]')) dialog.querySelector('[data-partes]').insertAdjacentHTML('beforeend', linhaParte());
    if (e.target.closest('[data-add-outro]')) dialog.querySelector('[data-outros]').insertAdjacentHTML('beforeend', linhaOutro());
    const r = e.target.closest('[data-remover-linha]'); if (r) r.closest('.ficha-linha').remove();
  });
  dialog.addEventListener('cancel', e => { e.preventDefault(); fechar(); });
  const erro = dialog.querySelector('.aviso-erro');
  const gravar = async (partes, materiais_) => {
    await sb.rpc('salvar_ficha_variacao', { p_variacao_id: v.id, p_partes: partes, p_materiais: materiais_ }).then(ok);
    fechar(); await aoConcluir();
  };
  dialog.querySelector('[data-usar-produto]')?.addEventListener('click', async () => {
    try { await gravar([], []); } catch (err) { erro.textContent = err.message; erro.hidden = false; }
  });
  dialog.querySelector('form').addEventListener('submit', async e => {
    e.preventDefault();
    try {
      // Número lido do jeito brasileiro; texto inválido segue como está e o banco explica o erro.
      const num = (t, casas) => { const n = lerDecimal(t, casas); return Number.isFinite(n) ? String(n) : t.trim(); };
      const partes = [...dialog.querySelectorAll('[data-parte]')].map(el => ({
        nome: el.querySelector('[data-nome]').value.trim(),
        gramas: num(el.querySelector('[data-g]').value, 2),
        purga_g: num(el.querySelector('[data-purga]').value.trim() || '0', 2),
      })).filter(x => x.nome || x.gramas);
      const mats = [...dialog.querySelectorAll('[data-outro]')].map(el => ({
        material_id: el.querySelector('[data-material]').value,
        quantidade: num(el.querySelector('[data-qtd]').value, 3),
      })).filter(x => x.material_id || x.quantidade);
      if (!partes.length && !mats.length) throw new Error('Informe pelo menos uma parte ou um material, ou use a ficha do produto.');
      await gravar(partes, mats);
    } catch (err) { erro.textContent = err.message; erro.hidden = false; }
  });
  dialog.showModal();
}
