// Nomes e regras de apresentação usados nas telas de dinheiro.
import { hojeISO } from './format.js';

// R47
export const FORMAS = [
  { valor: 'PIX', rotulo: 'Pix', imediato: true },
  { valor: 'DINHEIRO', rotulo: 'Dinheiro', imediato: true },
  { valor: 'CARTAO_CREDITO', rotulo: 'Cartão de crédito', imediato: false },
  { valor: 'CARTAO_DEBITO', rotulo: 'Cartão de débito', imediato: true },
  { valor: 'BOLETO', rotulo: 'Boleto', imediato: true },
  { valor: 'TRANSFERENCIA', rotulo: 'Transferência', imediato: true },
  { valor: 'OUTROS', rotulo: 'Outros', imediato: true },
];
export const ROTULO_FORMA = Object.fromEntries(FORMAS.map(f => [f.valor, f.rotulo]));
export const pagoNaHora = forma => FORMAS.find(f => f.valor === forma)?.imediato ?? true;

export const SITUACAO = {
  PAGO: { rotulo: 'Pago', classe: 'selo-ativo' },
  A_PAGAR: { rotulo: 'A pagar', classe: 'selo-despesa' },
  PAGO_EM_PARTE: { rotulo: 'Pago em parte', classe: 'selo-despesa' },
  CANCELADO: { rotulo: 'Cancelado', classe: 'selo-inativo' },
};

export const ORIGEM = {
  PAGAMENTO_GASTO: 'Pagamento de gasto',
  APORTE: 'Aporte',
  RETIRADA: 'Retirada',
  ESTORNO: 'Estorno',
};

/** "2026-10" → { inicio: '2026-10-01', fim: '2026-10-31' } */
export function intervaloMes(mes) {
  const [a, m] = mes.split('-').map(Number);
  const fim = new Date(Date.UTC(a, m, 0)).getUTCDate();
  return { inicio: `${mes}-01`, fim: `${mes}-${String(fim).padStart(2, '0')}` };
}

export const mesAtual = () => hojeISO().slice(0, 7);

const fmtMes = new Intl.DateTimeFormat('pt-BR', { month: 'long', year: 'numeric', timeZone: 'UTC' });
/** "2026-10" → "outubro de 2026" */
export const nomeMes = mes => fmtMes.format(new Date(`${mes}-15T12:00:00Z`));
