// Etapa 4 · Catálogo Essencial de Produtos (só Admin)
// Regras: R71–R75 (especificação v1.3).
// Grava só pelas funções salvar_produto, definir_produto_ativo e excluir_produto.
// Catálogo público (R85–R88): as marcações são gravadas por definir_produto_catalogo.
// Ficha de consumo (R93): partes e outros materiais, gravados por salvar_ficha_produto.
// Fotos: pasta privada "produtos" do Storage, vistas por links temporários.
// Até 5 fotos por produto (sql/20, R73 v1.12): a primeira é a capa
// (produtos.foto_path) e as outras ficam em produto_fotos. Antes do sql/20,
// uma foto só, como sempre.
// Variações (sql/22, R112–R116): opções e combinações com preço próprio e
// ficha opcional por combinação. Antes do sql/22, sem variações.

import { supabase, configurado } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, lerDecimal, paraCampo, dinheiroCampo } from '../format.js';
import { cliqueForaDoDialogo } from '../ui/dialogo.js';
import { recortarQuadrado } from '../ui/recorte.js';
import { carregarVariacoes, precoVariacoes, htmlCombinacoesDetalhe, montarEditorVariacoes, abrirFichaVariacao } from './variacoes.js';

const PASTA = 'produtos';
const filtro = { busca: '', situacao: 'ativos' };

// ---------------------------------------------------------------- utilidades

/** 135 → "2h15min"; 120 → "2h"; 45 → "45min" */
export function tempoTexto(min) {
  const n = Number(min);
  if (!n) return '';
  const h = Math.floor(n / 60), m = n % 60;
  return `${h ? `${h}h` : ''}${m ? `${String(m).padStart(h ? 2 : 1, '0')}min` : ''}`;
}

const normal = s => String(s || '').trim().toLocaleLowerCase('pt-BR')
  .normalize('NFD').replace(/[̀-ͯ]/g, '');

const corTexto = c => `${c.tipo} · ${c.cor}`;

const gramas = v => `${paraCampo(v, 0, 2)} g`;
const nomeMaterial = m => (m ? `${m.tipo}${m.variacao ? ` · ${m.variacao}` : ''}` : 'Material');
const plural = (n, um, varios) => `${n} ${n === 1 ? um : varios}`;

/**
 * Ficha de consumo (R93). Antes do sql/14 as tabelas não existem: devolve
 * null e as telas continuam funcionando, só sem a ficha.
 */
async function carregarFichas(sb, produtos) {
  const [partes, outros] = await Promise.all([
    sb.from('produto_partes').select('produto_id, ordem, nome, gramas, purga_g').order('ordem'),
    sb.from('produto_materiais').select('produto_id, material_id, quantidade'),
  ]);
  if (partes.error || outros.error) {
    produtos.forEach(p => Object.assign(p, { partes: [], outros: [] }));
    return null;
  }
  const materiais = await sb.from('materiais').select('id, categoria, tipo, variacao, unidade, ativo')
    .in('categoria', ['INSUMO', 'EMBALAGEM']).order('tipo').order('variacao').then(ok);
  produtos.forEach(p => {
    p.partes = partes.data.filter(x => x.produto_id === p.id);
    p.outros = outros.data.filter(x => x.produto_id === p.id)
      .map(x => ({ ...x, material: materiais.find(m => m.id === x.material_id) }));
  });
  return { materiais };
}

/** Ficha no detalhe do produto: partes, total por peça e outros materiais. */
function htmlFicha(p) {
  if (!p.partes.length && !p.outros.length) return '';
  const peca = p.partes.reduce((t, x) => t + Number(x.gramas), 0);
  const purga = p.partes.reduce((t, x) => t + Number(x.purga_g), 0);
  return `<p class="detalhe-titulo">Ficha de consumo <span class="texto-secundario">(por peça)</span></p>
    <ul class="lista-ficha">
      ${p.partes.map(x => `<li><span>${esc(x.nome)}</span><strong>${gramas(x.gramas)}${Number(x.purga_g) ? ` + ${gramas(x.purga_g)} de purga` : ''}</strong></li>`).join('')}
      ${p.partes.length > 1 ? `<li class="ficha-total-linha"><span>Total de filamento</span><strong>${gramas(peca + purga)}</strong></li>` : ''}
      ${p.outros.map(x => `<li><span>${esc(nomeMaterial(x.material))}</span><strong>${paraCampo(x.quantidade, 0, 3)} ${esc(x.material?.unidade || '')}</strong></li>`).join('')}
    </ul>`;
}

function dimensoesTexto(p) {
  const v = [p.altura_cm, p.largura_cm, p.profundidade_cm];
  if (v.every(x => x == null)) return '';
  return `${v.map(x => (x == null ? '—' : paraCampo(x, 0, 2))).join(' × ')} cm`;
}

function novoId() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// ---------------------------------------------------------------- otimização da foto (R73)
// Tudo no navegador, sem biblioteca e sem servidor:
//   1. foto JPEG/WebP já pequena (até 1.200 px e 300 KB) e sem metadados é enviada como está;
//   2. senão, é redesenhada com a orientação correta, no máximo 1.200 px, mantendo a proporção;
//   3. a qualidade desce aos poucos até ficar perto de 300 KB, sem passar do piso de qualidade;
//      se ainda assim passar, o lado maior diminui um pouco (até 900 px);
//   4. WebP de preferência; JPEG quando o navegador não gera WebP;
//   5. 2 MB continua como limite final de proteção.
// Redesenhar também remove os metadados da foto original (como localização do celular).
export const FOTO = { LADO_MAX: 1200, LADO_MIN: 900, ALVO: 300 * 1024, MAXIMO: 2 * 1024 * 1024 };
const QUALIDADES = [0.86, 0.8, 0.74, 0.68, 0.62];

/** Lê o começo do arquivo para saber se tem metadados (EXIF/XMP) — nesse caso, sempre redesenha. */
async function temMetadados(arquivo) {
  const b = new Uint8Array(await arquivo.slice(0, Math.min(arquivo.size, 256 * 1024)).arrayBuffer());
  if (arquivo.type === 'image/jpeg') {
    // Procura segmentos APP1 (EXIF/XMP) antes do início da imagem.
    for (let i = 2; i + 4 < b.length;) {
      if (b[i] !== 0xff) break;
      const marca = b[i + 1];
      if (marca === 0xda) break;                // início dos dados da imagem
      if (marca === 0xe1) return true;          // APP1 = EXIF ou XMP
      i += 2 + ((b[i + 2] << 8) | b[i + 3]);
    }
    return false;
  }
  if (arquivo.type === 'image/webp') {
    const txt = new TextDecoder('latin1').decode(b);
    return txt.includes('EXIF') || txt.includes('XMP ');
  }
  return true;
}

