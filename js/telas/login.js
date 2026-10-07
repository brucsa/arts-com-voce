import { supabase } from '../supabase.js';

const MENSAGENS = {
  'Invalid login credentials': 'E-mail ou senha incorretos.',
  'Email not confirmed': 'Este e-mail ainda não foi confirmado.',
};

export function telaLogin(app, { marca, aoEntrar }) {
  document.title = 'Entrar · Arts com Você';
  app.innerHTML = `
    <div class="tela-centro">
      <form class="cartao cartao-login" novalidate>
        ${marca}
        <h1 class="login-titulo">Entrar</h1>
        <label class="campo">
          <span>E-mail</span>
          <input type="email" name="email" autocomplete="username" required placeholder="voce@email.com">
        </label>
        <label class="campo">
          <span>Senha</span>
          <input type="password" name="senha" autocomplete="current-password" required>
        </label>
        <p class="aviso aviso-erro" role="alert" hidden></p>
        <button class="botao botao-primario botao-largo" type="submit">Entrar</button>
      </form>
    </div>`;

  const form = app.querySelector('form');
  const erro = form.querySelector('.aviso-erro');
  const botao = form.querySelector('button');
  const mostrarErro = texto => { erro.textContent = texto; erro.hidden = !texto; };
  form.addEventListener('input', () => mostrarErro(''));

  form.addEventListener('submit', async e => {
    e.preventDefault();
    const email = form.email.value.trim();
    const senha = form.senha.value;
    if (!email || !senha) return mostrarErro('Preencha e-mail e senha.');

    botao.disabled = true;
    botao.textContent = 'Entrando…';
    try {
      const sb = await supabase();
      const { error } = await sb.auth.signInWithPassword({ email, password: senha });
      if (error) {
        mostrarErro(MENSAGENS[error.message] || 'Não foi possível entrar. Tente de novo.');
        return;
      }
      aoEntrar();
    } catch {
      mostrarErro('Sem conexão. Verifique a internet e tente de novo.');
    } finally {
      botao.disabled = false;
      botao.textContent = 'Entrar';
    }
  });

  form.email.focus();
}
