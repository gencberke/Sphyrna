// Home's band: one hammerhead on one fixed loop, a wide flat ellipse whose turns fall out of sight past the band's edges:
// left along the top, back along the bottom; as its tail leaves on one side, its head comes back on the other. It never leaves, and the loop repeats, so its frames can be worked out once.
const LOOP = { period: 180, rx: .64, ry: .13, cx: .5, cy: .36 };
function loopHammer(c) {
  if (!c) return null;
  const o = new Ocean(c, { cell: 11, alpha: .36, fps: 12, plankton: 0, wake: false, specs: [{ kind: 'hammerhead', L: 330, depth: .66, speed: 13 }] });
  const s = o.sharks[0];
  const at = th => ({ x: o.w * (LOOP.cx + LOOP.rx * Math.cos(th)), y: o.h * (LOOP.cy - LOOP.ry * Math.sin(th)) });
  const thOf = t => t / LOOP.period * Math.PI * 2 + Math.PI / 2;
  const place = t => { const th = thOf(t), p = at(th), q = at(th + .002); Object.assign(s, p); s.heading = Math.atan2(q.y - p.y, q.x - p.x); };
  s.spawn = () => {
    place(o.t); s.size = o.w + 'x' + o.h;
    let th = thOf(o.t), prev = at(th), len = 0; s.trail = [prev];
    // A hidden band has no size, so its trail is laid when it gets one.
    if (o.w < 50 || o.h < 20) return;
    for (let k = 0; len < s.L * s.K.reach + 24 && k < 40000; k++) { th -= .0008; const p = at(th), d = dist(p, prev); if (d >= 4) { s.trail.push(p); len += d; prev = p; } }
  };
  s.step = (dt, t) => {
    if (s.size !== o.w + 'x' + o.h) s.spawn();
    s.phase += dt * Math.PI * 2 * s.K.beat;
    place(t);
    if (dist(s, s.trail[0]) >= 3) s.trail.unshift({ x: s.x, y: s.y });
    let acc = dist(s, s.trail[0]);
    for (let k = 1; k < s.trail.length; k++) { acc += dist(s.trail[k], s.trail[k - 1]); if (acc > s.L * s.K.reach) { s.trail.length = k + 1; break; } }
  };
  s.spawn(); o.draw();
  return o;
}
