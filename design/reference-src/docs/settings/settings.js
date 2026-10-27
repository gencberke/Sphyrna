/* ============================================================
   Settings and About, and the tones and Glass on the app.
   Listeners are delegated, so Settings' copy over the desktop
   works the same as the window above it.
   ============================================================ */
const iconize = root => $$('[data-i]', root).forEach(el => { if (!el.querySelector(':scope>svg')) el.insertAdjacentHTML('afterbegin', svg(el.dataset.i)); });
const winB = $('#winB'), desk = $('#winA');
const HNAME = { claude: 'Claude Code', codex: 'Codex' };
const hmark = h => `<span class="hm ${h}" title="${HNAME[h]}"></span>`;

/* ---------- the app's sidebar, as the project page draws it ---------- */
PROJECTS[0].sessions = [
  { id: 'ink', t: 'Port the sidebar to Ink tokens', st: 'work', h: 'claude', meta: 'now', ago: 0, br: 'ui/ink-sidebar',
    subs: [{ st: 'work', type: 'explorer', d: "Check the tree colour's contrast", e: '52s' }, { st: 'done', type: '1 finished' }] },
  { id: 'gate', t: 'Review the gate failure', st: 'attn', h: 'claude', meta: 'now', ago: 0, br: 'fix/side-chat-race' },
  { id: 'rc', t: 'Release C health check', st: 'unv', h: 'claude', meta: '12m', ago: 12, br: 'release/c' },
  { id: 'lb', t: 'Remora spike S10', st: '', h: 'codex', meta: '2h', ago: 120, br: 'spike/remora-s10' },
  { id: 'p2', t: 'Draw the Ink reference', st: '', h: 'claude', meta: '4h', ago: 240, br: 'swarm/1' },
  { draft: true, t: 'Try a lighter inspector…' }
];
PROJECTS[1].sessions = [
  { id: 'vm', t: 'Weekly vault maintenance', st: 'work', h: 'claude', meta: 'now', ago: 1 },
  { id: 'th', t: 'Thesis outline', st: 'unv', h: 'codex', meta: '25m', ago: 25 }
];
PROJECTS[2].sessions = [
  { id: 'jwt', t: 'Migrate auth to JWT', st: 'fail', h: 'codex', meta: '3h', ago: 180, br: 'feat/jwt-auth' },
  { id: 'rl', t: 'Rate limiter tests', st: '', h: 'codex', meta: '2d', ago: 2880, br: 'main' }
];
const rowV = (s, sel) => `<div class="row srow${s.id === sel ? ' sel' : ''}" data-s="${s.id}"><span class="ind">${mark(s.st)}</span>${hmark(s.h)}<span class="t">${s.t}</span><span class="meta">${s.meta}</span></div>` + (s.subs ? subs(s.subs, 1, []) : '');
const draftV = s => `<div class="row srow draft"><span class="ind"></span><span class="t">${s.t}</span><span class="x" data-i="x"></span></div>`;
const groupV = (p, sel) => `<div class="pgroup" style="--tone:${p.tone}">
    <div class="proj-head"><span class="pmark">${initial(p.name)}</span><span class="pn">${p.name}</span>${p.dot ? `<i class="dot ${p.dot}" style="width:6px;height:6px"></i>` : ''}<span class="chev" data-i="chev-d"></span></div>
    ${p.sessions.map(s => s.draft ? draftV(s) : rowV(s, sel)).join('')}
  </div>`;
$$('.side[data-sel]').forEach(side => {
  side.innerHTML = sidebar(side.dataset.sel);
  $('.side-sec', side).innerHTML = '<span class="label">Projects</span><span class="view"><button class="on" title="Group by project · ⌘2">projects</button> · <button title="Recent activity · ⌘1">activity</button></span>';
  $('.plist', side).innerHTML = PROJECTS.map(p => groupV(p, side.dataset.sel)).join('');
  iconize(side);
});

