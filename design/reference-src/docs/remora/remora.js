/* ============================================================
   Remora, Home's assistant. The brief, its arrival and the
   remora are the identity page's (D-77). Home's band keeps its
   one hammerhead on its loop (D-79), and it is the one that brings
   the remora. The art moves under Reduce Motion; the Animated art
   switch stops it.
   ============================================================ */
const iconize = root => $$('[data-i]', root).forEach(el => { if (!el.querySelector(':scope>svg')) el.insertAdjacentHTML('afterbegin', svg(el.dataset.i)); });
const HNAME = { claude: 'Claude Code', codex: 'Codex' };
const hmark = h => `<span class="hm ${h}" title="${HNAME[h]}"></span>`;
const motionReduced = () => !ambient;
const winR = $('#winR'), winA = $('#winA'), winM = $('#winM'), winK = $('#winK'), winN = $('#winN');
// The pins are placed once everything below is drawn.
let ready = false;

/* ---------- the sidebar: four projects, as the project page draws them ---------- */
const PJ = { loom: { name: 'loom', tone: 'var(--orchid)' }, sb: { name: 'second-brain', tone: 'var(--aqua)' }, api: { name: 'backend-api', tone: 'var(--mint)' }, web: { name: 'website', tone: 'var(--sage)' } };
const DOT_OF = { fail: 'fail', attn: 'attn', unv: 'unv' };
const projDot = list => ['fail', 'attn', 'unv'].find(c => list.some(s => DOT_OF[s.st] === c));
const usage = left => `<button class="usage" title="Plan limits: 5-hour ${left}% left, weekly 81% left"><span>5h</span><span class="meter"><i style="width:${left}%"></i></span><span class="v">${left}%</span><span>·</span><span>wk</span><span class="v">81%</span></button>`;
const S = (id, t, st, meta, h = 'claude') => ({ id, t, st, meta, h });
const MORNING = [
  [PJ.loom, [S('ink', 'Port the sidebar to Ink tokens', 'work', 'now'), S('gate', 'Review the gate failure', 'attn', '3m'), S('s10', 'Remora spike S10', '', '2h')]],
  [PJ.sb, [S('th', 'Thesis outline', 'unv', '25m'), S('vm', 'Weekly vault maintenance', '', '1h')]],
  [PJ.api, [S('jwt', 'Migrate auth to JWT', 'fail', '9h'), S('rl', 'Rate limiter tests', '', '2d')]],
  [PJ.web, [S('ft', 'Footer links', '', '6d')]]
];
const LATER = [
  [PJ.loom, [S('ink', 'Port the sidebar to Ink tokens', 'work', 'now'), S('gate', 'Review the gate failure', '', '1h'), S('s10', 'Remora spike S10', '', '4h')]],
  [PJ.sb, [S('th', 'Thesis outline', 'unv', '2h'), S('vm', 'Weekly vault maintenance', '', '3h')]],
  [PJ.api, [S('jwt', 'Migrate auth to JWT', 'attn', '40m'), S('rl', 'Rate limiter tests', '', '2d')]],
  [PJ.web, [S('ft', 'Footer links', '', '6d')]]
];
const EMPTY = [[PJ.loom, []], [PJ.sb, []], [PJ.api, []], [PJ.web, []]];
function drawSide(side, o) {
  const groups = o.groups || [];
  const plist = groups.map(([p, list]) => {
    const dot = projDot(list);
    return `<div class="pgroup" style="--tone:${p.tone}"><div class="proj-head"><span class="pmark">${initial(p.name)}</span><span class="pn">${p.name}</span>${dot ? `<i class="dot ${dot}" style="width:6px;height:6px"></i>` : ''}<span class="chev" data-i="chev-d"></span></div>`
      + (list.length ? list.map(s => `<div class="row srow${s.id === o.sel ? ' sel' : ''}" data-s="${s.id}"><span class="ind">${mark(s.st)}</span>${hmark(s.h)}<span class="t">${s.t}</span><span class="meta">${s.meta}</span></div>`).join('') : '<div class="none in">No sessions</div>')
      + '</div>';
  }).join('');
  side.innerHTML = `
    <div class="side-top"><div class="lights"><i></i><i></i><i></i></div><button class="ib" title="Hide the sidebar" data-i="side-l"></button></div>
    <button class="search"><span data-i="search"></span><span>Search</span><kbd>⌘K</kbd></button>
    <div class="nav">
      <div class="row${o.sel === 'home' ? ' sel' : ''}"><span class="ic" data-i="home"></span><span class="t">Home</span>${o.badge ? `<span class="badge attn">${o.badge}</span>` : ''}</div>
      <div class="row act${o.sel === 'new' ? ' sel' : ''}"><span class="ic" data-i="plus"></span><span class="t">New session</span><kbd>⌘N</kbd></div>
    </div>
    <div class="side-sec"><span class="label">Projects</span><span class="view"><button class="on" title="Group by project · ⌘2">projects</button> · <button title="Recent activity · ⌘1">activity</button></span></div>
    <div class="plist">${plist}</div>
    <div class="side-foot"><button class="ib" data-i="plus" title="New"></button>${usage(o.left || 94)}<button class="ib" data-i="gear" title="Settings" style="margin-left:auto"></button></div>`;
  iconize(side);
}
drawSide($('.side', winR), { groups: MORNING, sel: 'home', badge: 3 });
drawSide($('.side', winA), { groups: LATER, sel: 'home', badge: 2, left: 61 });
drawSide($('.side', winM), { groups: LATER, sel: 'home', badge: 2, left: 61 });
drawSide($('.side', winK), { groups: MORNING, sel: 'ink', badge: 3 });
drawSide($('.side', winN), { groups: MORNING, sel: 'new', badge: 3 });

/* ---------- Home's cards: Needs you lists what the Home row counts, failures first (§9) ---------- */
const cmd = c => `<span class="mono" style="font-size:11.5px">${c}</span>`;
const NEEDS = {
  morning: [['api', 'Migrate auth to JWT', 'fail', '9h', 'Failed: three token tests fail after the claims change.'],
    ['loom', 'Review the gate failure', 'attn', '3m', `Claude asks to run ${cmd('swift test -c release --filter SideChatFlowTests')}.`],
    ['sb', 'Thesis outline', 'unv', '25m', 'Finished: the outline has five chapters; chapter three needs its reading list.']],
  later: [['api', 'Migrate auth to JWT', 'attn', '40m', `Claude asks to run ${cmd('npm test -- tokens')}.`],
    ['sb', 'Thesis outline', 'unv', '2h', 'Finished: the outline has five chapters; chapter three needs its reading list.']],
  none: []
};
function drawNeeds(win, list) {
  $('[data-role=needs]', win).innerHTML = `<div class="lc-h"><span class="dot attn"></span>Needs you${list.length ? `<span class="n">${list.length}</span>` : ''}</div>`
    + (list.length ? list.map(([pk, t, st, age, why]) => `<div class="hrow" style="--tone:${PJ[pk].tone}"><span class="ind">${mark(st)}</span><span class="t">${t}<span class="pj"><span class="pmark sm">${initial(PJ[pk].name)}</span>${PJ[pk].name}</span></span><span class="age">${age}</span>
                  <span class="why">${why}</span></div>`).join('')
      // With nothing waiting the card stays and says what appears there (06, D-79).
      : '<div class="hrow blank">A session that waits for an answer, or finished while you were away, is listed here.</div>');
}
// Plan limits: what is left of the 5-hour window, and the marker for the time gone.
const PLAN = { morning: [94, '09:12', 8, 'at this pace it lasts'], later: [61, '11:20', 52, 'at this pace it lasts'], limit: [8, '09:12', 8, 'at this pace it runs out at 09:40'] };
function setPlan(win, [left, at, gone, pace]) {
  const c = $('[data-role=plan]', win);
  $('.sc-h span', c).textContent = 'updated ' + at;
  $('.pace .l span', c).textContent = left + '% left';
  $('.ptrack i', c).style.width = left + '%'; $('.ptrack em', c).style.left = gone + '%';
  $('.pace small', c).textContent = 'Resets 13:40 · ' + pace;
}
drawNeeds(winR, NEEDS.morning); drawNeeds(winA, NEEDS.later); setPlan(winA, PLAN.later);

