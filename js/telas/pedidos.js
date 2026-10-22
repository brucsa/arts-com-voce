// Arts com Você Essencial · Pedidos (só Admin)
// Duas abas: Diretos (Pedidos Diretos Essencial, R76–R84, e as vendas da
// Shopee, R103) e Shopee (pedidos importados da planilha, R70, R102).
// O botão "Importar planilha da Shopee" fica no topo, nas duas abas (R111).

import { telaShopee, importarPlanilhaShopee } from './shopee.js';
import { telaPedidosDiretos } from './pedidos-diretos.js';

const ABAS = [
  { id: 'diretos', titulo: 'Diretos' },
  { id: 'shopee', titulo: 'Shopee' },
];

// Ao chegar em Pedidos (pelo menu, pela barra ou ao entrar), abre sempre na aba
// Diretos. Quando a própria tela de Pedidos é redesenhada (por exemplo, depois
// de um gasto lançado pelo ＋), a aba que estava aberta continua aberta.
let abaAtual = 'diretos';
// Depois de salvar um pedido pelo atalho ＋: mostra a aba Diretos com o pedido aberto.
let pendente = null;
let pendenteShopee = null;

/** Faz a próxima abertura da tela Pedidos mostrar a aba Diretos (com mensagem e pedido aberto). */
export function mostrarPedidoDireto(mensagem, id) {
  abaAtual = 'diretos';
  pendente = { mensagem, abrir: id };
}

export function telaPedidos(el) {
  const redesenho = !!el.querySelector('#aba-diretos');   // já estava na tela de Pedidos
  if (!redesenho) abaAtual = 'diretos';
  el.innerHTML = `
    <div class="pedidos-topo">
      <div class="abas" role="tablist" aria-label="Tipo de pedido">
        ${ABAS.map(a => `<button type="button" class="aba" role="tab" id="aba-${a.id}"
          aria-controls="painel-pedidos" data-aba="${a.id}">${a.titulo}</button>`).join('')}
      </div>
      <label class="botao" data-importar-shopee>
        <i class="ti ti-file-upload" aria-hidden="true"></i> Importar planilha da Shopee
        <input type="file" accept=".xlsx" hidden>
      </label>
    </div>
    <p class="aviso aviso-erro" role="alert" hidden data-erro-importar></p>
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
    if (id === 'shopee') {
      const opcoes = { ...(pendenteShopee || {}),
        aoRegistrarVenda: async (msg, vendaId) => { mostrarPedidoDireto(msg, vendaId); mostrar('diretos'); },
        aoAbrirVenda: vendaId => { mostrarPedidoDireto(null, vendaId); mostrar('diretos'); } };
      pendenteShopee = null;
      telaShopee(painel, opcoes);
    } else desenharDiretos(painel);
  };

  // Importar a planilha sem precisar ir até a aba Shopee (R111): ao terminar, mostra a aba Shopee.
  const entrada = el.querySelector('[data-importar-shopee] input');
  const erroImportar = el.querySelector('[data-erro-importar]');
  entrada.addEventListener('change', async () => {
    const arquivo = entrada.files[0];
    entrada.value = '';
    if (!arquivo) return;
    erroImportar.hidden = true;
    try {
      await importarPlanilhaShopee(arquivo, async msg => { pendenteShopee = { mensagem: msg }; mostrar('shopee'); });
    } catch (e) {
      erroImportar.textContent = `${e.message || 'Não foi possível ler a planilha.'}${/Nada foi importado/.test(e.message || '') ? '' : ' Nada foi importado.'}`;
      erroImportar.hidden = false;
    }
  });

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
  const opcoes = pendente || {};
  pendente = null;
  telaPedidosDiretos(painel, opcoes);
}
