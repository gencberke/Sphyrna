/* ---------- the app icon, drawn by the art engine ----------
   A still hammerhead in a square: the engine's own field, ramp and eyes. Only the pose is set here:
   where the head is, which way it faces, how much the body bends, and the cell size. The glyphs are
   bold, so they keep their light when macOS scales the icon down to 32 and 16. */
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
