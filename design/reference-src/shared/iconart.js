/* ---------- Rising, the app icon until D-97, drawn by the art engine ----------
   A still hammerhead in a square: the engine's own field, ramp and eyes. Only the pose is set here:
   where the head is, which way it faces, how much the body bends, and the cell size. The glyphs are
   bold, so they keep their light when macOS scales the icon down to 32 and 16. The app icon is now
   drawAppIcon (below); Rising stays as art and for design/identity/candidates/. */
const ICON_POSES = {
  // Round 2, the user's pick: Rising, a little smaller, centred on its outline, and whiter.
  rising:  { name: 'Rising', L: .7, x: .11, y: .36, heading: Math.PI + .35, bend: .3, phase: 1.6, cell: 15, alpha: 1.75, ink: '246,246,248', weight: 700, center: true },
  // Round 1, kept for the comparison.
  rising1: { name: 'Rising, round 1', L: .8, x: .11, y: .36, heading: Math.PI + .35, bend: .3, phase: 1.6, cell: 15, alpha: 1.35, ink: '236,236,240', weight: 700 }
};
// A trail along a gentle arc behind the head, so the still body curves as if it were turning.
function poseShark(s, x, y, heading, bend) {
  s.x = x; s.y = y; s.heading = heading; s.trail = [];
  const d = 4, n = Math.ceil(s.L * s.K.reach / d);
  let px = x, py = y, a = heading;
  for (let k = 0; k <= n; k++) {
    s.trail.push({ x: px, y: py });
    a += bend * d / s.L;
    px -= Math.cos(a) * d; py -= Math.sin(a) * d;
  }
}
// An Ocean with a fixed pixel size (square unless h is given) and no observers or timers: the engine's stamp and draw, nothing else.
function stillOcean(canvas, size, cell, ink, alpha, weight = 400, h = size) {
  const o = Object.create(Ocean.prototype);
  canvas.width = size; canvas.height = h;
  Object.assign(o, { c: canvas, ctx: canvas.getContext('2d'), w: size, h, ink, wake: [], plankton: [], sharks: [], t: 0,
    opt: { cell, fps: 0, alpha, specs: [], wake: false, plankton: 0, still: true } });
  o.f = document.createElement('canvas'); o.fx = o.f.getContext('2d', { willReadFrequently: true });
  const ctx = o.ctx; ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.font = `${weight} ${cell}px ${MONO}`; ctx.textBaseline = 'top';
  o.cw = ctx.measureText('M').width || cell * .6; o.ch = Math.round(cell * 1.22);
  o.cols = Math.ceil(size / o.cw) + 1; o.rows = Math.ceil(h / o.ch) + 1;
  o.f.width = o.cols; o.f.height = o.rows;
  o.code = new Uint8Array(o.cols * o.rows); o.alpha = new Float32Array(o.cols * o.rows);
  return o;
}
// layer: 'full' (the black square with the shark), 'fg' (the glyphs alone, for Icon Composer's foreground) or 'bg'.
function drawIcon(canvas, { size = 1024, pose = 'rising', facing = 'left', ground = 'black', layer = 'full', tune = {} } = {}) {
  const P = Object.assign({ alpha: 1 }, ICON_POSES[pose], tune), cell = P.cell * size / 1024;
  const o = stillOcean(canvas, size, cell, P.ink || '236,236,240', P.alpha, P.weight);
  const s = new Shark(o, { kind: 'hammerhead', L: P.L * size, depth: 1, speed: 0, fx: .5, fy: .5 }, 0);
  s.phase = P.phase;
  const left = facing === 'left', heading = left ? P.heading : Math.PI - P.heading, bend = left ? P.bend : -P.bend;
  let hx = (left ? P.x : 1 - P.x) * size, hy = P.y * size;
  poseShark(s, hx, hy, heading, bend);
  // Centred: the outline's box (hammer, fins and tail) moves to the middle of the square.
  if (P.center) { const b = s.geometry().box; hx += size / 2 - (b.x0 + b.x1) / 2; hy += size / 2 - (b.y0 + b.y1) / 2; poseShark(s, hx, hy, heading, bend); }
  // Kept for the page's pins: the eyes, the outline's box and a point on the body.
  const g = s.geometry(); canvas.geo = { eyes: g.eyes, box: g.box, mid: s.spine(34)[11] };
  if (layer !== 'bg') { o.sharks = [s]; o.draw(); } else o.ctx.clearRect(0, 0, size, size);
  if (layer === 'fg') return canvas;
  const ctx = o.ctx;
  ctx.save(); ctx.globalCompositeOperation = 'destination-over';
  if (ground === 'grid') {
    const step = size / 16, lw = Math.max(1, size / 512);
    ctx.fillStyle = 'rgba(255,255,255,.06)';
    for (let k = 1; k < 16; k++) { const p = Math.round(k * step); ctx.fillRect(p, 0, lw, size); ctx.fillRect(0, p, size, lw); }
  }
  ctx.fillStyle = '#000'; ctx.fillRect(0, 0, size, size);
  ctx.restore();
  return canvas;
}

