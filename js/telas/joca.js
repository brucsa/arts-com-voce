// Joca ⭐ · visão da Admin (especificação v1.7, R89–R92).
// Comissão de cada Pedido Direto (calculada e acertada pelo banco), totais
// A receber / Disponível / Pago e pagamentos ao Joca (registrar e estornar).
// Toda gravação passa pelas funções do banco (registrar_pagamento_joca,
// estornar_pagamento_joca). O pagamento sai do Caixa pelo próprio banco.

import { supabase, configurado } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, dataBR, dataHoraBR, hojeISO, paraCampo } from '../format.js';
import { cliqueForaDoDialogo } from '../ui/dialogo.js';
import { abrirFormulario } from '../ui/formulario.js';
import { FORMAS, ROTULO_FORMA } from '../financeiro.js';

export const SITUACAO_COMISSAO = {
  A_RECEBER: { rotulo: 'A receber', classe: 'selo-despesa' },
  DISPONIVEL: { rotulo: 'Disponível', classe: 'selo-investimento' },
  PAGA_EM_PARTE: { rotulo: 'Paga em parte', classe: 'selo-investimento' },
  PAGA: { rotulo: 'Paga', classe: 'selo-ativo' },
  CANCELADO: { rotulo: 'Cancelado', classe: 'selo-inativo' },
};
const TIPO = { COMISSAO: 'Comissão', AJUSTE: 'Ajuste', CANCELAMENTO: 'Cancelamento' };

const selo = s => (SITUACAO_COMISSAO[s] ? `<span class="selo-p ${SITUACAO_COMISSAO[s].classe}">${SITUACAO_COMISSAO[s].rotulo}</span>` : '');
const numeroPedido = n => `#${String(n).padStart(4, '0')}`;
const negativo = v => (Number(v) < 0 ? 'valor-negativo' : '');
const sinal = v => `${Number(v) < 0 ? '−' : '+'} ${brl(Math.abs(Number(v)))}`;

function novaChave() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// A área do Joca ainda não instalada no banco (sql/13): a função não existe.
const naoInstalada = e => /PGRST202|42883|PGRST205|42P01/.test(`${e?.original?.code}`)
  || /joca_resumo|joca_extrato|vw_joca_pedidos|does not exist|Could not find/i.test(`${e?.original?.message}`);

export function telaJoca(el) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">A área do Joca precisa do Supabase configurado.</p></section>';
    return;
  }
  carregar(el);
}

