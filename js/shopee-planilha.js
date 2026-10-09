// Pedidos da Shopee · interpretação da planilha exportada pela Shopee
// (Meus Pedidos › Exportar). Regras aprovadas:
//  · só as colunas desta lista são lidas; todas as outras, inclusive as de
//    dados pessoais do comprador, são descartadas antes de qualquer gravação;
//  · valor vazio ou coluna ausente = null ("Não informado"); nada é calculado;
//  · valores ficam em texto exato ("79.50"), sem números aproximados;
//  · cada linha da planilha é um item; o pedido usa os dados da 1ª linha dele.

import { lerXlsx, ErroPlanilha } from './planilha-xlsx.js';

// Coluna da planilha → campo do pedido. Para colunas com nome repetido,
// a ocorrência (1ª, 2ª) entra no nome: "Desconto do vendedor#2".
const CAMPOS_PEDIDO = [
  ['Status do pedido', 'status', 'texto'],
  ['Status da Devolução / Reembolso', 'status_devolucao', 'texto'],
  ['Número de rastreamento', 'rastreio', 'texto'],
  ['Opção de envio', 'opcao_envio', 'texto'],
  ['Método de envio', 'metodo_envio', 'texto'],
  ['Data de criação do pedido', 'criado_em', 'data'],
  ['Hora do pagamento do pedido', 'pago_em', 'data'],
  ['Data prevista de envio', 'envio_previsto', 'data'],
  ['Tempo de Envio', 'enviado_em', 'data'],
  ['Valor Total', 'valor_total', 'dinheiro'],
  ['Desconto do vendedor#1', 'desconto_vendedor_1', 'dinheiro'],
  ['Desconto do vendedor#2', 'desconto_vendedor_2', 'dinheiro'],
  ['Cupom do vendedor', 'cupom_vendedor', 'dinheiro'],
  ['Cupom', 'cupom_shopee', 'dinheiro'],
  ['Código do Cupom', 'codigo_cupom', 'texto'],
  ['Total global', 'total_global', 'dinheiro'],
  ['Taxa de envio pagas pelo comprador', 'frete_comprador', 'dinheiro'],
  ['Valor estimado do frete', 'frete_estimado', 'dinheiro'],
  ['Desconto de Frete Aproximado', 'desconto_frete', 'dinheiro'],
  ['Taxa de comissão líquida', 'taxa_comissao', 'dinheiro'],
  ['Taxa de serviço líquida', 'taxa_servico', 'dinheiro'],
  ['Taxa de transação', 'taxa_transacao', 'dinheiro'],
  ['Taxa de Envio Reversa', 'taxa_envio_reversa', 'dinheiro'],
  ['Número de produtos pedidos', 'numero_produtos', 'inteiro'],
];

const CAMPOS_ITEM = [
  ['Nome do Produto', 'produto', 'texto'],
  ['Nome da variação', 'variacao', 'texto'],
  ['Número de referência SKU', 'sku', 'texto'],
  ['Nº de referência do SKU principal', 'sku_principal', 'texto'],
  ['Quantidade', 'quantidade', 'inteiro'],
  ['Returned quantity', 'qtd_devolvida', 'inteiro'],
  ['Preço original', 'preco_original', 'dinheiro'],
  ['Preço acordado', 'preco_acordado', 'dinheiro'],
  ['Subtotal do produto', 'subtotal', 'dinheiro'],
];

// Outras colunas sem dados pessoais, guardadas só como cópia (nada se perde).
const OUTRAS_PEDIDO = [
  'Hot Listing', 'Incentivo Shopee para ação comercial', 'Ajuste por participação em ação comercial',
  'Peso total do pedido', 'Coin Cashback Voucher Amount Sponsored by Seller', 'Incentivo de cupom',
  'Ajuste por pagamento via PIX', 'Indicador da Leve Mais por Menos', 'Desconto Shopee da Leve Mais por Menos',
  'Desconto da Leve Mais por Menos do vendedor', 'Compensar Moedas Shopee', 'Total descontado Cartão de Crédito',
  'Taxa de Serviço Instantâneo pago pelo comprador', 'Taxa de comissão bruta', 'Taxa de serviço bruta',
];
const OUTRAS_ITEM = ['Peso total SKU'];

const COL_ID = 'ID do pedido';

