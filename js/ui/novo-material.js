// Cadastro rápido de material sem sair da compra de estoque.
// Mesmas regras de Estoque › Materiais: filamento sempre em gramas e com
// cor; o mesmo material (categoria + tipo + variação) não se repete.
// Grava na tabela materiais, como Configurações (só a Admin pode).
import { ok } from '../db.js';
import { esc, lerDecimal } from '../format.js';
import { cliqueForaDoDialogo } from './dialogo.js';

const CATEGORIAS = [
  { valor: 'FILAMENTO', rotulo: 'Filamento', tipo: 'Tipo', tipoEx: 'PLA', variacao: 'Cor', variacaoEx: 'Branco' },
  { valor: 'EMBALAGEM', rotulo: 'Embalagem', tipo: 'Tipo', tipoEx: 'Caixa', variacao: 'Descrição ou tamanho', variacaoEx: '15 x 10 x 5 cm' },
  { valor: 'INSUMO', rotulo: 'Insumo', tipo: 'Item', tipoEx: 'Ímã', variacao: 'Especificação', variacaoEx: '10 mm' },
];
const CAT = Object.fromEntries(CATEGORIAS.map(c => [c.valor, c]));
const UNIDADES = [
  { valor: 'un', rotulo: 'Unidade (un)' }, { valor: 'g', rotulo: 'Grama (g)' }, { valor: 'kg', rotulo: 'Quilo (kg)' },
  { valor: 'ml', rotulo: 'Mililitro (ml)' }, { valor: 'l', rotulo: 'Litro (l)' },
  { valor: 'cm', rotulo: 'Centímetro (cm)' }, { valor: 'm', rotulo: 'Metro (m)' },
];
const normal = s => String(s || '').trim().toLocaleLowerCase('pt-BR');

/**
 * Abre o cadastro rápido. Devolve o material criado ({ id, categoria, tipo, variacao, unidade, ativo })
 * ou null se a Admin cancelar. `existentes` evita repetir um material já cadastrado.
 */
