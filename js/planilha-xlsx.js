// Leitor mínimo de planilhas .xlsx, sem bibliotecas externas.
//
// Um .xlsx é um arquivo ZIP com XMLs dentro. Aqui lemos só o necessário:
// a lista de abas, os textos compartilhados e as células da aba escolhida.
// Os valores voltam como TEXTO exatamente como estão no arquivo (por
// exemplo "79.50"), sem passar por números aproximados do JavaScript.
//
// Usa recursos nativos do navegador (DecompressionStream e DOMParser).

const NS_MAIN = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const NS_REL_DOC = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const LIMITE_BYTES = 10 * 1024 * 1024; // 10 MB

class ErroPlanilha extends Error {}

/** Lê as entradas do ZIP (nome → { metodo, inicio, tamanho }). */
function indiceZip(bytes) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  // Fim do diretório central: assinatura 0x06054b50, procurada de trás para frente.
  let fim = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 22 - 65535); i--) {
    if (dv.getUint32(i, true) === 0x06054b50) { fim = i; break; }
  }
  if (fim < 0) throw new ErroPlanilha('Este arquivo não é uma planilha .xlsx válida.');
  const total = dv.getUint16(fim + 10, true);
  let p = dv.getUint32(fim + 16, true);
  const dec = new TextDecoder();
  const entradas = new Map();
  for (let n = 0; n < total; n++) {
    if (dv.getUint32(p, true) !== 0x02014b50) throw new ErroPlanilha('A planilha está corrompida.');
    const metodo = dv.getUint16(p + 10, true);
    const tamanho = dv.getUint32(p + 20, true);
    const lenNome = dv.getUint16(p + 28, true);
    const lenExtra = dv.getUint16(p + 30, true);
    const lenComent = dv.getUint16(p + 32, true);
    const local = dv.getUint32(p + 42, true);
    const nome = dec.decode(bytes.subarray(p + 46, p + 46 + lenNome));
    if (dv.getUint32(local, true) !== 0x04034b50) throw new ErroPlanilha('A planilha está corrompida.');
    const inicio = local + 30 + dv.getUint16(local + 26, true) + dv.getUint16(local + 28, true);
    entradas.set(nome.replace(/^\//, ''), { metodo, inicio, tamanho });
    p += 46 + lenNome + lenExtra + lenComent;
  }
  return entradas;
}

async function textoDaEntrada(bytes, entradas, nome) {
  const e = entradas.get(nome.replace(/^\//, ''));
  if (!e) return null;
  const dados = bytes.subarray(e.inicio, e.inicio + e.tamanho);
  let saida;
  if (e.metodo === 0) saida = dados;
  else if (e.metodo === 8) {
    if (typeof DecompressionStream === 'undefined') {
      throw new ErroPlanilha('Este navegador não consegue abrir planilhas. Atualize o navegador e tente de novo.');
    }
    const fluxo = new Blob([dados]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
    saida = new Uint8Array(await new Response(fluxo).arrayBuffer());
  } else {
    throw new ErroPlanilha('A planilha usa um formato de compressão que o sistema não lê.');
  }
  return new TextDecoder().decode(saida);
}

function xml(texto) {
  const doc = new DOMParser().parseFromString(texto, 'application/xml');
  if (doc.getElementsByTagName('parsererror').length) throw new ErroPlanilha('A planilha está corrompida.');
  return doc;
}

const elementos = (no, nome) => Array.from(no.getElementsByTagNameNS(NS_MAIN, nome));
const textoDe = (no) => elementos(no, 't').map(t => t.textContent).join('');

/** "AB12" → 27 (coluna, começando em 0) */
function indiceColuna(ref) {
  const letras = String(ref || '').match(/^[A-Z]+/i);
  if (!letras) return -1;
  let n = 0;
  for (const ch of letras[0].toUpperCase()) n = n * 26 + (ch.charCodeAt(0) - 64);
  return n - 1;
}

/**
 * Lê um arquivo .xlsx e devolve as linhas de uma aba como listas de textos.
 * nomeAba: aba preferida (por exemplo "orders"); se não existir, usa a primeira.
 */
export async function lerXlsx(arquivo, nomeAba) {
  if (!arquivo) throw new ErroPlanilha('Escolha um arquivo.');
  if (!/\.xlsx$/i.test(arquivo.name || '')) throw new ErroPlanilha('Escolha a planilha .xlsx exportada pela Shopee.');
  if (arquivo.size > LIMITE_BYTES) throw new ErroPlanilha('A planilha é grande demais (máximo 10 MB). Exporte um período menor.');

  const bytes = new Uint8Array(await arquivo.arrayBuffer());
  const entradas = indiceZip(bytes);

  const wbTexto = await textoDaEntrada(bytes, entradas, 'xl/workbook.xml');
  const relTexto = await textoDaEntrada(bytes, entradas, 'xl/_rels/workbook.xml.rels');
  if (!wbTexto || !relTexto) throw new ErroPlanilha('Este arquivo não é uma planilha .xlsx válida.');

  const rels = new Map(Array.from(xml(relTexto).getElementsByTagName('Relationship'))
    .map(r => [r.getAttribute('Id'), r.getAttribute('Target')]));
  const abas = elementos(xml(wbTexto), 'sheet').map(s => ({
    nome: s.getAttribute('name'),
    alvo: rels.get(s.getAttributeNS(NS_REL_DOC, 'id') || s.getAttribute('r:id')),
  })).filter(a => a.alvo);
  if (!abas.length) throw new ErroPlanilha('A planilha não tem nenhuma aba.');
  const aba = abas.find(a => a.nome === nomeAba) || abas[0];
  const caminho = aba.alvo.startsWith('/') ? aba.alvo.slice(1) : `xl/${aba.alvo.replace(/^\.\//, '')}`;

  const compartilhados = [];
  const ssTexto = await textoDaEntrada(bytes, entradas, 'xl/sharedStrings.xml');
  if (ssTexto) for (const si of elementos(xml(ssTexto), 'si')) compartilhados.push(textoDe(si));

  const folhaTexto = await textoDaEntrada(bytes, entradas, caminho);
  if (!folhaTexto) throw new ErroPlanilha('Não encontrei a aba de pedidos na planilha.');

  const linhas = [];
  for (const row of elementos(xml(folhaTexto), 'row')) {
    const valores = [];
    let proxima = 0;
    for (const c of elementos(row, 'c')) {
      const col = c.hasAttribute('r') ? indiceColuna(c.getAttribute('r')) : proxima;
      proxima = col + 1;
      const tipo = c.getAttribute('t');
      const v = elementos(c, 'v')[0]?.textContent ?? '';
      let valor;
      if (tipo === 's') valor = compartilhados[Number(v)] ?? '';
      else if (tipo === 'inlineStr') valor = elementos(c, 'is').map(textoDe).join('');
      else if (tipo === 'e') valor = '';
      else valor = v; // número, texto de fórmula ou booleano: o texto exato do arquivo
      valores[col] = valor;
    }
    linhas.push(Array.from(valores, x => (x == null ? '' : String(x))));
  }
  return { aba: aba.nome, linhas };
}

export { ErroPlanilha };
