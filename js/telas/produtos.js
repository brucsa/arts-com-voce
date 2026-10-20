// Etapa 4 · Catálogo Essencial de Produtos (só Admin)
// Regras: R71–R75 (especificação v1.3).
// Grava só pelas funções salvar_produto, definir_produto_ativo e excluir_produto.
// Catálogo público (R85–R88): as marcações são gravadas por definir_produto_catalogo.
// Fotos: pasta privada "produtos" do Storage, vistas por links temporários.

import { supabase, configurado } from '../supabase.js';
import { ok } from '../db.js';
import { esc, brl, lerDecimal, paraCampo } from '../format.js';
import { cliqueForaDoDialogo } from '../ui/dialogo.js';
import { recortarQuadrado } from '../ui/recorte.js';

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
  const caminhos = produtos.map(p => p.foto_path).filter(Boolean);
  if (!caminhos.length) return {};
  const { data, error } = await sb.storage.from(PASTA).createSignedUrls(caminhos, 3600);
  if (error) return {};
  return Object.fromEntries((data || []).filter(d => d.signedUrl).map(d => [d.path, d.signedUrl]));
}

// Apaga uma foto que deixou de ser usada. Se falhar, ela fica como "foto sem
// produto" na verificação e pode ser apagada pelo painel do Storage.
async function apagarFoto(sb, caminho) {
  if (!caminho) return;
  try { await sb.storage.from(PASTA).remove([caminho]); } catch { /* fica para limpeza manual */ }
}

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
  const fotos = await linksDasFotos(sb, produtos);
  // Marcações do catálogo público (R86). Antes do sql/11 as colunas não
  // existem: a tela continua funcionando, só sem as marcações.
  const marcas = await sb.from('produtos').select('id, no_catalogo, personalizado')
    .then(({ data, error }) => (error ? null : Object.fromEntries((data || []).map(m => [m.id, m]))));
  if (marcas) produtos.forEach(p => Object.assign(p, { no_catalogo: false, personalizado: false }, marcas[p.id] || {}));
  const contexto = { sb, produtos, filamentos, fotos, recarregar, catalogo: !!marcas };

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