/* ---------- the app icon (D-97): the hammerhead seen from above ----------
   The engine's outline (body, hammer, fins and tail from Shark.geometry()), filled solid near-white and climbing to
   the left at Rising's angle, on a deep ink-blue gradient. The hammer is drawn 1.3 times its art size and a stroke of
   the same white thickens the body, so both hold at 32 px; the eyes are holes at the hammer's tips. The outline's box
   is `fit` of the square on its longer side, centred, so the hammer stays clear of the rounded corners. This is
   design/identity/icon/layers.html's drawing, the source of assets/icon/; keep the two the same. */
const APP_ICON = { ground: ['#1D2445', '#0B0E1D'], ink: '246,246,248',
  heading: Math.PI + .35, bend: .3, phase: 1.6, fit: .76, hammer: 1.3, bold: 22, eye: .014 };
// layer: 'full' (the ground and the shark), 'fg' (the shark alone, on transparency) or 'bg' (the ground alone).
function drawAppIcon(canvas, { size = 1024, layer = 'full' } = {}) {
  const P = APP_ICON, k = size / 1024;
  // The engine's outline at length L (a share of the square), with the hammer and the eyes grown about the head.
  const outline = L => {
    const o = stillOcean(canvas, size, 15 * k, P.ink, 1, 700);
    const s = new Shark(o, { kind: 'hammerhead', L: L * size, depth: 1, speed: 0, fx: .5, fy: .5 }, 0);
    s.phase = P.phase;
    poseShark(s, size / 2, size / 2, P.heading, P.bend);
    const g = s.geometry(), h = s.spine(34)[0], grow = q => ({ x: h.x + (q.x - h.x) * P.hammer, y: h.y + (q.y - h.y) * P.hammer });
    g.shapes[1] = g.shapes[1].map(grow); g.eyes = g.eyes.map(grow); g.mid = s.spine(34)[11];
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const poly of g.shapes) for (const q of poly) { x0 = Math.min(x0, q.x); y0 = Math.min(y0, q.y); x1 = Math.max(x1, q.x); y1 = Math.max(y1, q.y); }
    return Object.assign(g, { x0, y0, x1, y1 });
  };
  let L = .62, g = outline(L);
  L *= P.fit * size / Math.max(g.x1 - g.x0, g.y1 - g.y0); g = outline(L);
  const dx = size / 2 - (g.x0 + g.x1) / 2, dy = size / 2 - (g.y0 + g.y1) / 2, at = q => ({ x: q.x + dx, y: q.y + dy });
  // Kept for the page's pins: the eyes, the outline's box and a point on the body, in the square's pixels.
  canvas.geo = { eyes: g.eyes.map(at), box: { x0: g.x0 + dx, y0: g.y0 + dy, x1: g.x1 + dx, y1: g.y1 + dy }, mid: at(g.mid) };
  const ctx = canvas.getContext('2d'), fill = `rgb(${P.ink})`;
  ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, size, size);
  if (layer !== 'bg') {
    ctx.save(); ctx.translate(dx, dy);
    ctx.fillStyle = fill; ctx.beginPath();
    for (const poly of g.shapes) { ctx.moveTo(poly[0].x, poly[0].y); for (const q of poly.slice(1)) ctx.lineTo(q.x, q.y); ctx.closePath(); }
    ctx.fill('nonzero');
    ctx.strokeStyle = fill; ctx.lineWidth = P.bold * k; ctx.lineJoin = 'round'; ctx.stroke();
    ctx.globalCompositeOperation = 'destination-out';
    for (const e of g.eyes) { ctx.beginPath(); ctx.arc(e.x, e.y, L * size * P.eye, 0, Math.PI * 2); ctx.fill(); }
    ctx.restore();
  }
  if (layer === 'fg') return canvas;
  // The ground goes under the shark, so it also shows through the eyes.
  ctx.save(); ctx.globalCompositeOperation = 'destination-over';
  const grad = ctx.createLinearGradient(0, 0, 0, size);
  grad.addColorStop(0, P.ground[0]); grad.addColorStop(1, P.ground[1]);
  ctx.fillStyle = grad; ctx.fillRect(0, 0, size, size);
  ctx.restore();
  return canvas;
}
