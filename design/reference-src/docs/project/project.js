/* ============================================================
   The project page and the new-session page's one
   model chip. Listeners are delegated.
   ============================================================ */
const iconize = root => $$('[data-i]', root).forEach(el => { if (!el.querySelector(':scope>svg')) el.insertAdjacentHTML('afterbegin', svg(el.dataset.i)); });
const winC = $('#winC');
const HNAME = { claude: 'Claude Code', codex: 'Codex' };
const hmark = h => `<span class="hm ${h}" title="${HNAME[h]}"></span>`;
const M = s => `<span class="mono">${s}</span>`;

/* ---------- the projects: each session's harness, branch and last line ---------- */
// `ago` is minutes since the last activity (the activity view's order); `day` its heading when it is not today.
PROJECTS[0].sessions = [
  { id: 'ink', t: 'Port the sidebar to Ink tokens', st: 'work', h: 'claude', meta: 'now', ago: 0, br: 'ui/ink-sidebar', line: 'Editing ' + M('Sources/LoomCatalogUI/SidebarRow.swift'),
    subs: [{ st: 'work', type: 'explorer', d: "Check the tree colour's contrast", e: '52s' }, { st: 'done', type: '1 finished' }] },
  { id: 'gate', t: 'Review the gate failure', st: 'attn', h: 'claude', meta: 'now', ago: 0, br: 'fix/side-chat-race', line: 'Allow: ' + M('swift test -c release --filter SideChatFlowTests'),
    why: 'Allow: ' + M('swift test -c release --filter SideChatFlowTests') },
  { id: 'rc', t: 'Release C health check', st: 'unv', h: 'claude', meta: '12m', ago: 12, br: 'release/c', line: 'Four checks ran; the last answer lists one follow-up.' },
  { id: 'lb', t: 'Remora spike S10', st: '', h: 'codex', meta: '2h', ago: 120, br: 'spike/remora-s10', line: 'The notes are in ' + M('plans/v2-research/REMORA-S10.md') + '.' },
  { id: 'p2', t: 'Draw the Ink reference', st: '', h: 'claude', meta: '4h', ago: 240, br: 'swarm/1', line: 'It is in ' + M('design/reference.html') + '.' },
  { id: 'kn', t: 'Cut the ChatGPT knot', st: '', h: 'claude', meta: '5h', ago: 300, br: 'swarm/1', line: 'The knot is a template image: black on transparent, 128 px.' },
  { id: 'fx', t: 'Release C fix round 2', st: '', h: 'claude', meta: '1d', ago: 1440, day: 'Yesterday', br: 'v2', line: 'Five fixes; the gate passes on ' + M('371aaf6') + '.' },
  { id: 'rw', t: 'Rewind copy limits', st: '', h: 'codex', meta: '2d', ago: 2880, day: 'Sunday', br: 'v2', line: 'The copy lives only while its Undo is offered.' },
  { id: 'cr', t: 'Changes tab review', st: '', stale: true, h: 'claude', meta: '2w', ago: 23040, day: '4 October', br: 'v2', line: 'Comments go back to Claude as one message.' },
  { draft: true, t: 'Try a lighter inspector…' }
];
PROJECTS[1].sessions = [
  { id: 'vm', t: 'Weekly vault maintenance', st: 'work', h: 'claude', meta: 'now', ago: 1, line: 'Editing ' + M('Projects.md') },
  { id: 'th', t: 'Thesis outline', st: 'unv', h: 'codex', meta: '25m', ago: 25, line: 'The outline has six chapters and a reading list of twelve papers.' },
  { id: 'rd', t: 'Reading list for chapter 3', st: '', h: 'claude', meta: '2d', ago: 2900, day: 'Sunday', line: 'Twelve papers; four are open access.' },
  { id: 'ib', t: 'Tidy the inbox notes', st: '', h: 'codex', meta: '5d', ago: 7200, day: 'Thursday', line: 'Moved 31 notes out of the inbox.' }
];
PROJECTS[2].sessions = [
  { id: 'jwt', t: 'Migrate auth to JWT', st: 'fail', h: 'codex', meta: '3h', ago: 180, br: 'feat/jwt-auth', line: 'Failed: codex exited with code 1', why: 'Failed: codex exited with code 1' },
  { id: 'rl', t: 'Rate limiter tests', st: '', h: 'codex', meta: '2d', ago: 2880, day: 'Sunday', br: 'main', line: 'Added 12 tests; all 214 pass.' }
];
const DOTFILES = { name: 'dotfiles', tone: 'var(--rose)', sessions: [] };
const byName = n => [...PROJECTS, DOTFILES].find(p => p.name === n);
// The parts sheet's rows: one per state the last line can show.
const STATES = [
  PROJECTS[0].sessions[0], PROJECTS[0].sessions[1],
  { id: 's3', t: 'Pick the webhook fix', st: 'attn', h: 'claude', meta: '3m', br: 'fix/webhook-sig', line: 'Asks: Which fix should I make?' },
  { id: 's4', t: 'Plan the Settings round', st: 'attn', h: 'claude', meta: '8m', br: 'swarm/1', line: 'Plan ready for review' },
  PROJECTS[2].sessions[0], PROJECTS[0].sessions[2], PROJECTS[0].sessions[3], PROJECTS[0].sessions[8]
];
const LISTS = { states: STATES, narrow: [STATES[1], STATES[6]] };


