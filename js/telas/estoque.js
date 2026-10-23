// Etapa 3 · Estoque (só Admin). Simplificado em 23/10/2026, a pedido da Bruna:
// uma tela só com os materiais (saldo, custo médio, mínimo), o cadastro e o ajuste
// juntos, e o botão "Entrada de material" (com a opção "Lançar no caixa").
// As compras aparecem no extrato do Caixa, onde são editadas ou canceladas.
// Regras: R12, R40, R41, R49 a R55; ajuste de inventário R99 (sql/16), por ajustar_estoque.
// Nenhuma regra do banco muda: a tela chama as mesmas funções de antes.

import { supabase, configurado } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, hojeISO } from '../format.js';
import { abrirFormulario } from '../ui/formulario.js';
import { abrirNovaCompra } from './compra.js';
import { oferecerGastoDosOutros } from './gastos.js';
import { novaChave } from './producao.js';
import { CATEGORIA_MATERIAL, nomeMaterial, nomeMaterialHtml, quantidade, custoUnitario } from '../estoque-util.js';

// Cadastro de material (mesmas regras de antes em Configurações, R12, R41, R55).
const CATEGORIAS_MATERIAL = [
  { valor: 'FILAMENTO', rotulo: 'Filamento', tipo: 'Tipo', tipoEx: 'PLA', variacao: 'Cor', variacaoEx: 'Branco' },
  { valor: 'EMBALAGEM', rotulo: 'Embalagem', tipo: 'Tipo', tipoEx: 'Caixa', variacao: 'Descrição ou tamanho', variacaoEx: '15 x 10 x 5 cm' },
  { valor: 'INSUMO', rotulo: 'Insumo', tipo: 'Item', tipoEx: 'Ímã', variacao: 'Especificação', variacaoEx: '10 mm' },
];
const CAT = Object.fromEntries(CATEGORIAS_MATERIAL.map(c => [c.valor, c]));
const UNIDADES = [
  { valor: 'un', rotulo: 'Unidade (un)' },
  { valor: 'g', rotulo: 'Grama (g)' },
  { valor: 'kg', rotulo: 'Quilo (kg)' },
  { valor: 'ml', rotulo: 'Mililitro (ml)' },
  { valor: 'l', rotulo: 'Litro (l)' },
  { valor: 'cm', rotulo: 'Centímetro (cm)' },
  { valor: 'm', rotulo: 'Metro (m)' },
];

export function telaEstoque(el) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">O estoque precisa do Supabase configurado.</p></section>';
    return;
  }
  carregar(el);
}

