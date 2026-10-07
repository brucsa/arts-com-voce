// Formatação no padrão brasileiro. Todo valor e data mostrado na tela
// passa por aqui, para que o sistema inteiro fale a mesma língua.

export const FUSO = 'America/Sao_Paulo';

const fmtBRL = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' });
const fmtNum = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 2 });
const fmtData = new Intl.DateTimeFormat('pt-BR', {
  timeZone: FUSO, day: '2-digit', month: '2-digit', year: 'numeric',
});
const fmtDataHora = new Intl.DateTimeFormat('pt-BR', {
  timeZone: FUSO, day: '2-digit', month: '2-digit', year: 'numeric',
  hour: '2-digit', minute: '2-digit',
});
const fmtISO = new Intl.DateTimeFormat('en-CA', {
  timeZone: FUSO, year: 'numeric', month: '2-digit', day: '2-digit',
});

const SO_DATA = /^(\d{4})-(\d{2})-(\d{2})$/;

/** 1234.5 → "R$ 1.234,50" */
export function brl(valor) {
  const n = Number(valor);
  return fmtBRL.format(Number.isFinite(n) ? n : 0);
}

/** 1234.5 → "1.234,5" */
export function numero(valor) {
  const n = Number(valor);
  return fmtNum.format(Number.isFinite(n) ? n : 0);
}

/**
 * "2026-10-07" → "07/10/2026"
 * Datas sem hora são formatadas direto, sem passar por fuso,
 * para não virarem o dia anterior.
 */
export function dataBR(valor) {
  if (!valor) return '';
  if (typeof valor === 'string') {
    const m = valor.match(SO_DATA);
    if (m) return `${m[3]}/${m[2]}/${m[1]}`;
  }
  const d = valor instanceof Date ? valor : new Date(valor);
  return Number.isNaN(d.getTime()) ? '' : fmtData.format(d);
}

/** timestamp → "07/10/2026 08:20" no horário de São Paulo */
export function dataHoraBR(valor) {
  if (!valor) return '';
  const d = valor instanceof Date ? valor : new Date(valor);
  return Number.isNaN(d.getTime()) ? '' : fmtDataHora.format(d).replace(',', '');
}

/** Data de hoje em São Paulo, no formato do banco: "2026-10-07" */
export function hojeISO(agora = new Date()) {
  return fmtISO.format(agora);
}

/** Competência (mês) no formato do banco: "2026-10" */
export function competencia(dataISO = hojeISO()) {
  return String(dataISO).slice(0, 7);
}

/**
 * Converte o que a pessoa digitou em número.
 * Aceita "1.234,56", "R$ 1.234,56", "1234,5", "1234.56", "10".
 * Devolve NaN se não for um valor válido.
 */
export function lerValor(texto) {
  return lerDecimal(texto, 2);
}

/**
 * Como lerValor, mas com a quantidade de casas decimais escolhida.
 * Ex.: lerDecimal('0,95432', 5) → 0.95432
 * Um ponto seguido de 3 dígitos só é lido como milhar quando a parte
 * inteira não é zero ("1.000" → 1000; "0.954" → 0,954).
 */
export function lerDecimal(texto, casas = 2) {
  if (typeof texto === 'number') return arredN(texto, casas);
  let s = String(texto ?? '').replace(/R\$|%|\s/g, '').trim();
  if (!s) return NaN;
  const negativo = s.startsWith('-');
  if (negativo) s = s.slice(1);
  if (s.includes(',')) {
    s = s.replace(/\./g, '').replace(',', '.');
  } else if ((s.match(/\./g) || []).length > 1 || /^[1-9]\d{0,2}\.\d{3}$/.test(s)) {
    s = s.replace(/\./g, '');
  }
  if (!/^\d+(\.\d+)?$/.test(s)) return NaN;
  const n = arredN(Number(s), casas);
  return negativo ? -n : n;
}

/** Número para mostrar dentro de um campo: 0.95432 → "0,95432" */
export function paraCampo(valor, casasMin = 0, casasMax = casasMin) {
  if (valor === null || valor === undefined || valor === '') return '';
  const n = Number(valor);
  if (!Number.isFinite(n)) return '';
  return n.toLocaleString('pt-BR', {
    minimumFractionDigits: casasMin, maximumFractionDigits: casasMax, useGrouping: false,
  });
}

function arredN(n, casas) {
  const f = 10 ** casas;
  return Math.round((Number(n) + Number.EPSILON) * f) / f;
}

/** Arredonda para centavos sem erro de ponto flutuante. */
export function arred2(n) {
  return Math.round((Number(n) + Number.EPSILON) * 100) / 100;
}

/** Escapa texto antes de colocar em HTML. */
export function esc(texto) {
  return String(texto ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
