// Vendas da Shopee (Etapa 6 · Lote C1): registrar e editar a venda a partir
// de um pedido importado (R101–R105, R110). Grava só por salvar_venda_shopee
// e, para produtos com ficha, definir_cores_partes (R94). A venda entra na
// lista de pedidos, sem cliente e sem origem (R103, R104).

import { ok } from '../db.js';
import { esc, brl, lerDecimal, paraCampo, arred2, hojeISO, FUSO } from '../format.js';
import { cliqueForaDoDialogo } from '../ui/dialogo.js';

const corDoFilamento = f => `${f.tipo} · ${f.variacao ?? f.cor}`;
const num = v => Number(v || 0);
const dataLocal = iso => (iso ? new Date(iso).toLocaleDateString('en-CA', { timeZone: FUSO }) : hojeISO());

/** As vendas da Shopee estão instaladas no banco? (antes do sql/17 a coluna não existe) */
export async function vendasShopeeInstaladas(sb) {
  const { error } = await sb.from('vendas').select('shopee_pedido_ref').limit(1);
  return !error;
}

async function carregarCadastros(sb) {
  const [produtos, filamentos, partes] = await Promise.all([
    sb.from('vw_produtos').select('id, nome, ativo, cores').order('nome').then(ok),
    sb.from('materiais').select('id, tipo, variacao, ativo').eq('categoria', 'FILAMENTO').order('tipo').order('variacao').then(ok),
    sb.from('produto_partes').select('produto_id, ordem, nome, gramas').order('ordem').then(ok),
  ]);
  produtos.forEach(p => { p.partes = partes.filter(x => x.produto_id === p.id); });
  return { produtos, filamentos };
}

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

/**
 * Registrar (shopee = pedido importado, com itens) ou editar (venda = linha de
 * vw_pedidos, itensVenda = itens com partes) uma venda da Shopee.
 * aoConcluir(mensagem, idDaVenda).
 */
