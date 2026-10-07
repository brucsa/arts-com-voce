import { esc, dataBR, hojeISO } from '../format.js';
import { ETAPAS, ETAPA_ATUAL } from '../menu.js';

// Até a Etapa 10 (Dashboard), o Início mostra o andamento do projeto.
export function telaInicio(el, { perfil }) {
  const etapas = ETAPAS.map((nome, i) => {
    const situacao = i < ETAPA_ATUAL ? 'feita' : i === ETAPA_ATUAL ? 'atual' : 'futura';
    const rotulo = { feita: 'Concluída', atual: 'Em andamento', futura: '' }[situacao];
    return `<li class="etapa etapa-${situacao}">
      <span class="etapa-num">${i}</span>
      <span class="etapa-nome">${esc(nome)}</span>
      ${rotulo ? `<span class="etapa-rotulo">${rotulo}</span>` : ''}
    </li>`;
  }).join('');

  el.innerHTML = `
    <section class="boas-vindas">
      <p class="texto-secundario">${dataBR(hojeISO())}</p>
      <h2>Olá, ${esc(perfil.nome)}</h2>
      <p>O painel com resultados, caixa, canais e Joca chega na Etapa 10. Por enquanto, acompanhe aqui o andamento da construção.</p>
    </section>
    <section class="cartao">
      <h3>Etapas do sistema</h3>
      <ol class="etapas">${etapas}</ol>
    </section>`;
}
