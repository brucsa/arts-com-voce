// Etapa 3 · Estoque de materiais (só Admin)
// Regras: R12, R40, R49 a R55.

import { supabase, configurado } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, dataBR, hojeISO } from '../format.js';
import { abrirFormulario } from '../ui/formulario.js';
import { abrirNovaCompra } from './compra.js';
import { oferecerGastoDosOutros } from './gastos.js';
import { CATEGORIA_MATERIAL, nomeMaterial, nomeMaterialHtml, quantidade, custoUnitario } from '../estoque-util.js';

export function telaEstoque(el) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">O estoque precisa do Supabase configurado.</p></section>';
    return;
  }
  carregar(el);
}

async function carregar(el) {
  const area = document.createElement('div');
  area.className = 'painel-area';
  area.innerHTML = '<p class="texto-secundario">Carregando…</p>';
  el.replaceChildren(area);
  try {
    await desenhar(area, () => carregar(el));
  } catch (e) {
    area.innerHTML = `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  }
}

async function desenhar(area, recarregar) {
  const sb = await supabase();
  const [estoque, iniciais] = await Promise.all([
    sb.from('vw_estoque').select('*').order('tipo').order('variacao').then(ok),
    sb.from('vw_lotes').select('*').eq('origem', 'ESTOQUE_INICIAL').eq('status', 'ATIVO')
      .order('data', { ascending: false }).order('created_at', { ascending: false }).then(ok),
  ]);

  const visiveis = estoque.filter(m => m.ativo || Number(m.quantidade) > 0);
  const valorTotal = estoque.reduce((t, m) => t + Number(m.valor), 0);
  const baixos = visiveis.filter(m => m.estoque_baixo);

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
      <button class="botao botao-primario" data-compra><i class="ti ti-shopping-cart-plus" aria-hidden="true"></i> Nova compra de estoque</button>
      <button class="botao" data-inicial><i class="ti ti-package-import" aria-hidden="true"></i> Estoque inicial</button>
    </div>
    <p class="aviso aviso-ok" role="status" hidden></p>

    ${Object.entries(CATEGORIA_MATERIAL).map(([cat, info]) => {
      const itens = visiveis.filter(m => m.categoria === cat);
      return `<section class="cartao">
        <h3>${info.plural}</h3>
        ${itens.length ? `<ul class="lista">${itens.map(m => `
          <li class="linha ${m.ativo ? '' : 'inativo'}">
            <div class="linha-texto">
              <strong>${nomeMaterialHtml(m)}
                ${m.estoque_baixo ? '<span class="selo-p selo-despesa">Estoque baixo</span>' : ''}
                ${m.ativo ? '' : '<span class="selo-p selo-inativo">Inativo</span>'}</strong>
              <span class="texto-secundario">Custo médio: ${custoUnitario(m.custo_medio, m.unidade)}</span>
              <span class="texto-secundario">${m.estoque_minimo !== null ? `Mínimo: ${quantidade(m.estoque_minimo, m.unidade)}` : 'Sem mínimo definido'} · Valor: ${brl(m.valor)}</span>
            </div>
            <span class="linha-valor ${m.estoque_baixo ? 'valor-alerta' : ''}">${quantidade(m.quantidade, m.unidade)}</span>
          </li>`).join('')}</ul>` : `<p class="texto-secundario vazio">${info.vazio}. Cadastre em Configurações → Materiais.</p>`}
      </section>`;
    }).join('')}

    <section class="cartao">
      <h3>Estoque inicial lançado</h3>
      <p class="texto-secundario">Materiais que a loja já tinha antes do sistema. Não movimentam o caixa.</p>
      ${iniciais.length ? `<ul class="lista">${iniciais.map(l => `
        <li class="linha">
          <div class="linha-texto">
            <strong>${nomeMaterialHtml(l)}${l.marca ? ` · ${esc(l.marca)}` : ''}</strong>
            <span class="texto-secundario">${dataBR(l.data)} · ${quantidade(l.quantidade, l.unidade)} por ${brl(l.custo_total)} · ${custoUnitario(l.custo_unitario, l.unidade)}${l.obs ? ` · ${esc(l.obs)}` : ''}</span>
          </div>
          <div class="linha-direita"><div class="linha-acoes">
            <button class="botao botao-pequeno" data-editar-lote="${l.id}">Editar</button>
            ${l.tem_consumo_posterior ? '' : `<button class="botao botao-pequeno botao-perigo" data-cancelar-lote="${l.id}">Cancelar</button>`}
          </div></div>
        </li>`).join('')}</ul>` : '<p class="texto-secundario vazio">Nenhum estoque inicial lançado.</p>'}
    </section>`;

  const avisar = texto => {
    const p = document.querySelector('.painel-area .aviso-ok');
    if (p) { p.textContent = texto; p.hidden = false; setTimeout(() => { p.hidden = true; }, 4000); }
  };

  area.querySelector('[data-compra]').addEventListener('click', () => {
    abrirNovaCompra({
      async aoConcluir(resultado, cab) {
        await recarregar();
        avisar('Compra registrada. O estoque já foi atualizado.');
        await oferecerGastoDosOutros(resultado, cab, async () => avisar('Compra e gasto dos outros itens registrados.'));
      },
    });
  });

  area.querySelector('[data-inicial]').addEventListener('click', () => {
    const ativos = estoque.filter(m => m.ativo);
    if (!ativos.length) { window.alert('Cadastre os materiais em Configurações → Materiais.'); return; }
    const MAT = Object.fromEntries(ativos.map(m => [m.material_id, m]));
    const un = v => MAT[v.material_id]?.unidade || '';
    abrirFormulario({
      titulo: 'Estoque inicial',
      textoSalvar: 'Lançar estoque inicial',
      valores: { data: hojeISO() },
      campos: [
        { nome: 'material_id', rotulo: 'Material', tipo: 'select', obrigatorio: true, recarrega: true,
          opcoes: [{ valor: '', rotulo: 'Escolha…' }, ...ativos.map(m => ({
            valor: m.material_id, rotulo: `${CATEGORIA_MATERIAL[m.categoria].rotulo} · ${nomeMaterial(m)} (${m.unidade})` }))] },
        { nome: 'quantidade', rotulo: v => `Quantidade disponível${un(v) ? ` (${un(v)})` : ''}`, tipo: 'decimal', casas: 3,
          obrigatorio: true, maiorQueZero: true, placeholder: v => (un(v) === 'g' ? '350' : '10'),
          dica: 'O que existe de verdade agora. Rolo aberto: os gramas que restam, não o peso do rolo cheio.' },
        { nome: 'custo_total', rotulo: 'Custo dessa quantidade (R$)', tipo: 'decimal', casas: 2, casasMin: 2,
          obrigatorio: true, maiorQueZero: true, placeholder: '0,00',
          dica: 'Proporcional ao que sobrou. Ex.: rolo de 1 kg que custou R$ 90,00 com 350 g restantes → R$ 31,50.' },
        { nome: 'data', rotulo: 'Data', tipo: 'data', obrigatorio: true, maxData: hojeISO() },
        { nome: 'marca', rotulo: 'Marca', tipo: 'texto' },
        { nome: 'obs', rotulo: 'Observação', tipo: 'texto', placeholder: 'Rolo aberto' },
      ],
      async aoSalvar(v) {
        await sb.rpc('registrar_estoque_inicial', {
          p_material_id: v.material_id, p_data: v.data, p_quantidade: v.quantidade,
          p_custo_total: v.custo_total, p_marca: v.marca, p_obs: v.obs,
        }).then(ok);
        await recarregar();
        avisar('Estoque inicial lançado. O caixa não foi alterado.');
      },
    });
  });

  area.addEventListener('click', e => {
    const be = e.target.closest('[data-editar-lote]');
    const bc = e.target.closest('[data-cancelar-lote]');
    if (be) {
      const l = iniciais.find(x => x.id === be.dataset.editarLote);
      abrirFormulario({
        titulo: `Editar: ${nomeMaterial(l)}`,
        valores: { marca: l.marca, obs: l.obs },
        campos: [
          { nome: 'marca', rotulo: 'Marca', tipo: 'texto' },
          { nome: 'obs', rotulo: 'Observação', tipo: 'texto',
            dica: 'Quantidade e custo não mudam depois de lançados. Para corrigir, cancele e lance de novo.' },
        ],
        async aoSalvar(v) {
          await sb.rpc('editar_lote', { p_lote_id: l.id, p_marca: v.marca, p_obs: v.obs }).then(ok);
          await recarregar();
          avisar('Lançamento atualizado.');
        },
      });
    }
    if (bc) {
      const l = iniciais.find(x => x.id === bc.dataset.cancelarLote);
      abrirFormulario({
        titulo: `Cancelar estoque inicial: ${nomeMaterial(l)}`,
        textoSalvar: 'Cancelar lançamento',
        valores: {},
        campos: [
          { nome: 'motivo', rotulo: 'Motivo', tipo: 'texto', obrigatorio: true, placeholder: 'Quantidade errada',
            dica: `${quantidade(l.quantidade, l.unidade)} saem do estoque. O lançamento continua no histórico.` },
        ],
        async aoSalvar(v) {
          await sb.rpc('cancelar_estoque_inicial', { p_lote_id: l.id, p_motivo: v.motivo }).then(ok);
          await recarregar();
          avisar('Estoque inicial cancelado.');
        },
      });
    }
  });
}