/* ---------- the art: the remora rides under its host's flank (the identity page's) ---------- */
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
withRider(sea('ocean-intro', { cell: 11, alpha: .6, specs: [{ kind: 'hammerhead', L: 520, depth: .66, speed: 16 }, remoraOf(130, .62), { kind: 'whale', L: 820, depth: .26, speed: 8 }] }));
// The new-session page's art, as the foundations draw it.
sea('ocean-draft', { cell: 11, alpha: .5, specs: [{ kind: 'hammerhead', L: 420, depth: .6, speed: 15 }, { kind: 'hammerhead', L: 270, depth: .95, speed: 21 }, { kind: 'whale', L: 760, depth: .24, speed: 7 }] });

/* ---------- Home's band: one hammerhead on one fixed loop (06, D-79) ---------- */
// A wide, flat ellipse, left along the top and back along the bottom, whose turns fall out of sight past the band's edges.
const LOOP = { period: 180, rx: .64, ry: .13, cx: .5, cy: .36 };
const loopAt = (w, h, th) => ({ x: w * (LOOP.cx + LOOP.rx * Math.cos(th)), y: h * (LOOP.cy - LOOP.ry * Math.sin(th)) });
// Where its head comes back in at the band's left edge, on the lower pass, about 3.4 s after Home opened with a brief.
const TH_BACK = Math.PI + Math.acos((LOOP.cx) / LOOP.rx), BACK_AT = 3.4;
function layLoop(s, w, h, th) {
  const p = loopAt(w, h, th), q = loopAt(w, h, th + .002);
  Object.assign(s, p); s.heading = Math.atan2(q.y - p.y, q.x - p.x);
  let t = th, prev = p, len = 0; s.trail = [p];
  // A band with no size yet gets its trail when it has one.
  if (w < 50 || h < 20) return;
  for (let k = 0; len < s.L * s.K.reach + 24 && k < 40000; k++) { t -= .0008; const r = loopAt(w, h, t), d = dist(r, prev); if (d >= 4) { s.trail.push(r); len += d; prev = r; } }
}
function loopHammer(c) {
  if (!c) return null;
  const o = new Ocean(c, { cell: 11, alpha: .36, fps: 12, plankton: 0, wake: false, specs: [{ kind: 'hammerhead', L: 330, depth: .66, speed: 13 }] });
  const s = o.sharks[0], thOf = t => t / LOOP.period * Math.PI * 2 + Math.PI / 2;
  s.spawn = () => { layLoop(s, o.w, o.h, thOf(o.t)); s.size = o.w + 'x' + o.h; };
  s.step = (dt, t) => {
    if (s.size !== o.w + 'x' + o.h) s.spawn();
    s.phase += dt * Math.PI * 2 * s.K.beat;
    const th = thOf(t), p = loopAt(o.w, o.h, th), q = loopAt(o.w, o.h, th + .002);
    Object.assign(s, p); s.heading = Math.atan2(q.y - p.y, q.x - p.x);
    if (dist(s, s.trail[0]) >= 3) s.trail.unshift({ x: s.x, y: s.y });
    let acc = dist(s, s.trail[0]);
    for (let k = 1; k < s.trail.length; k++) { acc += dist(s.trail[k], s.trail[k - 1]); if (acc > s.L * s.K.reach) { s.trail.length = k + 1; break; } }
  };
  s.spawn(); o.draw();
  // The arrival takes the band's hammerhead away, and it comes back on the loop's lower pass, in from the left.
  o.away = () => c.classList.add('away');
  o.back = th => { o.t = (th - Math.PI / 2) / (Math.PI * 2) * LOOP.period; s.spawn(); o.draw(); c.classList.remove('away'); };
  return o;
}
const band = loopHammer($('#ocean-band'));
loopHammer($('#ocean-band2'));
// A remora at rest for the folded brief's line: level, in semibold glyphs, and large enough for its disc to show.
function miniRemora(id) {
  const o = sea(id, { cell: 5, alpha: .86, plankton: 0, wake: false, still: true, specs: [{ kind: 'remora', L: 72, depth: 1, speed: 0, fx: .5, fy: .5 }] });
  if (!o) return o;
  const s = o.sharks[0], r0 = o.resize.bind(o);
  o.resize = () => { r0(); o.ctx.font = `600 ${o.opt.cell}px ${MONO}`; };
  s.spawn = () => poseShark(s, o.w / 2 + s.L * .47 * Math.cos(-.1), o.h / 2 + s.L * .47 * Math.sin(-.1), -.1, -.08);
  s.phase = 2.2; o.resize(); s.spawn(); o.draw();
  return o;
}
['mini-remora', 'mini-remora2', 'mini-remora3'].forEach(miniRemora);

/* ============================================================
   01 The brief. The arrival is the identity page's: the host swims
   in from the right with the remora on its flank, lets it go at the
   brief's start and leaves at the left; the remora turns up to its
   place, swims while Remora reads, and holds still once the brief is
   written. Here the host is the band's own hammerhead, which comes
   back on its loop's lower pass a moment later.
   ============================================================ */
const PAIR = { cell: 6, alpha: .82, weight: 600, host: 250, hostDepth: .5, rider: 110, at: .34, turn: 40, approach: 46, lead: 50, rise: -.3, bend: -.1, phase: 2.2 };
const detail = $('.detail', winR), pairCanvas = $('#ocean-arrive'), sent = $('.bsent', winR);
sent.innerHTML = sent.textContent.trim().split(/\s+/).map(w => `<span class="w">${w}</span>`).join(' ');
const words = $$('.w', sent), tiles = $$('.tile', winR);
const foot = $('[data-role=foot]', winR), quiet = $('[data-role=quiet]', winR), prop = $('[data-role=prop]', winR);
const TL = { inEnd: 1.3, turnEnd: 2.2, settle: .6, readEnd: 3.5, word: .034, tile: .13, rest: .5 };
TL.writeEnd = TL.readEnd + words.length * TL.word + .1;
TL.tilesEnd = TL.writeEnd + (tiles.length - 1) * TL.tile + .26;
TL.end = TL.tilesEnd + TL.rest + .3;