/* ---------- the page: session rows and branch rows from the same data ---------- */
const srV = s => `<div class="sr${s.stale ? ' stale' : ''}${s.br ? '' : ' nobr'}" data-s="${s.id}" title="Opens the session"><div class="sr-in"><span class="ind">${mark(s.st)}</span>${hmark(s.h)}<span class="tt"><span class="t">${s.t}</span>${s.line ? `<span class="sl">${s.line}</span>` : ''}</span>${s.br ? `<span class="bc"><span data-i="branch"></span><span>${s.br}</span></span>` : ''}<span class="ts">${s.meta}</span></div></div>`;
$$('[data-list]').forEach(el => {
  const rows = LISTS[el.dataset.list] || byName(el.dataset.list).sessions.filter(s => !s.draft);
  el.innerHTML = rows.map(srV).join(''); iconize(el);
});
// The current branch first, then by when each one changed; a branch another worktree has checked out names that folder.
const BRANCHES = {
  loom: [
    { n: 'swarm/1', cur: true, s: 2, t: 'now' },
    { n: 'ui/ink-sidebar', wt: '~/Library/Caches/loom-v2/wt/ink', s: 1, t: 'now' },
    { n: 'release/c', s: 1, t: '12m' },
    { n: 'fix/side-chat-race', wt: '~/Library/Caches/loom-v2/wt/sideflake', s: 1, t: '1h' },
    { n: 'v2', wt: '~/Library/Caches/loom-v2/wt/v2', s: 3, t: '2h' },
    { n: 'spike/remora-s10', s: 1, t: '2h' },
    { n: 'main', s: 0, t: '3d' }
  ],
  dotfiles: [{ n: 'main', cur: true, s: 0, t: '3w' }]
};
const brV = b => `<div class="brw${b.cur ? ' cur' : ''}"><span class="g" data-i="branch"></span><span class="bn2">${b.n}</span>${b.cur ? '<span class="cur2">current</span>' : b.wt ? `<span class="wt">worktree <b>${b.wt}</b></span>` : ''}<span class="ns">${b.s ? (b.s === 1 ? '1 session' : b.s + ' sessions') : ''}</span><span class="ts">${b.t}</span></div>`;
$$('[data-branches]').forEach(el => { el.innerHTML = BRANCHES[el.dataset.branches].slice(0, +el.dataset.max || 99).map(brV).join(''); iconize(el); });

/* ---------- the parts sheet shows the frames' own menus ---------- */
$$('[data-clone]').forEach(ph => {
  const src = $(ph.dataset.clone); if (!src) return;
  const c = src.cloneNode(true);
  c.classList.add('static'); c.classList.remove('open');
  ['data-pop', 'id', 'data-place'].forEach(a => c.removeAttribute(a));
  ['left', 'top', 'bottom', 'right'].forEach(p => c.style[p] = '');
  ph.replaceWith(c);
});

