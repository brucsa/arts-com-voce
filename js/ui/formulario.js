import { esc, lerDecimal, paraCampo } from '../format.js';

/**
 * Abre um formulário em folha (de baixo no celular, centralizado no computador).
 *
 * campos: [{ nome, rotulo, tipo, obrigatorio, dica, placeholder, opcoes, casas,
 *            min, max, recarrega, rotulo(valores)?, oculto(valores)?, fixo(valores)? }]
 *   tipo: 'texto' | 'decimal' | 'inteiro' | 'select' | 'checkbox'
 *   recarrega: redesenha os campos quando este muda (rótulos que dependem de outro campo)
 *   fixo(valores): devolve um valor obrigatório para o campo, que fica travado
 *   aoMudar(valores, anterior): ajusta outros valores quando este campo muda
 *
 * aoSalvar(valores) e aoExcluir() podem lançar Error: a mensagem aparece no formulário.
 */
export function abrirFormulario({ titulo, campos, valores = {}, textoSalvar = 'Salvar', aoSalvar, aoExcluir, textoExcluir = 'Excluir', confirmarExclusao }) {
  const dialog = document.createElement('dialog');
  dialog.className = 'folha folha-form';
  dialog.setAttribute('aria-labelledby', 'form-titulo');
  dialog.innerHTML = `
    <form novalidate>
      <div class="folha-topo">
        <h2 id="form-titulo">${esc(titulo)}</h2>
        <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>
      <div class="form-campos"></div>
      <p class="aviso aviso-erro" role="alert" hidden></p>
      <div class="form-acoes">
        ${aoExcluir ? `<button type="button" class="botao botao-perigo" data-excluir>${esc(textoExcluir)}</button>` : ''}
        <span class="espaco"></span>
        <button type="button" class="botao" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">${esc(textoSalvar)}</button>
      </div>
    </form>`;
  document.body.appendChild(dialog);

  const form = dialog.querySelector('form');
  const area = dialog.querySelector('.form-campos');
  const erroGeral = dialog.querySelector('.aviso-erro');
  let atuais = { ...valores };

  const valorDe = c => (c.fixo && c.fixo(atuais) !== undefined ? c.fixo(atuais) : atuais[c.nome]);

  function desenhar() {
    area.innerHTML = campos.filter(c => !(c.oculto && c.oculto(atuais))).map(c => {
      const rotulo = typeof c.rotulo === 'function' ? c.rotulo(atuais) : c.rotulo;
      const dica = typeof c.dica === 'function' ? c.dica(atuais) : c.dica;
      const placeholder = typeof c.placeholder === 'function' ? c.placeholder(atuais) : c.placeholder;
      const v = valorDe(c);
      const travado = c.fixo && c.fixo(atuais) !== undefined;
      const id = `f-${c.nome}`;
      const dicaHtml = dica ? `<small class="campo-dica" id="${id}-dica">${esc(dica)}</small>` : '';
      const erroHtml = `<small class="campo-erro" id="${id}-erro" hidden></small>`;
      const desc = `aria-describedby="${id}-dica ${id}-erro"`;

      if (c.tipo === 'checkbox') {
        return `<div class="campo campo-check">
          <label><input type="checkbox" name="${c.nome}" id="${id}" ${v ? 'checked' : ''} ${desc}>
          <span>${esc(rotulo)}</span></label>${dicaHtml}${erroHtml}</div>`;
      }
      if (c.tipo === 'select') {
        return `<div class="campo"><label for="${id}">${esc(rotulo)}${c.obrigatorio ? '' : ' <em>(opcional)</em>'}</label>
          <select name="${c.nome}" id="${id}" ${travado ? 'disabled' : ''} ${desc}>
            ${c.opcoes.map(o => `<option value="${esc(o.valor)}" ${String(v ?? '') === String(o.valor) ? 'selected' : ''}>${esc(o.rotulo)}</option>`).join('')}
          </select>${dicaHtml}${erroHtml}</div>`;
      }
      const numerico = c.tipo === 'decimal' || c.tipo === 'inteiro';
      const mostrado = numerico && typeof v === 'number' ? paraCampo(v, 0, c.casas ?? 0) : (v ?? '');
      return `<div class="campo"><label for="${id}">${esc(rotulo)}${c.obrigatorio ? '' : ' <em>(opcional)</em>'}</label>
        <input name="${c.nome}" id="${id}" type="text" value="${esc(mostrado)}"
          ${numerico ? `inputmode="${c.tipo === 'inteiro' ? 'numeric' : 'decimal'}"` : ''}
          ${placeholder ? `placeholder="${esc(placeholder)}"` : ''} autocomplete="off" ${desc}>
        ${dicaHtml}${erroHtml}</div>`;
    }).join('');
  }

  function lerBruto() {
    const fd = new FormData(form);
    for (const c of campos) {
      const el = form.elements[c.nome];
      if (!el) continue;
      atuais[c.nome] = c.tipo === 'checkbox' ? el.checked : (fd.get(c.nome) ?? atuais[c.nome]);
    }
  }

  function mostrarErro(nome, texto) {
    const el = form.querySelector(`#f-${nome}-erro`);
    if (el) { el.textContent = texto; el.hidden = !texto; }
    form.elements[nome]?.setAttribute('aria-invalid', texto ? 'true' : 'false');
  }

  function converter() {
    const saida = {};
    let valido = true;
    for (const c of campos) {
      if (c.oculto && c.oculto(atuais)) continue;
      let v = valorDe(c);
      mostrarErro(c.nome, '');
      if (c.tipo === 'checkbox') { saida[c.nome] = !!v; continue; }
      const texto = String(v ?? '').trim();
      if (!texto) {
        if (c.obrigatorio) { mostrarErro(c.nome, 'Preencha este campo.'); valido = false; }
        saida[c.nome] = null;
        continue;
      }
      if (c.tipo === 'decimal' || c.tipo === 'inteiro') {
        const n = c.tipo === 'inteiro' ? (/^\d+$/.test(texto) ? Number(texto) : NaN) : lerDecimal(texto, c.casas ?? 2);
        if (!Number.isFinite(n)) { mostrarErro(c.nome, c.tipo === 'inteiro' ? 'Digite um número inteiro.' : 'Digite um número válido, como 12,5.'); valido = false; continue; }
        if ((c.min !== undefined && n < c.min) || (c.max !== undefined && n > c.max)) {
          mostrarErro(c.nome, c.mensagemFaixa || `Use um valor entre ${paraCampo(c.min, 0, 5)} e ${paraCampo(c.max, 0, 5)}.`);
          valido = false; continue;
        }
        if (c.maiorQueZero && n <= 0) { mostrarErro(c.nome, 'Use um valor maior que zero.'); valido = false; continue; }
        saida[c.nome] = n;
        continue;
      }
      saida[c.nome] = texto;
    }
    return valido ? saida : null;
  }

  const fechar = () => { dialog.close(); dialog.remove(); };

  form.addEventListener('change', e => {
    const c = campos.find(x => x.nome === e.target.name);
    const anterior = c ? atuais[c.nome] : undefined;
    lerBruto();
    if (c && c.aoMudar) c.aoMudar(atuais, anterior);
    if (c && c.recarrega) desenhar();
  });
  form.addEventListener('input', e => { mostrarErro(e.target.name, ''); erroGeral.hidden = true; });
  dialog.addEventListener('click', e => { if (e.target === dialog || e.target.closest('[data-fechar]')) fechar(); });
  dialog.addEventListener('cancel', e => { e.preventDefault(); fechar(); });

  async function executar(acao, botao) {
    const textoOriginal = botao.textContent;
    form.querySelectorAll('button').forEach(b => { b.disabled = true; });
    botao.textContent = 'Aguarde…';
    erroGeral.hidden = true;
    try {
      await acao();
      fechar();
    } catch (e) {
      erroGeral.textContent = e.message || 'Não foi possível concluir.';
      erroGeral.hidden = false;
    } finally {
      form.querySelectorAll('button').forEach(b => { b.disabled = false; });
      botao.textContent = textoOriginal;
    }
  }

  form.addEventListener('submit', e => {
    e.preventDefault();
    lerBruto();
    const dados = converter();
    if (!dados) return;
    executar(() => aoSalvar(dados), form.querySelector('[type="submit"]'));
  });

  dialog.querySelector('[data-excluir]')?.addEventListener('click', e => {
    if (!window.confirm(confirmarExclusao || 'Excluir este cadastro? Esta ação não pode ser desfeita.')) return;
    executar(() => aoExcluir(), e.currentTarget);
  });

  desenhar();
  dialog.showModal();
  area.querySelector('input, select')?.focus();
}
