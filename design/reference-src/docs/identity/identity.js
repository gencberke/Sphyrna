/* ---------- the app icon: the hammerhead seen from above (D-97), drawn once and shown everywhere on the page ---------- */
const iconCanvas = document.createElement('canvas'), layerCanvas = document.createElement('canvas');
function paintIcon() {
  const url = drawAppIcon(iconCanvas, { size: 1024 }).toDataURL('image/png');
  $$('img.appicon').forEach(i => { i.src = url; });
  // The pins follow the drawing: A1 above the upper eye, A2 on the body, A3 in the left margin.
  const k = 420 / 1024, g = iconCanvas.geo, eye = g.eyes.reduce((a, b) => (b.y < a.y ? b : a));
  const pin = (id, x, y) => Object.assign($(id).style, { left: Math.round(x * k - 11) + 'px', top: Math.round(y * k - 9) + 'px' });
  pin('#pinA1', eye.x, eye.y - 56); pin('#pinA2', g.mid.x, g.mid.y); pin('#pinA3', g.box.x0 / 2, 512);
  $('#layerBg').src = drawAppIcon(layerCanvas, { size: 256, layer: 'bg' }).toDataURL('image/png');
  $('#layerFg').src = drawAppIcon(layerCanvas, { size: 512, layer: 'fg' }).toDataURL('image/png');
}
paintIcon();

/* ---------- the menu bar mark: Front, in the desktop, on its grid and at real size in every state ---------- */
const STATES = [['', 'idle'], ['work', 'working'], ['attn', 'needs you'], ['unv', 'finished'], ['fail', 'failed']];
$$('[data-mb]').forEach(el => el.insertAdjacentHTML('afterbegin', markSVG('front', { badge: el.dataset.badge || '', px: +(el.dataset.px || 20) })));
$('#mbRows').innerHTML = `<div class="mbrow hd"><span>bar · size</span>${STATES.map(([, l]) => `<span>${l}</span>`).join('')}</div>`
  + [['dk', 20, 'dark · 20 pt, real'], ['dk', 16, 'dark · 16 pt'], ['lt', 20, 'light · 20 pt, real'], ['lt', 16, 'light · 16 pt']].map(([bar, px, lb]) =>
    `<div class="mbrow ${bar}"><span class="lb">${lb}</span>${STATES.map(([b]) => `<span class="cellm">${markSVG('front', { badge: b, px })}</span>`).join('')}</div>`).join('');