async function abrirImagem(arquivo) {
  try {
    return await createImageBitmap(arquivo, { imageOrientation: 'from-image' });
  } catch { /* alguns navegadores não aceitam a opção: tenta pelo elemento <img> */ }
  const url = URL.createObjectURL(arquivo);
  try {
    const img = new Image();
    img.decoding = 'async';
    img.src = url;
    await img.decode();                          // <img> já aplica a orientação da foto
    return img;
  } catch {
    throw new Error('Não foi possível abrir esta foto. Use uma imagem JPEG, PNG ou WebP (fotos HEIC do iPhone podem não abrir em alguns navegadores).');
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 0);
  }
}

const larguraDe = im => im.naturalWidth || im.width;
const alturaDe = im => im.naturalHeight || im.height;

/** Prepara a foto para envio. Devolve { blob, ext, tipo, largura, altura, original, otimizada }. */
export async function otimizarFoto(arquivo) {
  const imagem = await abrirImagem(arquivo);
  const w0 = larguraDe(imagem), h0 = alturaDe(imagem);

  // Já otimizada: não processa de novo.
  if (['image/jpeg', 'image/webp'].includes(arquivo.type) && arquivo.size <= FOTO.ALVO
      && Math.max(w0, h0) <= FOTO.LADO_MAX && !(await temMetadados(arquivo))) {
    imagem.close?.();
    return { blob: arquivo, ext: arquivo.type === 'image/webp' ? 'webp' : 'jpg', tipo: arquivo.type,
             largura: w0, altura: h0, original: arquivo.size, otimizada: false };
  }

  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  const gerar = (tipo, q) => new Promise(r => canvas.toBlob(r, tipo, q));
  const desenhar = lado => {
    const escala = Math.min(1, lado / Math.max(w0, h0));
    canvas.width = Math.max(1, Math.round(w0 * escala));
    canvas.height = Math.max(1, Math.round(h0 * escala));
    ctx.fillStyle = '#fff';                      // fundo branco para PNG com transparência
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(imagem, 0, 0, canvas.width, canvas.height);
  };

  // O navegador gera WebP? (Senão, JPEG.)
  desenhar(FOTO.LADO_MAX);
  const teste = await gerar('image/webp', QUALIDADES[0]);
  const tipo = teste && teste.type === 'image/webp' ? 'image/webp' : 'image/jpeg';

  let melhor = null;
  for (let lado = FOTO.LADO_MAX; ; lado = Math.max(FOTO.LADO_MIN, Math.round(lado * 0.85))) {
    desenhar(lado);
    for (const q of QUALIDADES) {
      const blob = (tipo === 'image/webp' && lado === FOTO.LADO_MAX && q === QUALIDADES[0]) ? teste : await gerar(tipo, q);
      if (!blob) continue;
      if (!melhor || blob.size < melhor.blob.size) melhor = { blob, largura: canvas.width, altura: canvas.height };
      if (blob.size <= FOTO.ALVO) { melhor = { blob, largura: canvas.width, altura: canvas.height }; break; }
    }
    if (melhor.blob.size <= FOTO.ALVO || lado === FOTO.LADO_MIN || Math.max(w0, h0) <= FOTO.LADO_MIN) break;
  }
  imagem.close?.();
  if (!melhor) throw new Error('Não foi possível preparar a foto. Tente outra imagem.');
  if (melhor.blob.size > FOTO.MAXIMO) throw new Error('A foto continua maior que 2 MB depois de reduzida. Tente outra imagem.');
  return { blob: melhor.blob, ext: tipo === 'image/webp' ? 'webp' : 'jpg', tipo,
           largura: melhor.largura, altura: melhor.altura, original: arquivo.size, otimizada: true };
}

async function linksDasFotos(sb, produtos) {
  const caminhos = produtos.flatMap(p => [p.foto_path, ...(p.fotos_extra || [])]).filter(Boolean);
  if (!caminhos.length) return {};
  const { data, error } = await sb.storage.from(PASTA).createSignedUrls(caminhos, 3600);
  if (error) return {};
  return Object.fromEntries((data || []).filter(d => d.signedUrl).map(d => [d.path, d.signedUrl]));
}

// Apaga uma ou mais fotos que deixaram de ser usadas. Se falhar, elas ficam
// como "foto sem produto" na verificação e podem ser apagadas pelo painel do Storage.
async function apagarFoto(sb, caminho) {
  const lista = (Array.isArray(caminho) ? caminho : [caminho]).filter(Boolean);
  if (!lista.length) return;
  try { await sb.storage.from(PASTA).remove(lista); } catch { /* fica para limpeza manual */ }
}

const MAX_FOTOS = 5;
const todasAsFotos = p => [p?.foto_path, ...(p?.fotos_extra || [])].filter(Boolean);

// ---------------------------------------------------------------- tela

export function telaProdutos(el) {
  if (!configurado) {
    el.innerHTML = '<section class="cartao"><p class="texto-secundario">Os produtos precisam do Supabase configurado.</p></section>';
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
    area.innerHTML = `<p class="aviso aviso-erro" role="alert">${esc(e.message)}</p>`;
  }
}