const offsetIn = (el, root) => {
  let x = 0, y = 0;
  for (let e = el; e && e !== root; e = e.offsetParent) { x += e.offsetLeft; y += e.offsetTop; }
  return { x, y, w: el.offsetWidth, h: el.offsetHeight };
};
// Where things are in the detail pane, the canvases' space; measured while the brief shows, and kept for when it does not.
let lastLay = null;
function homeLayout() {
  if (lastLay && $('[data-role=brief]', winR).hidden) return lastLay;
  const spot = offsetIn($('.rspot', winR), detail), text = offsetIn($('.btext', winR), detail);
  const r = PAIR.turn, th = PAIR.rise, rest = { x: spot.x + spot.w - 6, y: text.y + text.h / 2 + PAIR.rider * Math.sin(th) / 2 };
  return lastLay = { W: pairCanvas.clientWidth, H: pairCanvas.clientHeight, spot, text, rest, lane: rest.y - PAIR.approach * Math.sin(th) + r * Math.cos(th) + r,
    head: offsetIn($('.bhead h1', winR), detail), when: offsetIn($('.bhead .when', winR), detail), tiles: tiles.map(t => offsetIn(t, detail)) };
}
function moveHead(s, x, y) {
  s.x = x; s.y = y;
  if (dist(s, s.trail[0]) >= 3) s.trail.unshift({ x, y });
  let acc = dist(s, s.trail[0]);
  for (let k = 1; k < s.trail.length; k++) { acc += dist(s.trail[k], s.trail[k - 1]); if (acc > s.L * s.K.reach) { s.trail.length = k + 1; break; } }
}
function resample(poly, step, n) {
  const out = [{ x: poly[0].x, y: poly[0].y }];
  let i = 0, a = out[0], left = step;
  while (out.length < n) {
    const b = poly[i + 1];
    if (!b) { out.push({ ...out[out.length - 1] }); continue; }
    const d = dist(a, b);
    if (d >= left) { const f = left / d; a = { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f }; out.push(a); left = step; }
    else { left -= d; a = b; i++; }
  }
  return out;
}
class Arrival {
  constructor(o, lay, live) { this.o = o; this.lay = lay; this.live = live; [this.host, this.rider] = o.sharks; this.reset(); }
  reset() {
    const { host, rider, lay } = this;
    Object.assign(this, { t: 0, v: 0, path: null, trail0: null, gone: false, done: false });
    this.o.opt.fps = 60;
    this.o.sharks = [host, rider];
    host.phase = 1.2; rider.phase = .4; host.speed = 1; rider.speed = 0;
    this.y1 = lay.lane + host.hw(PAIR.at) + rider.hw(.22) * .6; this.y0 = this.y1 - 26;
    this.x0 = lay.W + 24; this.x1 = lay.rest.x - PAIR.approach * Math.cos(PAIR.rise) - PAIR.turn * Math.sin(PAIR.rise) + PAIR.lead - PAIR.at * host.L;
    poseShark(host, this.x0, this.y0, Math.PI, 0);
    ride(host, rider, PAIR.at, 1);
  }
  // The remora alone in its place, still: the arrival's end, Animated art off, and the states with no new brief.
  rest() {
    const { rider, lay } = this, tmp = { L: rider.L, K: rider.K };
    poseShark(tmp, lay.rest.x, lay.rest.y, PAIR.rise, PAIR.bend);
    Object.assign(rider, { x: lay.rest.x, y: lay.rest.y, trail: tmp.trail, speed: 0, phase: PAIR.phase });
    this.o.sharks = [rider]; this.gone = this.done = true;
  }
  letGo() {
    const { rider, lay } = this, r = PAIR.turn, th = PAIR.rise, A = PAIR.approach, T = lay.rest;
    const E = { x: T.x - A * Math.cos(th), y: T.y - A * Math.sin(th) }, c = { x: E.x - r * Math.sin(th), y: E.y + r * Math.cos(th) };
    const B = { x: c.x, y: c.y + r }, pts = [{ x: rider.x, y: rider.y }], n1 = Math.ceil(dist(pts[0], B) / 2);
    for (let i = 1; i <= n1; i++) pts.push({ x: rider.x + (B.x - rider.x) * i / n1, y: rider.y + (B.y - rider.y) * i / n1 });
    for (let i = 1; i <= 48; i++) { const f = Math.PI + (Math.PI + th) * i / 48; pts.push({ x: c.x + r * Math.sin(f), y: c.y - r * Math.cos(f) }); }
    for (let i = 1, n3 = Math.ceil(A / 2); i <= n3; i++) pts.push({ x: E.x + (T.x - E.x) * i / n3, y: E.y + (T.y - E.y) * i / n3 });
    let S2 = 0; pts[0].s = 0;
    for (let i = 1; i < pts.length; i++) { S2 += dist(pts[i], pts[i - 1]); pts[i].s = S2; }
    Object.assign(this, { path: pts, S: S2, vDrop: this.v });
  }
  at(s) {
    const P = this.path; let lo = 0, hi = P.length - 1;
    s = Math.max(0, Math.min(this.S, s));
    while (hi - lo > 1) { const m = (lo + hi) >> 1; if (P[m].s < s) lo = m; else hi = m; }
    const a = P[lo], b = P[hi], f = b.s > a.s ? (s - a.s) / (b.s - a.s) : 0;
    return { x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f };
  }
  tick(dt) {
    if (this.done) return;
    const t = this.t += dt, { host, rider, lay } = this, TAU = Math.PI * 2;
    if (t < TL.inEnd) {
      const u = t / TL.inEnd, a = .45, D = this.x0 - this.x1, e = a * u + (1 - a) * (2 * u - u * u);
      this.v = D / TL.inEnd * (a + (1 - a) * 2 * (1 - u));
      moveHead(host, this.x0 - D * e, this.y0 + (this.y1 - this.y0) * (1 - (1 - u) ** 3));
      host.phase += dt * TAU * (host.K.beat + this.v / 320);
      ride(host, rider, PAIR.at, 1);
      rider.phase += dt * TAU * rider.K.beat * .6;
    } else {
      if (!this.path) this.letGo();
      if (!this.gone) {
        const k = Math.min(1, (t - TL.inEnd) / .5), v = this.vDrop + (700 - this.vDrop) * k * k * (3 - 2 * k), ang = Math.PI - .12 * k;
        moveHead(host, host.x + Math.cos(ang) * v * dt, host.y + Math.sin(ang) * v * dt);
        host.phase += dt * TAU * (host.K.beat + v / 320);
        if (host.x < -host.L * 1.4) { this.o.sharks = [rider]; this.gone = true; if (this.onGone) this.onGone(); }
      }
      if (t < TL.turnEnd) {
        const D = TL.turnEnd - TL.inEnd, u = (t - TL.inEnd) / D, v0 = this.vDrop * D, S2 = this.S;
        const s = v0 * (u - 2 * u * u + u ** 3) + S2 * (3 * u * u - 2 * u ** 3), sp = (v0 * (1 - 4 * u + 3 * u * u) + S2 * (6 * u - 6 * u * u)) / D;
        const p = this.at(s);
        rider.speed = 1; moveHead(rider, p.x, p.y);
        rider.phase += dt * TAU * (rider.K.beat + sp / 200);
      } else {
        if (!this.trail0) {
          const tmp = { L: rider.L, K: rider.K };
          poseShark(tmp, lay.rest.x, lay.rest.y, PAIR.rise, PAIR.bend);
          Object.assign(rider, { x: lay.rest.x, y: lay.rest.y, speed: 0 });
          this.ideal = tmp.trail; this.trail0 = resample([{ x: rider.x, y: rider.y }, ...rider.trail], 4, tmp.trail.length);
          this.o.opt.fps = 12;
        }
        const f = Math.min(1, (t - TL.turnEnd) / TL.settle), k = f * f * (3 - 2 * f);
        rider.trail = this.ideal.map((p, i) => ({ x: this.trail0[i].x + (p.x - this.trail0[i].x) * k, y: this.trail0[i].y + (p.y - this.trail0[i].y) * k }));
        const slow = t < TL.tilesEnd ? 1 : Math.max(0, 1 - (t - TL.tilesEnd) / TL.rest);
        rider.phase += dt * TAU * rider.K.beat * slow * slow;
        if (t >= TL.end) { this.done = true; this.o.opt.still = true; this.o.sync(); }
      }
    }
    if (this.live) this.beats(t);
  }
  // The brief's own beats, on the same clock: reading, the words, the tiles, the lines under them, the footer and the play bar.
  beats(t) {
    winR.classList.toggle('reading', t >= TL.turnEnd && t < TL.readEnd);
    words.forEach((w, i) => w.classList.toggle('in', t >= TL.readEnd + i * TL.word));
    tiles.forEach((x, j) => x.classList.toggle('wait', t < TL.writeEnd + j * TL.tile));
    quiet.classList.toggle('wait', t < TL.tilesEnd);
    prop.classList.toggle('wait', t < TL.tilesEnd + .12);
    foot.classList.toggle('wait', t < TL.tilesEnd + .24);
    $('#tline .head').style.left = Math.min(100, t / TL.end * 100) + '%';
    $('#tclock').textContent = Math.min(t, TL.end).toFixed(1) + ' s';
  }
}
const pair = new Ocean(pairCanvas, { cell: PAIR.cell, alpha: PAIR.alpha, fps: 60, plankton: 0, wake: false, still: true,
  specs: [{ kind: 'hammerhead', L: PAIR.host, depth: PAIR.hostDepth, speed: 0 }, { kind: 'remora', L: PAIR.rider, depth: 1, speed: 0 }] });
