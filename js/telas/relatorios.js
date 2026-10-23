// Etapa 11 · Relatórios (só Admin), grupo Mais. Regras R129–R131 (versão 1.15).
// Começa pelos canais: Direto × Shopee no período, com o total. Os números vêm
// da função relatorio_canais() do banco (sql/25), com as mesmas regras do
// Início. Antes do sql/25 a função não existe e a tela avisa.

import { supabase, configurado } from '../supabase.js';
import { esc, brl, dataBR } from '../format.js';
import { intervalo as intervaloDe, htmlFiltroPeriodo, ligarFiltroPeriodo } from '../ui/periodo.js';

// Abre em Mês (R129); a escolha fica enquanto o sistema estiver aberto.
const filtro = { periodo: 'mes', de: null, ate: null };
const intervalo = () => intervaloDe(filtro);
const num = v => Number(v || 0);
const NOME = { DIRETO: 'Direto', SHOPEE: 'Shopee', TOTAL: 'Total' };

export function telaRelatorios(el) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">Os relatórios precisam do Supabase configurado.</p></section>';
    return;
  }
  el.innerHTML = `
    <section class="inicio-topo">
      <div><h2>Canais</h2><p class="texto-secundario">Direto e Shopee lado a lado no período.</p></div>
      ${htmlFiltroPeriodo(filtro)}
    </section>
    <div data-painel aria-live="polite"><p class="texto-secundario">Carregando…</p></div>`;
  ligarFiltroPeriodo(el, filtro, () => carregar(el));
  carregar(el);
}

let pedidoAtual = 0;
async function carregar(el) {
  const painel = el.querySelector('[data-painel]');
  const { inicio, fim } = intervalo();
  const meu = ++pedidoAtual;                      // uma busca ainda em andamento não sobrescreve esta
  if (fim < inicio) {
    painel.removeAttribute('aria-busy');
    painel.innerHTML = '<p class="aviso aviso-erro" role="alert">A data final não pode ser antes da inicial.</p>';
    return;
  }
  painel.setAttribute('aria-busy', 'true');
  try {
    const sb = await supabase();
    const { data, error } = await sb.rpc('relatorio_canais', { p_inicio: inicio, p_fim: fim });
    if (meu !== pedidoAtual) return;
    if (error) {
      const faltaInstalar = /relatorio_canais/.test(error.message || '') && /(function|função|schema cache|not find)/i.test(error.message || '');
      painel.innerHTML = faltaInstalar
        ? '<section class="cartao"><p class="texto-secundario">Os relatórios aparecem depois da instalação no banco (sql/25).</p></section>'
        : `<p class="aviso aviso-erro" role="alert">${esc(error.message)}</p>`;
      return;
    }
    painel.innerHTML = desenhar(data.canais || [], inicio, fim);
  } catch (e) {
    if (meu === pedidoAtual) painel.innerHTML = `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  } finally {
    if (meu === pedidoAtual) painel.removeAttribute('aria-busy');
  }
}

/** R130: uma coluna por canal e o total; uma linha por número. */
function desenhar(canais, inicio, fim) {
  const periodoTexto = inicio === fim ? dataBR(inicio) : `${dataBR(inicio)} a ${dataBR(fim)}`;
  const reais = (c, k, sinal = '') => (num(c[k]) ? `${sinal}${brl(c[k])}` : brl(0));
  const pct = c => (c.margem == null ? '—' : `${String(c.margem).replace('.', ',')}%`);
  const linhas = [
    ['Pedidos', c => String(num(c.pedidos))],
    ['Ticket médio', c => (c.ticket_medio == null ? '—' : brl(c.ticket_medio))],
    ['Faturamento', c => brl(c.faturamento)],
    ['Frete cobrado', c => reais(c, 'frete', '+ ')],
    ['Taxas das plataformas', c => reais(c, 'taxas', '− ')],
    ['Custo dos produtos', c => reais(c, 'custos', '− ')],
    ['Comissão do Joca', c => reais(c, 'comissao_joca', '− ')],
  ];
  const semCusto = canais.filter(c => c.canal !== 'TOTAL' && num(c.pedidos_sem_custo));
  return `<section class="cartao" aria-labelledby="t-canais">
    <h3 id="t-canais">Direto × Shopee <span class="texto-secundario">· ${esc(periodoTexto)}</span></h3>
    <div class="tabela-rolagem">
      <table class="tabela-canais">
        <thead><tr><th scope="col"><span class="so-leitor">Número</span></th>
          ${canais.map(c => `<th scope="col" class="${c.canal === 'TOTAL' ? 'col-total' : ''}">${NOME[c.canal] || esc(c.canal)}</th>`).join('')}</tr></thead>
        <tbody>
          ${linhas.map(([rot, f]) => `<tr><th scope="row">${rot}</th>${canais.map(c => `<td class="${c.canal === 'TOTAL' ? 'col-total' : ''}">${f(c)}</td>`).join('')}</tr>`).join('')}
          <tr class="linha-lucro"><th scope="row">Lucro dos pedidos</th>${canais.map(c => `<td class="${c.canal === 'TOTAL' ? 'col-total' : ''} ${num(c.lucro) < 0 ? 'valor-negativo' : ''}">${brl(c.lucro)}</td>`).join('')}</tr>
          <tr><th scope="row">Margem</th>${canais.map(c => `<td class="${c.canal === 'TOTAL' ? 'col-total' : ''}">${pct(c)}</td>`).join('')}</tr>
        </tbody>
      </table>
    </div>
    <p class="metrica-nota texto-secundario">Lucro dos pedidos: faturamento + frete − taxas − custos − comissão. Margem: lucro ÷ faturamento. Cancelados ficam fora.</p>
    ${semCusto.length ? `<p class="aviso aviso-atencao"><i class="ti ti-info-circle" aria-hidden="true"></i>
      ${semCusto.map(c => `${NOME[c.canal]}: ${num(c.pedidos_sem_custo)} pedido(s) ainda sem custo de produção`).join(' · ')}. O custo entra quando a produção é registrada.</p>` : ''}
  </section>`;
}