async function carregar(el) {
  // Contêiner novo a cada abertura, para os eventos não se acumularem.
  const area = document.createElement('div');
  area.className = 'painel-area';
  area.innerHTML = '<p class="texto-secundario">Carregando…</p>';
  el.replaceChildren(area);
  try {
    await materiais(area, () => carregar(el));
  } catch (e) {
    area.innerHTML = `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  }
}

// O aviso fica no painel atual (a área é trocada a cada recarga).
const avisar = texto => {
  const p = document.querySelector('.painel-area .aviso-ok');
  if (p) { p.textContent = texto; p.hidden = false; setTimeout(() => { p.hidden = true; }, 4000); }
};

// ------------------------------------------------------------- Materiais

async function materiais(area, recarregar) {
  const sb = await supabase();
  const [estoque, cadastro] = await Promise.all([
    sb.from('vw_estoque').select('*').order('tipo').order('variacao').then(ok),
    sb.from('materiais').select('*').order('tipo').order('variacao').then(ok),
  ]);
  const CADASTRO = Object.fromEntries(cadastro.map(m => [m.id, m]));

  // Ajuste de inventário (R99): só depois da instalação da produção (sql/16).
  const comAjuste = !(await sb.from('ajustes_estoque').select('id').limit(1)).error;
  const ativosPrimeiro = (a, b) => Number(b.ativo) - Number(a.ativo);
  const valorTotal = estoque.reduce((t, m) => t + Number(m.valor), 0);
  const baixos = estoque.filter(m => m.ativo && m.estoque_baixo);

  area.innerHTML = `
    <div class="grade-metricas">
      <div class="metrica metrica-caixa">
        <p class="metrica-rotulo"><i class="ti ti-stack-2" aria-hidden="true"></i> Valor em estoque</p>
        <p class="metrica-valor">${brl(valorTotal)}</p>
        <p class="metrica-nota">Pelo custo médio de cada material.</p>
      </div>
      <div class="metrica ${baixos.length ? 'metrica-espera' : 'metrica-neutra'}">
        <p class="metrica-rotulo"><i class="ti ti-alert-triangle" aria-hidden="true"></i> Estoque baixo</p>
        <p class="metrica-valor">${baixos.length}</p>
        <p class="metrica-nota">${baixos.length ? esc(baixos.map(nomeMaterial).join(', ')) : 'Nenhum material abaixo do mínimo.'}</p>
      </div>
    </div>

    <div class="acoes-caixa">
      <button class="botao botao-primario" data-entrada><i class="ti ti-package-import" aria-hidden="true"></i> Entrada de material</button>
      <button class="botao" data-novo-material><i class="ti ti-plus" aria-hidden="true"></i> Novo material</button>
    </div>
    <p class="aviso aviso-ok" role="status" hidden></p>

    ${Object.entries(CATEGORIA_MATERIAL).map(([cat, info]) => {
      const itens = estoque.filter(m => m.categoria === cat).sort(ativosPrimeiro);
      return `<section class="cartao">
        <h3>${info.plural}</h3>
        ${itens.length ? `<ul class="lista">${itens.map(m => `
          <li class="linha ${m.ativo ? '' : 'inativo'}">
            <div class="linha-texto">
              <strong>${nomeMaterialHtml(m)}
                ${m.ativo && m.estoque_baixo ? '<span class="selo-p selo-despesa">Estoque baixo</span>' : ''}
                ${m.ativo ? '' : '<span class="selo-p selo-inativo">Inativo</span>'}</strong>
              <span class="texto-secundario">Custo médio: ${custoUnitario(m.custo_medio, m.unidade)} · Valor: ${brl(m.valor)}</span>
              <span class="texto-secundario">${m.estoque_minimo !== null ? `Mínimo: ${quantidade(m.estoque_minimo, m.unidade)}` : 'Sem mínimo definido'}</span>
            </div>
            <div class="linha-direita">
              <span class="linha-valor ${m.ativo && m.estoque_baixo ? 'valor-alerta' : ''}">${quantidade(m.quantidade, m.unidade)}</span>
              <div class="linha-acoes">
                ${comAjuste && m.ativo ? `<button class="botao botao-pequeno" data-ajustar="${m.material_id}">Ajustar</button>` : ''}
                <button class="botao botao-pequeno" data-editar-material="${m.material_id}">Editar</button>
              </div>
            </div>
          </li>`).join('')}</ul>` : `<p class="texto-secundario vazio">${info.vazio}. Use "Novo material".</p>`}
      </section>`;
    }).join('')}`;


  // Categoria e unidade travam no primeiro movimento de estoque (R41, R55).
  const comMovimento = new Set(estoque.filter(x => x.tem_movimento).map(x => x.material_id));
  const formMaterial = m => abrirFormulario({
    titulo: m ? `Editar · ${nomeMaterial(m)}` : 'Novo material',
    valores: m ? { ...m } : { categoria: 'FILAMENTO', unidade: 'g', ativo: true },
    campos: [
      { nome: 'categoria', rotulo: 'Categoria', tipo: 'select', obrigatorio: true, recarrega: true,
        opcoes: CATEGORIAS_MATERIAL.map(c => ({ valor: c.valor, rotulo: c.rotulo })),
        // Saindo de filamento (sempre em g), embalagens e insumos começam em unidades.
        aoMudar: (v, anterior) => { if (anterior === 'FILAMENTO' && v.categoria !== 'FILAMENTO') v.unidade = 'un'; },
        fixo: () => (m && comMovimento.has(m.id) ? m.categoria : undefined),
        dica: () => (m && comMovimento.has(m.id) ? 'Travada: este material já tem movimento de estoque.' : undefined) },
      { nome: 'tipo', rotulo: v => CAT[v.categoria].tipo, tipo: 'texto', obrigatorio: true,
        placeholder: v => CAT[v.categoria].tipoEx },
      { nome: 'variacao', rotulo: v => CAT[v.categoria].variacao, tipo: 'texto',
        placeholder: v => CAT[v.categoria].variacaoEx },
      { nome: 'unidade', rotulo: 'Unidade de medida', tipo: 'select', obrigatorio: true, recarrega: true,
        opcoes: UNIDADES,
        fixo: v => (m && comMovimento.has(m.id) ? m.unidade : (v.categoria === 'FILAMENTO' ? 'g' : undefined)),
        dica: v => (m && comMovimento.has(m.id) ? 'Travada: este material já tem movimento de estoque.'
          : (v.categoria === 'FILAMENTO' ? 'Filamento é sempre controlado em gramas.' : 'Unidade usada no estoque e na ficha técnica deste material.')) },
      { nome: 'estoque_minimo', rotulo: v => `Avisar quando o estoque ficar abaixo de (${v.categoria === 'FILAMENTO' ? 'g' : (v.unidade || 'un')})`,
        tipo: 'decimal', casas: 3, min: 0, mensagemFaixa: 'Use zero ou um valor positivo.', placeholder: '200' },
      ...(m ? [{ nome: 'ativo', rotulo: 'Ativo', tipo: 'checkbox', dica: 'Inativo some das listas de escolha, mas continua no histórico.' }] : []),
    ],
    async aoSalvar(v) {
      // A cor é obrigatória para filamento (custo médio por tipo e cor, R12).
      if (v.categoria === 'FILAMENTO' && !v.variacao) throw new Error('Informe a cor do filamento.');
      if (v.categoria === 'FILAMENTO') v.unidade = 'g';
      if (m) await sb.from('materiais').update(v).eq('id', m.id).select().single().then(ok);
      else await sb.from('materiais').insert(v).select().single().then(ok);
      await recarregar();
    },
    aoExcluir: m ? async () => { await sb.from('materiais').delete().eq('id', m.id).then(ok); await recarregar(); } : null,
  });

  area.querySelector('[data-novo-material]').addEventListener('click', () => formMaterial(null));

  area.querySelector('[data-entrada]').addEventListener('click', () => {
    abrirNovaCompra({
      async aoConcluir(resultado, cab) {
        await recarregar();
        if (cab.semCaixa) { avisar('Material lançado no estoque. O caixa não mudou.'); return; }
        avisar(cab.pago ? 'Compra registrada e paga: saiu do caixa e entrou no estoque.'
          : 'Compra registrada como A pagar (veja no Caixa). O material já entrou no estoque.');
        await oferecerGastoDosOutros(resultado, cab, async () => avisar('Gasto dos outros itens registrado no Caixa.'));
      },
    });
  });

  area.addEventListener('click', e => {
    const be = e.target.closest('[data-editar-material]');
    if (be) { formMaterial(CADASTRO[be.dataset.editarMaterial]); return; }
    const b = e.target.closest('[data-ajustar]');
    if (!b) return;
    const m = estoque.find(x => x.material_id === b.dataset.ajustar);
    const chave = novaChave();
    abrirFormulario({
      titulo: `Ajustar estoque · ${nomeMaterial(m)}`,
      textoSalvar: 'Ajustar',
      valores: { data: hojeISO() },
      campos: [
        { nome: 'contada', rotulo: `Quantidade real, depois de pesar ou contar (${m.unidade})`, tipo: 'decimal', casas: 3, obrigatorio: true, min: 0,
          dica: `No sistema: ${quantidade(m.quantidade, m.unidade)}. Sobra entra pelo custo médio; falta sai como perda.` },
        { nome: 'motivo', rotulo: 'Motivo', tipo: 'texto', obrigatorio: true, placeholder: 'Ex.: pesei o rolo' },
        { nome: 'data', rotulo: 'Data', tipo: 'data', obrigatorio: true, maxData: hojeISO() },
      ],
      async aoSalvar(v) {
        if (v.contada === Number(m.quantidade)) throw new Error('O saldo já é esse. Nada a ajustar.');
        const r = await sb.rpc('ajustar_estoque', { p_material_id: m.material_id, p_quantidade_contada: v.contada,
          p_motivo: v.motivo, p_data: v.data, p_chave: chave }).then(ok);
        await recarregar();
        avisar(Number(r.diferenca) > 0
          ? `Ajuste registrado: entraram ${quantidade(r.diferenca, m.unidade)} (${brl(r.valor)}).`
          : `Ajuste registrado: saíram ${quantidade(-r.diferenca, m.unidade)} como perda (${brl(r.valor)}).`);
      },
    });
  });
}
