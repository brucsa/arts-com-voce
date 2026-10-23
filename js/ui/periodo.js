// Filtro de período do Início e dos Relatórios (R122, R129):
// Hoje, Semana (de segunda até hoje), Mês (do dia 1 até hoje) e Período (de/até).

import { hojeISO } from '../format.js';

export const PERIODOS = [
  { id: 'hoje', titulo: 'Hoje' },
  { id: 'semana', titulo: 'Semana' },
  { id: 'mes', titulo: 'Mês' },
  { id: 'periodo', titulo: 'Período' },
];

const somarDias = (iso, n) => { const d = new Date(`${iso}T12:00:00`); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };

/** Datas do período escolhido em `filtro` ({ periodo, de, ate }). */
export function intervalo(filtro) {
  const hoje = hojeISO();
  if (filtro.periodo === 'hoje') return { inicio: hoje, fim: hoje };
  if (filtro.periodo === 'semana') {
    const dia = new Date(`${hoje}T12:00:00`).getDay();          // 0 = domingo
    return { inicio: somarDias(hoje, -((dia + 6) % 7)), fim: hoje };
  }
  if (filtro.periodo === 'periodo') {
    return { inicio: filtro.de || `${hoje.slice(0, 7)}-01`, fim: filtro.ate || hoje };
  }
  return { inicio: `${hoje.slice(0, 7)}-01`, fim: hoje };
}

/** Botões do período e os campos De/Até. */
export function htmlFiltroPeriodo(filtro) {
  return `<div class="filtro-periodo">
    <div class="abas abas-periodo" role="group" aria-label="Período">
      ${PERIODOS.map(p => `<button type="button" class="aba" data-periodo="${p.id}" aria-pressed="${filtro.periodo === p.id}">${p.titulo}</button>`).join('')}
    </div>
    <div class="periodo-datas" data-datas ${filtro.periodo === 'periodo' ? '' : 'hidden'}>
      <label class="campo campo-compacto"><span>De</span><input type="date" name="de" max="${hojeISO()}"></label>
      <label class="campo campo-compacto"><span>Até</span><input type="date" name="ate" max="${hojeISO()}"></label>
    </div>
  </div>`;
}

/** Liga os botões e as datas; chama aoMudar() a cada mudança. */
export function ligarFiltroPeriodo(el, filtro, aoMudar) {
  const datas = el.querySelector('[data-datas]');
  const preencher = () => {
    const { inicio, fim } = intervalo(filtro);
    datas.querySelector('[name=de]').value = inicio;
    datas.querySelector('[name=ate]').value = fim;
  };
  preencher();
  el.querySelector('.abas-periodo').addEventListener('click', e => {
    const b = e.target.closest('[data-periodo]');
    if (!b) return;
    filtro.periodo = b.dataset.periodo;
    el.querySelectorAll('[data-periodo]').forEach(x => x.setAttribute('aria-pressed', String(x === b)));
    datas.hidden = filtro.periodo !== 'periodo';
    if (filtro.periodo === 'periodo') preencher();
    aoMudar();
  });
  datas.addEventListener('change', e => {
    if (e.target.name === 'de') filtro.de = e.target.value || null;
    if (e.target.name === 'ate') filtro.ate = e.target.value || null;
    aoMudar();
  });
}
