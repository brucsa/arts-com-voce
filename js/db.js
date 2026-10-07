// Traduz erros do banco para mensagens que a Bruna entende.

const POR_CODIGO = {
  '23505': 'Já existe um cadastro com esses dados.',
  '23503': 'Este cadastro já foi usado e não pode ser excluído. Desative em vez de excluir.',
  '23514': 'Algum valor está fora do permitido. Confira os campos.',
  '23502': 'Preencha todos os campos obrigatórios.',
  '42501': 'Você não tem permissão para fazer isso.',
};

export function erroAmigavel(erro) {
  if (!erro) return '';
  if (erro.code === 'P0001' && erro.message) return erro.message; // mensagens escritas no próprio banco
  if (POR_CODIGO[erro.code]) return POR_CODIGO[erro.code];
  if (/fetch|network|Failed/i.test(erro.message || '')) {
    return 'Sem conexão com o servidor. Verifique a internet e tente de novo.';
  }
  return 'Não foi possível concluir. Tente de novo em instantes.';
}

/** Lança erro amigável se a resposta do Supabase tiver erro; senão devolve os dados. */
export function ok({ data, error }) {
  if (error) {
    const e = new Error(erroAmigavel(error));
    e.original = error;
    throw e;
  }
  return data;
}
