import { esc } from '../format.js';

// Área pessoal do Joca (regra R26).
// Mostra só valores dele. Nunca percentual, base, total da venda,
// taxas, custos, lucro ou qualquer outro número da loja.
// Os dados reais chegam na Etapa 8, pelas funções joca_resumo() e joca_extrato().
export function telaJocaPessoal(el, { perfil }) {
  const card = (rotulo, icone, classe) => `
    <div class="metrica ${classe}">
      <p class="metrica-rotulo"><i class="ti ${icone}" aria-hidden="true"></i> ${rotulo}</p>
      <p class="metrica-valor">—</p>
    </div>`;

  el.innerHTML = `
    <section class="boas-vindas">
      <h2>Olá, ${esc(perfil.nome)} ⭐</h2>
      <p>Aqui você acompanha o que ganhou com as vendas da Arts com Você.</p>
    </section>
    <div class="grade-metricas">
      ${card('A receber', 'ti-hourglass', 'metrica-espera')}
      ${card('Disponível', 'ti-coin', 'metrica-disponivel')}
      ${card('Já recebi', 'ti-circle-check', 'metrica-recebido')}
    </div>
    <section class="cartao">
      <h3>Minhas vendas</h3>
      <p class="texto-secundario">Os valores aparecem aqui a partir da Etapa 8.</p>
    </section>
    <section class="cartao">
      <h3>Pagamentos que recebi</h3>
      <p class="texto-secundario">Ainda não há pagamentos.</p>
    </section>`;
}
