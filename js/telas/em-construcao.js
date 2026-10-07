import { esc } from '../format.js';

// Tela provisória. Cada etapa substitui esta tela pela versão real.
export function telaEmConstrucao(el, { tela }) {
  el.innerHTML = `
    <section class="cartao em-construcao">
      <span class="selo">Etapa ${tela.etapa}</span>
      <h2><i class="ti ${tela.icone}" aria-hidden="true"></i> ${esc(tela.titulo)}</h2>
      <p class="texto-secundario">Esta tela fica pronta na Etapa ${tela.etapa}. O que ela vai ter:</p>
      <ul class="lista-check">
        ${tela.itens.map(i => `<li>${esc(i)}</li>`).join('')}
      </ul>
    </section>`;
}