/* ---------- the parts sheet shows the window's own menu ---------- */
$$('[data-clone]').forEach(ph => {
  const src = $(ph.dataset.clone); if (!src) return;
  const c = src.cloneNode(true);
  c.classList.add('static'); c.classList.remove('open');
  ['data-pop', 'id', 'data-place'].forEach(a => c.removeAttribute(a));
  ['left', 'top', 'bottom', 'right'].forEach(p => c.style[p] = '');
  ph.replaceWith(c);
});

/* ---------- Settings: one window's markup, copied over the desktop at Theme ---------- */
const deskSettings = $('.swin', winB).cloneNode(true);
$('[data-settings-clone]').appendChild(deskSettings);
const FRESH = new Map();   // each window's Sessions pane as it opened, for Review again
$$('.swin').forEach(sw => FRESH.set(sw, $('[data-role=cbody]', sw).innerHTML));
function showTab(sw, key) {
  $$('.stabs .itab', sw).forEach(t => t.classList.toggle('on', t.dataset.stab === key));
  $$('.spane', sw).forEach(p => p.hidden = p.dataset.stab !== key);
}
showTab(deskSettings, 'theme');

/* ---------- the settings themselves, the same in both windows ---------- */
const STATE = { appearance: 'ink', cast: 'neutral', sidebar: 'solid', pcolors: true, face: 'chat', search: true, menubar: true, notify: true, login: false, mode: 'last', font: 14, art: true, remora: true, propose: true, brief: 'auto' };
const MODES = {
  last: { name: 'Last used in the project' }, ask: { name: 'Ask', i: 'bubble', t: 'ask' }, abe: { name: 'Ask before edits', i: 'shield', t: 'abe' },
  acc: { name: 'Accept edits', i: 'penline', t: 'acc' }, auto: { name: 'Auto', i: 'bolt', t: 'auto' }, full: { name: 'Full access', i: 'excl', t: 'full' }
};
const darkQuery = matchMedia('(prefers-color-scheme: dark)');
let syncing = false;
function paint(key) {
  const v = STATE[key];
  $$(`[data-set="${key}"]`).forEach(el => {
    if (el.classList.contains('sw')) el.classList.toggle('on', !!v);
    else $$('[data-v]', el).forEach(b => b.classList.toggle('on', b.dataset.v === v));
  });
}
function applyAppearance() {
  const v = STATE.appearance, theme = v === 'system' ? (darkQuery.matches ? 'dark' : 'light') : v === 'ink' ? 'dark' : 'light';
  syncing = true; $(`#themeSeg [data-theme-set=${theme}]`).click(); syncing = false;
}
function setState(key, v) {
  STATE[key] = v; paint(key);
  if (key === 'appearance') applyAppearance();
  if (key === 'cast') document.body.dataset.cast = v;
  if (key === 'sidebar') document.body.dataset.side = v;
  if (key === 'pcolors') document.body.classList.toggle('nopc', !v);
  if (key === 'remora') {
    $$('[data-dim]').forEach(r => r.classList.toggle('dim', !v));
    $$('[data-role=remnote]').forEach(n => n.textContent = v ? REMORA_ON : REMORA_OFF);
  }
  requestAnimationFrame(placeAllPins);
}
const REMORA_ON = $('[data-role=remnote]').textContent;
const REMORA_OFF = 'Off: Home starts with its band and Needs you, ⌘K has no Ask row, and the new-session page has no brief row. The memory stays until you clear it.';
// The top bar's switch is the same setting, said as Ink or Paper.
$$('#themeSeg button').forEach(b => b.addEventListener('click', () => { if (!syncing) { STATE.appearance = b.dataset.themeSet === 'dark' ? 'ink' : 'paper'; paint('appearance'); } }));
darkQuery.addEventListener('change', () => { if (STATE.appearance === 'system') applyAppearance(); });
function paintMode() {
  const m = MODES[STATE.mode];
  $$('[data-role=modename]').forEach(el => el.textContent = m.name);
  $$('[data-role=modeicon]').forEach(el => { el.innerHTML = m.i ? svg(m.i) : ''; el.closest('.popup').style.setProperty('--mt', m.t ? `var(--m-${m.t})` : ''); });
  $$('.mi[data-mode]').forEach(r => { const c = $('.ck2', r); if (c) c.innerHTML = r.dataset.mode === STATE.mode ? svg('check') : ''; });
}
function paintFont() {
  $$('[data-role=fontsize]').forEach(el => el.textContent = STATE.font + ' pt');
  $$('.mi[data-font]').forEach(r => $('.ck2', r).innerHTML = +r.dataset.font === STATE.font ? svg('check') : '');
}
paintMode(); paintFont();
const openAlert = (sw, name) => $(`[data-alert=${name}]`, sw).classList.add('open');
const closeAlerts = sw => $$('.salert.open', sw || document).forEach(a => a.classList.remove('open'));

