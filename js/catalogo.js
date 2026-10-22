// Arts com Você · Catálogo público (R85–R88).
// Página sem login: lê só a função catalogo_publico() e as fotos dos produtos
// marcados (links temporários). Não grava nada no sistema: o pedido vai
// pelo WhatsApp (R87). O carrinho fica só no aparelho do cliente.
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';
import { brl, esc } from './format.js';

const WHATSAPP = '5511940266564';
const CHAVE_CARRINHO = 'arts-catalogo-carrinho';
const QTD_MAX = 99;

const conteudo = document.getElementById('conteudo');
const contadorEl = document.querySelector('[data-contador]');

let produtos = [];          // { id, nome, descricao, preco, sob_consulta, foto_path, foto, fotos? }
let cliente = null;         // cliente do Supabase (visitante), guardado para buscar as outras fotos
// Cores: por enquanto não aparecem nem são escolhidas; ficam "a consultar" (R86).
let carregado = false;
let busca = '';
let carrinho = lerCarrinho(); // [{ id, qtd }]
let aviso = '';              // "… foi adicionado ao carrinho", mostrado uma vez na vitrine
let dados = { nome: '', tel: '', obs: '' };
let escolha = { id: null, qtd: 1 };

// ------------------------------------------------------------ carrinho no aparelho
function lerCarrinho() {
  try {
    const lista = JSON.parse(localStorage.getItem(CHAVE_CARRINHO) || '[]');
    return Array.isArray(lista) ? lista.filter(i => i && typeof i.id === 'string' && Number.isInteger(i.qtd) && i.qtd > 0) : [];
  } catch { return []; }
}
function guardarCarrinho() {
  try { localStorage.setItem(CHAVE_CARRINHO, JSON.stringify(carrinho)); } catch { /* sem armazenamento: fica só na memória */ }
  atualizarContador();
}
// Itens de produtos que saíram do catálogo são retirados; o mesmo produto fica numa linha só.
function limparCarrinho() {
  const juntos = new Map();
  carrinho.filter(i => achar(i.id)).forEach(i => juntos.set(i.id, Math.min(QTD_MAX, (juntos.get(i.id) || 0) + i.qtd)));
  carrinho = [...juntos].map(([id, qtd]) => ({ id, qtd }));
  guardarCarrinho();
}
const qtdTotal = () => carrinho.reduce((s, i) => s + i.qtd, 0);
function atualizarContador() {
  const n = qtdTotal();
  contadorEl.hidden = n === 0;
  contadorEl.textContent = n > QTD_MAX ? `${QTD_MAX}+` : String(n);
  contadorEl.parentElement.setAttribute('aria-label', n ? `Abrir carrinho, ${n} ${n === 1 ? 'item' : 'itens'}` : 'Abrir carrinho');
}