async function desenhar(area, recarregar, mensagem) {
  const sb = await supabase();
  const [produtos, filamentos] = await Promise.all([
    sb.from('vw_produtos').select('*').order('nome').then(ok),
    sb.from('materiais').select('id, tipo, variacao, ativo').eq('categoria', 'FILAMENTO')
      .order('tipo').order('variacao').then(ok),
  ]);
  // Fotos a mais (sql/20). Antes de instalar, a tabela não existe: uma foto só.
  const extras = await sb.from('produto_fotos').select('produto_id, ordem, foto_path').order('ordem')
    .then(({ data, error }) => (error ? null : data || []));
  produtos.forEach(p => { p.fotos_extra = (extras || []).filter(f => f.produto_id === p.id).map(f => f.foto_path); });
  // Descrição interna (sql/21). Antes de instalar, a coluna não existe: só a descrição do cliente.
  const internas = await sb.from('produtos').select('id, descricao_interna')
    .then(({ data, error }) => (error ? null : Object.fromEntries((data || []).map(x => [x.id, x.descricao_interna]))));
  produtos.forEach(p => { p.descricao_interna = internas ? internas[p.id] || null : null; });
  const fotos = await linksDasFotos(sb, produtos);
  // Marcações do catálogo público (R86). Antes do sql/11 as colunas não
  // existem: a tela continua funcionando, só sem as marcações.
  const marcas = await sb.from('produtos').select('id, no_catalogo, personalizado')
    .then(({ data, error }) => (error ? null : Object.fromEntries((data || []).map(m => [m.id, m]))));
  if (marcas) produtos.forEach(p => Object.assign(p, { no_catalogo: false, personalizado: false }, marcas[p.id] || {}));
  const ficha = await carregarFichas(sb, produtos);
  const variacoes = await carregarVariacoes(sb, produtos);
  // Combinações no catálogo público (sql/23)? Antes de instalar, a função não existe.
  const catVar = variacoes && marcas ? !(await sb.rpc('catalogo_variacoes')).error : false;
  const contexto = { sb, produtos, filamentos, fotos, recarregar, catalogo: !!marcas, ficha, galeria: !!extras, interna: !!internas, variacoes, catVar };

  area.innerHTML = `
    <section class="cartao filtros filtros-produtos">
      <label class="campo campo-compacto"><span>Buscar por nome</span>
        <input type="search" name="busca" value="${esc(filtro.busca)}" placeholder="Ex.: chaveiro" autocomplete="off"></label>
      <label class="campo campo-compacto"><span>Mostrar</span>
        <select name="situacao">
          <option value="ativos" ${filtro.situacao === 'ativos' ? 'selected' : ''}>Ativos</option>
          <option value="inativos" ${filtro.situacao === 'inativos' ? 'selected' : ''}>Inativos</option>
          <option value="todos" ${filtro.situacao === 'todos' ? 'selected' : ''}>Todos</option>
        </select></label>
      <div class="filtros-acao">
        <button type="button" class="botao botao-primario" data-novo>
          <i class="ti ti-plus" aria-hidden="true"></i> Novo produto</button>
      </div>
    </section>
    ${marcas ? barraCatalogo(produtos.filter(p => p.ativo && p.no_catalogo).length) : ''}
    <p class="aviso aviso-ok" role="status" ${mensagem ? '' : 'hidden'}>${esc(mensagem || '')}</p>
    <p class="texto-secundario contagem-produtos" data-contagem aria-live="polite"></p>
    <div class="grade-produtos" data-lista></div>`;

  const listaEl = area.querySelector('[data-lista]');
  const contagemEl = area.querySelector('[data-contagem]');

  function mostrar() {
    const termo = normal(filtro.busca);
    const lista = produtos.filter(p =>
      (filtro.situacao === 'todos' || (filtro.situacao === 'ativos') === p.ativo)
      && (!termo || normal(p.nome).includes(termo)));
    contagemEl.textContent = produtos.length
      ? `${lista.length} de ${produtos.length} produto(s)` : '';
    if (!produtos.length) {
      listaEl.innerHTML = `<section class="cartao vazio-produtos">
        <i class="ti ti-box" aria-hidden="true"></i>
        <h3>Nenhum produto cadastrado</h3>
        <p class="texto-secundario">Cadastre o primeiro com o botão <strong>Novo produto</strong>. Só o nome é obrigatório.</p>
      </section>`;
      return;
    }
    if (!lista.length) {
      listaEl.innerHTML = '<p class="texto-secundario vazio">Nenhum produto encontrado com esse filtro.</p>';
      return;
    }
    listaEl.innerHTML = lista.map(p => cartaoProduto(p, fotos[p.foto_path])).join('');
  }

  area.querySelector('.filtros').addEventListener('input', e => {
    if (!e.target.name) return;
    filtro[e.target.name] = e.target.value;
    mostrar();
  });
  area.querySelector('[data-novo]').addEventListener('click', () => abrirFormulario(contexto, null));
  area.querySelector('[data-copiar-link]')?.addEventListener('click', async e => {
    const b = e.currentTarget;
    const link = new URL('catalogo.html', location.href).href;
    const mostrarLink = area.querySelector('[data-link-catalogo]');
    try {
      await navigator.clipboard.writeText(link);
      b.innerHTML = '<i class="ti ti-check" aria-hidden="true"></i> Link copiado';
      setTimeout(() => { b.innerHTML = '<i class="ti ti-copy" aria-hidden="true"></i> Copiar link'; }, 2500);
    } catch {
      // Sem acesso à área de transferência: mostra o link para copiar à mão.
      mostrarLink.hidden = false;
      mostrarLink.querySelector('input').value = link;
      mostrarLink.querySelector('input').select();
    }
  });
  listaEl.addEventListener('click', e => {
    const b = e.target.closest('[data-produto]');
    if (!b) return;
    const p = produtos.find(x => x.id === b.dataset.produto);
    if (p) abrirDetalhe(contexto, p);
  });

  mostrar();
}

function miniFoto(url, nome, classe) {
  return url
    ? `<img class="${classe}" src="${esc(url)}" alt="Foto de ${esc(nome)}" loading="lazy">`
    : `<div class="${classe} foto-vazia" aria-hidden="true"><i class="ti ti-photo"></i></div>`;
}

function chipsCores(cores, limite = Infinity) {
  if (!cores.length) return '';
  const mostrar = cores.slice(0, limite);
  const resto = cores.length - mostrar.length;
  return `<ul class="chips-cores" aria-label="Cores">${mostrar.map(c =>
    `<li class="chip-cor ${c.ativo ? '' : 'chip-inativo'}">${esc(corTexto(c))}${c.ativo ? '' : ' (inativo)'}</li>`).join('')}
    ${resto > 0 ? `<li class="chip-cor chip-mais">+${resto}</li>` : ''}</ul>`;
}

// Com combinações ligadas, o preço vem delas: "a partir de" o menor (R114).
function precoCartao(p) {
  const v = precoVariacoes(p);
  if (v) return v.minimo == null ? '<span class="selo-p selo-sem-preco">Sob consulta</span>' : `<strong class="produto-preco">${v.texto}</strong>`;
  return p.sem_preco ? '<span class="selo-p selo-sem-preco">Sem preço</span>' : `<strong class="produto-preco">${brl(p.preco_venda)}</strong>`;
}

function cartaoProduto(p, url) {
  const tempo = tempoTexto(p.tempo_impressao_min);
  return `<button type="button" class="cartao-produto ${p.ativo ? '' : 'produto-inativo'}" data-produto="${p.id}">
    ${miniFoto(url, p.nome, 'produto-foto')}
    <span class="produto-corpo">
      <span class="produto-nome">${esc(p.nome)}${p.ativo ? '' : ' <span class="selo-p selo-inativo">Inativo</span>'}${selosCatalogo(p)}</span>
      <span class="produto-linha">
        ${precoCartao(p)}
        ${tempo ? `<span class="produto-tempo"><i class="ti ti-clock" aria-hidden="true"></i> ${tempo}</span>` : ''}
        ${p.partes?.length ? `<span class="produto-tempo"><i class="ti ti-puzzle" aria-hidden="true"></i> ${plural(p.partes.length, 'parte', 'partes')}</span>` : ''}
      </span>
      ${chipsCores(p.cores, 3)}
    </span>
  </button>`;
}

// Atalho para o catálogo público (R85): abrir em outra aba e copiar o link para mandar aos clientes.
function barraCatalogo(visiveis) {
  return `<section class="cartao barra-catalogo">
    <div class="barra-catalogo-texto">
      <strong><i class="ti ti-building-store" aria-hidden="true"></i> Catálogo público</strong>
      <span class="texto-secundario">${visiveis ? `${visiveis} produto(s) aparecendo para os clientes` : 'Nenhum produto marcado “No catálogo” ainda'}</span>
    </div>
    <div class="barra-catalogo-acoes">
      <a class="botao" href="catalogo.html" target="_blank" rel="noopener"><i class="ti ti-external-link" aria-hidden="true"></i> Ver catálogo</a>
      <button type="button" class="botao" data-copiar-link><i class="ti ti-copy" aria-hidden="true"></i> Copiar link</button>
    </div>
    <label class="campo campo-compacto barra-catalogo-link" data-link-catalogo hidden><span>Link do catálogo (copie e envie)</span>
      <input type="text" readonly></label>
  </section>`;
}

