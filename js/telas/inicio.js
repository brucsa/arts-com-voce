// Etapa 10 · Início (Dashboard), só Admin. Regras R122, R123 e R128 (versão 1.14).
// Dinheiro agora, canais, Joca e movimento do período saíram da tela em
// 22/10/2026, a pedido da Bruna (R124–R127).
// Todos os números vêm da função dashboard() do banco (sql/24): esta tela só
// mostra. Antes do sql/24 a função não existe e a tela avisa.

import { supabase, configurado } from '../supabase.js';
import { esc, brl, dataBR, hojeISO } from '../format.js';
import { mostrarAbaShopee } from './pedidos.js';
import { intervalo as intervaloDe, htmlFiltroPeriodo, ligarFiltroPeriodo } from '../ui/periodo.js';

const intervalo = () => intervaloDe(filtro);

// Abre em Mês (R122); a escolha fica enquanto o sistema estiver aberto.
const filtro = { periodo: 'mes', de: null, ate: null };

const num = v => Number(v || 0);

export function telaInicio(el, { perfil }) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">O Início precisa do Supabase configurado.</p></section>';
    return;
  }
  el.innerHTML = `
    <section class="inicio-topo">
      <div>
        <p class="texto-secundario">${dataBR(hojeISO())}</p>
        <h2>Olá, ${esc(perfil?.nome || '')}</h2>
      </div>
      ${htmlFiltroPeriodo(filtro)}
    </section>
    <div data-painel aria-live="polite"><p class="texto-secundario">Carregando…</p></div>`;
  ligarFiltroPeriodo(el, filtro, () => carregar(el));
  el.addEventListener('click', e => {
    if (e.target.closest('[data-ir-shopee]')) mostrarAbaShopee();
  });
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
    const { data, error } = await sb.rpc('dashboard', { p_inicio: inicio, p_fim: fim });
    if (meu !== pedidoAtual) return;              // chegou uma escolha mais nova
    if (error) {
      const faltaInstalar = /dashboard/.test(error.message || '') && /(function|função|schema cache|not find)/i.test(error.message || '');
      painel.innerHTML = faltaInstalar
        ? '<section class="cartao"><p class="texto-secundario">O painel aparece depois da instalação do Dashboard no banco (sql/24).</p></section>'
        : `<p class="aviso aviso-erro" role="alert">${esc(error.message)}</p>`;
      return;
    }
    painel.innerHTML = desenhar(data, inicio, fim);
  } catch (e) {
    if (meu === pedidoAtual) painel.innerHTML = `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  } finally {
    if (meu === pedidoAtual) painel.removeAttribute('aria-busy');
  }
}

// ---------------------------------------------------------------- blocos
function desenhar(d, inicio, fim) {
  const periodoTexto = inicio === fim ? dataBR(inicio) : `${dataBR(inicio)} a ${dataBR(fim)}`;
  return `
    ${alertas(d.alertas)}
    ${resultado(d.resultado, periodoTexto)}`;
}

/** R128: só os alertas que têm algo; cada um leva para a tela onde se resolve. */
function alertas(a) {
  const itens = [
    a.atrasados && { rota: 'pedidos', icone: 'ti-alarm', texto: `${a.atrasados} pedido(s) atrasado(s)`, forte: true },
    a.vencem_hoje && { rota: 'pedidos', icone: 'ti-calendar-due', texto: `${a.vencem_hoje} pedido(s) vencem hoje` },
    a.itens_a_produzir && { rota: 'producao', icone: 'ti-printer', texto: `${a.pecas_a_produzir} peça(s) a produzir em ${a.itens_a_produzir} item(ns)` },
    a.estoque_baixo && { rota: 'estoque', icone: 'ti-stack-2', texto: `${a.estoque_baixo} material(is) com estoque baixo` },
    a.repasses_a_confirmar && { rota: 'pedidos', shopee: true, icone: 'ti-cash', texto: `${a.repasses_a_confirmar} repasse(s) da Shopee a confirmar` },
    a.avisos_shopee && { rota: 'pedidos', shopee: true, icone: 'ti-alert-triangle', texto: `${a.avisos_shopee} aviso(s) da Shopee` },
    a.gastos_a_pagar && { rota: 'caixa', icone: 'ti-receipt', texto: `${a.gastos_a_pagar} gasto(s) a pagar` },
  ].filter(Boolean);
  if (!itens.length) return '<section class="cartao alertas-vazio"><p><i class="ti ti-circle-check" aria-hidden="true"></i> Nada pendente por aqui.</p></section>';
  return `<section class="cartao" aria-labelledby="t-alertas">
    <h3 id="t-alertas">Para resolver</h3>
    <ul class="lista-alertas">${itens.map(i => `
      <li><a class="alerta ${i.forte ? 'alerta-forte' : ''}" href="#/${i.rota}" ${i.shopee ? 'data-ir-shopee' : ''}>
        <i class="ti ${i.icone}" aria-hidden="true"></i><span>${i.texto}</span><i class="ti ti-chevron-right" aria-hidden="true"></i></a></li>`).join('')}
    </ul></section>`;
}

/** R123: a cascata do resultado do período. */
function resultado(r, periodoTexto) {
  const res = num(r.resultado);
  const linha = (rotulo, valor, sinal = '−') => (num(valor) ? `<li><span>${rotulo}</span><span>${sinal} ${brl(valor)}</span></li>` : '');
  return `<section class="cartao" aria-labelledby="t-resultado">
    <h3 id="t-resultado">Resultado do período <span class="texto-secundario">· ${esc(periodoTexto)}</span></h3>
    <div class="grade-metricas">
      <div class="metrica ${res < 0 ? 'metrica-perda' : 'metrica-recebido'}">
        <p class="metrica-rotulo"><i class="ti ti-trending-up" aria-hidden="true"></i> Resultado</p>
        <p class="metrica-valor">${brl(res)}</p>
      </div>
      <div class="metrica metrica-caixa">
        <p class="metrica-rotulo"><i class="ti ti-shopping-bag" aria-hidden="true"></i> Faturamento</p>
        <p class="metrica-valor">${brl(r.faturamento)}</p>
      </div>
      <div class="metrica metrica-neutra">
        <p class="metrica-rotulo"><i class="ti ti-receipt" aria-hidden="true"></i> Pedidos</p>
        <p class="metrica-valor">${num(r.pedidos)}</p>
        <p class="metrica-nota">${r.ticket_medio != null ? `Ticket médio ${brl(r.ticket_medio)}` : 'Nenhum pedido no período'}</p>
      </div>
    </div>
    <ul class="cascata">
      <li><span>Faturamento de produtos</span><span>${brl(r.faturamento)}</span></li>
      ${linha('Frete cobrado', r.frete, '+')}
      ${linha('Taxas das plataformas', r.taxas)}
      ${linha('Custo dos produtos vendidos', r.custos)}
      ${linha('Perdas de produção', r.perdas)}
      ${linha('Despesas da loja', r.despesas)}
      ${linha('Comissão do Joca', r.comissao_joca)}
      <li class="cascata-total"><span>Resultado</span><span>${brl(res)}</span></li>
    </ul>
    ${num(r.pedidos_sem_custo) ? `<p class="aviso aviso-atencao"><i class="ti ti-info-circle" aria-hidden="true"></i>
      ${num(r.pedidos_sem_custo)} pedido(s) ainda sem custo de produção: o custo entra quando a produção é registrada.</p>` : ''}
  </section>`;
}