export async function abrirVendaShopee(sb, { shopee = null, venda = null, itensVenda = null, aoConcluir }) {
  const { produtos, filamentos } = await carregarCadastros(sb);
  const editando = !!venda;
  const ref = editando ? venda.shopee_pedido_ref : shopee.id;
  const pedidoShopee = editando ? venda.pedido_shopee : shopee.pedido_id;
  const prodPorId = id => produtos.find(p => p.id === id);

  // Itens: os da venda (edição) ou os da planilha (registro).
  const itens = editando
    ? itensVenda.map(i => ({ id: i.id, produto_id: i.produto_id, descricao: i.descricao, quantidade: i.quantidade,
                             preco: num(i.preco_unitario), material_id: i.material_id, partes: i.partes || [] }))
    : shopee.itens.map(i => ({ planilha: `${i.produto}${i.variacao ? ` (${i.variacao})` : ''}`,
                               descricao: `${i.produto}${i.variacao ? ` · ${i.variacao}` : ''}`.slice(0, 150),
                               quantidade: Number(i.quantidade) || 1,
                               preco: i.preco_acordado != null ? num(i.preco_acordado)
                                 : (Number(i.quantidade) ? arred2(num(i.subtotal) / Number(i.quantidade)) : 0) }));
  const taxaPlanilha = editando ? num(venda.taxa_plataforma)
    : arred2(num(shopee.taxa_comissao) + num(shopee.taxa_servico) + num(shopee.taxa_transacao));
  const valores = editando
    ? { data: venda.data, desconto: num(venda.desconto), taxa: taxaPlanilha, frete: num(venda.frete_comprador), obs: venda.observacao || '' }
    : { data: dataLocal(shopee.criado_em), desconto: num(shopee.cupom_vendedor), taxa: taxaPlanilha, frete: num(shopee.frete_comprador), obs: '' };

  const opcoesProduto = atual => produtos.filter(p => p.ativo || p.id === atual)
    .map(p => `<option value="${p.id}" ${p.id === atual ? 'selected' : ''}>${esc(p.nome)}${p.ativo ? '' : ' (inativo)'}</option>`).join('');

  function htmlCores(el, item, produtoId) {
    const prod = prodPorId(produtoId);
    const mesmo = item.id && item.produto_id === produtoId;
    const partes = produtoId ? (mesmo ? item.partes : prod?.partes || []) : [];
    if (partes.length) {
      const doProduto = new Set((prod?.cores || []).map(c => c.material_id));
      const op = atual => `<option value="">A definir</option>${['Cores do produto', 'Outros filamentos'].map((g, k) => {
        const lista = filamentos.filter(f => (f.ativo || f.id === atual) && (k === 0) === doProduto.has(f.id));
        return lista.length ? `<optgroup label="${g}">${lista.map(f => `<option value="${f.id}" ${f.id === atual ? 'selected' : ''}>${esc(corDoFilamento(f))}</option>`).join('')}</optgroup>` : '';
      }).join('')}`;
      return `<p class="cores-partes-titulo">Cor de cada parte</p>${partes.map(x => `
        <label class="campo campo-compacto"><span>${esc(x.nome)} <em>(${paraCampo(x.gramas, 0, 2)} g)</em></span>
          <select data-cor-parte>${op(x.material_id || null)}</select></label>`).join('')}`;
    }
    const cores = produtoId ? (prod?.cores || []) : filamentos.filter(f => f.ativo || f.id === item.material_id)
      .map(f => ({ material_id: f.id, tipo: f.tipo, cor: f.variacao, ativo: f.ativo }));
    return `<label class="campo campo-compacto"><span>Cor <em>(opcional)</em></span>
      <select data-cor-unica><option value="">Sem cor definida</option>
        ${cores.map(c => `<option value="${c.material_id}" ${c.material_id === item.material_id && (!item.id || item.produto_id === produtoId) ? 'selected' : ''}>${esc(corDoFilamento(c))}</option>`).join('')}
      </select></label>`;
  }

  const { dialog, fechar } = abrirFolha(`
    <form novalidate>
      <div class="folha-topo">
        <h2 id="form-venda-shopee">${editando ? `Editar venda ${esc(venda.numero_formatado)}` : 'Registrar como venda'}</h2>
        <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>
      <p class="campo-dica nota-form">Pedido ${esc(pedidoShopee)} da Shopee. ${editando ? '' : 'Os valores vêm da planilha: confira antes de salvar.'}
        A venda entra na lista de pedidos, sem cliente. O dinheiro entra pelo repasse da Shopee.</p>

      <div class="campo"><label for="vs-data">Data da venda</label>
        <input type="date" id="vs-data" name="data" value="${esc(valores.data)}" max="${hojeISO()}"></div>

      <fieldset class="itens-compra">
        <legend>Itens</legend>
        <p class="campo-dica">Ligue cada item a um produto do catálogo para usar a ficha, a produção e as peças prontas. Sem ligação, ele fica como personalizado.</p>
        <div class="itens-pedido" data-itens>${itens.map((it, n) => `
          <div class="item-compra item-pedido" data-item="${n}">
            ${it.planilha ? `<p class="cores-partes-titulo">Na planilha: ${esc(it.planilha)}</p>` : ''}
            <div class="campo"><label>Produto do catálogo</label>
              <select data-produto><option value="">Não ligar ao catálogo</option>${opcoesProduto(it.produto_id)}</select></div>
            <div class="campo" data-so-livre ${it.produto_id ? 'hidden' : ''}><label>Descrição</label>
              <input type="text" data-descricao maxlength="150" value="${esc(it.descricao)}" autocomplete="off"></div>
            <div class="campo"><label>Quantidade</label>
              <input type="text" inputmode="numeric" data-qtd value="${it.quantidade}" autocomplete="off"></div>
            <div class="campo"><label>Preço unitário (R$)</label>
              <input type="text" inputmode="decimal" data-preco value="${paraCampo(it.preco, 2, 2)}" autocomplete="off"></div>
            <div class="cores-partes" data-cores>${htmlCores(null, it, it.produto_id || null)}</div>
          </div>`).join('')}</div>
      </fieldset>

      <div class="grade-form">
        <div class="campo"><label for="vs-desc">Desconto do vendedor (R$)</label>
          <input type="text" inputmode="decimal" id="vs-desc" name="desconto" value="${paraCampo(valores.desconto, 2, 2)}" autocomplete="off">
          <small class="campo-dica">Cupom do vendedor. Sai do faturamento e da comissão.</small></div>
        <div class="campo"><label for="vs-taxa">Taxa da Shopee (R$)</label>
          <input type="text" inputmode="decimal" id="vs-taxa" name="taxa" value="${paraCampo(valores.taxa, 2, 2)}" autocomplete="off">
          <small class="campo-dica">Comissão + serviço + transação da planilha.</small></div>
        <div class="campo"><label for="vs-frete">Frete do comprador (R$)</label>
          <input type="text" inputmode="decimal" id="vs-frete" name="frete" value="${paraCampo(valores.frete, 2, 2)}" autocomplete="off">
          <small class="campo-dica">Só informativo: não entra no faturamento.</small></div>
      </div>
      <div class="resumo-compra" data-resumo aria-live="polite"></div>
      <div class="campo"><label for="vs-obs">Observação <em>(opcional)</em></label>
        <textarea id="vs-obs" name="obs" rows="2" maxlength="2000">${esc(valores.obs)}</textarea></div>

      <p class="aviso aviso-erro" role="alert" hidden data-erro></p>
      <div class="form-acoes">
        <span class="espaco"></span>
        <button type="button" class="botao" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">${editando ? 'Salvar alterações' : 'Registrar venda'}</button>
      </div>
    </form>`, 'form-venda-shopee');

  const form = dialog.querySelector('form');
  const f = form.elements;
  const erroEl = dialog.querySelector('[data-erro]');
  const resumoEl = dialog.querySelector('[data-resumo]');
  const blocos = () => [...dialog.querySelectorAll('[data-item]')];
  const lerValor = nome => { const t = f[nome].value.trim(); return t === '' ? 0 : lerDecimal(t, 2); };

  function lerItens() {
    return blocos().map((el, i) => {
      const it = itens[Number(el.dataset.item)];
      const produtoId = el.querySelector('[data-produto]').value || null;
      const qtdTxt = el.querySelector('[data-qtd]').value.trim();
      const qtd = /^\d{1,6}$/.test(qtdTxt) ? Number(qtdTxt) : NaN;
      const preco = lerDecimal(el.querySelector('[data-preco]').value.trim(), 2);
      const partes = [...el.querySelectorAll('[data-cor-parte]')];
      const unica = el.querySelector('[data-cor-unica]');
      return {
        n: i + 1, it,
        envio: { ...(it.id ? { id: it.id } : {}), produto_id: produtoId,
                 descricao: produtoId ? null : el.querySelector('[data-descricao]').value.trim(),
                 quantidade: qtd, preco_unitario: preco, material_id: partes.length ? null : (unica?.value || null) },
        cores: partes.length ? partes.map(s => s.value || null) : null,
      };
    });
  }

  function resumir() {
    const lidos = lerItens();
    const produtosTotal = lidos.reduce((t, x) => t + (Number.isFinite(x.envio.quantidade) && Number.isFinite(x.envio.preco_unitario)
      ? arred2(x.envio.quantidade * x.envio.preco_unitario) : 0), 0);
    const desconto = lerValor('desconto'), taxa = lerValor('taxa');
    const fat = arred2(produtosTotal - (Number.isFinite(desconto) ? desconto : 0));
    resumoEl.innerHTML = `
      <div><span>Produtos</span><strong>${brl(produtosTotal)}</strong></div>
      ${desconto ? `<div><span>Desconto do vendedor</span><strong>− ${brl(desconto)}</strong></div>` : ''}
      <div class="resumo-total"><span>Faturamento</span><strong>${brl(fat)}</strong></div>
      <div><span>Taxa da Shopee</span><strong>− ${brl(Number.isFinite(taxa) ? taxa : 0)}</strong></div>
      <div class="resumo-outros"><span>Repasse estimado</span><span>${brl(fat - (Number.isFinite(taxa) ? taxa : 0))}</span></div>`;
    return { produtosTotal, desconto, taxa, fat };
  }

  dialog.querySelector('[data-itens]').addEventListener('change', e => {
    const el = e.target.closest('[data-item]');
    if (el && e.target.matches('[data-produto]')) {
      const it = itens[Number(el.dataset.item)];
      el.querySelector('[data-so-livre]').hidden = !!e.target.value;
      el.querySelector('[data-cores]').innerHTML = htmlCores(el, it, e.target.value || null);
    }
    erroEl.hidden = true; resumir();
  });
  form.addEventListener('input', () => { erroEl.hidden = true; resumir(); });

  form.addEventListener('submit', async e => {
    e.preventDefault();
    const falhar = msg => { erroEl.textContent = msg; erroEl.hidden = false; };
    const lidos = lerItens();
    const { produtosTotal, desconto, taxa, fat } = resumir();
    const frete = lerValor('frete');
    for (const x of lidos) {
      if (!x.envio.produto_id && !x.envio.descricao) return falhar(`Item ${x.n}: escreva a descrição ou ligue a um produto.`);
      if (!Number.isFinite(x.envio.quantidade) || x.envio.quantidade < 1) return falhar(`Item ${x.n}: a quantidade precisa ser um número inteiro, no mínimo 1.`);
      if (!Number.isFinite(x.envio.preco_unitario) || x.envio.preco_unitario < 0) return falhar(`Item ${x.n}: informe o preço (R$ 0,00 ou mais).`);
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(f.data.value)) return falhar('Informe a data da venda.');
    if (f.data.value > hojeISO()) return falhar('A data da venda não pode ser futura.');
    if (!Number.isFinite(desconto) || desconto < 0) return falhar('Desconto: digite um valor válido, como 2,00.');
    if (desconto > produtosTotal) return falhar('O desconto do vendedor não pode passar do valor dos produtos.');
    if (!Number.isFinite(taxa) || taxa < 0) return falhar('Taxa: digite um valor válido, como 5,50.');
    if (taxa > fat) return falhar('A taxa da Shopee não pode passar do valor dos produtos menos o desconto.');
    if (!Number.isFinite(frete) || frete < 0) return falhar('Frete: digite um valor válido, como 10,00.');

    const botao = form.querySelector('[type=submit]');
    const texto = botao.textContent;
    form.querySelectorAll('button').forEach(b => { b.disabled = true; });
    botao.textContent = 'Salvando…';
    try {
      const r = await sb.rpc('salvar_venda_shopee', {
        p_id: editando ? venda.id : null, p_shopee_ref: ref, p_data: f.data.value,
        p_desconto: desconto, p_taxa: taxa, p_frete_comprador: frete, p_observacao: f.obs.value.trim() || null,
        p_itens: lidos.map(x => ({ ...x.envio, quantidade: String(x.envio.quantidade), preco_unitario: String(x.envio.preco_unitario) })),
      }).then(ok);
      const numero = `#${String(r.numero).padStart(4, '0')}`;
      let msg = editando ? `Venda ${numero} da Shopee atualizada.` : `Pedido ${pedidoShopee} da Shopee registrado como venda ${numero}.`;
      const cores = lidos.filter(x => x.cores).map(x => ({ ordem: x.n, cores: x.cores }));
      if (cores.length) {
        try { await sb.rpc('definir_cores_partes', { p_venda_id: r.id, p_itens: cores }).then(ok); } catch (err) {
          msg = `Venda ${numero} salva, mas as cores das partes não foram gravadas (${err.message}). Abra o pedido e tente de novo.`;
        }
      }
      fechar();
      await aoConcluir?.(msg, r.id);
    } catch (err) {
      falhar(err.message);
      form.querySelectorAll('button').forEach(b => { b.disabled = false; });
      botao.textContent = texto;
    }
  });

  resumir();
}