pair.sharks.forEach(s => { s.step = () => {}; s.spawn = () => {}; });
const resize0 = pair.resize.bind(pair);
pair.resize = () => { resize0(); pair.ctx.font = `${PAIR.weight} ${PAIR.cell}px ${MONO}`; };
pair.resize();
const arr = new Arrival(pair, homeLayout(), true), sim0 = pair.simulate.bind(pair);
pair.simulate = dt => { sim0(dt); arr.tick(dt); };
let backTimer = 0, seeking = false;
// The host leaves at the left; out of sight it turns, and the band's hammerhead comes back along the loop's lower pass.
arr.onGone = () => { if (seeking) return; clearTimeout(backTimer); backTimer = setTimeout(() => band && band.back(TH_BACK), 1200); };

const BEATS = [['Swims in', 0, TL.inEnd], ['Lets go, turns', TL.inEnd, TL.turnEnd], ['Reads', TL.turnEnd, TL.readEnd], ['Writes', TL.readEnd, TL.writeEnd], ['Tiles, then still', TL.writeEnd, TL.end]];
$('#tline').innerHTML = BEATS.map(([n, a, b]) => `<span style="flex:${(b - a).toFixed(2)} 0 0"><b>${a.toFixed(1)}</b>${n}</span>`).join('') + '<i class="head"></i>';

/* ---------- the brief's states ---------- */
const R = { home: 'morning', call: 'ok' };
let timers = [];
const RSTATE = {
  login: 'Remora uses your Claude Code login. Log in with <span class="mono">claude</span> in a terminal.',
  limit: 'Less than a tenth of your 5-hour limit is left until 13:40, so the morning brief waits. Questions still run.<button class="lk2" data-act="catchup">Catch Me Up Anyway</button>',
  fail: '<span title="The call ended after 60 s without an answer.">Remora could not get an answer from Claude.</span><button class="lk2" data-act="catchup">Try Again</button>',
  ask: 'Your latest sessions, newest first.<button class="lk2" data-act="catchup">Catch Me Up</button>'
};
function showAll() {
  winR.classList.remove('reading');
  words.forEach(w => w.classList.add('in')); tiles.forEach(x => x.classList.remove('wait'));
  [quiet, prop, foot].forEach(e => e.classList.remove('wait'));
}
function resetBrief() {
  timers.forEach(clearTimeout); timers = []; clearTimeout(backTimer);
  // An arrival cut short gives the band its hammerhead back.
  if (band && band.c.classList.contains('away')) band.back(TH_BACK);
  winR.classList.remove('reading');
  words.forEach(w => w.classList.remove('in')); tiles.forEach(x => x.classList.add('wait'));
  [quiet, prop, foot].forEach(e => e.classList.add('wait'));
  $$('.bf', $('#board')).forEach(f => f.classList.remove('on'));
}
// The remora at rest, with nothing new to read: the states with no new brief, and the end of a played one.
function restRemora() {
  arr.lay = homeLayout(); arr.reset(); arr.rest();
  pair.opt.still = true; pair.sync(); pair.draw();
  $('#tline').classList.remove('on'); $('#tclock').textContent = 'at rest';
}
function play() {
  resetBrief(); arr.lay = homeLayout(); arr.reset();
  if (motionReduced()) {
    // Animated art off: no crossing. The remora fades in at its place, and the brief appears once it is read.
    arr.rest(); pair.opt.still = true; pair.sync(); pair.draw();
    pairCanvas.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 450, easing: 'ease-out' });
    $('#tline').classList.remove('on'); $('#tclock').textContent = 'still';
    winR.classList.add('reading');
    timers.push(setTimeout(showAll, 1200));
    return;
  }
  band && band.away();
  $('#tline').classList.add('on'); arr.beats(0);
  pair.opt.still = false; pair.draw(); pair.sync();
}
function seek(t) {
  resetBrief(); arr.lay = homeLayout(); arr.reset();
  seeking = true;
  for (let k = 0, n = Math.round(t * 60); k < n; k++) arr.tick(1 / 60);
  seeking = false;
  if (band) { if (t < BACK_AT) band.away(); else band.back(loopTh(t)); }
  arr.beats(t); $('#tline').classList.add('on');
  pair.opt.still = true; pair.sync(); pair.draw();
}
function setTiles(catalog) {
  tiles.forEach(t => {
    t.classList.toggle('catalog', catalog);
    const tm = $('.tm', t); tm.textContent = catalog ? tm.dataset.last : tm.dataset.tm;
    $('.ta', t).hidden = false; $('.placed', t).hidden = true;
  });
}
function drawR() {
  const h = R.home, brief = $('[data-role=brief]', winR), fold = $('[data-role=fold]', winR), hero = $('[data-role=hband]', winR);
  const briefOn = h === 'morning' || h === 'ask';
  brief.hidden = !briefOn; fold.hidden = h !== 'later'; hero.hidden = !(h === 'off' || h === 'none');
  $('[data-role=rnone]', winR).hidden = h !== 'none';
  pairCanvas.hidden = !briefOn;
  $('#callGrp').style.visibility = h === 'morning' ? '' : 'hidden';
  const plan = h === 'later' ? PLAN.later : h === 'morning' && R.call === 'limit' ? PLAN.limit : PLAN.morning;
  drawSide($('.side', winR), h === 'none' ? { groups: EMPTY, sel: 'home' } : h === 'later' ? { groups: LATER, sel: 'home', badge: 2, left: plan[0] } : { groups: MORNING, sel: 'home', badge: 3, left: plan[0] });
  drawNeeds(winR, NEEDS[h] || NEEDS.morning); setPlan(winR, plan);
  if (h === 'none') { $('[data-role=stmt]', winR).innerHTML = 'Nothing is working or waiting.'; $('[data-role=counts]', winR).innerHTML = '<b>0</b> sessions'; }
  else { $('[data-role=stmt]', winR).innerHTML = 'One session is working. <em>Three need you.</em>'; $('[data-role=counts]', winR).innerHTML = '<b>1</b> working · <b>3</b> need you · <b>5</b> sessions today'; }
  const st = $('[data-role=rstate]', winR), noCall = h === 'ask' || (h === 'morning' && R.call !== 'ok');
  st.hidden = !noCall; st.innerHTML = h === 'ask' ? RSTATE.ask : (RSTATE[R.call] || '');
  sent.hidden = noCall;
  $('[data-role=bh1]', winR).textContent = 'Where you left off';
  $('[data-role=when]', winR).textContent = h === 'ask' ? 'tuesday 20 october · 09:12' : 'tuesday 20 october · since yesterday 23:10';
  setTiles(noCall);
  prop.hidden = noCall; foot.hidden = noCall;
  iconize(winR);
  placeAll();
  if (!briefOn) { resetBrief(); return; }
  if (noCall) { resetBrief(); showAll(); restRemora(); return; }
  play();
}
$$('#homeSeg button').forEach(b => b.addEventListener('click', () => { R.home = b.dataset.h; if (R.home === 'morning') R.call = R.call || 'ok'; drawR(); }));
$$('#callSeg button').forEach(b => b.addEventListener('click', () => { R.call = b.dataset.c; drawR(); }));
const setSeg = (seg, attr, v) => $$('button', seg).forEach(x => x.classList.toggle('on', x.dataset[attr] === v));
function catchUp() {
  R.home = 'morning'; R.call = 'ok';
  setSeg($('#homeSeg'), 'h', 'morning'); setSeg($('#callSeg'), 'c', 'ok');
  closePops(); drawR();
}
$('#replay').addEventListener('click', catchUp);

// The storyboard: the arrival's moments over a wireframe of the brief, and the band's hammerhead back on its loop.
const FRAMES = [
  [.6, 'Swims in', "The band's hammerhead comes in from the right with the remora on its flank, through the brief before it is written."],
  [1.3, 'Lets go', "At the start of the brief the remora lets go of the hammerhead's flank."],
  [1.8, 'Turns', 'The remora curves up toward its place and turns to its sentence; the hammerhead dips and swims on, out to the left.'],
  [2.9, 'Reads', 'In its place the remora swims slowly while Remora reads. Then the sentence and the tiles come in, and it holds still.'],
  [30, 'Back on its loop', 'Out of sight the hammerhead turns. A moment later it comes back in from the left along the bottom of its loop, slow and faint, and keeps circling while Home is open.']];