/* ---------- Usage: each period's figures ---------- */
const fmtT = n => n < 1e3 ? String(n) : n < 1e6 ? +(n / 1e3).toPrecision(3) + 'K' : n < 1e9 ? +(n / 1e6).toPrecision(3) + 'M' : +(n / 1e9).toPrecision(3) + 'B';
const seeded = seed => () => (seed = seed * 16807 % 2147483647) / 2147483647;
const PERIODS = {
  '24h': { title: 'Last 24 hours', sess: 3, cost: '~$6.90', kinds: [540e3, 52e3, 18e3, 30e3], cache: '91%', bars: 24, atitle: 'Tokens per hour', peak: 'Peak 96K, 14:00', axis: ['18:00', '00:00', '06:00', '12:00', '17:00'], seed: 7 },
  '7d': { title: 'Last 7 days', sess: 7, cost: '~$31.20', kinds: [2.6e6, 310e3, 95e3, 120e3], cache: '89%', bars: 7, atitle: 'Tokens per day', peak: 'Peak 812K, Sunday', axis: ['Wed', 'Thu', 'Fri', 'Sat', 'Sun', 'Mon', 'Tue'], vals: [320, 410, 280, 150, 812, 540, 600] },
  '30d': { title: 'Last 30 days', sess: 21, cost: '~$118', kinds: [9.9e6, 1.2e6, 310e3, 420e3], cache: '88%', bars: 30, atitle: 'Tokens per day', peak: 'Peak 1.4M, 9 Oct', axis: ['21 Sep', '20 Oct'], seed: 11 },
  '90d': { title: 'Last 90 days', sess: 64, cost: '~$296', kinds: [25.1e6, 3.3e6, 790e3, 1.0e6], cache: '87%', bars: 90, atitle: 'Tokens per day', peak: 'Peak 1.9M, 2 Sep', axis: ['23 Jul', '20 Oct'], seed: 23 }
};
const KIND = ['Cache read', 'Cache write', 'Input', 'Output'];
function showPeriod(sw, key) {
  const P = PERIODS[key], total = P.kinds.reduce((a, b) => a + b, 0), r = seeded(P.seed || 1);
  $$('[data-role=period] button', sw).forEach(b => b.classList.toggle('on', b.dataset.p === key));
  $('[data-role=ptitle]', sw).textContent = P.title;
  $('[data-role=psess]', sw).textContent = P.sess === 1 ? '1 session with usage' : `${P.sess} sessions with usage`;
  $('[data-role=ptotal]', sw).textContent = fmtT(total);
  $('[data-role=ptotal]', sw).title = total.toLocaleString('en-US') + ' tokens';
  $('[data-role=pcost]', sw).textContent = P.cost;
  $('[data-role=kinds]', sw).innerHTML = P.kinds.map((v, k) => `<div class="kr"${k === 1 ? ' title="5 min ' + fmtT(Math.round(v * .7)) + ', 1 h ' + fmtT(Math.round(v * .3)) + '"' : ''}><span>${KIND[k]}</span><span class="bar"><i style="width:${(v / total * 100).toFixed(1)}%"></i></span><span class="v">${fmtT(v)}</span></div>`).join('')
    + `<div class="cache" title="Share of input-side tokens served from the cache."><span>Served from the cache</span><b>${P.cache}</b></div>`;
  const vals = P.vals || Array.from({ length: P.bars }, () => .15 + r() * .85), max = Math.max(...vals);
  $('[data-role=bars]', sw).innerHTML = vals.map((v, k) => `<i${k === vals.length - 1 ? ' class="now"' : ''} style="height:${Math.max(4, v / max * 100).toFixed(1)}%"></i>`).join('');
  $('[data-role=axis]', sw).innerHTML = P.axis.map(a => `<span>${a}</span>`).join('');
  $('[data-role=atitle]', sw).textContent = P.atitle;
  $('[data-role=apeak]', sw).textContent = P.peak;
  const M = [['Opus 5.5', .77, .84], ['Sonnet 5.5', .2, .15], ['Haiku 5.5', .03, .01]], cost = parseFloat(P.cost.replace(/[^0-9.]/g, ''));
  $('[data-role=models]', sw).innerHTML = '<span class="h">Model</span><span class="h r">Tokens</span><span class="h">Share</span><span class="h r">Est. cost</span>'
    + M.map(([n, s, c]) => `<span>${n}</span><span class="r">${fmtT(Math.round(total * s))}</span><span class="sh"><i><b style="width:${s * 100}%"></b></i>${Math.round(s * 100)}%</span><span class="r">~$${(cost * c).toFixed(cost * c < 10 ? 2 : 0)}</span>`).join('');
}
$$('.swin').forEach(sw => showPeriod(sw, '7d'));

