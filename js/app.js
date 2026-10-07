import { configurado, supabase, problemaConfig } from './supabase.js';
import { GRUPOS, TELAS, BARRA_INFERIOR, ATALHOS } from './menu.js';
import { esc } from './format.js';
import { telaLogin } from './telas/login.js';
import { telaEmConstrucao } from './telas/em-construcao.js';
import { telaInicio } from './telas/inicio.js';
import { telaJocaPessoal } from './telas/joca-pessoal.js';
import { telaConfiguracoes } from './telas/configuracoes.js';

const app = document.getElementById('app');
const estado = { perfil: null, demo: false };

const LOGO = `<img class="logo-marca" src="img/flor.png" alt="" width="36" height="36">`;

const marca = () => `
  <div class="marca">${LOGO}
    <div><strong>Arts com Você</strong><span>Ideias que ganham forma</span></div>
  </div>`;

// ---------------------------------------------------------------- início

async function iniciar() {
  if (!configurado) {
    estado.demo = true;
    const papel = new URLSearchParams(location.search).get('demo') === 'joca' ? 'JOCA' : 'ADMIN';
    estado.perfil = { nome: papel === 'ADMIN' ? 'Bruna' : 'Joca', papel };
    return montar();
  }

  const problema = problemaConfig();
  if (problema) return erroFatal(problema);

  let sb;
  try {
    sb = await supabase();
  } catch {
    return erroFatal('Não foi possível carregar o sistema. Verifique sua internet e recarregue a página.');
  }

  sb.auth.onAuthStateChange(evento => {
    if (evento === 'SIGNED_OUT') location.replace(location.pathname);
  });

  const { data: { session } } = await sb.auth.getSession();
  if (!session) return telaLogin(app, { marca: marca(), aoEntrar: iniciar });

  const { data: perfil, error } = await sb
    .from('perfis')
    .select('nome, papel, ativo')
    .eq('id', session.user.id)
    .maybeSingle();

  if (error) return erroFatal('Não foi possível carregar seu perfil. Tente de novo em instantes.', true);
  if (!perfil || !perfil.ativo) {
    return erroFatal('Seu login funciona, mas ainda não tem acesso ao sistema. Fale com a administradora.', true);
  }

  estado.perfil = perfil;
  montar();
}

function erroFatal(mensagem, comSair = false) {
  app.innerHTML = `
    <div class="tela-centro">
      <div class="cartao cartao-login">
        ${marca()}
        <p class="aviso aviso-erro" role="alert">${esc(mensagem)}</p>
        ${comSair ? '<button class="botao" data-sair>Sair</button>' : ''}
      </div>
    </div>`;
  app.querySelector('[data-sair]')?.addEventListener('click', sair);
}

async function sair() {
  if (estado.demo) return location.replace(location.pathname);
  const sb = await supabase();
  await sb.auth.signOut();
}

// ---------------------------------------------------------------- layout

function montar() {
  if (estado.perfil.papel === 'JOCA') return montarJoca();
  montarAdmin();
}

function bannerDemo() {
  if (!estado.demo) return '';
  const outro = estado.perfil.papel === 'ADMIN'
    ? '<a href="?demo=joca">ver como Joca</a>'
    : '<a href="?">ver como Admin</a>';
  return `<div class="banner-demo" role="status">
    <i class="ti ti-eye" aria-hidden="true"></i>
    Modo demonstração: Supabase ainda não configurado, nada é salvo · ${outro}
  </div>`;
}

function linkTela(t) {
  return `<a class="nav-item" href="#/${t.rota}" data-rota="${t.rota}">
    <i class="ti ${t.icone}" aria-hidden="true"></i><span>${esc(t.titulo)}</span></a>`;
}

