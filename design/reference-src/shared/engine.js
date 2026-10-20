/* ---------- the working mark: a braille spinner ---------- */
const SPIN = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; let si = 0;
setInterval(() => { if (document.hidden) return; si = (si + 1) % SPIN.length; $$('.spin').forEach(e => e.textContent = SPIN[si]); }, 80);

/* ============================================================
   The art layer: ASCII hammerheads.
   Each shark is a spine that follows its own path, with a
   travelling body wave. Its silhouette (body, hammer, fins,
   tail) is filled into a one-pixel-per-cell field, and each
   cell's coverage picks a character from a density ramp.
   ============================================================ */
const MONO = '"SF Mono", SFMono-Regular, ui-monospace, Menlo, monospace';
const GLYPH = { 1:'.', 2:':', 3:'-', 4:'=', 5:'+', 6:'*', 7:'#', 8:'%', 9:'@', 10:'o', 11:'-', 12:'~', 13:'.', 14:'·', 15:'°', 16:'|', 17:'/', 18:'-', 19:'\\' };
// The cast. A profile is the half width along the body (0 = the head, 1 = the tail's root), as a share of the length.
// `ext` is how far the spine runs past the body (the thresher's long tail), `reach` how much path the body remembers.
const KINDS = {
  hammerhead: { reach: 1.3, ext: 1, beat: .42, core: .3, profile: [[0,.03],[.05,.046],[.11,.064],[.19,.08],[.27,.085],[.37,.078],[.49,.062],[.61,.045],[.73,.03],[.83,.02],[.91,.014],[1,.009]] },
  thresher: { reach: 2.1, ext: 1.7, beat: .5, core: .3, profile: [[0,.006],[.03,.028],[.08,.048],[.16,.064],[.26,.07],[.38,.064],[.5,.05],[.62,.035],[.74,.023],[.84,.015],[.92,.011],[1,.008]] },
  // A broad, flat head under the disc (the first two fifths), the lower jaw a point in front of it, and a body that tapers behind.
  remora: { reach: 1.3, ext: 1, beat: .7, core: .18, disc: [.03, .43, .84], eye: [.09, .95], fins: [.42, .52, .05, .06], ridge: [.5, .8], profile: [[0,.012],[.025,.046],[.06,.076],[.12,.092],[.22,.096],[.32,.088],[.42,.07],[.54,.056],[.66,.044],[.8,.031],[.9,.021],[1,.015]] },
  whale: { reach: 1.3, ext: 1, beat: .22, core: .16, profile: [[0,.068],[.03,.08],[.08,.092],[.16,.102],[.26,.106],[.38,.098],[.5,.082],[.62,.06],[.74,.04],[.84,.025],[.92,.016],[1,.011]] }
};
function widthAt(profile, s) {
  if (s <= 0) return profile[0][1];
  for (let i = 1; i < profile.length; i++) {
    const [s1, w1] = profile[i];
    if (s <= s1) { const [s0, w0] = profile[i - 1], f = (s - s0) / (s1 - s0), k = f * f * (3 - 2 * f); return w0 + (w1 - w0) * k; }
  }
  return profile[profile.length - 1][1];
}
const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
function tangents(pts) {
  const n = pts.length;
  for (let i = 0; i < n; i++) {
    const a = pts[Math.max(0, i - 1)], b = pts[Math.min(n - 1, i + 1)];
    const dx = a.x - b.x, dy = a.y - b.y, l = Math.hypot(dx, dy) || 1;
    pts[i].tx = dx / l; pts[i].ty = dy / l;
  }
}
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const oceans = [];
let ambient = true;

