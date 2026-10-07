// Etapa 3 · Nova compra de estoque (R49 a R51)
import { supabase } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, hojeISO, lerValor, lerDecimal } from '../format.js';
import { FORMAS, pagoNaHora } from '../financeiro.js';
import { CATEGORIA_MATERIAL, nomeMaterial, ratear, custoUnitario } from '../estoque-util.js';
import { cliqueForaDoDialogo } from '../ui/dialogo.js';

/**
 * Abre a folha de nova compra.
 * aoConcluir(resultado, cabecalho) é chamado depois de salvar.
 * resultado traz valor_outros_final quando o pedido teve outros itens (R51).
 */
export async function abrirNovaCompra({ aoConcluir }) {
  const sb = await supabase();
  const [materiais, categorias] = await Promise.all([
    sb.from('materiais').select('id, categoria, tipo, variacao, unidade, ativo').eq('ativo', true)
      .order('categoria').order('tipo').order('variacao').then(ok),
    sb.from('categorias_lanc').select('id, nome, natureza, ativo').eq('natureza', 'ESTOQUE').eq('ativo', true)
      .order('nome').then(ok),
  ]);
  if (!materiais.length) { window.alert('Cadastre os materiais em Configurações → Materiais antes de registrar uma compra.'); return; }
  if (!categorias.length) { window.alert('Não há categoria de Estoque ativa em Configurações → Categorias.'); return; }

  const MAT = Object.fromEntries(materiais.map(m => [m.id, m]));
  // Sugestão de categoria pelo tipo do primeiro material (Filamento → "Filamentos" etc.)
  const sugerirCategoria = (matId) => {
    const plural = CATEGORIA_MATERIAL[MAT[matId]?.categoria]?.plural?.toLowerCase();
    return categorias.find(c => c.nome.toLowerCase() === plural)?.id;
  };

  const opcoesMaterial = `<option value="">Escolha…</option>` + Object.keys(CATEGORIA_MATERIAL).map(cat => {
    const lista = materiais.filter(m => m.categoria === cat);
    return lista.length ? `<optgroup label="${CATEGORIA_MATERIAL[cat].plural}">${lista.map(m =>
      `<option value="${m.id}">${esc(nomeMaterial(m))} (${m.unidade})</option>`).join('')}</optgroup>` : '';
  }).join('');

  const dialog = document.createElement('dialog');
  dialog.className = 'folha folha-form folha-larga';
  dialog.setAttribute('aria-labelledby', 'compra-titulo');
  dialog.innerHTML = `
    <form novalidate>
      <div class="folha-topo">
        <h2 id="compra-titulo">Nova compra de estoque</h2>
        <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>

      <div class="grade-form">
        <div class="campo"><label for="c-data">Data da compra</label>
          <input type="date" id="c-data" name="data" value="${hojeISO()}" max="${hojeISO()}"></div>
        <div class="campo"><label for="c-categoria">Categoria</label>
          <select id="c-categoria" name="categoria">${categorias.map(c => `<option value="${c.id}">${esc(c.nome)}</option>`).join('')}</select></div>
        <div class="campo"><label for="c-fornecedor">Fornecedor <em>(opcional)</em></label>
          <input type="text" id="c-fornecedor" name="fornecedor" placeholder="Loja ou site" autocomplete="off"></div>
        <div class="campo"><label for="c-forma">Forma de pagamento</label>
          <select id="c-forma" name="forma">${FORMAS.map(f => `<option value="${f.valor}">${f.rotulo}</option>`).join('')}</select></div>
      </div>
      <div class="campo campo-check">
        <label><input type="checkbox" name="pago" checked><span>Já foi pago</span></label>
        <small class="campo-dica" data-dica-pago>O valor sai do caixa na data do pagamento.</small>
      </div>
      <div class="campo" data-bloco-data-pag><label for="c-data-pag">Data do pagamento</label>
        <input type="date" id="c-data-pag" name="data_pagamento" value="${hojeISO()}" max="${hojeISO()}"></div>

      <fieldset class="itens-compra">
        <legend>Itens</legend>
        <p class="campo-dica">Valor pago por item. Se o desconto foi só de um item, digite o valor já com desconto.</p>
        <div data-itens></div>
        <button type="button" class="botao botao-pequeno" data-add><i class="ti ti-plus" aria-hidden="true"></i> Adicionar item</button>
      </fieldset>

      <fieldset class="itens-compra">
        <legend>Pedido</legend>
        <div class="grade-form">
          <div class="campo"><label for="c-frete">Frete do pedido (R$) <em>(opcional)</em></label>
            <input type="text" inputmode="decimal" id="c-frete" name="frete" placeholder="0,00"></div>
          <div class="campo"><label for="c-desc">Desconto geral do pedido (R$) <em>(opcional)</em></label>
            <input type="text" inputmode="decimal" id="c-desc" name="desconto" placeholder="0,00"></div>
        </div>
        <small class="campo-dica">Frete e desconto geral são divididos entre os itens, proporcionalmente ao valor de cada um.</small>
        <div class="campo campo-check">
          <label><input type="checkbox" name="tem_outros"><span>O pedido também teve itens que não são estoque (ferramenta, peça, etc.)</span></label>
        </div>
        <div class="campo" data-bloco-outros hidden><label for="c-outros">Valor desses outros itens (R$)</label>
          <input type="text" inputmode="decimal" id="c-outros" name="outros" placeholder="0,00">
          <small class="campo-dica">Eles serão lançados como gasto separado. O frete e o desconto são divididos entre as duas partes.</small></div>
      </fieldset>

      <div class="campo"><label for="c-obs">Observação <em>(opcional)</em></label>
        <input type="text" id="c-obs" name="obs" autocomplete="off"></div>

      <div class="resumo-compra" aria-live="polite" data-resumo></div>
      <p class="aviso aviso-erro" role="alert" hidden></p>
      <div class="form-acoes">
        <span class="espaco"></span>
        <button type="button" class="botao" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">Registrar compra</button>
      </div>
    </form>`;
  document.body.appendChild(dialog);

  const form = dialog.querySelector('form');
  const listaItens = dialog.querySelector('[data-itens]');
  const erro = dialog.querySelector('.aviso-erro');
  let categoriaTocada = false;
  let n = 0;

  function novaLinha() {
    n += 1;
    const div = document.createElement('div');
    div.className = 'item-compra';
    div.innerHTML = `
      <div class="campo"><label for="i-mat-${n}">Material</label>
        <select id="i-mat-${n}" data-campo="material">${opcoesMaterial}</select></div>
      <div class="campo"><label for="i-qtd-${n}">Quantidade <span data-unidade></span></label>
        <input type="text" inputmode="decimal" id="i-qtd-${n}" data-campo="quantidade" placeholder="1000"></div>
      <div class="campo"><label for="i-val-${n}">Valor pago (R$)</label>
        <input type="text" inputmode="decimal" id="i-val-${n}" data-campo="valor" placeholder="0,00"></div>
      <div class="campo"><label for="i-marca-${n}">Marca <em>(opcional)</em></label>
        <input type="text" id="i-marca-${n}" data-campo="marca" autocomplete="off"></div>
      <div class="item-compra-rodape">
        <small class="campo-dica" data-custo-item></small>
        <button type="button" class="botao-texto" data-remover>Remover</button>
      </div>`;
    listaItens.appendChild(div);
    return div;
  }

  function lerItens() {
    return [...listaItens.querySelectorAll('.item-compra')].map(div => {
      const get = c => div.querySelector(`[data-campo="${c}"]`).value;
      return {
        div,
        material_id: get('material'),
        quantidade: lerDecimal(get('quantidade'), 3),
        valor: lerValor(get('valor')),
        marca: get('marca').trim(),
      };
    });
  }

  function atualizar() {
    const itens = lerItens();
    const frete = lerValor(form.elements.frete.value) || 0;
    const desconto = lerValor(form.elements.desconto.value) || 0;
    const temOutros = form.elements.tem_outros.checked;
    const outros = temOutros ? (lerValor(form.elements.outros.value) || 0) : 0;
    dialog.querySelector('[data-bloco-outros]').hidden = !temOutros;

    const validos = itens.map(i => ({ valor: Number.isFinite(i.valor) && i.valor > 0 ? i.valor : 0 }));
    const r = ratear({ itens: validos, frete, desconto, outros });

    itens.forEach((it, idx) => {
      const m = MAT[it.material_id];
      it.div.querySelector('[data-unidade]').textContent = m ? `(${m.unidade})` : '';
      const dica = it.div.querySelector('[data-custo-item]');
      const c = r.itens[idx];
      if (m && Number.isFinite(it.quantidade) && it.quantidade > 0 && c.custo > 0) {
        const extra = (c.frete || c.desconto) ? ` (com ${c.frete ? `frete ${brl(c.frete)}` : ''}${c.frete && c.desconto ? ' e ' : ''}${c.desconto ? `desconto ${brl(c.desconto)}` : ''})` : '';
        dica.textContent = `Custo: ${brl(c.custo)}${extra} · ${custoUnitario(c.custo / it.quantidade, m.unidade)}`;
      } else dica.textContent = '';
    });
    listaItens.querySelectorAll('[data-remover]').forEach(b => { b.hidden = itens.length === 1; });

    dialog.querySelector('[data-resumo]').innerHTML = `
      <div><span>Itens</span><strong>${brl(r.soma)}</strong></div>
      ${frete ? `<div><span>Frete nesta compra</span><strong>+ ${brl(r.freteCompra)}</strong></div>` : ''}
      ${desconto ? `<div><span>Desconto nesta compra</span><strong>− ${brl(r.descontoCompra)}</strong></div>` : ''}
      <div class="resumo-total"><span>Total da compra</span><strong>${brl(r.totalCompra)}</strong></div>
      ${temOutros && outros > 0 ? `<div class="resumo-outros"><span>Gasto separado dos outros itens
        (${brl(outros)}${r.freteOutros ? ` + frete ${brl(r.freteOutros)}` : ''}${r.descontoOutros ? ` − desconto ${brl(r.descontoOutros)}` : ''})</span>
        <strong>${brl(r.outrosFinal)}</strong></div>` : ''}`;
    return { itens, frete, desconto, outros, temOutros, r };
  }

  const fechar = () => { dialog.close(); dialog.remove(); };

  dialog.querySelector('[data-add]').addEventListener('click', () => { novaLinha().querySelector('select').focus(); atualizar(); });
  listaItens.addEventListener('click', e => {
    const b = e.target.closest('[data-remover]');
    if (b) { b.closest('.item-compra').remove(); atualizar(); }
  });
  form.addEventListener('input', () => { erro.hidden = true; atualizar(); });
  form.addEventListener('change', e => {
    if (e.target.name === 'categoria') categoriaTocada = true;
    if (e.target.dataset.campo === 'material' && !categoriaTocada) {
      const primeiro = listaItens.querySelector('[data-campo="material"]').value;
      const sug = sugerirCategoria(primeiro);
      if (sug) form.elements.categoria.value = sug;
    }
    if (e.target.name === 'forma') form.elements.pago.checked = pagoNaHora(e.target.value);
    const pago = form.elements.pago.checked;
    dialog.querySelector('[data-bloco-data-pag]').hidden = !pago;
    dialog.querySelector('[data-dica-pago]').textContent = pago
      ? 'O valor sai do caixa na data do pagamento.'
      : 'Fica "A pagar" e não mexe no caixa. O estoque entra agora.';
    atualizar();
  });
  dialog.addEventListener('click', e => { if (cliqueForaDoDialogo(e, dialog) || e.target.closest('[data-fechar]')) fechar(); });
  dialog.addEventListener('cancel', e => { e.preventDefault(); fechar(); });

  form.addEventListener('submit', async e => {
    e.preventDefault();
    const mostrar = t => { erro.textContent = t; erro.hidden = false; };
    const { itens, frete, desconto, outros, temOutros } = atualizar();
    const data = form.elements.data.value;
    if (!data) return mostrar('Informe a data da compra.');
    if (data > hojeISO()) return mostrar('A data da compra não pode ser no futuro.');
    for (const [i, it] of itens.entries()) {
      const rot = `Item ${i + 1}`;
      if (!it.material_id) return mostrar(`${rot}: escolha o material.`);
      if (!Number.isFinite(it.quantidade) || it.quantidade <= 0) return mostrar(`${rot}: informe a quantidade.`);
      if (!Number.isFinite(it.valor) || it.valor <= 0) return mostrar(`${rot}: informe o valor pago.`);
    }
    if ([frete, desconto, outros].some(v => !Number.isFinite(v) || v < 0)) return mostrar('Frete, desconto e outros itens precisam ser valores válidos.');
    if (temOutros && outros <= 0) return mostrar('Informe o valor dos outros itens do pedido, ou desmarque a opção.');
    const pago = form.elements.pago.checked;
    const dataPag = form.elements.data_pagamento.value;
    if (pago && (!dataPag || dataPag > hojeISO())) return mostrar('Informe uma data de pagamento válida.');

    const cabecalho = {
      data, fornecedor: form.elements.fornecedor.value.trim(), forma: form.elements.forma.value, pago,
      data_pagamento: pago ? dataPag : null,
    };
    const botao = form.querySelector('[type="submit"]');
    botao.disabled = true; botao.textContent = 'Aguarde…';
    try {
      const resultado = await sb.rpc('registrar_compra', {
        p_data: data, p_categoria_id: form.elements.categoria.value, p_fornecedor: cabecalho.fornecedor,
        p_forma_pagamento: cabecalho.forma, p_obs: form.elements.obs.value.trim(),
        p_pago: pago, p_data_pagamento: cabecalho.data_pagamento,
        p_frete: frete, p_desconto: desconto, p_valor_outros: temOutros ? outros : 0,
        p_itens: itens.map(i => ({ material_id: i.material_id, quantidade: i.quantidade, valor: i.valor, marca: i.marca })),
      }).then(ok);
      fechar();
      await aoConcluir(resultado, cabecalho);
    } catch (err) {
      mostrar(err.message);
    } finally {
      botao.disabled = false; botao.textContent = 'Registrar compra';
    }
  });

  novaLinha();
  atualizar();
  dialog.showModal();
}