async function carregar(el, mensagem) {
  const area = document.createElement('div');
  area.className = 'painel-area';
  area.innerHTML = '<p class="texto-secundario">Carregando…</p>';
  el.replaceChildren(area);
  try {
    await desenhar(area, msg => carregar(el, msg), mensagem);
  } catch (e) {
    area.innerHTML = naoInstalada(e)
      ? `<section class="cartao"><h3>Área do Joca</h3>
           <p class="texto-secundario">As comissões e os pagamentos do Joca aparecem aqui depois da instalação no banco (R89–R92).</p></section>`
      : `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  }
}

async function desenhar(area, recarregar, mensagem) {
  const sb = await supabase();
  const resumo = (await sb.rpc('joca_resumo').then(ok))[0];
  const [pedidos, historico, pagamentos, config] = await Promise.all([
    sb.from('vw_joca_pedidos').select('*').order('data', { ascending: false }).order('numero', { ascending: false }).then(ok),
    sb.from('comissoes_joca').select('venda_id, seq, data, tipo, valor, comissao_apos, obs, created_at').order('seq').then(ok),
    sb.from('pagamentos_joca').select('*').order('data', { ascending: false }).order('created_at', { ascending: false }).then(ok),
    sb.from('configuracoes').select('comissao_joca_pct').eq('id', 1).single().then(ok),
  ]);
  const lista = pedidos.filter(p => p.situacao !== 'SEM_COMISSAO' && (Number(p.comissao) !== 0 || p.registros > 0));
  const disp = Number(resumo.disponivel);

  area.innerHTML = `
    <p class="texto-secundario joca-pct">Percentual atual: <strong>${paraCampo(config.comissao_joca_pct, 0, 2)}%</strong>
      de (produtos − desconto), sem o frete. Cada pedido usa o percentual da data dele.
      <a href="#/configuracoes">Mudar em Configurações</a></p>
    <div class="grade-metricas">
      <div class="metrica metrica-espera">
        <p class="metrica-rotulo"><i class="ti ti-hourglass" aria-hidden="true"></i> A receber</p>
        <p class="metrica-valor">${brl(resumo.a_receber)}</p>
        <p class="metrica-nota">Pedidos que ainda não foram todo recebidos.</p>
      </div>
      <div class="metrica metrica-disponivel">
        <p class="metrica-rotulo"><i class="ti ti-coin" aria-hidden="true"></i> Disponível</p>
        <p class="metrica-valor ${negativo(disp)}">${brl(disp)}</p>
        <p class="metrica-nota">${disp < 0 ? 'Negativo por estorno de comissão já paga: é descontado das próximas.' : 'Pode ser pago ao Joca.'}</p>
      </div>
      <div class="metrica metrica-recebido">
        <p class="metrica-rotulo"><i class="ti ti-circle-check" aria-hidden="true"></i> Pago</p>
        <p class="metrica-valor">${brl(resumo.ja_recebi)}</p>
        <p class="metrica-nota">Total já pago ao Joca.</p>
      </div>
    </div>

    <div class="acoes-caixa">
      <button class="botao botao-primario" data-pagar ${disp > 0 ? '' : 'disabled'}>
        <i class="ti ti-credit-card-pay" aria-hidden="true"></i> Registrar pagamento</button>
      ${disp > 0 ? '' : '<span class="texto-secundario">Sem valor disponível para pagar agora.</span>'}
    </div>
    <p class="aviso aviso-ok" role="status" ${mensagem ? '' : 'hidden'}>${esc(mensagem || '')}</p>

    <section class="cartao">
      <h3>Comissões por pedido</h3>
      ${lista.length ? `<ul class="lista">${lista.map(p => `
        <li><button type="button" class="linha linha-botao" data-pedido="${p.venda_id}">
          <span class="linha-texto">
            <strong>${numeroPedido(p.numero)} · ${esc(p.cliente)}</strong>
            <span class="texto-secundario">${dataBR(p.data)} · ${paraCampo(p.percentual, 0, 2)}% de ${brl(p.base)}${Number(p.valor_devolvido) > 0 ? ` · devolvido ${brl(p.valor_devolvido)}` : ''}</span>
          </span>
          <span class="linha-direita">
            <span class="linha-valor">${brl(p.comissao)}</span>
            ${selo(p.situacao)}
          </span>
        </button></li>`).join('')}</ul>` : '<p class="texto-secundario vazio">Nenhuma comissão ainda. Cada Pedido Direto gera a comissão do Joca.</p>'}
    </section>

    <section class="cartao">
      <h3>Pagamentos ao Joca</h3>
      ${pagamentos.length ? `<ul class="lista">${pagamentos.map(g => `
        <li class="linha ${g.situacao === 'ESTORNADO' ? 'inativo' : ''}">
          <div class="linha-texto">
            <strong>Pagamento de ${dataBR(g.data)} ${g.situacao === 'ESTORNADO' ? '<span class="selo-p selo-inativo">Estornado</span>' : ''}</strong>
            <span class="texto-secundario">${ROTULO_FORMA[g.forma_pagamento] || g.forma_pagamento}${g.obs ? ` · ${esc(g.obs)}` : ''}</span>
            ${g.situacao === 'ESTORNADO' ? `<span class="texto-secundario">Estornado em ${dataHoraBR(g.estornado_em)} · ${esc(g.motivo_estorno)}</span>` : ''}
          </div>
          <div class="linha-direita">
            <span class="linha-valor">${brl(g.valor)}</span>
            ${g.situacao === 'ATIVO' ? `<div class="linha-acoes"><button class="botao botao-pequeno botao-perigo" data-estornar="${g.id}">Estornar</button></div>` : ''}
          </div>
        </li>`).join('')}</ul>` : '<p class="texto-secundario vazio">Nenhum pagamento ao Joca ainda.</p>'}
    </section>`;

  area.querySelector('[data-pagar]').addEventListener('click', () => {
    const chave = novaChave();
    abrirFormulario({
      titulo: 'Registrar pagamento ao Joca',
      textoSalvar: 'Registrar pagamento',
      valores: { data: hojeISO(), valor: disp, forma: 'PIX' },
      campos: [
        { nome: 'valor', rotulo: 'Valor pago (R$)', tipo: 'decimal', casas: 2, casasMin: 2, obrigatorio: true, maiorQueZero: true,
          dica: `Disponível: ${brl(disp)}. Não existe adiantamento: o valor não pode passar do Disponível.` },
        { nome: 'data', rotulo: 'Data do pagamento', tipo: 'data', obrigatorio: true, maxData: hojeISO() },
        { nome: 'forma', rotulo: 'Forma de pagamento', tipo: 'select', obrigatorio: true,
          opcoes: FORMAS.map(f => ({ valor: f.valor, rotulo: f.rotulo })) },
        { nome: 'obs', rotulo: 'Observação', tipo: 'texto', placeholder: 'Ex.: comissões de outubro' },
      ],
      async aoSalvar(v) {
        if (v.valor > disp) throw new Error(`O valor passa do Disponível do Joca (${brl(disp)}). Não existe adiantamento de comissão.`);
        await sb.rpc('registrar_pagamento_joca', {
          p_data: v.data, p_valor: v.valor, p_forma_pagamento: v.forma, p_obs: v.obs, p_chave: chave,
        }).then(ok);
        await recarregar(`Pagamento de ${brl(v.valor)} ao Joca registrado e lançado no Caixa.`);
      },
    });
  });

  area.querySelectorAll('[data-estornar]').forEach(b => b.addEventListener('click', () => {
    const g = pagamentos.find(x => x.id === b.dataset.estornar);
    abrirFormulario({
      titulo: `Estornar pagamento de ${brl(g.valor)}`,
      textoSalvar: 'Estornar',
      campos: [
        { nome: 'motivo', rotulo: 'Motivo do estorno', tipo: 'texto', obrigatorio: true, placeholder: 'Ex.: valor digitado errado',
          dica: `Use só para corrigir um pagamento feito por engano (${dataBR(g.data)}). O pagamento continua no histórico, `
            + 'o valor volta ao Caixa com a data de hoje e volta ao Disponível do Joca.' },
      ],
      async aoSalvar(v) {
        await sb.rpc('estornar_pagamento_joca', { p_pagamento_id: g.id, p_motivo: v.motivo }).then(ok);
        await recarregar(`Pagamento de ${brl(g.valor)} estornado. O valor voltou ao Caixa e ao Disponível do Joca.`);
      },
    });
  }));

  area.querySelectorAll('[data-pedido]').forEach(b => b.addEventListener('click', () => {
    const p = lista.find(x => x.venda_id === b.dataset.pedido);
    abrirHistorico(p, historico.filter(h => h.venda_id === p.venda_id));
  }));
}

function abrirHistorico(p, linhas) {
  const dialog = document.createElement('dialog');
  dialog.className = 'folha folha-form';
  dialog.setAttribute('aria-labelledby', 'joca-hist');
  dialog.innerHTML = `
    <div class="folha-topo">
      <h2 id="joca-hist">Comissão do pedido ${numeroPedido(p.numero)}</h2>
      <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
    </div>
    <div class="detalhe-dados">
      <div class="linha-dado"><span>Cliente</span><strong>${esc(p.cliente)}</strong></div>
      <div class="linha-dado"><span>Data do pedido</span><strong>${dataBR(p.data)}</strong></div>
      <div class="linha-dado"><span>Produtos − desconto</span><strong>${brl(p.base)}</strong></div>
      ${Number(p.valor_devolvido) > 0 ? `<div class="linha-dado"><span>Devolvido ao cliente</span><strong>${brl(p.valor_devolvido)} de ${brl(p.total)}</strong></div>` : ''}
      <div class="linha-dado"><span>Percentual (data do pedido)</span><strong>${paraCampo(p.percentual, 0, 2)}%</strong></div>
      <div class="linha-dado"><span>Comissão</span><strong>${brl(p.comissao)} ${selo(p.situacao)}</strong></div>
    </div>
    <p class="detalhe-titulo">Histórico</p>
    ${linhas.length ? `<ul class="lista">${linhas.map(h => `
      <li class="linha">
        <div class="linha-texto">
          <strong>${esc(h.obs)}</strong>
          <span class="texto-secundario">${dataBR(h.data)} · ${TIPO[h.tipo]} · comissão depois: ${brl(h.comissao_apos)}</span>
        </div>
        <span class="linha-valor ${Number(h.valor) < 0 ? 'valor-saida' : 'valor-entrada'}">${sinal(h.valor)}</span>
      </li>`).join('')}</ul>` : '<p class="texto-secundario">Sem registros.</p>'}
    <div class="form-acoes"><span class="espaco"></span><button type="button" class="botao" data-fechar>Fechar</button></div>`;
  document.body.appendChild(dialog);
  const fechar = () => { dialog.close(); dialog.remove(); };
  dialog.addEventListener('click', e => { if (cliqueForaDoDialogo(e, dialog) || e.target.closest('[data-fechar]')) fechar(); });
  dialog.addEventListener('cancel', e => { e.preventDefault(); fechar(); });
  dialog.showModal();
}