/* ---------- Sessions: the cleanup review ---------- */
function paintClean(sw) {
  const rows = $$('[data-role=can] .crow:not(.done)', sw), on = rows.filter(r => $('.cbx', r).classList.contains('on')).length;
  const del = $('[data-act=cdelete]', sw);
  del.disabled = !on; del.textContent = on ? `Delete ${on} Session${on === 1 ? '' : 's'}` : 'Delete Sessions';
  const all = $('[data-act=selall]', sw); if (all) all.textContent = rows.length && on === rows.length ? 'Clear' : 'Select All';
}
function runDelete(sw) {
  const rows = $$('[data-role=can] .crow', sw).filter(r => $('.cbx', r).classList.contains('on'));
  $('[data-role=canlab]', sw).textContent = `Deletion results (${$$('[data-role=can] .crow', sw).length})`;
  $('[data-act=selall]', sw).hidden = true;
  $('[data-act=cdelete]', sw).hidden = true;
  $$('[data-role=can] .cbx', sw).forEach(c => c.style.visibility = 'hidden');
  rows.forEach(r => { r.classList.add('done'); $('.res', r).textContent = 'Waiting'; });
  const foot = $('[data-role=cfoot]', sw);
  rows.forEach((r, k) => setTimeout(() => {
    const res = $('.res', r); res.textContent = 'Deleted'; res.classList.add('ok'); r.classList.add('gone');
    foot.textContent = k === rows.length - 1 ? `${rows.length} deleted, 0 not deleted` : `Deleting ${k + 2} of ${rows.length}`;
  }, 420 * (k + 1)));
  foot.textContent = `Deleting 1 of ${rows.length}`;
}
function step(sw, stp, d) {
  const v = Math.max(+stp.dataset.min, Math.min(+stp.dataset.max, +stp.dataset.val + d));
  setStep(stp, v);
  $('[data-role=chg]', sw).hidden = false;
  paintDefaults(sw);
}
function setStep(stp, v) {
  stp.dataset.val = v;
  $('.v', stp).textContent = v === 1 ? '1 day' : `${v} days`;
  $('[data-d="-1"]', stp).classList.toggle('dis', v <= +stp.dataset.min);
  $('[data-d="1"]', stp).classList.toggle('dis', v >= +stp.dataset.max);
}
const paintDefaults = sw => $('[data-act=cdefaults]', sw).classList.toggle('dis', $$('.stepper', sw).every(s => s.dataset.val === s.dataset.def));