// Where the band's hammerhead is t seconds after Home opened with a brief: back in at the left at about 3.4 s, then on along its loop.
const loopTh = t => TH_BACK + Math.max(0, t - BACK_AT) / LOOP.period * Math.PI * 2;
function renderBoard() {
  const lay = homeLayout(), ink = getComputedStyle(pairCanvas).getPropertyValue('--art').trim() || '236,236,240';
  const P = (v, of) => (v / of * 100).toFixed(2) + '%';
  const box = (x, y, w, h, cls) => `<i class="${cls}" style="left:${P(x, lay.W)};top:${P(y, lay.H)};width:${P(w, lay.W)};height:${P(h, lay.H)}"></i>`;
  const wire = (reading, written) => box(lay.head.x, lay.head.y + 10, lay.head.w, 20, 'tx') + box(lay.when.x, lay.when.y + 1, lay.when.w, 9, 'tx')
    + box(lay.spot.x, lay.spot.y, lay.spot.w, lay.spot.h, 'spotk') + lay.tiles.map(t => box(t.x, t.y, t.w, t.h, 'tk')).join('')
    + (reading ? box(lay.text.x, lay.text.y + 6, 250, 10, 'tx') : '') + (written ? box(lay.text.x, lay.text.y + 4, lay.text.w * .92, 10, 'tx') + box(lay.text.x, lay.text.y + 26, lay.text.w * .5, 10, 'tx') : '');
  const board = $('#board');
  board.innerHTML = FRAMES.map(([t, name, text], i) => `<figure class="bf" data-t="${t}"><div class="bfr" style="aspect-ratio:${lay.W}/${lay.H}"><div class="artbg"></div>${wire(i === 3, i === 4)}<canvas></canvas></div>`
    + `<figcaption><b>${t} s · ${name}</b>${text}</figcaption></figure>`).join('');
  $$('canvas', board).forEach((c, i) => {
    const o = stillOcean(c, lay.W, PAIR.cell, ink, PAIR.alpha, PAIR.weight, lay.H);
    o.sharks = [new Shark(o, { kind: 'hammerhead', L: PAIR.host, depth: PAIR.hostDepth, speed: 0 }, 0), new Shark(o, { kind: 'remora', L: PAIR.rider, depth: 1, speed: 0 }, 1)];
    const a = new Arrival(o, lay, false);
    for (let k = 0, n = Math.round(Math.min(FRAMES[i][0], TL.end) * 60); k < n; k++) a.tick(1 / 60);
    if (i === 4) {
      // The band's hammerhead on its loop's lower pass, at the band's size and contrast (alpha .36 at depth .66).
      const s = new Shark(o, { kind: 'hammerhead', L: 330, depth: .66 * .36 / PAIR.alpha, speed: 0 }, 2);
      layLoop(s, lay.W, 300, loopTh(FRAMES[i][0]));
      o.sharks.push(s);
    }
    o.draw();
  });
  $$('.bf', board).forEach(f => f.addEventListener('click', () => {
    if (R.home !== 'morning' || R.call !== 'ok') catchUp();
    const t = +f.dataset.t;
    if (t > TL.end) { seek(TL.end); showAll(); band && band.back(loopTh(t)); }
    else seek(t);
    f.classList.add('on');
  }));
}

/* ---------- the remora at its three places: the folded line, beside the brief, on the hammerhead's flank ---------- */
// [canvas width, height, length, cell, alpha, weight, heading]
const DISC_AT = { fold: [84, 30, 72, 5, .86, 600, -.1], rest: [170, 64, 110, 6, .82, 600, -.3], ride: [330, 112, 110, 6, .82, 600, Math.PI] };
function drawDiscs() {
  const ink = getComputedStyle(pairCanvas).getPropertyValue('--art').trim() || '236,236,240', dpr = Math.min(2, devicePixelRatio || 1);
  $$('[data-disc]').forEach(c => {
    const at = c.dataset.disc, [W, H, L, cell, alpha, weight, head] = DISC_AT[at];
    const o = stillOcean(c, W * dpr, cell * dpr, ink, alpha, weight, H * dpr);
    c.style.width = W + 'px'; c.style.height = H + 'px';
    const s = new Shark(o, { kind: 'remora', L: L * dpr, depth: 1, speed: 0 }, 0);
    s.phase = PAIR.phase;
    if (at === 'ride') {
      // On the hammerhead's flank, as it swims in with a new brief.
      const host = new Shark(o, { kind: 'hammerhead', L: PAIR.host * dpr, depth: PAIR.hostDepth, speed: 0 }, 1);
      host.phase = 1.2; s.phase = .4;
      poseShark(host, 46 * dpr, H * .6 * dpr, head, 0);
      ride(host, s, PAIR.at, 1);
      o.sharks = [host, s];
    } else {
      poseShark(s, (W / 2 + L * .47 * Math.cos(head)) * dpr, (H / 2 + L * .47 * Math.sin(head)) * dpr, head, at === 'fold' ? -.08 : PAIR.bend);
      o.sharks = [s];
    }
    o.draw();
  });
}

/* ---------- the brief's parts: Put in Draft, the proposal, the menus and Sources ---------- */
function bindDraft(win) {
  const dpop = $('[data-role=dpop]', win), host = $('.detail', win);
  const show = btn => {
    $('[data-role=dtext]', dpop).textContent = btn.dataset.draft;
    $('[data-role=dwhere]', dpop).textContent = btn.dataset.has ? 'Its composer has text, so this is copied instead' : 'Put in its composer, not sent';
    const r = btn.getBoundingClientRect(), d = host.getBoundingClientRect(), k = d.width / host.offsetWidth || 1;
    dpop.style.left = Math.max(12, Math.min(host.offsetWidth - 342, (r.left - d.left) / k - 8)) + 'px';
    dpop.style.top = ((r.bottom - d.top) / k + 8) + 'px';
    dpop.classList.add('open');
  };
  win.addEventListener('mouseover', e => { const b = e.target.closest('[data-act=draft]'); if (b && b.dataset.draft) show(b); });
  win.addEventListener('mouseout', e => { if (e.target.closest('[data-act=draft]')) dpop.classList.remove('open'); });
  win.addEventListener('click', e => {
    const b = e.target.closest('[data-act=draft]'); if (!b) return;
    dpop.classList.remove('open');
    const tile = b.closest('.tile');
    if (tile) { $('.ta', tile).hidden = true; $('.placed', tile).hidden = false; return; }
    const span = document.createElement('span');
    span.className = 'placedx'; span.style.cssText = 'font:11px var(--mono);color:var(--fg-2)';
    span.textContent = b.dataset.has ? 'Copied: it already has a draft' : 'In its composer, not sent';
    b.replaceWith(span);
  });
}
bindDraft(winR); bindDraft(winA);
const PROP0 = prop.innerHTML;
prop.addEventListener('click', e => {
  const b = e.target.closest('[data-act]'); if (!b) return;
  if (b.dataset.act === 'save') prop.innerHTML = '<span>Saved to <span class="mono">Remora.md</span>.</span><u data-act="undo">Undo</u>';
  if (b.dataset.act === 'undo') prop.innerHTML = PROP0;
  if (b.dataset.act === 'notnow') prop.innerHTML = '<span>Not saved.</span><u data-act="undo">Undo</u>';
});
// The popovers: a [data-open] opens its [data-pop] in the same window, under it, or over it near the window's foot.
function closePops(except) { $$('.win .pop.open').forEach(p => { if (p !== except) p.classList.remove('open'); }); $$('.bhead .ib.on').forEach(b => b.classList.remove('on')); }
document.addEventListener('click', e => {
  const opener = e.target.closest('[data-open]');
  if (opener) {
    const win = opener.closest('.win'), pop = win && $(`[data-pop="${opener.dataset.open}"]`, win);
    if (!pop) return;
    const was = pop.classList.contains('open'); closePops(pop);
    if (was) { pop.classList.remove('open'); return; }
    const host = pop.offsetParent || win, r = opener.getBoundingClientRect(), d = host.getBoundingClientRect(), k = d.width / host.offsetWidth || 1;
    const x = (r.left - d.left) / k, y = (r.bottom - d.top) / k, top = (r.top - d.top) / k;
    pop.style.right = 'auto';
    pop.style.left = Math.max(10, Math.min(host.offsetWidth - pop.offsetWidth - 10, opener.closest('.bhead') ? x + opener.offsetWidth - pop.offsetWidth : x)) + 'px';
    pop.style.top = (y + pop.offsetHeight + 12 > host.offsetHeight ? top - pop.offsetHeight - 6 : y + 6) + 'px';
    pop.classList.add('open');
    if (opener.matches('.ib')) opener.classList.add('on');
    return;
  }
  if (!e.target.closest('.pop')) closePops();
});
// The field's scope: its chip and the check in its menu.
function setScope(win, name) {
  // The check is drawn here, not by data-i, so that redrawing the icons cannot bring an old one back.
  $$('[data-scope]', win).forEach(x => { const ck = $('.ck2', x); ck.removeAttribute('data-i'); ck.innerHTML = x.dataset.scope === name ? svg('check') : ''; });
  $$('[data-role=scopename]', win).forEach(n => { n.textContent = name; });
}
$$('[data-scope]').forEach(b => b.addEventListener('click', () => { setScope(b.closest('.win'), b.dataset.scope); closePops(); }));
winR.addEventListener('click', e => {
  const a = e.target.closest('[data-act]'); if (!a) return;
  const act = a.dataset.act;
  if (act === 'catchup') catchUp();
  if (act === 'memory') { closePops(); $('#memory').scrollIntoView({ behavior: 'smooth' }); }
  if (act === 'settings') { closePops(); $('#settings').scrollIntoView({ behavior: 'smooth' }); }
  if (act === 'show') { R.home = 'morning'; R.call = 'ok'; setSeg($('#homeSeg'), 'h', 'morning'); drawR(); }
});
// The brief's field asks in the Asking section's window.
$('[data-role=askR] input', winR).addEventListener('keydown', e => {
  if (e.key !== 'Enter' || !e.target.value.trim()) return;
  const v = e.target.value.trim(); e.target.value = '';
  $('#asking').scrollIntoView({ behavior: 'smooth' });
  setTimeout(() => ask(keyOf(v), v), 450);
});

