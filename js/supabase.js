import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

// Enquanto os valores de exemplo estiverem em config.js, o sistema abre em modo demonstração.
export const configurado = !SUPABASE_URL.startsWith('COLE_AQUI') || !SUPABASE_ANON_KEY.startsWith('COLE_AQUI');

/**
 * Classifica a chave colocada em config.js.
 *  - 'publica'  → chave que pode ficar no site (publishable "sb_publishable_…" ou JWT "anon")
 *  - 'secreta'  → chave que NUNCA pode ficar no site ("sb_secret_…" ou JWT "service_role")
 *  - 'invalida' → qualquer outra coisa
 */
export function tipoChave(chave) {
  const k = String(chave || '').trim();
  if (k.startsWith('sb_secret_')) return 'secreta';
  if (k.startsWith('sb_publishable_')) return 'publica';
  const partes = k.split('.');
  if (partes.length === 3) {
    try {
      const b64 = partes[1].replace(/-/g, '+').replace(/_/g, '/');
      const { role } = JSON.parse(atob(b64 + '='.repeat((4 - (b64.length % 4)) % 4)));
      if (role === 'anon') return 'publica';
      if (role === 'service_role') return 'secreta';
    } catch { /* cai em inválida */ }
  }
  return 'invalida';
}

/** Devolve uma mensagem de erro de configuração, ou null se estiver tudo certo. */
export function problemaConfig() {
  if (!configurado) return null;
  if (!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/i.test(SUPABASE_URL.trim())) {
    return 'O endereço do Supabase em js/config.js não parece certo. Ele deve ser como https://xxxx.supabase.co';
  }
  const tipo = tipoChave(SUPABASE_ANON_KEY);
  if (tipo === 'secreta') {
    return 'A chave em js/config.js é a chave SECRETA do Supabase. Ela não pode ficar no site. ' +
      'Troque pela chave pública (Publishable ou anon) e gere uma nova chave secreta no Supabase.';
  }
  if (tipo === 'invalida') {
    return 'A chave em js/config.js não foi reconhecida. Use a Publishable key (sb_publishable_…) ou a anon key.';
  }
  return null;
}

let cliente = null;

export async function supabase() {
  if (!configurado) throw new Error('Supabase não configurado.');
  const problema = problemaConfig();
  if (problema) throw new Error(problema);
  if (!cliente) {
    const { createClient } = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm');
    cliente = createClient(SUPABASE_URL.trim().replace(/\/$/, ''), SUPABASE_ANON_KEY.trim(), {
      auth: { persistSession: true, autoRefreshToken: true },
    });
  }
  return cliente;
}