function selosCatalogo(p) {
  return (p.no_catalogo ? ' <span class="selo-p selo-catalogo">No catálogo</span>' : '')
    + (p.personalizado ? ' <span class="selo-p selo-personalizado">Personalizado</span>' : '');
}

// Como o produto aparece no catálogo público (R85–R86).
function situacaoCatalogo(p, catVar) {
  if (!p.no_catalogo) return 'Não aparece';
  if (!p.ativo) return 'Marcado, mas não aparece porque está inativo';
  // Combinações no catálogo (sql/23, R117): o cliente escolhe as opções.
  if (catVar && p.variacoes?.length) {
    const v = precoVariacoes(p);
    if (!v) return 'Aparece como “Indisponível”: nenhuma combinação ligada';
    if (p.personalizado || v.minimo == null) return 'Aparece como “Sob consulta”, com a escolha das opções';
    return `Aparece ${v.texto}, com a escolha das opções`;
  }
  return p.personalizado || p.sem_preco ? 'Aparece como “Sob consulta”' : `Aparece por ${brl(p.preco_venda)}`;
}

// ---------------------------------------------------------------- folhas

function abrirFolha(html, { larga = false, rotulo }) {
  const dialog = document.createElement('dialog');
  dialog.className = `folha folha-form${larga ? ' folha-produto' : ''}`;
  dialog.setAttribute('aria-labelledby', rotulo);
  dialog.innerHTML = html;
  document.body.appendChild(dialog);
  const fechar = () => { dialog.close(); dialog.remove(); };
  dialog.addEventListener('click', e => {
    if (cliqueForaDoDialogo(e, dialog) || e.target.closest('[data-fechar]')) fechar();
  });
  dialog.addEventListener('cancel', e => { e.preventDefault(); fechar(); });
  dialog.showModal();
  return { dialog, fechar };
}

function abrirDetalhe(ctx, p) {
  const { sb, fotos, recarregar, catalogo, ficha } = ctx;
  const tempo = tempoTexto(p.tempo_impressao_min);
  const dims = dimensoesTexto(p);
  const linha = (rotulo, valor) => (valor ? `<div class="linha-dado"><span>${rotulo}</span><strong>${valor}</strong></div>` : '');
  const { dialog, fechar } = abrirFolha(`
    <div class="folha-topo">
      <h2 id="det-produto">${esc(p.nome)}</h2>
      <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
    </div>
    <div class="detalhe-produto">
      <div class="detalhe-fotos">
        ${miniFoto(fotos[p.foto_path], p.nome, 'detalhe-foto')}
        ${p.fotos_extra?.length ? `<div class="miniaturas">${p.fotos_extra.map((f, i) =>
          miniFoto(fotos[f], `${p.nome} (${i + 2})`, 'miniatura')).join('')}</div>` : ''}
      </div>
      <div class="detalhe-dados">
        ${p.ativo && !p.no_catalogo && !p.personalizado ? '' : `<p>${p.ativo ? '' : '<span class="selo-p selo-inativo">Inativo</span>'}${selosCatalogo(p)}</p>`}
        ${p.descricao ? `${ctx.interna ? '<p class="detalhe-titulo">Descrição para o cliente</p>' : ''}<p class="detalhe-descricao">${esc(p.descricao)}</p>` : ''}
        ${p.descricao_interna ? `<p class="detalhe-titulo">Descrição interna <span class="texto-secundario">(só você vê)</span></p><p class="detalhe-descricao">${esc(p.descricao_interna)}</p>` : ''}
        ${precoVariacoes(p) ? linha('Preço', esc(precoVariacoes(p).texto)) : linha('Preço de venda', p.sem_preco ? '<span class="selo-p selo-sem-preco">Sem preço</span>' : brl(p.preco_venda))}
        ${linha('Tempo', tempo)}
        ${linha('Peso', p.peso_g != null ? `${paraCampo(p.peso_g, 0, 2)} g` : '')}
        ${linha('Dimensões (A × L × P)', dims)}
        ${catalogo ? linha('Catálogo público', esc(situacaoCatalogo(p, ctx.catVar))) : ''}
        ${p.cores.length ? `<p class="detalhe-titulo">Cores</p>${chipsCores(p.cores)}` : ''}
        ${ficha ? htmlFicha(p) : ''}
        ${htmlCombinacoesDetalhe(p, !!ficha)}
      </div>
    </div>
    <p class="aviso aviso-erro" role="alert" hidden></p>
    <div class="form-acoes">
      <button type="button" class="botao botao-perigo" data-excluir>Excluir</button>
      <span class="espaco"></span>
      <button type="button" class="botao" data-ativo>${p.ativo ? 'Desativar' : 'Reativar'}</button>
      <button type="button" class="botao botao-primario" data-editar><i class="ti ti-pencil" aria-hidden="true"></i> Editar</button>
    </div>`, { larga: true, rotulo: 'det-produto' });

  const erro = dialog.querySelector('.aviso-erro');
  const falhar = msg => { erro.textContent = msg; erro.hidden = false; };

  dialog.querySelector('[data-editar]').addEventListener('click', () => { fechar(); abrirFormulario(ctx, p); });
  // Ficha da combinação (R113): abre por cima e recarrega a tela ao salvar.
  dialog.querySelectorAll('[data-ficha-variacao]').forEach(b => b.addEventListener('click', () => {
    const v = p.variacoes.find(x => x.id === b.dataset.fichaVariacao);
    fechar();
    abrirFichaVariacao({ sb, p, v, materiais: ficha.materiais,
      aoConcluir: () => recarregar(`Ficha de "${p.nome} · ${v.descricao}" salva.`) });
  }));
  dialog.querySelector('[data-ativo]').addEventListener('click', async e => {
    e.target.disabled = true;
    try {
      await sb.rpc('definir_produto_ativo', { p_id: p.id, p_ativo: !p.ativo }).then(ok);
      fechar();
      await recarregar(p.ativo ? `"${p.nome}" foi desativado.` : `"${p.nome}" foi reativado.`);
    } catch (err) { falhar(err.message); e.target.disabled = false; }
  });
  dialog.querySelector('[data-excluir]').addEventListener('click', async e => {
    if (!window.confirm(`Excluir "${p.nome}"?\n\nO produto e as fotos dele são apagados de vez. Se preferir guardar, use "Desativar".`)) return;
    e.target.disabled = true;
    try {
      const foto = await sb.rpc('excluir_produto', { p_id: p.id }).then(ok);
      await apagarFoto(sb, [foto, ...(p.fotos_extra || [])]);
      fechar();
      await recarregar(`"${p.nome}" foi excluído.`);
    } catch (err) { falhar(err.message); e.target.disabled = false; }
  });
}

