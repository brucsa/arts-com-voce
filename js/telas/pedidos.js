// Arts com Você Essencial · E1 · Pedidos (só Admin)
// Duas abas: Diretos (cadastro chega na E2) e Shopee (o módulo existente, sem mudança).

import { telaShopee } from './shopee.js';

const ABAS = [
  { id: 'diretos', titulo: 'Diretos' },
  { id: 'shopee', titulo: 'Shopee' },
];

// Abre na aba Shopee. A aba escolhida fica guardada enquanto a página estiver aberta.
let abaAtual = 'shopee';

export function telaPedidos(el) {
  el.innerHTML = `
    <div class="abas" role="tablist" aria-label="Tipo de pedido">
      ${ABAS.map(a => `<button type="button" class="aba" role="tab" id="aba-${a.id}"
        aria-controls="painel-pedidos" data-aba="${a.id}">${a.titulo}</button>`).join('')}
    </div>
    <div id="painel-pedidos" role="tabpanel"></div>`;

  const botoes = [...el.querySelectorAll('[data-aba]')];
  const painel = el.querySelector('#painel-pedidos');

  const mostrar = (id, focar = false) => {
    abaAtual = id;
    botoes.forEach(b => {
      const ativa = b.dataset.aba === id;
      b.setAttribute('aria-selected', String(ativa));
      b.tabIndex = ativa ? 0 : -1;
      if (ativa && focar) b.focus();
    });
    painel.setAttribute('aria-labelledby', `aba-${id}`);
    if (id === 'shopee') telaShopee(painel);
    else desenharDiretos(painel);
  };

  botoes.forEach(b => b.addEventListener('click', () => mostrar(b.dataset.aba)));
  // Setas do teclado trocam de aba (padrão de abas acessíveis).
  el.querySelector('[role="tablist"]').addEventListener('keydown', e => {
    if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
    const i = ABAS.findIndex(a => a.id === abaAtual);
    const prox = ABAS[(i + (e.key === 'ArrowRight' ? 1 : ABAS.length - 1)) % ABAS.length];
    mostrar(prox.id, true);
  });

  mostrar(abaAtual);
}

function desenharDiretos(painel) {
  painel.innerHTML = `
    <section class="cartao em-construcao">
      <span class="selo">Em breve</span>
      <h2><i class="ti ti-truck-delivery" aria-hidden="true"></i> Pedidos diretos</h2>
      <p class="texto-secundario">O cadastro de pedidos diretos chega na próxima etapa (E2).
        Por enquanto, nada é cadastrado aqui.</p>
      <p class="texto-secundario">Os pedidos da Shopee continuam na aba <strong>Shopee</strong>.</p>
    </section>`;
}
