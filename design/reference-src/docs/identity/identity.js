/* ---------- the app icon: Rising, drawn once and shown everywhere on the page ---------- */
const iconCanvas = document.createElement('canvas'), layerCanvas = document.createElement('canvas');
function paintIcon() {
  const url = drawIcon(iconCanvas, { size: 1024 }).toDataURL('image/png');
  $$('img.appicon').forEach(i => { i.src = url; });
  // The pins follow the drawing: A1 above the upper eye, A2 on the body, A3 in the left margin.
  const k = 420 / 1024, g = iconCanvas.geo, eye = g.eyes.reduce((a, b) => (b.y < a.y ? b : a));
  const pin = (id, x, y) => Object.assign($(id).style, { left: Math.round(x * k - 11) + 'px', top: Math.round(y * k - 9) + 'px' });
  pin('#pinA1', eye.x, eye.y - 56); pin('#pinA2', g.mid.x, g.mid.y); pin('#pinA3', g.box.x0 / 2, 512);
  $('#layerBg').src = drawIcon(layerCanvas, { size: 256, layer: 'bg' }).toDataURL('image/png');
  $('#layerFg').src = drawIcon(layerCanvas, { size: 512, layer: 'fg' }).toDataURL('image/png');
}
paintIcon();

/* ---------- the menu bar mark: Front, in the desktop, on its grid and at real size in every state ---------- */
const STATES = [['', 'idle'], ['work', 'working'], ['attn', 'needs you'], ['unv', 'finished'], ['fail', 'failed']];
$$('[data-mb]').forEach(el => el.insertAdjacentHTML('afterbegin', markSVG('front', { badge: el.dataset.badge || '', px: +(el.dataset.px || 20) })));
$('#mbRows').innerHTML = `<div class="mbrow hd"><span>bar · size</span>${STATES.map(([, l]) => `<span>${l}</span>`).join('')}</div>`
  + [['dk', 20, 'dark · 20 pt, real'], ['dk', 16, 'dark · 16 pt'], ['lt', 20, 'light · 20 pt, real'], ['lt', 16, 'light · 16 pt']].map(([bar, px, lb]) =>
    `<div class="mbrow ${bar}"><span class="lb">${lb}</span>${STATES.map(([b]) => `<span class="cellm">${markSVG('front', { badge: b, px })}</span>`).join('')}</div>`).join('');

/* ---------- the seas ---------- */
const inPlace = (kind, L, cell) => ({ cell, fps: 12, alpha: .72, plankton: 0, wake: false, specs: [{ kind, L, depth: 1, speed: 0, fx: .5, fy: .5, angle: 0, center: true }] });
// A remora rides under its host's flank: its spine is the host's own from behind the pectoral fin back, set off to one
// side by the host's half width there, so it bends with the host and the host's edge is drawn over its inner side.
function ride(host, rider, at, side) {
  const N = Math.round(34 * host.K.ext), sp = host.spine(N), i0 = Math.round(at / host.K.ext * (N - 1));
  const g = side * (host.hw(at) + rider.hw(.22) * .6);
  const pts = sp.slice(i0).map(p => ({ x: p.x - p.ty * g, y: p.y + p.tx * g }));
  rider.x = pts[0].x; rider.y = pts[0].y; rider.trail = pts.slice(1);
}
function withRider(o, at = .34, side = 1) {
  if (!o) return o;
  const [host, rider] = o.sharks, step0 = rider.step.bind(rider), spawn0 = rider.spawn.bind(rider);
  rider.step = (dt, t) => { step0(dt, t); ride(host, rider, at, side); };
  rider.spawn = (init, i) => { spawn0(init, i); ride(host, rider, at, side); };
  ride(host, rider, at, side); o.draw();
  return o;
}
const remoraOf = (L, depth) => ({ kind: 'remora', L, depth, speed: 0, fx: .5, fy: .5, center: true });
// First launch and About: the hammerhead crosses once, right to left as the icon faces, then rests at the left.
// Under Reduce Motion it is drawn at rest at once.
function crossOnce(c, { cell, alpha, L, fy, rest }) {
  if (!c) return;
  const o = new Ocean(c, { cell, alpha, plankton: 10, specs: [{ kind: 'hammerhead', L, depth: 1, speed: 72, fx: 1.3, fy, angle: Math.PI }] });
  const s = o.sharks[0], step0 = s.step.bind(s), spawn0 = s.spawn.bind(s);
  s.spawn = (init, i) => { const still = s.rested || motionReduced(); s.fx = still ? rest : 1.3; s.speed = still ? 0 : 72; spawn0(init, i); };
  s.step = (dt, t) => { step0(dt, t); if (s.speed && s.x < o.w * rest) { s.speed = 0; s.rested = true; } };
  s.spawn(true); o.draw();
}
$$('.aart').forEach(c => crossOnce(c, { cell: 9, alpha: .5, L: 170, fy: .3, rest: .12 }));

document.addEventListener('visibilitychange', () => oceans.forEach(o => o.sync()));
reduceMotion.addEventListener('change', () => oceans.forEach(o => o.sync()));