/* ============================================================
   02 Asking: one answer under the field, written word by word,
   with the sessions it names as chips.
   ============================================================ */
const QA = {
  touch: { q: 'Which session touched the auth middleware?', at: '11:20', work: 'Reading 4 sessions and searching 14 days of transcripts…',
    a: '<p>Migrate auth to JWT, yesterday at 22:40. It moved the token check into <span class="mono">middleware/auth.py</span> and added the claims test. Rate limiter tests read the same file this morning but did not change it.</p>',
    chips: [['api', 'Migrate auth to JWT', 'yesterday'], ['api', 'Rate limiter tests', '09:05']],
    foot: 'Read 4 sessions · searched 14 days of transcripts · 3.1 s',
    src: [['api', 'Migrate auth to JWT', '40m'], ['api', 'Rate limiter tests', '2d'], ['loom', 'Port the sidebar to Ink tokens', 'now'], ['loom', 'Review the gate failure', '1h']] },
  yday: { q: 'What finished yesterday evening, and what is half done?', at: '10:05', work: 'Reading 6 sessions…',
    a: '<p>Finished: Weekly vault maintenance in second-brain, at 21:30, with the vault checks passing.</p><p>Half done: Migrate auth to JWT stopped at 22:40 with three token tests failing, and Port the sidebar to Ink tokens stopped at step 4 of 6.</p><p class="unread">I could not read Rate limiter tests: its transcript is missing, so it is left out.</p>',
    chips: [['sb', 'Weekly vault maintenance', '21:30'], ['api', 'Migrate auth to JWT', '22:40'], ['loom', 'Port the sidebar to Ink tokens', '23:10']],
    foot: 'Read 5 sessions · 1 could not be read · 3.8 s',
    src: [['sb', 'Weekly vault maintenance', '3h'], ['api', 'Migrate auth to JWT', '40m'], ['loom', 'Port the sidebar to Ink tokens', 'now'], ['sb', 'Thesis outline', '2h'], ['loom', 'Remora spike S10', '4h']] },
  where: { q: 'Where did we leave off in second-brain?', at: '11:31', scope: 'second-brain', work: "Reading 2 sessions and second-brain's note…",
    a: '<p>Thesis outline finished at 08:47, and you have not read it yet. The outline has five chapters; chapter three still needs its reading list, and that is the next step.</p>',
    chips: [['sb', 'Thesis outline', '08:47', 'Continue from the reading list for chapter three: start with the two retrieval papers.']],
    foot: "Read 2 sessions and second-brain's note · 2.4 s",
    src: [['sb', 'Thesis outline', '2h'], ['sb', 'Weekly vault maintenance', '3h']], notes: ["second-brain's note"] },
  remember: { q: 'Remember that backend-api ships on Friday 24 October.', at: '11:36', saved: true,
    a: '<p>Saved to <span class="mono">Remora.md</span>: backend-api ships on Friday 24 October. <u data-act="unsave" style="color:var(--fg-2);text-decoration-color:var(--line-3);text-underline-offset:3px;cursor:pointer">Undo</u></p>',
    chips: [], foot: 'No call: saved at once' }
};
const chipHTML = ([pk, t, when, draft]) => `<span class="rchip" style="--tone:${PJ[pk].tone}"><span class="pmark sm">${initial(PJ[pk].name)}</span>${t}<span class="when">${when}</span><span class="ar" data-i="arr"></span></span>`
  + (draft ? `<button class="btn sec sm" data-act="draft" data-draft="${draft}">Put in Draft</button>` : '');