export function abrirNovoMaterial(sb, { categoria = 'FILAMENTO', existentes = [] } = {}) {
  const dialog = document.createElement('dialog');
  dialog.className = 'folha folha-form';
  dialog.setAttribute('aria-labelledby', 'nm-titulo');
  dialog.innerHTML = `
    <form novalidate>
      <div class="folha-topo">
        <h2 id="nm-titulo">Cadastrar material novo</h2>
        <button type="button" class="botao-icone" data-fechar aria-label="Cancelar"><i class="ti ti-x"></i></button>
      </div>
      <p class="campo-dica nota-form">O material fica salvo em Estoque › Materiais e já entra escolhido neste item da compra.</p>
      <div class="campo"><label for="nm-cat">Categoria</label>
        <select id="nm-cat" name="categoria">${CATEGORIAS.map(c => `<option value="${c.valor}" ${c.valor === categoria ? 'selected' : ''}>${c.rotulo}</option>`).join('')}</select></div>
      <div class="campo"><label for="nm-tipo" data-rot-tipo></label>
        <input type="text" id="nm-tipo" name="tipo" maxlength="80" autocomplete="off"></div>
      <div class="campo"><label for="nm-var" data-rot-var></label>
        <input type="text" id="nm-var" name="variacao" maxlength="80" autocomplete="off"></div>
      <div class="campo"><label for="nm-un">Unidade de medida</label>
        <select id="nm-un" name="unidade">${UNIDADES.map(u => `<option value="${u.valor}">${u.rotulo}</option>`).join('')}</select>
        <small class="campo-dica" data-dica-un></small></div>
      <div class="campo"><label for="nm-min" data-rot-min></label>
        <input type="text" inputmode="decimal" id="nm-min" name="estoque_minimo" placeholder="200" autocomplete="off">
        <small class="campo-dica">Opcional. Vazio = sem aviso de estoque baixo.</small></div>
      <p class="aviso aviso-erro" role="alert" hidden></p>
      <div class="form-acoes">
        <span class="espaco"></span>
        <button type="button" class="botao" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">Cadastrar e usar</button>
      </div>
    </form>`;
  document.body.appendChild(dialog);
  const form = dialog.querySelector('form');
  const erro = dialog.querySelector('.aviso-erro');
  const el = form.elements;

  const ajustar = (antes) => {
    const c = CAT[el.categoria.value];
    dialog.querySelector('[data-rot-tipo]').textContent = c.tipo;
    dialog.querySelector('[data-rot-var]').innerHTML = c.valor === 'FILAMENTO' ? esc(c.variacao) : `${esc(c.variacao)} <em>(opcional)</em>`;
    el.tipo.placeholder = c.tipoEx; el.variacao.placeholder = c.variacaoEx;
    const filamento = c.valor === 'FILAMENTO';
    if (filamento) el.unidade.value = 'g';
    else if (antes === 'FILAMENTO') el.unidade.value = 'un';   // embalagens e insumos começam em unidades
    el.unidade.disabled = filamento;
    dialog.querySelector('[data-dica-un]').textContent = filamento
      ? 'Filamento é sempre controlado em gramas.' : 'Unidade usada no estoque deste material.';
    dialog.querySelector('[data-rot-min]').textContent = `Avisar quando o estoque ficar abaixo de (${el.unidade.value})`;
  };
  let catAntes = el.categoria.value;
  el.categoria.addEventListener('change', () => { ajustar(catAntes); catAntes = el.categoria.value; });
  el.unidade.addEventListener('change', () => ajustar(el.categoria.value));
  form.addEventListener('input', () => { erro.hidden = true; });
  ajustar();

  return new Promise(resolve => {
    const fechar = valor => { dialog.close(); dialog.remove(); resolve(valor); };
    dialog.addEventListener('click', e => { if (cliqueForaDoDialogo(e, dialog) || e.target.closest('[data-fechar]')) fechar(null); });
    dialog.addEventListener('cancel', e => { e.preventDefault(); fechar(null); });
    form.addEventListener('submit', async e => {
      e.preventDefault();
      const falhar = t => { erro.textContent = t; erro.hidden = false; };
      const v = {
        categoria: el.categoria.value,
        tipo: el.tipo.value.trim(),
        variacao: el.variacao.value.trim() || null,
        unidade: el.categoria.value === 'FILAMENTO' ? 'g' : el.unidade.value,
        ativo: true,
      };
      if (!v.tipo) { el.tipo.focus(); return falhar(`Informe o campo "${CAT[v.categoria].tipo}".`); }
      if (v.categoria === 'FILAMENTO' && !v.variacao) { el.variacao.focus(); return falhar('Informe a cor do filamento.'); }
      const minTxt = el.estoque_minimo.value.trim();
      if (minTxt) {
        const n = lerDecimal(minTxt, 3);
        if (!Number.isFinite(n) || n < 0) { el.estoque_minimo.focus(); return falhar('Aviso de estoque baixo: use zero ou um valor positivo, ou deixe vazio.'); }
        v.estoque_minimo = n;
      }
      const igual = existentes.find(m => m.categoria === v.categoria && normal(m.tipo) === normal(v.tipo)
        && normal(m.variacao) === normal(v.variacao));
      if (igual) {
        return falhar(igual.ativo === false
          ? 'Esse material já existe, mas está inativo. Reative em Estoque › Materiais.'
          : 'Esse material já está cadastrado. Feche e escolha-o na lista.');
      }
      const botao = form.querySelector('[type="submit"]');
      botao.disabled = true; botao.textContent = 'Salvando…';
      try {
        const novo = await sb.from('materiais').insert(v).select('id, categoria, tipo, variacao, unidade, ativo').single().then(ok);
        fechar(novo);
      } catch (err) {
        falhar(err.message);
        botao.disabled = false; botao.textContent = 'Cadastrar e usar';
      }
    });
    dialog.showModal();
    el.tipo.focus();
  });
}
