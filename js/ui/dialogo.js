// true quando o clique foi no fundo escurecido, fora da caixa do diálogo.
// (Clicar no espaço interno da própria folha não deve fechá-la.)
export function cliqueForaDoDialogo(e, dialog) {
  if (e.target !== dialog) return false;
  const r = dialog.getBoundingClientRect();
  return e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom;
}
