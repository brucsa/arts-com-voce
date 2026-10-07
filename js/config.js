// Configuração do Supabase.
// Supabase → botão "Connect" no topo do projeto (ou Project Settings → API Keys):
//   Project URL                          → SUPABASE_URL
//   Publishable key (sb_publishable_…)   → SUPABASE_ANON_KEY
//   (em projetos antigos: a "anon public" key, que começa com eyJ…)
//
// A chave pública pode ficar no site: quem protege os dados são as regras
// de RLS do banco. NUNCA coloque aqui a Secret key (sb_secret_…) nem a
// "service_role". O sistema recusa essas chaves se forem coladas aqui.
//
// Enquanto estes valores não forem preenchidos, o sistema abre em
// modo demonstração (só visual, nada é salvo).

export const SUPABASE_URL = 'https://formtvfdrrrtiixywhey.supabase.co';
export const SUPABASE_ANON_KEY = 'sb_publishable_AmlELM3NKCcHDE8M7Ktl1A_Btkr5LYk';