// ------------------------------------------------------------ dados
const achar = id => produtos.find(p => p.id === id);
const centavos = v => Math.round(Number(v) * 100);
const precoTexto = p => (p.sob_consulta ? 'Sob consulta' : brl(p.preco));
// Telefone com DDD: 10 ou 11 dígitos (aceita +55 na frente). Devolve só os dígitos, ou null.
function telDigitos(t) {
  let d = String(t || '').replace(/\D/g, '');
  if (d.length > 11 && d.startsWith('55')) d = d.slice(2);
  return /^[1-9]{2}\d{8,9}$/.test(d) ? d : null;
}
const telTexto = d => (d.length === 11 ? `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}` : `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}`);
const normal = t => String(t || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();

async function carregar() {
  const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm');
  // Cliente sem sessão: o catálogo é sempre visto como visitante.
  const sb = createClient(SUPABASE_URL.trim().replace(/\/$/, ''), SUPABASE_ANON_KEY.trim(), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  cliente = sb;
  const { data, error } = await sb.rpc('catalogo_publico');
  if (error) throw error;
  produtos = (data || []).map(({ cores, ...p }) => ({ ...p, foto: null }));
  const caminhos = produtos.map(p => p.foto_path).filter(Boolean);
  if (caminhos.length) {
    const r = await sb.storage.from('produtos').createSignedUrls(caminhos, 3600);
    const links = Object.fromEntries((r.data || []).filter(d => d.signedUrl).map(d => [d.path, d.signedUrl]));
    produtos.forEach(p => { p.foto = links[p.foto_path] || null; });
  }
  carregado = true;
  limparCarrinho();
}

// ------------------------------------------------------------ pedaços de tela
function foto(p, alt = true) {
  return p.foto
    ? `<img src="${esc(p.foto)}" alt="${alt ? `Foto de ${esc(p.nome)}` : ''}" loading="lazy">`
    : '<div class="sem-foto"><img src="img/flor.png" alt=""></div>';
}

/**
 * Todas as fotos do produto, na ordem (capa primeiro), até 5 (R73, R117 v1.12).
 * Antes do sql/20 a função não existe: fica só a capa.
 */
async function carregarFotos(p) {
  if (p.fotos) return p.fotos;
  p.fotos = p.foto ? [p.foto] : [];
  try {
    const { data, error } = await cliente.rpc('catalogo_fotos', { p_produto_id: p.id });
    if (error || !data || data.length < 2) return p.fotos;
    const caminhos = data.map(f => f.foto_path);
    const r = await cliente.storage.from('produtos').createSignedUrls(caminhos, 3600);
    const links = Object.fromEntries((r.data || []).filter(d => d.signedUrl).map(d => [d.path, d.signedUrl]));
    const urls = caminhos.map(c => links[c]).filter(Boolean);
    if (urls.length) p.fotos = urls;
  } catch { /* fica só a capa */ }
  return p.fotos;
}

/** Fotos do produto para passar com o dedo (ou com as setas no computador). */
function carrossel(p, urls) {
  if (urls.length < 2) return foto(p);
  return `<div class="carrossel" role="region" aria-roledescription="carrossel" aria-label="Fotos de ${esc(p.nome)}">
    <div class="carrossel-trilho" tabindex="0" data-trilho>
      ${urls.map((u, i) => `<div class="carrossel-slide" role="group" aria-roledescription="foto" aria-label="${i + 1} de ${urls.length}">
        <img src="${esc(u)}" alt="Foto ${i + 1} de ${esc(p.nome)}" ${i ? 'loading="lazy"' : ''}></div>`).join('')}
    </div>
    <button type="button" class="carrossel-seta carrossel-ant" data-seta="-1" aria-label="Foto anterior" disabled>‹</button>
    <button type="button" class="carrossel-seta carrossel-prox" data-seta="1" aria-label="Próxima foto">›</button>
    <div class="carrossel-pontos" aria-hidden="true">${urls.map((_, i) => `<span class="${i ? '' : 'ativo'}"></span>`).join('')}</div>
  </div>`;
}

function ligarCarrossel(el) {
  const trilho = el.querySelector('[data-trilho]');
  if (!trilho) return;
  const pontos = [...el.querySelectorAll('.carrossel-pontos span')];
  const [ant, prox] = [el.querySelector('[data-seta="-1"]'), el.querySelector('[data-seta="1"]')];
  const atual = () => Math.round(trilho.scrollLeft / Math.max(trilho.clientWidth, 1));
  const marcar = () => {
    const i = atual();
    pontos.forEach((p, k) => p.classList.toggle('ativo', k === i));
    ant.disabled = i <= 0; prox.disabled = i >= pontos.length - 1;
  };
  trilho.addEventListener('scroll', () => requestAnimationFrame(marcar), { passive: true });
  el.querySelectorAll('[data-seta]').forEach(b => b.addEventListener('click', () => {
    trilho.scrollTo({ left: (atual() + Number(b.dataset.seta)) * trilho.clientWidth, behavior: 'smooth' });
  }));
}

/** 150 → "2 h 30 min"; 45 → "45 min" (R85 v1.13). */
function tempoTexto(min) {
  const n = Number(min);
  const h = Math.floor(n / 60), m = n % 60;
  return [h ? `${h} h` : '', m ? `${m} min` : ''].filter(Boolean).join(' ');
}

function linhaTotal() {
  let total = 0, consulta = false;
  carrinho.forEach(i => {
    const p = achar(i.id);
    if (p.sob_consulta) consulta = true; else total += centavos(p.preco) * i.qtd;
  });
  const soConsulta = consulta && total === 0;
  return { totalTexto: soConsulta ? 'A combinar' : brl(total / 100), consulta, soConsulta };
}

function mensagem() {
  const { totalTexto, consulta, soConsulta } = linhaTotal();
  const linhas = ['*Pedido pelo Catálogo Arts com Você*', `Nome: ${dados.nome.trim()}`, `Telefone: ${telTexto(telDigitos(dados.tel))}`, '', '*Itens do pedido:*'];
  carrinho.forEach(i => {
    const p = achar(i.id);
    linhas.push(`• ${p.nome} x${i.qtd} — ${p.sob_consulta ? 'sob consulta' : brl(centavos(p.preco) * i.qtd / 100)}`);
  });
  linhas.push('Cores: a consultar');
  linhas.push('', `*Total: ${totalTexto}*${consulta && !soConsulta ? ' + itens sob consulta' : ''}`);
  if (dados.obs.trim()) linhas.push('', `Observação: ${dados.obs.trim()}`);
  return linhas.join('\n').replace(/ /g, ' ');
}

// ------------------------------------------------------------ telas
function telaVitrine() {
  conteudo.innerHTML = `
    <section class="chamada">
      <h1>Gostou? É só adicionar! 🛍️</h1>
      <p>Escolha seus favoritos, coloque no carrinho e envie seu pedido pelo WhatsApp. 💛</p>
    </section>
    <label class="busca">
      <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"/><path d="M20 20l-3.5-3.5"/></svg>
      <span class="so-leitor">Buscar produto</span>
      <input type="search" data-busca placeholder="Buscar produto" value="${esc(busca)}" autocomplete="off">
    </label>
    ${aviso ? `<p class="aviso-adicionado" role="status">${esc(aviso)} <a href="#/carrinho">Ver carrinho</a></p>` : ''}
    <div class="grade" data-grade></div>
    <p class="vazio" data-vazio hidden></p>`;
  aviso = '';
  const grade = conteudo.querySelector('[data-grade]');
  const vazio = conteudo.querySelector('[data-vazio]');
  const desenhar = () => {
    const termo = normal(busca);
    const lista = produtos.filter(p => !termo || normal(p.nome).includes(termo));
    grade.innerHTML = lista.map(p => `
      <article class="cartao">
        <a class="cartao-foto" href="#/produto/${p.id}" tabindex="-1" aria-hidden="true">${foto(p, false)}</a>
        <div class="cartao-corpo">
          <h2 class="cartao-nome"><a href="#/produto/${p.id}">${esc(p.nome)}</a></h2>
          <span class="espaco"></span>
          <span class="preco ${p.sob_consulta ? 'preco-consulta' : ''}">${precoTexto(p)}</span>
          <a class="botao" href="#/produto/${p.id}" aria-label="Adicionar ${esc(p.nome)}">+ Adicionar</a>
        </div>
      </article>`).join('');
    vazio.hidden = lista.length > 0;
    vazio.textContent = produtos.length ? 'Nenhum produto com esse nome.' : 'Novidades em breve! Fale com a gente pelo WhatsApp.';
  };
  conteudo.querySelector('[data-busca]').addEventListener('input', e => { busca = e.target.value; desenhar(); });
  desenhar();
}

function telaProduto(id) {
  const p = achar(id);
  if (!p) { location.replace('#/'); return; }
  if (escolha.id !== id) escolha = { id, qtd: 1 };
  conteudo.innerHTML = `
    <a class="botao botao-texto voltar" href="#/">‹ Voltar para o catálogo</a>
    <div class="detalhe">
      <div class="detalhe-foto" data-fotos>${carrossel(p, p.fotos || [])}</div>
      <form class="detalhe-dados" data-form novalidate>
        <div>
          <h1>${esc(p.nome)}</h1>
          <span class="preco ${p.sob_consulta ? 'preco-consulta' : ''}">${precoTexto(p)}</span>
        </div>
        ${p.sob_consulta ? '<p class="aviso-consulta">O valor desta peça é combinado na conversa pelo WhatsApp.</p>' : ''}
        ${p.descricao ? `<p class="descricao">${esc(p.descricao)}</p>` : ''}
        ${p.tempo_impressao_min ? `<p class="tempo-impressao"><strong>Tempo de impressão:</strong> ${tempoTexto(p.tempo_impressao_min)}</p>` : ''}
        <p class="cores-detalhe"><strong>Cores:</strong> a consultar. Combinamos a cor com você pelo WhatsApp.</p>
        <div class="quantidade-linha">
          <span id="rot-qtd">Quantidade</span>
          <div class="contador-qtd" role="group" aria-labelledby="rot-qtd">
            <button type="button" data-menos aria-label="Diminuir quantidade">−</button>
            <output data-qtd aria-live="polite">${escolha.qtd}</output>
            <button type="button" data-mais aria-label="Aumentar quantidade">+</button>
          </div>
        </div>
        <div class="pilha">
          <button type="submit" class="botao botao-cheio" value="comprar">Enviar pedido</button>
          <button type="submit" class="botao botao-borda" value="mais">Adicionar mais itens</button>
        </div>
      </form>
    </div>`;
  const fotosEl = conteudo.querySelector('[data-fotos]');
  ligarCarrossel(fotosEl);
  // As outras fotos chegam depois da página aberta (a capa já aparece).
  if (!p.fotos) carregarFotos(p).then(urls => {
    if (urls.length > 1 && fotosEl.isConnected) { fotosEl.innerHTML = carrossel(p, urls); ligarCarrossel(fotosEl); }
  });
  const form = conteudo.querySelector('[data-form]');
  const saida = form.querySelector('[data-qtd]');
  const menos = form.querySelector('[data-menos]');
  const mais = form.querySelector('[data-mais]');
  const mostrarQtd = () => { saida.textContent = escolha.qtd; menos.disabled = escolha.qtd <= 1; mais.disabled = escolha.qtd >= QTD_MAX; };
  menos.addEventListener('click', () => { escolha.qtd = Math.max(1, escolha.qtd - 1); mostrarQtd(); });
  mais.addEventListener('click', () => { escolha.qtd = Math.min(QTD_MAX, escolha.qtd + 1); mostrarQtd(); });
  form.addEventListener('submit', e => {
    e.preventDefault();
    const igual = carrinho.find(i => i.id === p.id);
    if (igual) igual.qtd = Math.min(QTD_MAX, igual.qtd + escolha.qtd);
    else carrinho.push({ id: p.id, qtd: escolha.qtd });
    const qtd = escolha.qtd;
    escolha = { id: null, qtd: 1 };
    guardarCarrinho();
    // "Enviar pedido" vai para o carrinho (nome, telefone e envio); "Adicionar mais itens" volta para a vitrine.
    if (e.submitter?.value === 'mais') {
      aviso = `${qtd > 1 ? `${qtd}× ` : ''}${p.nome} foi adicionado ao carrinho.`;
      location.hash = '#/';
    } else location.hash = '#/carrinho';
  });
  mostrarQtd();
}

function telaCarrinho() {
  if (!carrinho.length) {
    conteudo.innerHTML = `
      <h1 class="titulo">Seu carrinho</h1>
      <div class="resumo erro-carga"><p class="ajuda">O carrinho está vazio.</p>
        <a class="botao" href="#/">Ver produtos</a></div>`;
    return;
  }
  const { totalTexto, consulta } = linhaTotal();
  conteudo.innerHTML = `
    <h1 class="titulo">Seu carrinho</h1>
    <ul class="lista-itens">${carrinho.map((i, n) => {
      const p = achar(i.id);
      return `<li class="item">
        <div class="item-foto">${foto(p, false)}</div>
        <div>
          <div class="item-nome">${esc(p.nome)}</div>
          <div class="item-cor">Cores a consultar</div>
          <div class="preco ${p.sob_consulta ? 'preco-consulta' : ''}">${p.sob_consulta ? 'Sob consulta' : brl(centavos(p.preco) * i.qtd / 100)}</div>
        </div>
        <div class="contador-qtd" role="group" aria-label="Quantidade de ${esc(p.nome)}">
          <button type="button" data-menos="${n}" aria-label="${i.qtd === 1 ? 'Tirar' : 'Diminuir'} ${esc(p.nome)}">${i.qtd === 1 ? '×' : '−'}</button>
          <output>${i.qtd}</output>
          <button type="button" data-mais="${n}" aria-label="Aumentar ${esc(p.nome)}" ${i.qtd >= QTD_MAX ? 'disabled' : ''}>+</button>
        </div>
      </li>`;
    }).join('')}</ul>
    <a class="botao botao-borda botao-mais-itens" href="#/">+ Adicionar mais itens</a>
    <div class="resumo">
      <div class="resumo-total"><span>Total</span><span>${totalTexto}</span></div>
      ${consulta ? '<small class="nota-consulta">Peça(s) sob consulta: o valor é combinado no WhatsApp.</small>' : ''}
      <small>Entrega e pagamento são combinados na conversa.</small>
    </div>
    <form class="campos" data-form novalidate>
      <label class="campo" for="c-nome">Seu nome
        <input id="c-nome" name="nome" type="text" autocomplete="name" maxlength="80" placeholder="Como podemos te chamar?" value="${esc(dados.nome)}" aria-describedby="c-nome-erro">
        <span class="campo-erro" id="c-nome-erro" data-erro="nome" hidden>Preencha seu nome para enviar.</span>
      </label>
      <label class="campo" for="c-tel">Seu telefone (com DDD)
        <input id="c-tel" name="tel" type="tel" inputmode="tel" autocomplete="tel" maxlength="20" placeholder="(11) 91234-5678" value="${esc(dados.tel)}" aria-describedby="c-tel-erro">
        <span class="campo-erro" id="c-tel-erro" data-erro="tel" hidden>Informe um telefone com DDD, por exemplo (11) 91234-5678.</span>
      </label>
      <label class="campo" for="c-obs">Observação (opcional)
        <textarea id="c-obs" name="obs" maxlength="500" placeholder="Ex.: nome para gravar, data da festa">${esc(dados.obs)}</textarea>
      </label>
      <button type="submit" class="botao botao-whats">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20l1.3-4A8 8 0 1 1 8.6 19z"/></svg>
        Enviar pedido pelo WhatsApp</button>
    </form>`;
  conteudo.querySelector('.lista-itens').addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    if (b.dataset.mais != null) { const i = carrinho[+b.dataset.mais]; i.qtd = Math.min(QTD_MAX, i.qtd + 1); }
    if (b.dataset.menos != null) {
      const n = +b.dataset.menos;
      carrinho[n].qtd -= 1;
      if (carrinho[n].qtd <= 0) carrinho.splice(n, 1);
    }
    guardarCarrinho();
    telaCarrinho();
  });
  const form = conteudo.querySelector('[data-form]');
  const valido = { nome: () => !!dados.nome.trim(), tel: () => !!telDigitos(dados.tel) };
  const marcar = (campo, ok) => {
    form.querySelector(`[data-erro="${campo}"]`).hidden = ok;
    if (ok) form.elements[campo].removeAttribute('aria-invalid'); else form.elements[campo].setAttribute('aria-invalid', 'true');
  };
  form.addEventListener('input', e => {
    if (e.target.name in dados) dados[e.target.name] = e.target.value;
    if (e.target.name in valido && valido[e.target.name]()) marcar(e.target.name, true);
  });
  form.elements.tel.addEventListener('blur', () => {
    const d = telDigitos(dados.tel);
    if (d) { dados.tel = telTexto(d); form.elements.tel.value = dados.tel; }
  });
  form.addEventListener('submit', e => {
    e.preventDefault();
    const ruins = ['nome', 'tel'].filter(c => !valido[c]());
    ['nome', 'tel'].forEach(c => marcar(c, !ruins.includes(c)));
    if (ruins.length) { form.elements[ruins[0]].focus(); return; }
    location.hash = '#/enviar';
  });
}