const keyOf = v => /remember/i.test(v) ? 'remember' : /second-brain|leave off|left off/i.test(v) ? 'where' : /yesterday|finished|half/i.test(v) ? 'yday' : 'touch';
// Each word in its own span, tags kept, so an answer can come in word by word.
function wordify(el) {
  const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), nodes = [];
  while (walk.nextNode()) nodes.push(walk.currentNode);
  nodes.forEach(n => {
    if (!n.textContent.trim()) return;
    const f = document.createDocumentFragment();
    n.textContent.split(/(\s+)/).forEach(part => {
      if (!part) return;
      if (/^\s+$/.test(part)) f.appendChild(document.createTextNode(part));
      else { const s = document.createElement('span'); s.className = 'w'; s.textContent = part; f.appendChild(s); }
    });
    n.replaceWith(f);
  });
  return $$('.w', el);
}
const A = { cur: null, prev: { key: 'yday' }, run: 0 };
function answerIn(root, key, opts) {
  const qa = QA[key], o = Object.assign({ stream: true }, opts);
  const atx = $(o.atx, root), chips = $(o.chips, root), work = $(o.work, root), ft = o.foot && $(o.foot, root);
  const run = ++A.run;
  atx.innerHTML = ''; chips.innerHTML = qa.chips.map(chipHTML).join(''); iconize(chips); chips.classList.add('wait');
  if (ft) { ft.innerHTML = `<span>${qa.foot}</span>` + (qa.saved ? '' : '<u data-open="srcA">Sources</u>'); ft.classList.add('wait'); }
  const finish = () => { chips.classList.remove('wait'); if (ft) ft.classList.remove('wait'); if (o.done) o.done(); };
  if (!o.stream || qa.saved) { atx.innerHTML = qa.a; work.hidden = true; finish(); return; }
  work.hidden = false; work.innerHTML = `<span class="spin">⠋</span><span>${qa.work}</span>`;
  setTimeout(() => {
    if (run !== A.run) return;
    work.hidden = true; atx.innerHTML = qa.a;
    const ws = wordify(atx);
    ws.forEach((w, i) => setTimeout(() => { if (run === A.run) w.classList.add('in'); }, i * 30));
    setTimeout(() => { if (run === A.run) finish(); }, ws.length * 30 + 120);
  }, 900);
}
const askBox = $('[data-role=askA]', winA), ans = $('[data-role=ans]', winA), early = $('[data-role=early]', winA);
function showEarly() {
  early.hidden = !A.prev;
  if (A.prev) { $('[data-role=eq]', early).textContent = QA[A.prev.key].q; $('[data-role=etm]', early).textContent = QA[A.prev.key].at; }
}
function srcList(key) {
  const qa = QA[key];
  $('[data-role=srclist]', winA).innerHTML = (qa.src || []).map(([pk, t, m]) => `<div class="src"><span class="ic"><span class="pmark sm" style="--tone:${PJ[pk].tone}">${initial(PJ[pk].name)}</span></span><span class="t">${t}</span><span class="m">${m}</span></div>`).join('')
    + (qa.notes || []).map(n => `<div class="src"><span class="ic" data-i="doc"></span><span class="t">${n}</span><span class="m">09:12</span></div>`).join('');
  $('[data-role=srcfoot]', winA).textContent = qa.foot;
  iconize(winA);
}
function ask(key, typed, stream = true) {
  if (A.cur && A.cur.key !== key) A.prev = { key: A.cur.key };
  if (A.prev && A.prev.key === key) A.prev = null;
  A.cur = { key };
  const qa = QA[key];
  $('[data-role=qin]', winA).value = '';
  $('[data-role=qtx]', winA).textContent = typed || qa.q;
  $('[data-role=qtm]', winA).textContent = `You asked at ${qa.at}`;
  setScope(winA, qa.scope || 'All projects');
  ans.hidden = false; showEarly(); srcList(key);
  setSeg($('#qSeg'), 'q', key);
  askBox.classList.toggle('busy', stream && !qa.saved);
  answerIn(winA, key, { atx: '[data-role=atx]', chips: '[data-role=achips]', work: '[data-role=work]', foot: '[data-role=afoot]', stream, done: () => askBox.classList.remove('busy') });
  placeAll();
}
// Stop keeps the words that came and says so where the footer would be; stopped while reading, it says so in the reading line.
function stopAnswer() {
  if (!askBox.classList.contains('busy')) return;
  A.run++; askBox.classList.remove('busy');
  const work = $('[data-role=work]', winA), atx = $('[data-role=atx]', winA), ft = $('[data-role=afoot]', winA);
  $$('.w:not(.in)', atx).forEach(w => w.remove());
  const note = '<span>Stopped. Ask again for the whole answer.</span>';
  if (work.hidden) { ft.innerHTML = note; ft.classList.remove('wait'); }
  else work.innerHTML = note;
}
$('#askBtn').addEventListener('click', () => ask($('#qSeg .on').dataset.q));
$$('#qSeg button').forEach(b => b.addEventListener('click', () => ask(b.dataset.q)));
winA.addEventListener('click', e => {
  const a = e.target.closest('[data-act]');
  if (a && a.dataset.act === 'stop') stopAnswer();
  if (a && a.dataset.act === 'ask') { const v = $('[data-role=qin]', winA).value.trim(); if (v) ask(keyOf(v), v); }
  if (a && a.dataset.act === 'closeans') { ans.hidden = true; A.cur = null; placeAll(); }
  if (a && a.dataset.act === 'unsave') { a.closest('p').innerHTML = 'Not saved: <span class="mono">Remora.md</span> is as it was.'; }
  if (e.target.closest('[data-role=early]') && A.prev) ask(A.prev.key, null, false);
});
$('[data-role=qin]', winA).addEventListener('keydown', e => {
  if (e.key === 'Escape') stopAnswer();
  if (e.key === 'ArrowUp' && !e.target.value && A.cur) { e.target.value = QA[A.cur.key].q; e.preventDefault(); }
  if (e.key === 'Enter' && e.target.value.trim()) { const v = e.target.value.trim(); ask(keyOf(v), v); }
});
ask('touch', null, false);

/* ============================================================
   03 Memory: the sheet's three panes, with lines that go and
   notes that can be edited or removed.
   ============================================================ */
$$('#memSeg button').forEach(b => b.addEventListener('click', () => {
  $$('.mpane', winM).forEach(p => { p.hidden = p.dataset.m !== b.dataset.m; });
  placeAll();
}));
winM.addEventListener('click', e => {
  const x = e.target.closest('.jl .x'); if (x) { x.closest('.jl').classList.add('gone'); return; }
  const a = e.target.closest('[data-act]'); if (!a) return;
  const pn = a.closest('.memnote');
  if (a.dataset.act === 'edit') {
    const body = $('.body', pn), on = body.getAttribute('contenteditable') !== 'true';
    body.setAttribute('contenteditable', on ? 'true' : 'false'); a.textContent = on ? 'Done Editing' : 'Edit';
    if (on) body.focus();
  }
  if (a.dataset.act === 'rmnote') {
    pn.dataset.html = pn.innerHTML;
    pn.innerHTML = `<div class="ph2" style="font-weight:400;color:var(--fg-2)">Removed. Remora writes it again after the project's next session.<u data-act="unrm" style="margin-left:auto;cursor:pointer;color:var(--fg-2);text-decoration-color:var(--line-3);text-underline-offset:3px">Undo</u></div>`;
  }
  if (a.dataset.act === 'unrm') { pn.innerHTML = pn.dataset.html; }
});

/* ============================================================
   04 Beyond Home. ⌘K: Ask Remora heads the palette when what you
   type reads as a question. A new session: Remora drafts its brief.
   ============================================================ */
const K = { view: 'typing', scope: 'all' };
const KSCOPE = { all: 'All projects', proj: 'loom', sess: 'This session' };
const KANS = {
  all: { a: QA.touch.a, chips: QA.touch.chips, foot: 'Read 4 sessions · 3.1 s' },
  proj: { a: '<p>Nothing in loom touched the auth middleware in the last 14 days. In backend-api, Migrate auth to JWT did, yesterday at 22:40.</p>', chips: [['api', 'Migrate auth to JWT', 'yesterday']], foot: 'Read 3 sessions in loom · 2.2 s' },
  sess: { a: '<p>This session did not touch it. It changed the sidebar\'s rows, heads and footer, in <span class="mono">LoomTheme+Sidebar.swift</span>, <span class="mono">SidebarRow.swift</span> and <span class="mono">SidebarFooter.swift</span>.</p>', chips: [], foot: 'Read this session · 1.4 s' }
};
function drawK() {
  const list = $('[data-role=klist]', winK), box = $('[data-role=kans]', winK), kfoot = $('[data-role=kfoot]', winK);
  $('[data-role=kscope]', winK).textContent = KSCOPE[K.scope];
  $('[data-role=kchip]', winK).textContent = KSCOPE[K.scope];
  $('[data-role=kcaret]', winK).style.display = K.view === 'typing' ? '' : 'none';
  list.hidden = K.view !== 'typing'; box.hidden = K.view !== 'answer';
  if (K.view === 'typing') kfoot.innerHTML = '<span><b>↑↓</b> move</span><span><b>↵</b> ask</span><span><b>⇥</b> scope</span><span><b>esc</b> close</span>';
  else {
    const qa = KANS[K.scope];
    QA.k = { q: '', a: qa.a, chips: qa.chips, foot: qa.foot, work: K.scope === 'sess' ? 'Reading this session…' : 'Reading 4 sessions…' };
    kfoot.innerHTML = `<span>${qa.foot}</span><span style="margin-left:auto">${qa.chips.length ? '<b>↵</b> open the chip</span><span>' : ''}<b>⌘↵</b> open on Home</span><span><b>esc</b> close</span>`;
    answerIn(winK, 'k', { atx: '[data-role=katx]', chips: '[data-role=kchips]', work: '[data-role=kwork]' });
  }
  placeAll();
}
$$('#kSeg button').forEach(b => b.addEventListener('click', () => { K.view = b.dataset.k; drawK(); }));
$$('#kScope button').forEach(b => b.addEventListener('click', () => { K.scope = b.dataset.s; drawK(); }));
drawK();

