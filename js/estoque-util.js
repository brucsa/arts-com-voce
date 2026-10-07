// Apresentação de materiais, quantidades e custos do estoque.
import { esc } from './format.js';

export const CATEGORIA_MATERIAL = {
  FILAMENTO: { rotulo: 'Filamento', plural: 'Filamentos', vazio: 'Nenhum filamento cadastrado' },
  EMBALAGEM: { rotulo: 'Embalagem', plural: 'Embalagens', vazio: 'Nenhuma embalagem cadastrada' },
  INSUMO: { rotulo: 'Insumo', plural: 'Insumos', vazio: 'Nenhum insumo cadastrado' },
};

const fmtQtd = new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 3 });
const fmtCusto = (casas) => new Intl.NumberFormat('pt-BR', {
  style: 'currency', currency: 'BRL', minimumFractionDigits: 2, maximumFractionDigits: casas,
});

export const nomeMaterial = m => `${m.tipo}${m.variacao ? ` ${m.variacao}` : ''}`;
export const nomeMaterialHtml = m => `${esc(m.tipo)}${m.variacao ? ` · ${esc(m.variacao)}` : ''}`;

/** 1850 + 'g' → "1.850 g" */
export const quantidade = (q, unidade) => `${fmtQtd.format(Number(q) || 0)} ${unidade}`;

/** Custo médio por unidade; para gramas mostra também por kg. */
export function custoUnitario(custo, unidade) {
  if (custo === null || custo === undefined) return '—';
  const c = Number(custo);
  if (unidade === 'g') return `${fmtCusto(4).format(c)}/g · ${fmtCusto(2).format(c * 1000)}/kg`;
  return `${fmtCusto(4).format(c)}/${unidade}`;
}

/** Rateio igual ao do banco (R50, R51): proporcional ao valor, último item fica com o arredondamento. */
export function ratear({ itens, frete = 0, desconto = 0, outros = 0 }) {
  const r2 = n => Math.round((n + Number.EPSILON) * 100) / 100;
  const soma = itens.reduce((t, i) => t + (i.valor || 0), 0);
  const base = soma + outros;
  if (soma <= 0) {
    return { soma: 0, freteCompra: 0, descontoCompra: 0, totalCompra: 0, itens: itens.map(() => ({ frete: 0, desconto: 0, custo: 0 })),
             freteOutros: r2(frete), descontoOutros: r2(desconto), outrosFinal: r2(outros + frete - desconto) };
  }
  const freteCompra = r2(frete * soma / base);
  const descontoCompra = r2(desconto * soma / base);
  let fa = 0; let da = 0;
  const porItem = itens.map((it, i) => {
    let fr; let ds;
    if (i < itens.length - 1) { fr = r2(freteCompra * it.valor / soma); ds = r2(descontoCompra * it.valor / soma); }
    else { fr = r2(freteCompra - fa); ds = r2(descontoCompra - da); }
    fa = r2(fa + fr); da = r2(da + ds);
    return { frete: fr, desconto: ds, custo: r2(it.valor + fr - ds) };
  });
  return {
    soma: r2(soma), freteCompra, descontoCompra, totalCompra: r2(soma + freteCompra - descontoCompra), itens: porItem,
    freteOutros: r2(frete - freteCompra), descontoOutros: r2(desconto - descontoCompra),
    outrosFinal: r2(outros + (frete - freteCompra) - (desconto - descontoCompra)),
  };
}