/* ---------- one delegated listener for clicks ---------- */
document.addEventListener('click', e => {
  const t = e.target, sw = t.closest('.swin');
  if (t.closest('[data-open]')) return;
  const tab = t.closest('.stabs .itab'); if (tab) { showTab(sw, tab.dataset.stab); requestAnimationFrame(placeAllPins); return; }
  const opt = t.closest('[data-set] [data-v]'); if (opt) return setState(opt.closest('[data-set]').dataset.set, opt.dataset.v);
  const swc = t.closest('.sw[data-set]'); if (swc) return setState(swc.dataset.set, !STATE[swc.dataset.set]);
  const mode = t.closest('.mi[data-mode]');
  if (mode) {
    closeAll(); if (!sw) return;
    if (mode.dataset.mode === 'full' && STATE.mode !== 'full') return openAlert(sw, 'full');
    STATE.mode = mode.dataset.mode; return paintMode();
  }
  const font = t.closest('.mi[data-font]'); if (font) { closeAll(); STATE.font = +font.dataset.font; return paintFont(); }
  const per = t.closest('[data-role=period] button'); if (per) return showPeriod(sw, per.dataset.p);
  const cbx = t.closest('[data-role=can] .crow:not(.done) .cbx'); if (cbx) { cbx.classList.toggle('on'); return paintClean(sw); }
  const pk = t.closest('.pchk'); if (pk) { pk.classList.toggle('off'); $('.cbx', pk).classList.toggle('on', !pk.classList.contains('off')); return; }
  const stp = t.closest('.stepper[data-val] button[data-d]'); if (stp) return step(sw, stp.closest('.stepper'), +stp.dataset.d);
  const a = t.closest('[data-act]'); if (!a || !sw) return;
  const act = a.dataset.act;
  if (act === 'acancel') closeAlerts(sw);
  else if (act === 'fconfirm') { STATE.mode = 'full'; paintMode(); closeAlerts(sw); }
  else if (act === 'dconfirm') { closeAlerts(sw); runDelete(sw); }
  else if (act === 'cdelete') {
    // §6's Delete for every checked session: their names, then what goes and what stays
    const rows = $$('[data-role=can] .crow:not(.done)', sw).filter(r => $('.cbx', r).classList.contains('on')), one = rows.length === 1;
    const files = rows.reduce((a, r) => a + +r.dataset.files, 0), mb = rows.reduce((a, r) => a + +r.dataset.mb, 0);
    $('[data-role=dtitle]', sw).textContent = one ? 'Delete this session?' : `Delete ${rows.length} sessions?`;
    $('[data-role=dnames]', sw).textContent = rows.map(r => $('b', r).textContent).join(', ');
    $('[data-role=dlead]', sw).textContent = one ? "Sphyrna removes it from Sphyrna, and deletes Claude's local files for it. This can't be undone." : "Sphyrna removes them from Sphyrna, and deletes Claude's local files for them. This can't be undone.";
    $('[data-role=dsize]', sw).textContent = `${files} files · ${mb < 1 ? Math.round(mb * 1000) + ' KB' : +mb.toFixed(1) + ' MB'} · in ~/.claude`;
    openAlert(sw, 'delete');
  }
  else if (act === 'selall') { const rows = $$('[data-role=can] .crow:not(.done) .cbx', sw), all = rows.every(c => c.classList.contains('on')); rows.forEach(c => c.classList.toggle('on', !all)); paintClean(sw); }
  else if (act === 'dismiss') a.closest('.dueline').remove();
  else if (act === 'cdefaults') { if (a.classList.contains('dis')) return; $$('.stepper', sw).forEach(s => setStep(s, +s.dataset.def)); $('[data-role=chg]', sw).hidden = false; paintDefaults(sw); }
  else if (act === 'creview') {
    const foot = $('[data-role=cfoot]', sw); foot.textContent = 'Reviewing';
    setTimeout(() => { $('[data-role=cbody]', sw).innerHTML = FRESH.get(sw); $('[data-act=cdelete]', sw).hidden = false; paintClean(sw); foot.textContent = 'Reviewed 17:21'; }, 700);
  }
  else if (act === 'urefresh') { const f = $('[data-role=ufoot]', sw); f.textContent = 'Reading'; setTimeout(() => f.textContent = 'Updated 17:21 · Prices as of Oct 7, 2026', 700); }
  else if (act === 'diag') { a.disabled = true; a.textContent = 'Collecting…'; setTimeout(() => { a.disabled = false; a.textContent = 'Collect Diagnostics…'; }, 1400); }
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeAlerts(); });

