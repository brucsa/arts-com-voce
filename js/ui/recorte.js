// Recorte quadrado da foto do produto, com guias (régua) para enquadrar.
// Tudo no navegador: arrastar para posicionar, controle (ou pinça) para aproximar.
// Devolve um Blob JPEG quadrado (até 1.600 px) ou null se a Admin cancelar.
// O resultado segue depois para a otimização de sempre (R73).
import { cliqueForaDoDialogo } from './dialogo.js';

const SAIDA_MAX = 1600;
const ZOOM_MAX = 4;

async function abrir(arquivo) {
  try {
    return await createImageBitmap(arquivo, { imageOrientation: 'from-image' });
  } catch { /* alguns navegadores não aceitam a opção: tenta pelo <img> */ }
  const url = URL.createObjectURL(arquivo);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    return img;
  } catch {
    throw new Error('Não foi possível abrir esta foto. Use uma imagem JPEG, PNG ou WebP (fotos HEIC do iPhone podem não abrir em alguns navegadores).');
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 0);
  }
}

export async function recortarQuadrado(arquivo) {
  const imagem = await abrir(arquivo);
  const W = imagem.naturalWidth || imagem.width;
  const H = imagem.naturalHeight || imagem.height;

  const dialog = document.createElement('dialog');
  dialog.className = 'folha folha-recorte';
  dialog.setAttribute('aria-labelledby', 'rec-titulo');
  dialog.innerHTML = `
    <div class="folha-topo">
      <h2 id="rec-titulo">Enquadrar a foto</h2>
      <button type="button" class="botao-icone" data-cancelar aria-label="Cancelar"><i class="ti ti-x"></i></button>
    </div>
    <p class="campo-dica nota-form">Arraste a foto para posicionar e use o controle para aproximar. Tudo o que estiver dentro do quadrado é o que aparece no catálogo.</p>
    <div class="recorte-area" data-area>
      <canvas class="recorte-tela" data-tela aria-hidden="true"></canvas>
      <div class="recorte-regua" aria-hidden="true"><span></span><span></span><span></span><span></span></div>
    </div>
    <label class="campo recorte-zoom"><span>Aproximar</span>
      <input type="range" min="1" max="${ZOOM_MAX}" step="0.01" value="1" data-zoom aria-label="Aproximar a foto"></label>
    <div class="form-acoes">
      <button type="button" class="botao" data-centralizar>Centralizar</button>
      <span class="espaco"></span>
      <button type="button" class="botao" data-cancelar>Cancelar</button>
      <button type="button" class="botao botao-primario" data-usar>Usar esta foto</button>
    </div>`;
  document.body.appendChild(dialog);

  const area = dialog.querySelector('[data-area]');
  const tela = dialog.querySelector('[data-tela]');
  const ctx = tela.getContext('2d');
  const zoomEl = dialog.querySelector('[data-zoom]');

  // Estado: zoom (1 = foto cobre o quadrado) e centro do recorte, em pixels da foto.
  let zoom = 1, cx = W / 2, cy = H / 2;
  const ladoFonte = () => Math.min(W, H) / zoom;   // lado do quadrado recortado, em pixels da foto
  const prender = () => {
    const m = ladoFonte() / 2;
    cx = Math.min(W - m, Math.max(m, cx));
    cy = Math.min(H - m, Math.max(m, cy));
  };
  const desenhar = () => {
    const S = area.clientWidth || 300;
    const dpr = window.devicePixelRatio || 1;
    if (tela.width !== Math.round(S * dpr)) { tela.width = Math.round(S * dpr); tela.height = tela.width; }
    const l = ladoFonte();
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, tela.width, tela.height);
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(imagem, cx - l / 2, cy - l / 2, l, l, 0, 0, tela.width, tela.height);
  };
  const mudarZoom = z => { zoom = Math.min(ZOOM_MAX, Math.max(1, z)); zoomEl.value = zoom; prender(); desenhar(); };

  // Arrastar (mouse, toque ou caneta) e pinça com dois dedos.
  const ponteiros = new Map();
  let pinca = null;
  area.addEventListener('pointerdown', e => {
    area.setPointerCapture(e.pointerId);
    ponteiros.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (ponteiros.size === 2) {
      const [a, b] = [...ponteiros.values()];
      pinca = { d: Math.hypot(a.x - b.x, a.y - b.y), z: zoom };
    }
  });
  area.addEventListener('pointermove', e => {
    const antes = ponteiros.get(e.pointerId);
    if (!antes) return;
    const agora = { x: e.clientX, y: e.clientY };
    ponteiros.set(e.pointerId, agora);
    if (ponteiros.size === 2 && pinca) {
      const [a, b] = [...ponteiros.values()];
      mudarZoom(pinca.z * Math.hypot(a.x - b.x, a.y - b.y) / (pinca.d || 1));
      return;
    }
    const porPixel = ladoFonte() / (area.clientWidth || 300);
    cx -= (agora.x - antes.x) * porPixel;
    cy -= (agora.y - antes.y) * porPixel;
    prender(); desenhar();
  });
  const soltar = e => { ponteiros.delete(e.pointerId); if (ponteiros.size < 2) pinca = null; };
  area.addEventListener('pointerup', soltar);
  area.addEventListener('pointercancel', soltar);
  area.addEventListener('wheel', e => { e.preventDefault(); mudarZoom(zoom * (e.deltaY < 0 ? 1.08 : 1 / 1.08)); }, { passive: false });
  zoomEl.addEventListener('input', () => mudarZoom(Number(zoomEl.value)));
  // Setas do teclado movem a foto (acessível sem mouse).
  area.tabIndex = 0;
  area.setAttribute('role', 'application');
  area.setAttribute('aria-label', 'Área de enquadramento. Use as setas para mover a foto.');
  area.addEventListener('keydown', e => {
    const passo = ladoFonte() * 0.05;
    const mov = { ArrowLeft: [-passo, 0], ArrowRight: [passo, 0], ArrowUp: [0, -passo], ArrowDown: [0, passo] }[e.key];
    if (!mov) return;
    e.preventDefault(); cx += mov[0]; cy += mov[1]; prender(); desenhar();
  });
  dialog.querySelector('[data-centralizar]').addEventListener('click', () => { cx = W / 2; cy = H / 2; mudarZoom(1); });
  const aoRedimensionar = () => desenhar();
  window.addEventListener('resize', aoRedimensionar);

  return new Promise(resolve => {
    const fechar = valor => {
      window.removeEventListener('resize', aoRedimensionar);
      dialog.close(); dialog.remove(); imagem.close?.();
      resolve(valor);
    };
    dialog.addEventListener('click', e => {
      if (cliqueForaDoDialogo(e, dialog) || e.target.closest('[data-cancelar]')) fechar(null);
    });
    dialog.addEventListener('cancel', e => { e.preventDefault(); fechar(null); });
    dialog.querySelector('[data-usar]').addEventListener('click', async e => {
      e.target.disabled = true;
      const l = ladoFonte();
      const lado = Math.max(1, Math.min(SAIDA_MAX, Math.round(l)));
      const saida = document.createElement('canvas');
      saida.width = lado; saida.height = lado;
      const c2 = saida.getContext('2d');
      c2.fillStyle = '#fff';                       // fundo branco para PNG com transparência
      c2.fillRect(0, 0, lado, lado);
      c2.imageSmoothingQuality = 'high';
      c2.drawImage(imagem, cx - l / 2, cy - l / 2, l, l, 0, 0, lado, lado);
      const blob = await new Promise(r => saida.toBlob(r, 'image/jpeg', 0.95));
      fechar(blob ? new File([blob], 'recorte.jpg', { type: 'image/jpeg' }) : null);
    });
    dialog.showModal();
    requestAnimationFrame(() => { prender(); desenhar(); });
  });
}