class Shark {
  constructor(ocean, spec, i) {
    this.o = ocean;
    Object.assign(this, { kind: 'hammerhead', L: 300, depth: .6, speed: 16 }, spec);
    this.K = KINDS[this.kind]; this.baseL = this.L;
    this.phase = Math.random() * 6.28; this.seed = Math.random() * 100; this.wakeT = 0; this.tail = null;
    this.spawn(true, i);
  }
  hw(s) { return widthAt(this.K.profile, s) * this.L; }
  spawn(initial, i = 0) {
    const { w, h } = this.o;
    if (this.fx != null) {
      if (this.center) this.L = Math.min(this.baseL, w * .82 / (this.K.ext + .2));
      this.x = this.center ? w / 2 + this.L * (this.K.ext * .5 + .05) : w * this.fx; this.y = h * this.fy; this.heading = this.angle || 0;
    } else {
      const right = initial ? (i % 2 === 0) : Math.random() < .5;
      this.heading = (right ? 0 : Math.PI) + (Math.random() - .5) * .5;
      this.y = h * (.2 + Math.random() * .6);
      this.x = initial ? w * (.18 + ((i * .37) % .7) + Math.random() * .1) : (right ? -this.L * .25 : w + this.L * .25);
    }
    this.trail = [];
    for (let d = 0; d <= this.L * this.K.reach; d += 4) this.trail.push({ x: this.x - Math.cos(this.heading) * d, y: this.y - Math.sin(this.heading) * d });
  }
  step(dt, t) {
    this.phase += dt * Math.PI * 2 * this.K.beat;
    if (!this.speed) return;
    const { w, h } = this.o, n = Math.sin(t * .13 + this.seed) * .6 + Math.sin(t * .071 + this.seed * 1.7) * .4;
    this.heading += n * .12 * dt;
    const c = Math.sign(Math.cos(this.heading)) || 1, m = h * .14;
    if (this.y < m) this.heading += .3 * dt * c;
    if (this.y > h - m) this.heading -= .3 * dt * c;
    const v = this.speed * (1 + .14 * Math.sin(this.phase));
    this.x += Math.cos(this.heading) * v * dt; this.y += Math.sin(this.heading) * v * dt;
    if (dist(this, this.trail[0]) >= 3) this.trail.unshift({ x: this.x, y: this.y });
    let acc = dist(this, this.trail[0]);
    for (let k = 1; k < this.trail.length; k++) { acc += dist(this.trail[k], this.trail[k - 1]); if (acc > this.L * this.K.reach) { this.trail.length = k + 1; break; } }
    const pad = this.L * (this.K.ext + .3);
    if (this.x < -pad || this.x > w + pad || this.y < -pad || this.y > h + pad) this.spawn(false);
  }
  spine(N) {
    const L = this.L, ext = this.K.ext, poly = [{ x: this.x, y: this.y }].concat(this.trail), pts = new Array(N);
    let seg = 0, acc = 0, segLen = dist(poly[0], poly[1]);
    for (let i = 0; i < N; i++) {
      const s = i / (N - 1) * ext, d = s * L;
      while (seg < poly.length - 2 && acc + segLen < d) { acc += segLen; seg++; segLen = dist(poly[seg], poly[seg + 1]); }
      const a = poly[seg], b = poly[seg + 1] || a, f = segLen > 0 ? Math.min(1, Math.max(0, (d - acc) / segLen)) : 0;
      pts[i] = { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, s };
    }
    tangents(pts);
    const swim = this.speed ? 1 : .6, calm = this.kind === 'whale' ? .7 : 1;
    for (const p of pts) {
      const amp = L * .042 * swim * calm * (.1 + Math.pow(Math.min(p.s, 1.25), 1.6)), off = amp * Math.sin(p.s * 5.3 - this.phase);
      p.x += -p.ty * off; p.y += p.tx * off;
    }
    tangents(pts);
    return pts;
  }
  geometry() {
    const L = this.L, kind = this.kind, ext = this.K.ext, N = Math.round(34 * ext), sp = this.spine(N);
    const fr = p => ({ x: p.x, y: p.y, tx: p.tx, ty: p.ty, nx: -p.ty, ny: p.tx });
    const at = s => {
      const f = Math.max(0, Math.min(1, s / ext)) * (N - 1), i = Math.min(N - 2, Math.floor(f)), k = f - i, a = sp[i], b = sp[i + 1];
      const tx = a.tx + (b.tx - a.tx) * k, ty = a.ty + (b.ty - a.ty) * k, l = Math.hypot(tx, ty) || 1;
      return fr({ x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, tx: tx / l, ty: ty / l });
    };
    const P = (f, along, lat) => ({ x: f.x + f.tx * along + f.nx * lat, y: f.y + f.ty * along + f.ny * lat });
    const hw = s => this.hw(s);
    const left = [], right = [];
    for (let i = 0; i < N; i++) { const s = i / (N - 1) * ext; if (s > .93) break; const f = fr(sp[i]); left.push(P(f, 0, hw(s))); right.push(P(f, 0, -hw(s))); }
    const shapes = [left.concat(right.reverse())], eyes = [], spots = [], lines = [];
    const h0 = fr(sp[0]);
    if (kind === 'hammerhead') {
      const span = L * .17, front = [], back = [];
      for (let k = 0; k <= 16; k++) {
        const u = -1 + k / 8, along = L * (.014 - .032 * u * u), chord = L * .066 * (1 - .4 * u * u);
        front.push(P(h0, along + chord * .5, u * span)); back.push(P(h0, along - chord * .5, u * span));
      }
      shapes.push(front.concat(back.reverse()));
      eyes.push(P(h0, -L * .016, span * .95), P(h0, -L * .016, -span * .95));
    } else if (kind === 'thresher') {
      const e = at(.07); eyes.push(P(e, 0, hw(.07) * .7), P(e, 0, -hw(.07) * .7));
    } else if (kind === 'remora') {
      const [es, el] = this.K.eye, e = at(es); eyes.push(P(e, 0, hw(es) * el), P(e, 0, -hw(es) * el));
    } else if (kind === 'whale') {
      const e = at(.035); eyes.push(P(e, 0, hw(.035) * .9), P(e, 0, -hw(.035) * .9));
      for (let s = .08, r = 0; s < .8; s += .055, r++) for (let q = -.7 + (r % 2) * .175; q <= .71; q += .35) spots.push(P(at(s), 0, q * hw(s)));
    }
    const flap = 1 + .07 * Math.sin(this.phase * .5);
    const [p0, p1, back, reach] = { hammerhead: [.2, .33, .15, .1], thresher: [.19, .3, .2, .17], whale: [.2, .36, .13, .15], remora: this.K.fins }[kind];
    for (const side of [1, -1]) {
      const pm = (p0 + p1) / 2;
      shapes.push([P(at(p0), 0, side * hw(p0) * .9), P(at(pm), -L * back, side * (hw(pm) + L * reach * flap)), P(at(p1), 0, side * hw(p1) * .9)]);
      shapes.push([P(at(.6), 0, side * hw(.6) * .9), P(at(.62), -L * .05, side * (hw(.62) + L * .035)), P(at(.66), 0, side * hw(.66) * .9)]);
    }
    const tr = at(.88), te = at(1);
    let tip;
    if (kind === 'thresher') {
      shapes.push([P(tr, 0, -hw(.88)), P(te, -L * .07, -L * .05), P(te, -L * .01, 0)]);
      const bl = [], br = [];
      for (let i = 0; i < N; i++) {
        const s = i / (N - 1) * ext; if (s < .86) continue;
        const f = fr(sp[i]), k = (s - .86) / (ext - .86), w = L * (.016 * Math.pow(1 - k, .9) + .002);
        bl.push(P(f, 0, w)); br.push(P(f, 0, -w));
      }
      shapes.push(bl.concat(br.reverse()));
      tip = sp[N - 1];
    } else {
      const lobe = kind === 'whale' ? [.14, .13, .14, -.13] : [.16, .11, .09, -.075];
      shapes.push([P(tr, 0, hw(.88)), P(te, -L * lobe[0], L * lobe[1]), P(te, -L * .045, 0), P(te, -L * lobe[2], L * lobe[3]), P(tr, 0, -hw(.88))]);
      tip = P(te, -L * .06, 0);
    }
    const cl = [], cr = [];
    for (let i = 1; i < N; i++) { const s = i / (N - 1) * ext; if (s > .74) break; const f = fr(sp[i]), w = hw(s) * .45; cl.push(P(f, 0, w)); cr.push(P(f, 0, -w)); }
    const ridge = (q, a, b) => { const pts = []; for (let s = a; s <= b + 1e-6; s += .03) { const f = at(s); pts.push(P(f, 0, q * hw(s))); } return pts; };
    if (kind === 'whale') lines.push(ridge(0, .12, .8), ridge(.5, .14, .7), ridge(-.5, .14, .7));
    else if (kind === 'remora') lines.push(ridge(0, ...this.K.ridge));
    else lines.push(ridge(0, .27, .45));
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const poly of shapes) for (const q of poly) { if (q.x < x0) x0 = q.x; if (q.y < y0) y0 = q.y; if (q.x > x1) x1 = q.x; if (q.y > y1) y1 = q.y; }
    const tf = fr(sp[N - 1]);
    const dk = this.K.disc, dm = dk && (dk[0] + dk[1]) / 2, disc = dk && { f: at(dm), a: L * (dk[1] - dk[0]) / 2, b: dk[2] * hw(dm) };
    return { shapes, core: cl.concat(cr.reverse()), lines, eyes, spots, disc, tail: { x: tip.x, y: tip.y, tx: tf.tx, ty: tf.ty }, box: { x0, y0, x1, y1 } };
  }
}