function abrirFormulario(ctx, p) {
  const { sb, produtos, filamentos, fotos, recarregar, catalogo, ficha, galeria, interna, variacoes } = ctx;
  const editando = !!p;
  const maxFotos = galeria ? MAX_FOTOS : 1;
  const fotosOriginais = todasAsFotos(p);
  // Outros materiais da ficha: insumos e embalagens ativos + os inativos que já estão nela.
  const noProduto = new Set((p?.outros || []).map(x => x.material_id));
  const opcoesOutros = ficha ? ficha.materiais.filter(m => m.ativo || noProduto.has(m.id)) : [];
  const ligadas = new Set((p?.cores || []).map(c => c.material_id));
  // Filamentos ativos + os inativos que já estão neste produto (R72).
  const opcoesCor = filamentos.filter(f => f.ativo || ligadas.has(f.id));
  const horas = p?.tempo_impressao_min ? Math.floor(p.tempo_impressao_min / 60) : '';
  const minutos = p?.tempo_impressao_min ? p.tempo_impressao_min % 60 : '';
  const num = (v, casas = 2) => (v == null ? '' : paraCampo(v, 0, casas));

  const { dialog, fechar } = abrirFolha(`
    <form novalidate>
      <div class="folha-topo">
        <h2 id="form-produto">${editando ? 'Editar produto' : 'Novo produto'}</h2>
        <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>

      <p class="campo-dica nota-form">Só o nome é obrigatório. O resto pode ser preenchido depois.</p>
      <div class="form-produto">
        <div class="campo campo-foto">
          <span class="campo-rotulo">${galeria ? `Fotos <em>(até ${MAX_FOTOS})</em>` : 'Foto'}</span>
          <div class="galeria-form" data-galeria></div>
          <small class="campo-dica">JPEG, PNG ou WebP. Você enquadra a foto em quadrado e ela é reduzida antes de enviar.${galeria
            ? ' A primeira é a capa: aparece na lista, na vitrine e no carrinho. Use as setas para mudar a ordem.' : ''}</small>
        </div>

        <div class="campo"><label for="p-nome">Nome</label>
          <input type="text" id="p-nome" name="nome" maxlength="150" value="${esc(p?.nome || '')}" autocomplete="off" required>
          <small class="campo-dica campo-aviso-nome" data-aviso-nome hidden></small></div>

        <div class="campo"><label for="p-desc">${interna ? 'Descrição para o cliente' : 'Descrição'}</label>
          <textarea id="p-desc" name="descricao" rows="3" maxlength="4000" ${interna ? 'aria-describedby="p-desc-dica"' : ''}>${esc(p?.descricao || '')}</textarea>
          ${interna ? '<small class="campo-dica" id="p-desc-dica">Aparece no catálogo, junto com o tempo de impressão.</small>' : ''}</div>
        ${interna ? `<div class="campo"><label for="p-desc-int">Descrição interna <em>(opcional)</em></label>
          <textarea id="p-desc-int" name="descricao_interna" rows="3" maxlength="4000" aria-describedby="p-desc-int-dica">${esc(p?.descricao_interna || '')}</textarea>
          <small class="campo-dica" id="p-desc-int-dica">Só você vê. Não aparece no catálogo.</small></div>` : ''}

        <fieldset class="itens-compra">
          <legend>Cores (filamentos do estoque)</legend>
          ${opcoesCor.length ? `<div class="escolha-cores">${opcoesCor.map(f => `
            <label class="opcao-cor"><input type="checkbox" name="cores" value="${f.id}" ${ligadas.has(f.id) ? 'checked' : ''}>
              <span>${esc(f.tipo)} · ${esc(f.variacao)}${f.ativo ? '' : ' (inativo)'}</span></label>`).join('')}</div>`
            : '<p class="campo-dica">Nenhum filamento ativo. Cadastre filamentos em Configurações → Materiais.</p>'}
        </fieldset>

        ${ficha ? `<fieldset class="itens-compra ficha-consumo">
          <legend>Ficha de consumo <em>(opcional)</em></legend>
          <p class="campo-dica">Quanto cada peça gasta. A ficha não guarda cor: a cor de cada parte é escolhida no pedido.</p>
          <p class="ficha-subtitulo">Partes impressas</p>
          <div class="ficha-lista" data-partes></div>
          <button type="button" class="botao-texto ficha-adicionar" data-add-parte><i class="ti ti-plus" aria-hidden="true"></i> Adicionar parte</button>
          <p class="ficha-subtitulo">Outros materiais <span class="texto-secundario">(insumos e embalagem de entrega)</span></p>
          <div class="ficha-lista" data-outros></div>
          ${opcoesOutros.length
            ? '<button type="button" class="botao-texto ficha-adicionar" data-add-outro><i class="ti ti-plus" aria-hidden="true"></i> Adicionar material</button>'
            : '<p class="campo-dica">Nenhum insumo ou embalagem ativo. Cadastre em Configurações → Materiais.</p>'}
          <p class="ficha-total" data-total-ficha aria-live="polite"></p>
        </fieldset>` : ''}

        <div class="grade-produto">
          <fieldset class="itens-compra">
            <legend>Tempo de impressão</legend>
            <div class="grade-dois">
              <div class="campo"><label for="p-horas">Horas</label>
                <input type="text" inputmode="numeric" id="p-horas" name="horas" value="${horas}" placeholder="0" autocomplete="off"></div>
              <div class="campo"><label for="p-min">Minutos</label>
                <input type="text" inputmode="numeric" id="p-min" name="minutos" value="${minutos}" placeholder="0 a 59" autocomplete="off"></div>
            </div>
          </fieldset>
          <fieldset class="itens-compra">
            <legend>Peso e preço</legend>
            <div class="grade-dois">
              <div class="campo"><label for="p-peso">Peso (g)</label>
                <input type="text" inputmode="decimal" id="p-peso" name="peso" value="${num(p?.peso_g)}" placeholder="0" autocomplete="off"></div>
              <div class="campo"><label for="p-preco">Preço (R$)</label>
                <input type="text" inputmode="decimal" data-dinheiro id="p-preco" name="preco" value="${p?.preco_venda == null ? '' : dinheiroCampo(p.preco_venda)}" placeholder="R$ 0,00" autocomplete="off"></div>
            </div>
          </fieldset>
        </div>

        ${catalogo ? `<fieldset class="itens-compra">
          <legend>Catálogo público</legend>
          <div class="campo campo-check">
            <label><input type="checkbox" name="no_catalogo" ${p?.no_catalogo ? 'checked' : ''}><span>No catálogo</span></label>
            <small class="campo-dica">Aparece na vitrine com nome, preço, descrição, foto e cores. Produto inativo não aparece.</small>
          </div>
          <div class="campo campo-check">
            <label><input type="checkbox" name="personalizado" ${p?.personalizado ? 'checked' : ''}><span>Personalizado (preço sob consulta)</span></label>
            <small class="campo-dica">Personalizado ou sem preço aparece como “Sob consulta”.</small>
          </div>
        </fieldset>` : ''}

        ${variacoes ? `<fieldset class="itens-compra variacoes-form">
          <legend>Variações <em>(opcional)</em></legend>
          <p class="campo-dica">A opção é o que o cliente escolhe (ex.: Cor da flor) e os valores são as escolhas (ex.: Rosa claro, Vermelha). Até 3 opções. O preço vai em cada combinação, logo abaixo; ela pode ser desligada. A ficha de cada combinação é ajustada no detalhe do produto.</p>
          <div data-variacoes></div>
        </fieldset>` : ''}

        <fieldset class="itens-compra">
          <legend>Dimensões (cm)</legend>
          <div class="grade-dimensoes">
            <div class="campo"><label for="p-alt">Altura</label>
              <input type="text" inputmode="decimal" id="p-alt" name="altura" value="${num(p?.altura_cm)}" autocomplete="off"></div>
            <div class="campo"><label for="p-larg">Largura</label>
              <input type="text" inputmode="decimal" id="p-larg" name="largura" value="${num(p?.largura_cm)}" autocomplete="off"></div>
            <div class="campo"><label for="p-prof">Profundidade</label>
              <input type="text" inputmode="decimal" id="p-prof" name="profundidade" value="${num(p?.profundidade_cm)}" autocomplete="off"></div>
          </div>
        </fieldset>
      </div>

      <p class="aviso aviso-erro" role="alert" hidden></p>
      <div class="form-acoes">
        <span class="espaco"></span>
        <button type="button" class="botao" data-fechar>Cancelar</button>
        <button type="submit" class="botao botao-primario">${editando ? 'Salvar' : 'Cadastrar produto'}</button>
      </div>
    </form>`, { larga: true, rotulo: 'form-produto' });

  const form = dialog.querySelector('form');
  const erro = dialog.querySelector('.aviso-erro');
  const galeriaEl = dialog.querySelector('[data-galeria]');
  const avisoNome = dialog.querySelector('[data-aviso-nome]');
  // Fotos na ordem da tela: { path, url } das já salvas; { nova: {blob, ext, tipo}, url } das novas.
  let fotosTela = fotosOriginais.map(f => ({ path: f, url: fotos[f] || null }));

  const falhar = msg => { erro.textContent = msg; erro.hidden = false; };

  // Variações (sql/22): combinações novas começam com o preço do produto.
  const editorVar = variacoes ? montarEditorVariacoes(dialog.querySelector('[data-variacoes]'), p,
    () => form.elements.preco.value.trim()) : null;

  // Nome repetido: permitido, só avisa.
  const conferirNome = () => {
    const n = normal(form.elements.nome.value);
    const igual = n && produtos.some(x => x.id !== p?.id && normal(x.nome) === n);
    avisoNome.hidden = !igual;
    avisoNome.textContent = igual ? 'Já existe um produto com este nome. Você pode salvar mesmo assim.' : '';
  };
  form.elements.nome.addEventListener('input', conferirNome);
  conferirNome();

  // ---- ficha de consumo (R93)
  const partesEl = dialog.querySelector('[data-partes]');
  const outrosEl = dialog.querySelector('[data-outros]');
  const totalFicha = dialog.querySelector('[data-total-ficha]');
  const linhaParte = (x = {}) => `
    <div class="ficha-linha" data-parte>
      <label class="campo campo-compacto ficha-nome"><span>Parte</span>
        <input type="text" data-nome maxlength="60" value="${esc(x.nome || '')}" placeholder="Ex.: Flor" autocomplete="off"></label>
      <label class="campo campo-compacto"><span>Peça (g)</span>
        <input type="text" inputmode="decimal" data-g value="${x.gramas != null ? paraCampo(x.gramas, 0, 2) : ''}" placeholder="0" autocomplete="off"></label>
      <label class="campo campo-compacto"><span>Purga (g)</span>
        <input type="text" inputmode="decimal" data-purga value="${x.purga_g != null && Number(x.purga_g) ? paraCampo(x.purga_g, 0, 2) : ''}" placeholder="0" autocomplete="off"></label>
      <button type="button" class="botao-icone" data-remover-linha aria-label="Remover parte"><i class="ti ti-trash" aria-hidden="true"></i></button>
    </div>`;
  const linhaOutro = (x = {}) => `
    <div class="ficha-linha ficha-linha-outro" data-outro>
      <label class="campo campo-compacto ficha-nome"><span>Material</span>
        <select data-material>
          <option value="">Escolha</option>
          ${opcoesOutros.map(m => `<option value="${m.id}" ${m.id === x.material_id ? 'selected' : ''}>${m.categoria === 'EMBALAGEM' ? 'Embalagem' : 'Insumo'} · ${esc(nomeMaterial(m))} (${esc(m.unidade)})${m.ativo ? '' : ' (inativo)'}</option>`).join('')}
        </select></label>
      <label class="campo campo-compacto"><span>Quantidade</span>
        <input type="text" inputmode="decimal" data-qtd value="${x.quantidade != null ? paraCampo(x.quantidade, 0, 3) : ''}" placeholder="1" autocomplete="off"></label>
      <button type="button" class="botao-icone" data-remover-linha aria-label="Remover material"><i class="ti ti-trash" aria-hidden="true"></i></button>
    </div>`;

  /** Lê a ficha da tela. Devolve { partes, materiais } ou lança o erro para mostrar. */
  function lerFicha() {
    const partes = [], materiais = [], nomes = new Set(), mats = new Set();
    [...partesEl.querySelectorAll('[data-parte]')].forEach((el, i) => {
      const nome = el.querySelector('[data-nome]').value.trim();
      const gTxt = el.querySelector('[data-g]').value.trim();
      const pTxt = el.querySelector('[data-purga]').value.trim();
      if (!nome && !gTxt && !pTxt) return;                       // linha vazia é ignorada
      const rot = `Ficha, parte ${i + 1}`;
      if (!nome) throw new Error(`${rot}: informe o nome da parte (ex.: Flor, Vaso).`);
      if (nomes.has(normal(nome))) throw new Error(`${rot}: já existe uma parte "${nome}".`);
      nomes.add(normal(nome));
      const g = lerDecimal(gTxt, 2);
      if (!Number.isFinite(g) || g <= 0) throw new Error(`${rot} (${nome}): informe os gramas da peça, maior que zero.`);
      const purga = pTxt ? lerDecimal(pTxt, 2) : 0;
      if (!Number.isFinite(purga) || purga < 0) throw new Error(`${rot} (${nome}): a purga precisa ser zero ou mais gramas.`);
      partes.push({ nome, gramas: String(g), purga_g: String(purga) });
    });
    [...outrosEl.querySelectorAll('[data-outro]')].forEach((el, i) => {
      const id = el.querySelector('[data-material]').value;
      const qTxt = el.querySelector('[data-qtd]').value.trim();
      if (!id && !qTxt) return;
      const rot = `Ficha, material ${i + 1}`;
      if (!id) throw new Error(`${rot}: escolha o material.`);
      if (mats.has(id)) throw new Error(`${rot}: o mesmo material aparece duas vezes.`);
      mats.add(id);
      const q = lerDecimal(qTxt, 3);
      if (!Number.isFinite(q) || q <= 0) throw new Error(`${rot}: informe a quantidade por peça, maior que zero.`);
      materiais.push({ material_id: id, quantidade: String(q) });
    });
    return { partes, materiais };
  }
  const fichaOriginal = JSON.stringify({
    partes: (p?.partes || []).map(x => ({ nome: x.nome, gramas: String(Number(x.gramas)), purga_g: String(Number(x.purga_g)) })),
    materiais: (p?.outros || []).map(x => ({ material_id: x.material_id, quantidade: String(Number(x.quantidade)) })),
  });
  function atualizarTotalFicha() {
    if (!totalFicha) return;
    let peca = 0, purga = 0;
    partesEl.querySelectorAll('[data-parte]').forEach(el => {
      const g = lerDecimal(el.querySelector('[data-g]').value, 2);
      const pg = lerDecimal(el.querySelector('[data-purga]').value, 2);
      if (Number.isFinite(g)) peca += g;
      if (Number.isFinite(pg)) purga += pg;
    });
    totalFicha.textContent = peca || purga
      ? `Filamento por peça: ${gramas(peca)} de peça + ${gramas(purga)} de purga = ${gramas(peca + purga)}` : '';
  }
  if (ficha) {
    (p?.partes || []).forEach(x => partesEl.insertAdjacentHTML('beforeend', linhaParte(x)));
    (p?.outros || []).forEach(x => outrosEl.insertAdjacentHTML('beforeend', linhaOutro(x)));
    atualizarTotalFicha();
    dialog.querySelector('[data-add-parte]').addEventListener('click', () => {
      partesEl.insertAdjacentHTML('beforeend', linhaParte());
      partesEl.lastElementChild.querySelector('input').focus();
    });
    dialog.querySelector('[data-add-outro]')?.addEventListener('click', () => {
      outrosEl.insertAdjacentHTML('beforeend', linhaOutro());
      outrosEl.lastElementChild.querySelector('select').focus();
    });
    dialog.querySelector('.ficha-consumo').addEventListener('click', e => {
      const b = e.target.closest('[data-remover-linha]');
      if (!b) return;
      b.closest('.ficha-linha').remove();
      atualizarTotalFicha();
    });
    partesEl.addEventListener('input', atualizarTotalFicha);
  }

  function desenharGaleria() {
    const n = fotosTela.length;
    galeriaEl.innerHTML = `${fotosTela.map((f, i) => `
      <div class="galeria-item">
        ${f.url ? `<img class="previa-foto" src="${esc(f.url)}" alt="${i === 0 ? 'Capa' : `Foto ${i + 1}`}">` : miniFoto(null, '', 'previa-foto')}
        ${i === 0 && maxFotos > 1 ? '<span class="selo-p selo-capa">Capa</span>' : ''}
        <div class="galeria-botoes">
          ${maxFotos > 1 ? `<button type="button" class="botao-icone" data-mover="${i}:-1" ${i === 0 ? 'disabled' : ''} aria-label="Mover a foto ${i + 1} para a esquerda"><i class="ti ti-chevron-left" aria-hidden="true"></i></button>
          <button type="button" class="botao-icone" data-mover="${i}:1" ${i === n - 1 ? 'disabled' : ''} aria-label="Mover a foto ${i + 1} para a direita"><i class="ti ti-chevron-right" aria-hidden="true"></i></button>` : ''}
          <button type="button" class="botao-icone" data-remover-foto="${i}" aria-label="Remover a foto ${i + 1}"><i class="ti ti-trash" aria-hidden="true"></i></button>
        </div>
      </div>`).join('')}
      ${n < maxFotos || maxFotos === 1 ? `<label class="galeria-adicionar">
        <i class="ti ti-photo-plus" aria-hidden="true"></i>
        <span>${n ? (maxFotos > 1 ? 'Adicionar foto' : 'Trocar foto') : 'Escolher foto'}</span>
        <input type="file" accept="image/jpeg,image/png,image/webp" hidden data-arquivo></label>` : ''}`;
  }
  desenharGaleria();

  galeriaEl.addEventListener('click', e => {
    const m = e.target.closest('[data-mover]');
    if (m) {
      const [i, d] = m.dataset.mover.split(':').map(Number);
      [fotosTela[i], fotosTela[i + d]] = [fotosTela[i + d], fotosTela[i]];
      desenharGaleria();
      galeriaEl.querySelector(`[data-mover="${i + d}:${d}"]:not([disabled])`)?.focus();
      return;
    }
    const r = e.target.closest('[data-remover-foto]');
    if (r) {
      const [tirada] = fotosTela.splice(Number(r.dataset.removerFoto), 1);
      if (tirada.nova) URL.revokeObjectURL(tirada.url);
      desenharGaleria();
    }
  });
  galeriaEl.addEventListener('change', async e => {
    if (!e.target.matches('[data-arquivo]')) return;
    const arquivo = e.target.files[0];
    e.target.value = '';
    if (!arquivo) return;
    erro.hidden = true;
    try {
      // A foto é enquadrada em quadrado antes da otimização (catálogo e Produtos mostram quadrada).
      const quadrada = await recortarQuadrado(arquivo);
      if (!quadrada) return;
      // Enquanto a foto é preparada, "Salvar" fica bloqueado para não salvar sem ela.
      const salvar = form.querySelector('[type="submit"]');
      const textoSalvar = salvar.textContent;
      salvar.disabled = true; salvar.textContent = 'Preparando foto…';
      let reduzida;
      try { reduzida = await otimizarFoto(quadrada); }
      finally { salvar.disabled = false; salvar.textContent = textoSalvar; }
      const nova = { nova: reduzida, url: URL.createObjectURL(reduzida.blob) };
      // Uma foto só (antes do sql/20): a nova substitui a atual.
      if (maxFotos === 1) { fotosTela.filter(f => f.nova).forEach(f => URL.revokeObjectURL(f.url)); fotosTela = [nova]; }
      else if (fotosTela.length < maxFotos) fotosTela.push(nova);
      desenharGaleria();
    } catch (err) { falhar(err.message); }
  });

  // Lê um número opcional: vazio → null; inválido → erro com o nome do campo.
  const lerOpcional = (nome, rotulo, casas = 2) => {
    const t = form.elements[nome].value.trim();
    if (!t) return null;
    const v = lerDecimal(t, casas);
    if (!Number.isFinite(v) || v <= 0) throw new Error(`${rotulo}: informe um número maior que zero, ou deixe vazio.`);
    return v;
  };
  const lerInteiro = (nome, rotulo) => {
    const t = form.elements[nome].value.trim();
    if (!t) return null;
    if (!/^\d+$/.test(t)) throw new Error(`${rotulo}: use só números inteiros.`);
    return Number(t);
  };

  form.addEventListener('submit', async e => {
    e.preventDefault();
    erro.hidden = true;
    const nome = form.elements.nome.value.trim();
    let dados, novaFicha = null, novasVariacoes = null;
    try {
      if (!nome) { form.elements.nome.focus(); throw new Error('Informe o nome do produto.'); }
      const h = lerInteiro('horas', 'Horas');
      const m = lerInteiro('minutos', 'Minutos');
      if (m != null && m > 59) throw new Error('Minutos: vão de 0 a 59.');
      if ((h != null || m != null) && !(h || m)) throw new Error('O tempo de impressão precisa ser maior que zero, ou ficar vazio.');
      dados = {
        p_id: p?.id || null,
        p_nome: nome,
        p_descricao: form.elements.descricao.value.trim(),
        p_tempo_horas: h == null && m == null ? null : (h || 0),
        p_tempo_minutos: h == null && m == null ? null : (m || 0),
        p_peso_g: lerOpcional('peso', 'Peso'),
        p_altura_cm: lerOpcional('altura', 'Altura'),
        p_largura_cm: lerOpcional('largura', 'Largura'),
        p_profundidade_cm: lerOpcional('profundidade', 'Profundidade'),
        p_preco_venda: lerOpcional('preco', 'Preço de venda'),
        p_cores: [...form.querySelectorAll('[name="cores"]:checked')].map(c => c.value),
      };
      // A ficha é conferida antes de salvar, para não gravar o produto sem ela.
      if (ficha) novaFicha = lerFicha();
      if (editorVar?.mudou()) novasVariacoes = editorVar.ler();
    } catch (err) { falhar(err.message); return; }

    const botao = form.querySelector('[type="submit"]');
    const textoBotao = botao.textContent;
    botao.disabled = true; botao.textContent = 'Salvando…';
    const enviadas = [];
    try {
      // 1. Fotos novas vão primeiro para a pasta, com nome único (nunca sobrescreve).
      for (const f of fotosTela.filter(x => x.nova && !x.path)) {
        const nomeArq = `${novoId()}.${f.nova.ext}`;
        const { error } = await sb.storage.from(PASTA).upload(nomeArq, f.nova.blob, {
          contentType: f.nova.tipo, upsert: false, cacheControl: '3600',
        });
        if (error) throw new Error('Não foi possível enviar a foto. Verifique a internet e tente de novo.');
        enviadas.push(nomeArq);
        f.path = nomeArq;
      }
      const lista = fotosTela.map(f => f.path);
      const mudouFotos = JSON.stringify(lista) !== JSON.stringify(fotosOriginais);
      // 2. Produto e cores juntos (tudo ou nada). Com várias fotos, a capa só muda
      //    pelo passo 3, junto com as outras.
      dados.p_foto_path = galeria ? (p?.foto_path || null) : (lista[0] || null);
      const r = await sb.rpc('salvar_produto', dados).then(ok);
      enviadas.length = galeria ? enviadas.length : 0;   // uma foto só: já está gravada
      if (!galeria) await apagarFoto(sb, r?.foto_anterior);   // a foto que deixou de ser usada (R73)
      let feito = editando ? `"${nome}" foi atualizado.` : `"${nome}" foi cadastrado.`;
      // 3. Fotos na ordem escolhida (R73 v1.12); as que saíram são apagadas depois.
      if (galeria && mudouFotos) {
        try {
          await sb.rpc('salvar_fotos_produto', { p_produto_id: r.id, p_fotos: lista }).then(ok);
          enviadas.length = 0;
          await apagarFoto(sb, fotosOriginais.filter(f => !lista.includes(f)));
        } catch (err) {
          await apagarFoto(sb, enviadas.splice(0));
          feito = `"${nome}" foi salvo, mas as fotos não foram gravadas (${err.message}). Abra o produto e tente de novo.`;
        }
      }
      enviadas.length = 0;
      // 4. Marcações do catálogo público (R86), só quando mudaram.
      if (catalogo) {
        const noCatalogo = form.elements.no_catalogo.checked;
        const personalizado = form.elements.personalizado.checked;
        if (noCatalogo !== !!p?.no_catalogo || personalizado !== !!p?.personalizado) {
          try {
            await sb.rpc('definir_produto_catalogo', { p_id: r.id, p_no_catalogo: noCatalogo, p_personalizado: personalizado }).then(ok);
          } catch (err) {
            feito = `"${nome}" foi salvo, mas as marcações do catálogo não foram gravadas (${err.message}). Abra o produto e tente de novo.`;
          }
        }
      }
      // 5. Descrição interna (sql/21), só quando mudou.
      if (interna) {
        const novaInterna = form.elements.descricao_interna.value.trim();
        if (novaInterna !== (p?.descricao_interna || '')) {
          try {
            await sb.rpc('salvar_descricao_interna', { p_produto_id: r.id, p_texto: novaInterna }).then(ok);
          } catch (err) {
            feito = `"${nome}" foi salvo, mas a descrição interna não foi gravada (${err.message}). Abra o produto e tente de novo.`;
          }
        }
      }
      // 6. Ficha de consumo (R93), só quando mudou.
      if (novaFicha && JSON.stringify(novaFicha) !== fichaOriginal) {
        try {
          await sb.rpc('salvar_ficha_produto', { p_produto_id: r.id, p_partes: novaFicha.partes, p_materiais: novaFicha.materiais }).then(ok);
        } catch (err) {
          feito = `"${nome}" foi salvo, mas a ficha de consumo não foi gravada (${err.message}). Abra o produto e tente de novo.`;
        }
      }
      // 7. Variações (sql/22), só quando mudaram.
      if (novasVariacoes) {
        try {
          await sb.rpc('salvar_variacoes_produto', { p_produto_id: r.id, p_opcoes: novasVariacoes.opcoes, p_combinacoes: novasVariacoes.combinacoes }).then(ok);
        } catch (err) {
          feito = `"${nome}" foi salvo, mas as variações não foram gravadas (${err.message}). Abra o produto e tente de novo.`;
        }
      }
      fechar();
      await recarregar(feito);
    } catch (err) {
      await apagarFoto(sb, enviadas);   // não deixa sobra se o salvamento falhou
      fotosTela.forEach(f => { if (f.nova && enviadas.includes(f.path)) f.path = null; });
      falhar(err.message);
    } finally {
      botao.disabled = false; botao.textContent = textoBotao;
    }
  });

  dialog.addEventListener('close', () => fotosTela.forEach(f => { if (f.nova) URL.revokeObjectURL(f.url); }));
  form.elements.nome.focus();
}
