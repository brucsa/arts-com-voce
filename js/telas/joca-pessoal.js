import { esc, brl, dataBR } from '../format.js';
import { supabase, configurado } from '../supabase.js';
import { ok } from '../db.js';

// Área pessoal do Joca (R26, R92).
// Mostra só valores dele, pelas funções joca_resumo() e joca_extrato().
// Nunca percentual, base, total da venda, cliente, taxas, custos, lucro,
// Caixa ou qualquer outro número da loja.
const SITUACAO = {
  'A receber': 'selo-despesa',
  'Disponível': 'selo-investimento',
  'Recebido em parte': 'selo-investimento',
  'Recebido': 'selo-ativo',
  'Cancelado': 'selo-inativo',
};

const naoInstalada = e => /PGRST202|42883|PGRST205|42P01/.test(`${e?.original?.code}`)
  || /joca_resumo|joca_extrato|vw_joca_pedidos|does not exist|Could not find/i.test(`${e?.original?.message}`);

export async function telaJocaPessoal(el, { perfil, demo } = {}) {
  const card = (rotulo, icone, classe, valor, nota = '') => `
    <div class="metrica ${classe}">
      <p class="metrica-rotulo"><i class="ti ${icone}" aria-hidden="true"></i> ${rotulo}</p>
      <p class="metrica-valor ${Number(valor) < 0 ? 'valor-negativo' : ''}">${valor === null ? '—' : brl(valor)}</p>
      ${nota ? `<p class="metrica-nota">${nota}</p>` : ''}
    </div>`;
  const pagina = (resumo, vendas, pagamentos, aviso = '') => {
    el.innerHTML = `
      <section class="boas-vindas">
        <h2>Olá, ${esc(perfil.nome)} ⭐</h2>
        <p>Aqui você acompanha o que ganhou com as vendas da Arts com Você.</p>
      </section>
      <div class="grade-metricas">
        ${card('A receber', 'ti-hourglass', 'metrica-espera', resumo?.a_receber ?? null, 'Vendas que a loja ainda está recebendo.')}
        ${card('Disponível', 'ti-coin', 'metrica-disponivel', resumo?.disponivel ?? null,
          Number(resumo?.disponivel) < 0 ? 'Desconto de uma venda cancelada: sai das próximas.' : 'Já pode ser pago para você.')}
        ${card('Já recebi', 'ti-circle-check', 'metrica-recebido', resumo?.ja_recebi ?? null)}
      </div>
      <section class="cartao">
        <h3>Minhas vendas</h3>
        ${aviso ? `<p class="texto-secundario">${aviso}</p>`
          : vendas.length ? `<ul class="lista">${vendas.map(v => `
            <li class="linha">
              <div class="linha-texto">
                <strong>${esc(v.descricao || 'Venda')}</strong>
                <span class="texto-secundario">${dataBR(v.data)}${v.canal ? ` · ${esc(v.canal)}` : ''}</span>
              </div>
              <div class="linha-direita">
                <span class="linha-valor">${brl(v.valor)}</span>
                <span class="selo-p ${SITUACAO[v.situacao] || 'selo-inativo'}">${esc(v.situacao)}</span>
              </div>
            </li>`).join('')}</ul>` : '<p class="texto-secundario vazio">Ainda não há vendas.</p>'}
      </section>
      <section class="cartao">
        <h3>Pagamentos que recebi</h3>
        ${pagamentos.length ? `<ul class="lista">${pagamentos.map(g => `
          <li class="linha">
            <div class="linha-texto"><strong>Pagamento</strong><span class="texto-secundario">${dataBR(g.data)}</span></div>
            <span class="linha-valor">${brl(g.valor)}</span>
          </li>`).join('')}</ul>` : '<p class="texto-secundario vazio">Ainda não há pagamentos.</p>'}
      </section>`;
  };

  if (demo || !configurado) { pagina(null, [], [], 'Os valores aparecem aqui quando o sistema estiver conectado.'); return; }
  el.innerHTML = '<p class="texto-secundario">Carregando…</p>';
  try {
    const sb = await supabase();
    const [resumo, extrato] = await Promise.all([sb.rpc('joca_resumo').then(ok), sb.rpc('joca_extrato').then(ok)]);
    pagina(resumo[0], extrato.filter(x => x.tipo === 'PEDIDO'), extrato.filter(x => x.tipo === 'PAGAMENTO'));
  } catch (e) {
    if (naoInstalada(e)) pagina(null, [], [], 'Os valores aparecem aqui em breve.');
    else el.innerHTML = `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  }
}