const N = { state: 'empty' };
const BRIEF = `Continue the Ink sidebar port in loom, on ui/ink-sidebar.

Where it stands: in "Port the sidebar to Ink tokens" (today, 11:02), steps 1 to 5 are done. The rows, the project heads and the search field read Ink's tokens, and SidebarInkTests passes (14 tests).

Next: move the footer to the Ink tokens, keeping the usage chip's meter, then run the contrast tests for the footer's pairs in both appearances.

Files: Sources/LoomCatalogUI/SidebarFooter.swift, Sources/LoomCatalogUI/LoomTheme+Sidebar.swift, Tests/LoomCatalogUITests/ContrastTests.swift.

Watch for: the Glass sidebar keeps its canvas at 0.6 over the material (D-57). "Review the gate failure" waits for an approval in SideChatFlowTests; that is a separate session.`;
let nTimer = 0;
function drawN() {
  const ta = $('#nText'), row = $('[data-role=nrow]', winN), s = N.state;
  clearTimeout(nTimer);
  $('[data-role=ndraft]', winN).hidden = s !== 'drafted';
  ta.classList.toggle('brief7', s === 'drafted');
  ta.value = s === 'drafted' ? BRIEF : '';
  row.innerHTML = s === 'reading' ? '<span class="spin">⠋</span><span>Reading 3 sessions in loom and its note…</span><button class="btn gh sm" data-act="nstop">Stop</button>'
    : s === 'drafted' ? '<span>Remora drafted the brief above. Nothing is sent until you press ↵.</span><span class="m">6.2 s</span><button class="btn gh sm" data-act="ndraft">Draft Again</button>'
    : '<span>Remora can write this session\'s brief from loom\'s recent work.</span><button class="btn sec sm" data-act="ndraft">Draft Brief</button>';
  setSeg($('#nSeg'), 'n', s);
  placeAll();
}
winN.addEventListener('click', e => {
  const a = e.target.closest('[data-act]'); if (!a) return;
  if (a.dataset.act === 'ndraft') { N.state = 'reading'; drawN(); nTimer = setTimeout(() => { N.state = 'drafted'; drawN(); }, 1700); }
  if (a.dataset.act === 'nstop' || a.dataset.act === 'nclear') { N.state = 'empty'; drawN(); }
});
$$('#nSeg button').forEach(b => b.addEventListener('click', () => { N.state = b.dataset.n; drawN(); }));
drawN();

/* ---------- pins: each beside what it names ---------- */
function pinTo(win, id, el, fx, fy, dx, dy) {
  const pin = $('#' + id); if (!pin) return;
  if (!el || el.hidden || !el.offsetParent) { pin.style.display = 'none'; return; }
  pin.style.display = '';
  const w = win.getBoundingClientRect(), r = el.getBoundingClientRect(), k = w.width / win.offsetWidth || 1;
  pin.style.left = Math.round((r.left - w.left) / k + r.width / k * fx + dx) + 'px';
  pin.style.top = Math.round((r.top - w.top) / k + r.height / k * fy + dy) + 'px';
}
function placeAll() {
  if (!ready) return;
  const br = !$('[data-role=brief]', winR).hidden, fo = !$('[data-role=fold]', winR).hidden;
  pinTo(winR, 'pinR1', br && $('.bhead .when', winR), 1, .5, 10, -9);
  pinTo(winR, 'pinR2', br && $('.rspot', winR), 0, .5, -28, -9);
  pinTo(winR, 'pinR3', br && $('.tile .th', winR), 0, 0, -30, -4);
  pinTo(winR, 'pinR4', br && $('.tile .ta', winR), 1, .5, 0, -9);
  pinTo(winR, 'pinR5', br && quiet, 1, .5, 8, -9);
  pinTo(winR, 'pinR6', br && !prop.hidden && prop, 1, .5, 8, -9);
  pinTo(winR, 'pinR7', (br && $('[data-role=askR]', winR)) || (fo && $('.rfold .askr', winR)), 1, 0, -12, -12);
  pinTo(winR, 'pinR8', br && !foot.hidden && foot, 1, .5, 8, -9);
  pinTo(winR, 'pinR9', $('#ocean-band'), .97, .06, 0, 0);
  pinTo(winA, 'pinA1', !ans.hidden && $('.q', ans), 1, .5, -60, -9);
  pinTo(winA, 'pinA2', !ans.hidden && $('[data-role=achips] .rchip', ans), 0, .5, -30, -9);
  pinTo(winA, 'pinA3', !ans.hidden && $('[data-role=achips] [data-act=draft]', ans), 1, .5, 8, -9);
  pinTo(winA, 'pinA4', !ans.hidden && $('[data-role=afoot]', ans), 0, .5, -30, -9);
  pinTo(winA, 'pinA5', !early.hidden && early, 0, .5, -30, -9);
  pinTo(winA, 'pinA6', askBox, 1, 0, -12, -12);
  const mp = $$('.mpane', winM).find(p => !p.hidden);
  pinTo(winM, 'pinM1', mp && mp.dataset.m === 'journal' && $('.jl', mp), 0, .5, -32, -9);
  pinTo(winM, 'pinM2', mp && mp.dataset.m === 'notes' && $('.memnote', mp), 0, 0, -32, 2);
  pinTo(winM, 'pinM3', mp && mp.dataset.m === 'vault' && $('.rmd', mp), 0, 0, -32, 2);
  pinTo(winM, 'pinM4', $('.msheet .sbtn', winM), 1, .5, 10, -9);
  const typing = !$('[data-role=klist]', winK).hidden;
  pinTo(winK, 'pinK1', typing && $('.palette .prow.cur', winK), 0, .5, -34, -9);
  pinTo(winK, 'pinK2', typing ? $('[data-role=kscope]', winK) : $('[data-role=kchip]', winK), 0, .5, -30, -9);
  pinTo(winK, 'pinK3', !typing && $('[data-role=kans]', winK), 0, 0, -34, 8);
  pinTo(winK, 'pinK4', $('.dhead .state', winK), 1, .5, 8, -9);
  pinTo(winN, 'pinN1', $('[data-role=nrow]', winN), 0, .5, -34, -9);
  pinTo(winN, 'pinN2', $('[data-role=nrow] .btn', winN), 1, .5, 8, -9);
  pinTo(winN, 'pinN3', N.state === 'drafted' && $('[data-role=ndraft]', winN), 0, .5, -34, -9);
  pinTo(winN, 'pinN4', $('.presets', winN), 1, .5, 10, -9);
}
addEventListener('resize', () => requestAnimationFrame(placeAll));
$('#swPins').parentElement.addEventListener('click', () => requestAnimationFrame(placeAll));
new ResizeObserver(() => requestAnimationFrame(placeAll)).observe(document.body);
if (location.search.includes('pins')) { $('#swPins').classList.add('on'); document.body.classList.add('pins'); }
$$('#themeSeg button').forEach(b => b.addEventListener('click', () => requestAnimationFrame(() => { renderBoard(); drawDiscs(); })));

/* ---------- start: the arrival plays when the brief comes into view, once; ?h=, ?c= and ?seek= hold a state for checking ---------- */
const q = new URLSearchParams(location.search);
if (q.get('h')) { R.home = q.get('h'); setSeg($('#homeSeg'), 'h', R.home); }
if (q.get('c')) { R.call = q.get('c'); setSeg($('#callSeg'), 'c', R.call); }
if (q.get('k')) { K.view = 'answer'; K.scope = q.get('k'); setSeg($('#kSeg'), 'k', 'answer'); setSeg($('#kScope'), 's', K.scope); drawK(); }
if (q.get('n')) { N.state = q.get('n'); drawN(); }
if (q.get('m')) { const b = $(`#memSeg [data-m=${q.get('m')}]`); setSeg($('#memSeg'), 'm', q.get('m')); $$('.mpane', winM).forEach(p => { p.hidden = p.dataset.m !== b.dataset.m; }); }
renderBoard(); drawDiscs();
resetBrief(); restRemora(); pair.draw();
const seekAt = q.get('seek');
if (seekAt != null) { drawR(); seek(+seekAt); }
else if (R.home !== 'morning' || R.call !== 'ok') drawR();
else new IntersectionObserver((es, io) => { if (es[0].isIntersecting) { io.disconnect(); drawR(); } }, { threshold: .45 }).observe(winR);
ready = true;
requestAnimationFrame(placeAll);