/* ---------- popovers that open under their control ---------- */
function placeBelow(pop, anchor) {
  const win = anchor.closest('.win'); if (!win) return;
  const wr = win.getBoundingClientRect(); if (!wr.width) return;
  const s = wr.width / win.offsetWidth, ar = anchor.getBoundingClientRect();
  const x0 = (ar.left - wr.left) / s, x1 = (ar.right - wr.left) / s, y1 = (ar.bottom - wr.top) / s;
  pop.style.bottom = 'auto'; pop.style.right = 'auto';
  pop.style.top = (y1 + 6) + 'px';
  const w = pop.offsetWidth;
  pop.style.left = Math.max(8, Math.min(win.offsetWidth - w - 8, pop.dataset.place === 'below-right' ? x1 - w : x0)) + 'px';
}
const placeOpen = () => $$('.win .pop.open[data-place^=below]').forEach(pop => { const op = $(`[data-open="${pop.dataset.pop}"]`, pop.closest('.win')); if (op) placeBelow(pop, op); });
// The shared listener opens a popover; this one puts it under the control that opened it.
document.addEventListener('click', e => { if (e.target.closest('[data-open]')) placeOpen(); });

/* ---------- the one model chip: models by harness, the effort under them ---------- */
/* ---------- the project's colour, from the menu ---------- */
const TONE = { rose: 'Rose', orchid: 'Orchid', aqua: 'Aqua', mint: 'Mint', sage: 'Sage', lemon: 'Lemon', none: 'None' };
function setTone(sw) {
  const k = sw.dataset.tone, v = k === 'none' ? 'var(--fg-2)' : `var(--${k})`;
  PROJECTS[0].tone = v; I4_PROJECTS[0].tone = v;
  $$('.swt', sw.parentElement).forEach(x => x.classList.toggle('on', x === sw));
  $('[data-role=tonename]', sw.closest('.pop')).textContent = TONE[k];
  $$('.ppage[data-proj=loom]').forEach(el => el.style.setProperty('--tone', v));
  $$('.i4side').forEach(i4sidebar);
}

/* ---------- frame C: second-brain, or a project with no sessions ---------- */
$$('#cSeg button').forEach(b => b.addEventListener('click', () => {
  const name = b.dataset.cproj;
  $$('.ppage[data-cpage]', winC).forEach(p => p.hidden = p.dataset.cpage !== name);
  const side = $('.i4side', winC); side.dataset.i4open = name; i4sidebar(side);
}));

/* ---------- one delegated listener for clicks ---------- */
document.addEventListener('click', e => {
  const t = e.target, win = t.closest('.win');
  if (t.closest('[data-open]')) return;
  const jump = t.closest('[data-jump]'); if (jump) { $(jump.dataset.jump).scrollIntoView({ behavior: 'smooth', block: 'start' }); return; }
  const tab = t.closest('.ptabs .itab');
  if (tab) {
    const page = tab.closest('.ppage');
    $$('.ptabs .itab', page).forEach(x => x.classList.toggle('on', x === tab));
    $$('.ppanel', page).forEach(p => p.hidden = p.dataset.ptab !== tab.dataset.ptab);
    page.scrollTop = 0; return;
  }
  const sw = t.closest('.swt'); if (sw && !sw.closest('.static')) return setTone(sw);
});

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
      const sc = t.closest('.ppage');
      if (sc) { const sr = sc.getBoundingClientRect(); vis = r.bottom > sr.top + 12 * s && r.top < sr.bottom - 12 * s; }
    }
    p.style.visibility = vis ? '' : 'hidden';
  });
}
const placeAllPins = () => [winA, winC].forEach(placePins);
document.addEventListener('scroll', e => { const w = e.target instanceof Element && e.target.closest('.win'); if (w) placePins(w); }, true);
// The page's own switches (the theme, the pins, the size, the build) leave a frame's popover open.
[$('header.top')].forEach(el => el.addEventListener('click', e => e.stopPropagation()));
const relayout = () => requestAnimationFrame(() => { placeOpen(); placeAllPins(); });
$('#swPins').parentElement.addEventListener('click', relayout);
addEventListener('resize', relayout);
new ResizeObserver(relayout).observe(document.body);
document.addEventListener('click', () => requestAnimationFrame(placeAllPins));