function cartaoProduto(p, url) {
  const tempo = tempoTexto(p.tempo_impressao_min);
  return `<button type="button" class="cartao-produto ${p.ativo ? '' : 'produto-inativo'}" data-produto="${p.id}">
    ${miniFoto(url, p.nome, 'produto-foto')}
    <span class="produto-corpo">
      <span class="produto-nome">${esc(p.nome)}${p.ativo ? '' : ' <span class="selo-p selo-inativo">Inativo</span>'}${selosCatalogo(p)}</span>
      <span class="produto-linha">
        ${p.sem_preco ? '<span class="selo-p selo-sem-preco">Sem preço</span>' : `<strong class="produto-preco">${brl(p.preco_venda)}</strong>`}
        ${tempo ? `<span class="produto-tempo"><i class="ti ti-clock" aria-hidden="true"></i> ${tempo}</span>` : ''}
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
function situacaoCatalogo(p) {
  if (!p.no_catalogo) return 'Não aparece';
  if (!p.ativo) return 'Marcado, mas não aparece porque está inativo';
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
  const { sb, fotos, recarregar, catalogo } = ctx;
  const tempo = tempoTexto(p.tempo_impressao_min);
  const dims = dimensoesTexto(p);
  const linha = (rotulo, valor) => (valor ? `<div class="linha-dado"><span>${rotulo}</span><strong>${valor}</strong></div>` : '');
  const { dialog, fechar } = abrirFolha(`
    <div class="folha-topo">
      <h2 id="det-produto">${esc(p.nome)}</h2>
      <button type="button" class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
    </div>
    <div class="detalhe-produto">
      ${miniFoto(fotos[p.foto_path], p.nome, 'detalhe-foto')}
      <div class="detalhe-dados">
        ${p.ativo && !p.no_catalogo && !p.personalizado ? '' : `<p>${p.ativo ? '' : '<span class="selo-p selo-inativo">Inativo</span>'}${selosCatalogo(p)}</p>`}
        ${p.descricao ? `<p class="detalhe-descricao">${esc(p.descricao)}</p>` : ''}
        ${linha('Preço de venda', p.sem_preco ? '<span class="selo-p selo-sem-preco">Sem preço</span>' : brl(p.preco_venda))}
        ${linha('Tempo', tempo)}
        ${linha('Peso', p.peso_g != null ? `${paraCampo(p.peso_g, 0, 2)} g` : '')}
        ${linha('Dimensões (A × L × P)', dims)}
        ${catalogo ? linha('Catálogo público', esc(situacaoCatalogo(p))) : ''}
        ${p.cores.length ? `<p class="detalhe-titulo">Cores</p>${chipsCores(p.cores)}` : ''}
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
  dialog.querySelector('[data-ativo]').addEventListener('click', async e => {
    e.target.disabled = true;
    try {
      await sb.rpc('definir_produto_ativo', { p_id: p.id, p_ativo: !p.ativo }).then(ok);
      fechar();
      await recarregar(p.ativo ? `"${p.nome}" foi desativado.` : `"${p.nome}" foi reativado.`);
    } catch (err) { falhar(err.message); e.target.disabled = false; }
  });
  dialog.querySelector('[data-excluir]').addEventListener('click', async e => {
    if (!window.confirm(`Excluir "${p.nome}"?\n\nO produto e a foto dele são apagados de vez. Se preferir guardar, use "Desativar".`)) return;
    e.target.disabled = true;
    try {
      const foto = await sb.rpc('excluir_produto', { p_id: p.id }).then(ok);
      await apagarFoto(sb, foto);
      fechar();
      await recarregar(`"${p.nome}" foi excluído.`);
    } catch (err) { falhar(err.message); e.target.disabled = false; }
  });
}