function telaEnviar() {
  if (!carrinho.length || !dados.nome.trim() || !telDigitos(dados.tel)) { location.replace('#/carrinho'); return; }
  const texto = mensagem();
  conteudo.innerHTML = `
    <h1 class="titulo">Mensagem pronta</h1>
    <p class="ajuda">Toque no botão para abrir o WhatsApp da Arts com Você, (11) 94026-6564, com este texto. É só enviar.</p>
    <div class="mensagem-caixa"><div class="mensagem-balao" data-texto></div></div>
    <div class="pilha">
      <a class="botao botao-whats" href="https://wa.me/${WHATSAPP}?text=${encodeURIComponent(texto)}" target="_blank" rel="noopener">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20l1.3-4A8 8 0 1 1 8.6 19z"/></svg>
        Abrir no WhatsApp</a>
      <a class="botao botao-texto" href="#/carrinho">Voltar e alterar</a>
    </div>`;
  conteudo.querySelector('[data-texto]').textContent = texto;
}

function telaErro() {
  conteudo.innerHTML = `
    <div class="erro-carga">
      <p class="ajuda">Não foi possível carregar o catálogo agora. Verifique a internet e tente de novo.</p>
      <button type="button" class="botao" data-tentar>Tentar de novo</button>
      <a class="botao botao-texto" href="https://wa.me/${WHATSAPP}" target="_blank" rel="noopener">Falar pelo WhatsApp</a>
    </div>`;
  conteudo.querySelector('[data-tentar]').addEventListener('click', iniciar);
}

// ------------------------------------------------------------ rotas
function rotear() {
  if (!carregado) return;
  const h = location.hash.replace(/^#\/?/, '');
  const [tela, id] = h.split('/');
  const nav = tela === 'carrinho' || tela === 'enviar' ? 'carrinho' : 'vitrine';
  document.querySelectorAll('[data-nav]').forEach(a => {
    if (a.dataset.nav === nav) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  });
  if (tela === 'produto') telaProduto(id);
  else if (tela === 'carrinho') telaCarrinho();
  else if (tela === 'enviar') telaEnviar();
  else telaVitrine();
  window.scrollTo(0, 0);
}

async function iniciar() {
  conteudo.innerHTML = '<p class="carregando">Carregando o catálogo…</p>';
  try {
    await carregar();
    rotear();
  } catch {
    telaErro();
  }
}

window.addEventListener('hashchange', () => { rotear(); conteudo.focus({ preventScroll: true }); });
atualizarContador();
iniciar();