/* ---------- the page's own switch: the wallpaper ---------- */
$$('#wallSeg button').forEach(b => b.addEventListener('click', () => desk.dataset.wall = b.dataset.wall));

/* ---------- popovers that open under their control ---------- */
function placeBelow(pop, anchor) {
  const win = anchor.closest('.win'); if (!win) return;
  const wr = win.getBoundingClientRect(); if (!wr.width) return;
  const s = wr.width / win.offsetWidth, box = pop.offsetParent || win, br = box.getBoundingClientRect(), ar = anchor.getBoundingClientRect();
  const x0 = (ar.left - br.left) / s, x1 = (ar.right - br.left) / s, y1 = (ar.bottom - br.top) / s, W = box.offsetWidth, H = box.offsetHeight, w = pop.offsetWidth, h = pop.offsetHeight;
  pop.style.bottom = 'auto'; pop.style.right = 'auto';
  // A menu that would run off the window's bottom rises until it fits, over its control, as a pop-up menu does.
  pop.style.top = Math.max(8, Math.min(H - 8 - h, y1 + 6)) + 'px';
  pop.style.left = Math.max(8, Math.min(W - w - 8, pop.dataset.place === 'below-right' ? x1 - w : x0)) + 'px';
}
const placeOpen = () => $$('.win .pop.open[data-place^=below]').forEach(pop => { const op = $(`[data-open="${pop.dataset.pop}"]`, pop.closest('.swin') || pop.closest('.win')); if (op) placeBelow(pop, op); });
document.addEventListener('click', e => { if (e.target.closest('[data-open]')) placeOpen(); });

/* ---------- pins: each sits by the part it names, and hides when that part is out of sight ---------- */
function placePins(win) {
  if (!document.body.classList.contains('pins')) return;
  const wr = win.getBoundingClientRect(), s = wr.width / win.offsetWidth || 1;
  $$('.pin[data-for]', win).forEach(p => {
    const t = $(p.dataset.for, win);
    let vis = !!t && t.getClientRects().length > 0;
    if (vis) {
      const r = t.getBoundingClientRect();
      p.style.left = ((p.dataset.at === 'r' ? r.right : r.left) - wr.left) / s + (+p.dataset.dx || 0) + 'px';
      p.style.top = (r.top - wr.top) / s + (+p.dataset.dy || 0) + 'px';
      const sc = t.closest('.sbody');
      if (sc) { const sr = sc.getBoundingClientRect(); vis = r.bottom > sr.top + 12 * s && r.top < sr.bottom - 12 * s; }
    }
    p.style.visibility = vis ? '' : 'hidden';
  });
}
const placeAllPins = () => [winA, winB].forEach(placePins);
document.addEventListener('scroll', e => { const w = e.target instanceof Element && e.target.closest('.win'); if (w) placePins(w); }, true);
// The page's own switches (the theme, the art, the pins, the size, the wallpaper) leave a window's menu open.
[$('header.top'), $('#wallSeg')].forEach(el => el.addEventListener('click', e => e.stopPropagation()));
const relayout = () => requestAnimationFrame(() => { placeOpen(); placeAllPins(); });
$('#swPins').parentElement.addEventListener('click', relayout);
addEventListener('resize', relayout);
new ResizeObserver(relayout).observe(document.body);
document.addEventListener('click', () => requestAnimationFrame(placeAllPins));
addEventListener('load', relayout);