function abrirFormulario(ctx, p) {
  const { sb, produtos, filamentos, fotos, recarregar, catalogo } = ctx;
  const editando = !!p;
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
          <span class="campo-rotulo">Foto</span>
          <div class="foto-escolha">
            <div data-previa>${miniFoto(fotos[p?.foto_path], p?.nome || 'produto', 'previa-foto')}</div>
            <div class="foto-botoes">
              <label class="botao botao-pequeno"><i class="ti ti-photo-plus" aria-hidden="true"></i>
                <span data-texto-foto>${p?.foto_path ? 'Trocar foto' : 'Escolher foto'}</span>
                <input type="file" accept="image/jpeg,image/png,image/webp" hidden data-arquivo></label>
              <button type="button" class="botao-texto" data-tirar-foto ${p?.foto_path ? '' : 'hidden'}>Remover foto</button>
            </div>
          </div>
          <small class="campo-dica">JPEG, PNG ou WebP. Você enquadra a foto em quadrado e ela é reduzida antes de enviar.</small>
        </div>

        <div class="campo"><label for="p-nome">Nome</label>
          <input type="text" id="p-nome" name="nome" maxlength="150" value="${esc(p?.nome || '')}" autocomplete="off" required>
          <small class="campo-dica campo-aviso-nome" data-aviso-nome hidden></small></div>

        <div class="campo"><label for="p-desc">Descrição</label>
          <textarea id="p-desc" name="descricao" rows="3" maxlength="4000">${esc(p?.descricao || '')}</textarea></div>

        <fieldset class="itens-compra">
          <legend>Cores (filamentos do estoque)</legend>
          ${opcoesCor.length ? `<div class="escolha-cores">${opcoesCor.map(f => `
            <label class="opcao-cor"><input type="checkbox" name="cores" value="${f.id}" ${ligadas.has(f.id) ? 'checked' : ''}>
              <span>${esc(f.tipo)} · ${esc(f.variacao)}${f.ativo ? '' : ' (inativo)'}</span></label>`).join('')}</div>`
            : '<p class="campo-dica">Nenhum filamento ativo. Cadastre filamentos em Configurações → Materiais.</p>'}
        </fieldset>

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
                <input type="text" inputmode="decimal" id="p-preco" name="preco" value="${num(p?.preco_venda)}" placeholder="0,00" autocomplete="off"></div>
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
  const previa = dialog.querySelector('[data-previa]');
  const tirar = dialog.querySelector('[data-tirar-foto]');
  const textoFoto = dialog.querySelector('[data-texto-foto]');
  const avisoNome = dialog.querySelector('[data-aviso-nome]');
  let fotoNova = null;           // { blob, ext, tipo, url }
  let tirarFoto = false;

  const falhar = msg => { erro.textContent = msg; erro.hidden = false; };

  // Nome repetido: permitido, só avisa.
  const conferirNome = () => {
    const n = normal(form.elements.nome.value);
    const igual = n && produtos.some(x => x.id !== p?.id && normal(x.nome) === n);
    avisoNome.hidden = !igual;
    avisoNome.textContent = igual ? 'Já existe um produto com este nome. Você pode salvar mesmo assim.' : '';
  };
  form.elements.nome.addEventListener('input', conferirNome);
  conferirNome();

  dialog.querySelector('[data-arquivo]').addEventListener('change', async e => {
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
      if (fotoNova) URL.revokeObjectURL(fotoNova.url);
      fotoNova = { ...reduzida, url: URL.createObjectURL(reduzida.blob) };
      tirarFoto = false;
      previa.innerHTML = `<img class="previa-foto" src="${fotoNova.url}" alt="Prévia da foto">`;
      tirar.hidden = false;
      textoFoto.textContent = 'Trocar foto';
    } catch (err) { falhar(err.message); }
  });
  tirar.addEventListener('click', () => {
    if (fotoNova) URL.revokeObjectURL(fotoNova.url);
    fotoNova = null;
    tirarFoto = true;
    previa.innerHTML = miniFoto(null, '', 'previa-foto');
    tirar.hidden = true;
    textoFoto.textContent = 'Escolher foto';
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
    let dados;
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
    } catch (err) { falhar(err.message); return; }

    const botao = form.querySelector('[type="submit"]');
    const textoBotao = botao.textContent;
    botao.disabled = true; botao.textContent = 'Salvando…';
    let enviada = null;
    try {
      // 1. Foto nova vai primeiro para a pasta, com nome único (nunca sobrescreve).
      if (fotoNova) {
        enviada = `${novoId()}.${fotoNova.ext}`;
        const { error } = await sb.storage.from(PASTA).upload(enviada, fotoNova.blob, {
          contentType: fotoNova.tipo, upsert: false, cacheControl: '3600',
        });
        if (error) { enviada = null; throw new Error('Não foi possível enviar a foto. Verifique a internet e tente de novo.'); }
      }
      dados.p_foto_path = enviada || (tirarFoto ? null : p?.foto_path || null);
      // 2. Produto e cores juntos (tudo ou nada).
      const r = await sb.rpc('salvar_produto', dados).then(ok);
      // 3. A foto que deixou de ser usada é apagada depois de salvar (R73).
      await apagarFoto(sb, r?.foto_anterior);
      let feito = editando ? `"${nome}" foi atualizado.` : `"${nome}" foi cadastrado.`;
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
      fechar();
      await recarregar(feito);
    } catch (err) {
      if (enviada) await apagarFoto(sb, enviada);   // não deixa sobra se o salvamento falhou
      falhar(err.message);
    } finally {
      botao.disabled = false; botao.textContent = textoBotao;
    }
  });

  dialog.addEventListener('close', () => { if (fotoNova) URL.revokeObjectURL(fotoNova.url); });
  form.elements.nome.focus();
}