class Ocean {
  constructor(canvas, opts = {}) {
    this.c = canvas; this.ctx = canvas.getContext('2d');
    this.opt = Object.assign({ cell: 12, fps: 24, alpha: .55, specs: [], wake: true, plankton: 26, still: false }, opts);
    this.f = document.createElement('canvas'); this.fx = this.f.getContext('2d', { willReadFrequently: true });
    this.visible = false; this.t = 0; this.last = 0; this.acc = 0; this.raf = 0; this.wake = [];
    this.resize();
    this.sharks = this.opt.specs.map((s, i) => new Shark(this, s, i));
    this.plankton = Array.from({ length: this.opt.plankton }, () => this.mote(false));
    this.readInk();
    for (let k = 0; k < 40; k++) this.simulate(.05);
    this.draw();
    new ResizeObserver(() => {
      const w = this.w, h = this.h;
      if (Math.max(1, this.c.clientWidth) === w && Math.max(1, this.c.clientHeight) === h) return;
      this.resize();
      // A canvas that was laid out before its page had a width (a hidden pane) seeds again at its real size.
      if (w < 50 || h < 50) { this.sharks.forEach((s, i) => s.spawn(true, i)); this.plankton = this.plankton.map(() => this.mote(false)); }
      else this.sharks.forEach((s, i) => { if (s.center) s.spawn(true, i); });
      this.draw();
    }).observe(canvas);
    new IntersectionObserver(es => { this.visible = es[0].isIntersecting; this.sync(); }, { threshold: 0 }).observe(canvas);
    oceans.push(this);
  }
  readInk() { this.ink = getComputedStyle(this.c).getPropertyValue('--art').trim() || '236,236,240'; }
  resize() {
    const w = Math.max(1, this.c.clientWidth), h = Math.max(1, this.c.clientHeight), dpr = Math.min(2, devicePixelRatio || 1);
    this.c.width = Math.round(w * dpr); this.c.height = Math.round(h * dpr);
    this.w = w; this.h = h;
    const ctx = this.ctx; ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.font = `${this.opt.cell}px ${MONO}`; ctx.textBaseline = 'top';
    this.cw = ctx.measureText('M').width || this.opt.cell * .6;
    this.ch = Math.round(this.opt.cell * 1.22);
    this.cols = Math.ceil(w / this.cw) + 1; this.rows = Math.ceil(h / this.ch) + 1;
    this.f.width = this.cols; this.f.height = this.rows;
    this.code = new Uint8Array(this.cols * this.rows); this.alpha = new Float32Array(this.cols * this.rows);
  }
  mote(edge) {
    return { x: Math.random() * this.w, y: edge ? this.h + 6 : Math.random() * this.h, vx: (Math.random() - .5) * 5, vy: -(1.2 + Math.random() * 2.6),
      f: .4 + Math.random(), p: Math.random() * 6.28, a: .1 + Math.random() * .16, g: Math.random() < .75 ? 13 : 14 };
  }
  sync() {
    // The art moves under Reduce Motion too, as the spinner does (D-79); only the Sharks switch, the app's Animated art, stops it.
    const go = ambient && this.visible && !document.hidden && !this.opt.still;
    if (go && !this.raf) { this.last = performance.now(); this.raf = requestAnimationFrame(this.loop); }
    if (!go && this.raf) { cancelAnimationFrame(this.raf); this.raf = 0; }
  }
  loop = now => {
    this.raf = requestAnimationFrame(this.loop);
    this.acc += Math.min(.1, (now - this.last) / 1000); this.last = now;
    if (this.acc < 1 / this.opt.fps) return;
    const dt = this.acc; this.acc = 0;
    this.simulate(dt); this.draw();
  };
  simulate(dt) {
    this.t += dt;
    for (const s of this.sharks) s.step(dt, this.t);
    for (const m of this.plankton) {
      m.x += m.vx * dt + Math.sin(this.t * m.f + m.p) * 3 * dt; m.y += m.vy * dt;
      if (m.y < -8 || m.x < -8 || m.x > this.w + 8) Object.assign(m, this.mote(true));
    }
    if (this.opt.wake) {
      for (const s of this.sharks) {
        s.wakeT += dt;
        if (s.speed && s.tail && s.wakeT > .3) { s.wakeT = 0; this.wake.push({ x: s.tail.x, y: s.tail.y, vx: -s.tail.tx * 5, vy: -s.tail.ty * 5, life: 0, max: 2.4, a: s.depth }); }
      }
      for (const p of this.wake) { p.life += dt; p.x += p.vx * dt; p.y += p.vy * dt; }
      this.wake = this.wake.filter(p => p.life < p.max);
    }
  }
  put(x, y, g, a) {
    const c = Math.floor(x / this.cw), r = Math.floor(y / this.ch);
    if (c < 0 || r < 0 || c >= this.cols || r >= this.rows) return;
    const i = r * this.cols + c;
    if (a > this.alpha[i]) { this.alpha[i] = a; this.code[i] = g; }
  }
  stamp(s) {
    const { fx, cols, rows, cw, ch } = this, geo = s.geometry(), A = this.opt.alpha * s.depth;
    const c0 = Math.max(0, Math.floor(geo.box.x0 / cw) - 1), r0 = Math.max(0, Math.floor(geo.box.y0 / ch) - 1);
    const c1 = Math.min(cols - 1, Math.ceil(geo.box.x1 / cw) + 1), r1 = Math.min(rows - 1, Math.ceil(geo.box.y1 / ch) + 1);
    s.tail = geo.tail;
    if (c1 < c0 || r1 < r0) return;
    fx.setTransform(1, 0, 0, 1, 0, 0); fx.globalCompositeOperation = 'source-over'; fx.clearRect(0, 0, cols, rows);
    fx.setTransform(1 / cw, 0, 0, 1 / ch, 0, 0); fx.globalCompositeOperation = 'lighter';
    const path = poly => { fx.moveTo(poly[0].x, poly[0].y); for (let k = 1; k < poly.length; k++) fx.lineTo(poly[k].x, poly[k].y); fx.closePath(); };
    fx.fillStyle = 'rgba(255,255,255,.5)'; fx.beginPath(); geo.shapes.forEach(path); fx.fill('nonzero');
    fx.fillStyle = `rgba(255,255,255,${s.K.core})`; fx.beginPath(); path(geo.core); fx.fill();
    fx.strokeStyle = 'rgba(255,255,255,.22)'; fx.lineWidth = s.L * (s.kind === 'whale' ? .012 : .022); fx.lineCap = 'round';
    for (const line of geo.lines) { fx.beginPath(); line.forEach((q, k) => k ? fx.lineTo(q.x, q.y) : fx.moveTo(q.x, q.y)); fx.stroke(); }
    const w = c1 - c0 + 1, h = r1 - r0 + 1, data = fx.getImageData(c0, r0, w, h).data;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const v = data[(y * w + x) * 4 + 3] / 255;
      if (v < .05) continue;
      const i = (r0 + y) * cols + c0 + x;
      this.code[i] = Math.min(9, Math.max(1, Math.floor(Math.pow(v, .9) * 10)));
      this.alpha[i] = A * (.3 + .7 * v);
    }
    // Spots only on the body; eyes always, since a hammer's tips are thin.
    const over = (pts, g, a, always) => {
      for (const e of pts) {
        const c = Math.floor(e.x / cw), r = Math.floor(e.y / ch);
        if (c < 0 || r < 0 || c >= cols || r >= rows) continue;
        const i = r * cols + c;
        if (always || this.code[i] > 3) { this.code[i] = g; this.alpha[i] = a; }
      }
    };
    if (geo.disc) this.plates(geo.disc, A);
    over(geo.spots, 15, A * .95, false);
    over(geo.eyes, 10, A, true);
  }
  // The remora's disc: an oval of plates across its head, each cell a bar drawn across the head, whichever way the
  // fish faces. A large remora, four rows of plates or more, shows the ridge that splits them.
  plates(d, A) {
    const { cols, rows, cw, ch } = this, f = d.f, R = Math.max(d.a, d.b) + cw + ch;
    const bar = ang => { const q = (ang % Math.PI + Math.PI) % Math.PI / Math.PI * 8; return q < 1 || q >= 7 ? 18 : q < 3 ? 19 : q < 5 ? 16 : 17; };
    const across = bar(Math.atan2(f.ny, f.nx)), along = bar(Math.atan2(f.ty, f.tx)), ridge = 2 * d.b >= 4 * ch;
    const c0 = Math.max(0, Math.floor((f.x - R) / cw)), c1 = Math.min(cols - 1, Math.ceil((f.x + R) / cw));
    const r0 = Math.max(0, Math.floor((f.y - R) / ch)), r1 = Math.min(rows - 1, Math.ceil((f.y + R) / ch));
    for (let r = r0; r <= r1; r++) for (let c = c0; c <= c1; c++) {
      const x = (c + .5) * cw - f.x, y = (r + .5) * ch - f.y, u = x * f.tx + y * f.ty, v = x * f.nx + y * f.ny;
      if ((u / d.a) ** 2 + (v / d.b) ** 2 > 1) continue;
      const i = r * cols + c;
      this.code[i] = ridge && Math.abs(v) < ch * .5 ? along : across;
      this.alpha[i] = A;
    }
  }
  draw() {
    const { ctx, cols, rows, cw, ch } = this, N = cols * rows;
    this.code.fill(0); this.alpha.fill(0);
    for (const m of this.plankton) this.put(m.x, m.y, m.g, m.a * this.opt.alpha * 1.4);
    for (const p of this.wake) { const k = 1 - p.life / p.max; this.put(p.x, p.y, k > .55 ? 12 : 11, k * .55 * p.a * this.opt.alpha); }
    [...this.sharks].sort((a, b) => a.depth - b.depth).forEach(s => this.stamp(s));
    ctx.clearRect(0, 0, this.w, this.h);
    const buckets = new Map();
    for (let i = 0; i < N; i++) {
      if (!this.code[i]) continue;
      const a = Math.round(this.alpha[i] * 40) / 40;
      if (a <= 0) continue;
      let b = buckets.get(a); if (!b) buckets.set(a, b = []); b.push(i);
    }
    for (const [a, list] of buckets) {
      ctx.fillStyle = `rgba(${this.ink},${a})`;
      for (const i of list) ctx.fillText(GLYPH[this.code[i]], (i % cols) * cw, ((i / cols) | 0) * ch);
    }
  }
}

const sea = (id, o) => { const c = document.getElementById(id); return c && new Ocean(c, o); };