function montarAdmin() {
  const nav = GRUPOS.map(g => `
    <div class="nav-grupo">
      <p class="nav-grupo-nome">${esc(g.nome)}</p>
      ${g.telas.map(linkTela).join('')}
    </div>`).join('');

  const barra = BARRA_INFERIOR.map(b => b.rota
    ? `<a class="barra-item" href="#/${b.rota}" data-rota="${b.rota}">
         <i class="ti ${b.icone}" aria-hidden="true"></i><span>${b.titulo}</span></a>`
    : `<button class="barra-item ${b.destaque ? 'barra-destaque' : ''}" data-acao="${b.acao}">
         <i class="ti ${b.icone}" aria-hidden="true"></i><span>${b.titulo}</span></button>`
  ).join('');

  app.innerHTML = `
    ${bannerDemo()}
    <div class="shell">
      <aside class="lateral" aria-label="Menu principal">
        ${marca()}
        <nav class="nav">${nav}</nav>
        <div class="lateral-rodape">
          <span class="usuario"><i class="ti ti-user-circle" aria-hidden="true"></i>${esc(estado.perfil.nome)}</span>
          <button class="botao-texto" data-sair>Sair</button>
        </div>
      </aside>

      <div class="principal">
        <header class="topo">
          <div class="topo-marca">${marca()}</div>
          <h1 class="topo-titulo" id="titulo-tela"></h1>
          <button class="botao botao-primario topo-novo" data-acao="atalhos">
            <i class="ti ti-plus" aria-hidden="true"></i> Novo
          </button>
        </header>
        <main id="conteudo" class="conteudo" tabindex="-1"></main>
      </div>

      <nav class="barra-inferior" aria-label="Navegação rápida">${barra}</nav>
    </div>

    <dialog class="folha" id="folha-atalhos" aria-labelledby="folha-atalhos-titulo">
      <div class="folha-topo">
        <h2 id="folha-atalhos-titulo">Novo</h2>
        <button class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>
      <div class="atalhos">
        ${ATALHOS.map(a => `<a class="atalho" href="#/${a.rota}" data-fechar>
          <i class="ti ${a.icone}" aria-hidden="true"></i><span>${a.titulo}</span></a>`).join('')}
      </div>
    </dialog>

    <dialog class="folha" id="folha-menu" aria-labelledby="folha-menu-titulo">
      <div class="folha-topo">
        <h2 id="folha-menu-titulo">Menu</h2>
        <button class="botao-icone" data-fechar aria-label="Fechar"><i class="ti ti-x"></i></button>
      </div>
      <nav class="nav nav-folha">${nav}</nav>
      <div class="lateral-rodape">
        <span class="usuario"><i class="ti ti-user-circle" aria-hidden="true"></i>${esc(estado.perfil.nome)}</span>
        <button class="botao-texto" data-sair>Sair</button>
      </div>
    </dialog>`;

  app.querySelectorAll('[data-sair]').forEach(b => b.addEventListener('click', sair));
  app.querySelectorAll('[data-acao="atalhos"]').forEach(b =>
    b.addEventListener('click', () => app.querySelector('#folha-atalhos').showModal()));
  app.querySelectorAll('[data-acao="menu"]').forEach(b =>
    b.addEventListener('click', () => app.querySelector('#folha-menu').showModal()));
  app.querySelectorAll('dialog').forEach(d => {
    d.addEventListener('click', e => {
      if (e.target === d || e.target.closest('[data-fechar]') || e.target.closest('a')) d.close();
    });
  });

  window.addEventListener('hashchange', rotearAdmin);
  rotearAdmin();
}

function rotearAdmin() {
  const rota = location.hash.replace(/^#\/?/, '') || 'inicio';
  const tela = TELAS[rota];
  if (!tela) return location.replace('#/inicio');

  app.querySelectorAll('[data-rota]').forEach(a => {
    const ativo = a.dataset.rota === rota;
    a.classList.toggle('ativo', ativo);
    if (ativo) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
  });

  document.title = `${tela.titulo} · Arts com Você`;
  app.querySelector('#titulo-tela').textContent = tela.titulo;
  const conteudo = app.querySelector('#conteudo');

  if (rota === 'inicio') telaInicio(conteudo, { perfil: estado.perfil, tela });
  else if (rota === 'configuracoes') telaConfiguracoes(conteudo);
  else telaEmConstrucao(conteudo, { tela });

  conteudo.focus({ preventScroll: true });
  window.scrollTo(0, 0);
}

// Mantém o endereço do Joca sempre em #/meu, inclusive quando ele chega
// sem rota (logo após o login) ou digita outra rota com a página aberta.
function fixarRotaJoca() {
  if (location.hash !== '#/meu') {
    history.replaceState(null, '', `${location.pathname}${location.search}#/meu`);
  }
}

function montarJoca() {
  // O Joca só tem uma tela. Qualquer outro endereço volta para ela.
  fixarRotaJoca();
  window.addEventListener('hashchange', fixarRotaJoca);
  document.title = 'Joca ⭐ · Arts com Você';

  app.innerHTML = `
    ${bannerDemo()}
    <div class="shell-joca">
      <header class="topo topo-joca">
        ${marca()}
        <button class="botao-texto" data-sair>Sair</button>
      </header>
      <main id="conteudo" class="conteudo conteudo-joca"></main>
    </div>`;

  app.querySelector('[data-sair]').addEventListener('click', sair);
  telaJocaPessoal(app.querySelector('#conteudo'), { perfil: estado.perfil, demo: estado.demo });
}

iniciar();