/** Colunas que o sistema conhece (as demais são descartadas). */
export const COLUNAS_PERMITIDAS = new Set([
  COL_ID, ...CAMPOS_PEDIDO.map(c => c[0]), ...CAMPOS_ITEM.map(c => c[0]), ...OUTRAS_PEDIDO, ...OUTRAS_ITEM,
].map(n => n.replace(/#\d$/, '')));

const RE_DINHEIRO = /^-?\d{1,10}(?:[.,]\d{1,2})?$/;
const RE_DINHEIRO_ZEROS = /^(-?\d{1,10})[.,](\d{2})0+$/; // "79.500" → "79.50"
const RE_INTEIRO = /^-?\d{1,9}$/;
const RE_DATA = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?$/;
const RE_DATA_BR = /^(\d{2})\/(\d{2})\/(\d{4})(?:\s+(\d{2}):(\d{2})(?::(\d{2}))?)?$/;

/** "79,5" → "79.50" (texto exato, 2 casas). Lança erro se não for um valor. */
export function dinheiro(texto) {
  let t = String(texto ?? '').trim();
  if (t === '') return null;
  const z = t.match(RE_DINHEIRO_ZEROS);
  if (z) t = `${z[1]}.${z[2]}`;
  if (!RE_DINHEIRO.test(t)) throw new Error(`valor "${texto}" não é um valor em reais`);
  const [int, frac = ''] = t.replace(',', '.').split('.');
  const neg = int.startsWith('-');
  const inteiro = String(Number(neg ? int.slice(1) : int)); // tira zeros à esquerda (inteiro pequeno, exato)
  return `${neg && (inteiro !== '0' || /[1-9]/.test(frac)) ? '-' : ''}${inteiro}.${(frac + '00').slice(0, 2)}`;
}

/** "79.50" → 7950 (centavos inteiros, exatos). */
export function centavos(texto) {
  if (texto == null || texto === '') return null;
  const t = dinheiro(texto);
  const neg = t.startsWith('-');
  const [int, frac] = t.replace('-', '').split('.');
  const c = Number(int) * 100 + Number(frac);
  return neg ? -c : c;
}

function inteiro(texto) {
  const t = String(texto ?? '').trim();
  if (t === '') return null;
  const t2 = t.replace(/\.0+$/, '');
  if (!RE_INTEIRO.test(t2)) throw new Error(`"${texto}" não é um número inteiro`);
  return String(Number(t2));
}

/** Datas da Shopee estão no horário de Brasília. Devolve ISO com fuso. */
function data(texto) {
  const t = String(texto ?? '').trim();
  if (t === '') return null;
  let a, m, d, h = '00', mi = '00', s = '00';
  let x = t.match(RE_DATA);
  if (x) [, a, m, d, h = '00', mi = '00', s = '00'] = x;
  else if ((x = t.match(RE_DATA_BR))) [, d, m, a, h = '00', mi = '00', s = '00'] = x;
  else if (/^\d{5}(?:\.\d+)?$/.test(t)) {
    // Data guardada como número do Excel (dias desde 30/12/1899), no horário local da planilha.
    const ms = Math.round(Number(t) * 86400000);
    const dt = new Date(Date.UTC(1899, 11, 30) + ms);
    const p = n => String(n).padStart(2, '0');
    [a, m, d, h, mi, s] = [dt.getUTCFullYear(), p(dt.getUTCMonth() + 1), p(dt.getUTCDate()),
      p(dt.getUTCHours()), p(dt.getUTCMinutes()), p(dt.getUTCSeconds())];
  } else throw new Error(`"${texto}" não é uma data`);
  // Confere se a data existe de verdade (31/02 não existe).
  const teste = new Date(Date.UTC(Number(a), Number(m) - 1, Number(d), Number(h), Number(mi), Number(s)));
  if (teste.getUTCFullYear() !== Number(a) || teste.getUTCMonth() !== Number(m) - 1 || teste.getUTCDate() !== Number(d)
      || teste.getUTCHours() !== Number(h) || teste.getUTCMinutes() !== Number(mi) || teste.getUTCSeconds() !== Number(s)) {
    throw new Error(`"${texto}" não é uma data válida`);
  }
  return `${a}-${m}-${d}T${h}:${mi}:${s}-03:00`;
}

const CONVERSOR = { texto: v => (String(v ?? '').trim() || null), dinheiro, inteiro, data };

/** Normaliza para a chave do item: sem diferença de maiúsculas, acentos de digitação e espaços extras. */
function normalizar(t) {
  return String(t ?? '').normalize('NFC').trim().replace(/\s+/g, ' ').toLowerCase();
}

/**
 * Lê o arquivo e devolve { pedidos, errosArquivo, avisosArquivo, linhas }.
 * Cada pedido: { pedido_id, dados, colunas, itens: [{ chave, dados, colunas }], linhas, erros, avisos }.
 */
export async function lerPlanilhaShopee(arquivo) {
  const { linhas } = await lerXlsx(arquivo, 'orders');
  const resultado = { pedidos: [], errosArquivo: [], avisosArquivo: [], linhas: 0 };
  if (linhas.length < 2) throw new ErroPlanilha('A planilha não tem nenhum pedido.');

  // Cabeçalho: nome da coluna → posição (nomes repetidos ganham "#2", "#3"…).
  const vistos = {};
  const pos = {};
  linhas[0].forEach((nome, i) => {
    const n = String(nome || '').trim();
    if (!n) return;
    vistos[n] = (vistos[n] || 0) + 1;
    pos[`${n}#${vistos[n]}`] = i;
    if (vistos[n] === 1) pos[n] = i;
  });
  if (pos[COL_ID] == null) {
    throw new ErroPlanilha('Esta planilha não parece ser a exportação de pedidos da Shopee (falta a coluna "ID do pedido").');
  }
  // Sem as colunas essenciais, ou com a maioria das colunas conhecidas faltando,
  // a planilha não é interpretada com segurança: a importação é recusada.
  const essenciais = ['Status do pedido', 'Nome do Produto', 'Quantidade'].filter(n => pos[n] == null);
  if (essenciais.length) {
    throw new ErroPlanilha(`Esta planilha não parece ser a exportação de pedidos da Shopee: faltam as colunas ${essenciais.map(n => `"${n}"`).join(', ')}. Nada foi importado.`);
  }
  const conhecidas = [...CAMPOS_PEDIDO, ...CAMPOS_ITEM].map(c => c[0]);
  const faltando = conhecidas.filter(n => pos[n] == null);
  if (faltando.length > conhecidas.length / 2) {
    throw new ErroPlanilha(`Esta planilha tem colunas muito diferentes da exportação de pedidos da Shopee (${faltando.length} de ${conhecidas.length} colunas esperadas não foram encontradas). Nada foi importado.`);
  }
  if (faltando.length) {
    resultado.avisosArquivo.push(`Colunas não encontradas (aparecem como "Não informado"): ${faltando.map(n => n.replace(/#\d$/, ' (2ª)')).join(', ')}.`);
  }

  const cel = (linha, nome) => (pos[nome] == null ? '' : (linha[pos[nome]] ?? ''));
  const porId = new Map();

  linhas.slice(1).forEach((linha, idx) => {
    const numLinha = idx + 2; // número da linha como aparece no Excel
    if (!linha.some(v => String(v).trim() !== '')) return;
    resultado.linhas++;
    const id = String(cel(linha, COL_ID)).trim();
    if (!id) {
      resultado.errosArquivo.push(`Linha ${numLinha}: sem "ID do pedido". A linha foi ignorada.`);
      return;
    }

    let reg = porId.get(id);
    const primeira = !reg;
    if (primeira) {
      reg = { pedido_id: id, dados: {}, colunas: {}, itens: [], linhas: [], erros: [], avisos: [], brutos: {} };
      porId.set(id, reg);
    }
    reg.linhas.push(numLinha);

    // Dados do pedido (1ª linha); nas seguintes, só confere se repetem.
    for (const [col, campo, tipo] of CAMPOS_PEDIDO) {
      const bruto = String(cel(linha, col)).trim();
      if (primeira) {
        reg.brutos[campo] = bruto;
        try { reg.dados[campo] = CONVERSOR[tipo](bruto); } catch (e) {
          reg.erros.push(`Linha ${numLinha}, coluna "${col.replace(/#\d$/, '')}": ${e.message}.`);
        }
      } else if (bruto !== reg.brutos[campo] && reg.dados[campo] !== null) {
        // O valor muda de uma linha para outra: não dá para saber qual é o do pedido.
        // Fica "Não informado" no pedido (sem escolher um) e o de cada linha fica guardado no item.
        reg.dados[campo] = null;
        const nomeCol = col.replace(/#(\d)$/, ' ($1ª)');
        reg.avisos.push(`A coluna "${nomeCol}" tem valores diferentes entre os itens deste pedido. No pedido ela aparece como "Não informado"; o valor de cada item fica guardado no item.`);
      }
    }
    if (primeira) for (const col of OUTRAS_PEDIDO) if (pos[col] != null) reg.colunas[col] = String(cel(linha, col));

    // Item desta linha.
    const item = { dados: {}, colunas: {} };
    for (const [col, campo, tipo] of CAMPOS_ITEM) {
      try { item.dados[campo] = CONVERSOR[tipo](cel(linha, col)); } catch (e) {
        reg.erros.push(`Linha ${numLinha}, coluna "${col}": ${e.message}.`);
      }
    }
    if (!item.dados.produto) reg.erros.push(`Linha ${numLinha}: sem "Nome do Produto".`);
    // Cópia de todas as colunas permitidas desta linha (inclusive as do pedido, que podem variar por item).
    for (const col of COLUNAS_PERMITIDAS) {
      const repetida = (vistos[col] || 0) > 1;
      for (let n = 1; n <= (vistos[col] || 0); n++) {
        item.colunas[repetida ? `${col} (${n}ª)` : col] = String(cel(linha, `${col}#${n}`));
      }
    }
    // Chave do item: produto + variação + SKU + ocorrência (o SKU costuma vir vazio).
    const base = [item.dados.produto, item.dados.variacao, item.dados.sku].map(normalizar).join('|');
    const ocorrencia = reg.itens.filter(i => i.base === base).length + 1;
    item.base = base;
    item.chave = `${base}#${ocorrencia}`;
    reg.itens.push(item);
  });

  resultado.pedidos = [...porId.values()].map(({ brutos, ...p }) => ({
    ...p, itens: p.itens.map(({ base, ...i }) => i),
  }));
  return resultado;
}

/** Monta a lista que vai para o banco: só pedidos sem erro e só os campos permitidos. */
export function paraEnvio(pedidos) {
  return pedidos.filter(p => !p.erros.length).map(p => ({
    pedido_id: p.pedido_id, dados: p.dados, colunas: p.colunas,
    itens: p.itens.map(i => ({ chave: i.chave, dados: i.dados, colunas: i.colunas })),
  }));
}

export { ErroPlanilha };
