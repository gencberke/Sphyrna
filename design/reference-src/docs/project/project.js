/* ============================================================
   The project page and the new-session page's one
   model chip. Listeners are delegated.
   ============================================================ */
const iconize = root => $$('[data-i]', root).forEach(el => { if (!el.querySelector(':scope>svg')) el.insertAdjacentHTML('afterbegin', svg(el.dataset.i)); });
const winB = $('#winB'), winC = $('#winC');
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

/* ---------- the sidebar: the chat's rows, the head of an open page, and an empty project ---------- */
const LIVE = ['work', 'attn', 'unv', 'fail'];
const rowV = (s, sel) => `<div class="row srow${s.id === sel ? ' sel' : ''}${s.stale ? ' stale' : ''}" data-s="${s.id}"><span class="ind">${mark(s.st)}</span>${hmark(s.h)}<span class="t">${s.t}</span><span class="meta">${s.meta}</span></div>` + (s.subs ? subs(s.subs, 1, []) : '');
const draftV = (s, p, withMark) => `<div class="row srow draft"${withMark ? ` style="--tone:${p.tone}"` : ''}><span class="ind"></span><span class="t">${s.t}</span>${withMark ? `<span class="pmark xs">${initial(p.name)}</span>` : ''}<span class="x" data-i="x"></span></div>`;
function groupV(p, sel, head, shut) {
  const body = shut ? '' : p.sessions.length ? p.sessions.map(s => s.draft ? draftV(s, p, false) : rowV(s, sel)).join('') : '<div class="nosess">No sessions</div>';
  return `<div class="pgroup" style="--tone:${p.tone}">
    <div class="proj-head${p.name === head ? ' sel' : ''}"><span class="pmark">${initial(p.name)}</span><span class="pn">${p.name}</span>${p.dot ? `<i class="dot ${p.dot}" style="width:6px;height:6px"></i>` : ''}<span class="chev" data-i="${shut ? 'chev-r' : 'chev-d'}"></span></div>
    ${body}
  </div>`;
}
const cardV = (s, p, sel, active) => `<div class="scard${s.id === sel ? ' sel' : ''}${s.subs ? ' tree' : ''}" data-s="${s.id}" style="--tone:${p.tone}">
    <div class="c1"><span class="ind">${mark(s.st)}</span>${hmark(s.h)}<span class="t">${s.t}</span><span class="meta">${s.meta}</span></div>
    ${active ? `<div class="why"${s.why ? '' : ' hidden'}>${s.why || ''}</div>` : ''}
    <div class="c3">${s.br ? `<span class="bi" data-i="branch"></span><span class="bn">${s.br}</span>` : ''}<span class="pj"><span class="pmark xs">${initial(p.name)}</span>${p.name}</span></div>
  </div>` + (s.subs ? subs(s.subs, 1, []) : '');
function activityV(list, sel) {
  const all = list.flatMap(p => p.sessions.map(s => ({ s, p })));
  const drafts = all.filter(x => x.s.draft), rows = all.filter(x => !x.s.draft).sort((a, b) => a.s.ago - b.s.ago);
  const isActive = x => LIVE.includes(x.s.st) || x.s.id === sel;
  const active = rows.filter(isActive), days = [];
  rows.filter(x => !isActive(x)).forEach(x => { const d = x.s.day || 'Today'; let g = days.find(g => g.d === d); if (!g) days.push(g = { d, list: [] }); g.list.push(x); });
  const head = (t, n) => `<div class="ahead">${t}${n ? `<span class="n">${n}</span>` : ''}</div>`;
  return (drafts.length ? head('Drafts', drafts.length) + drafts.map(({ s, p }) => draftV(s, p, true)).join('') : '')
    + head('Active', active.length) + active.map(({ s, p }) => cardV(s, p, sel, true)).join('')
    + days.map(g => head(g.d) + g.list.map(({ s, p }) => cardV(s, p, sel, false)).join('')).join('');
}
function drawSide(side) {
  const sel = side.dataset.sel, head = side.dataset.head, shut = (side.dataset.collapse || '').split(' ');
  const list = side.dataset.extra ? [...PROJECTS, DOTFILES] : PROJECTS;
  side.innerHTML = sidebar(sel);
  $('.side-sec', side).innerHTML = '<span class="label" data-role="vlabel">Projects</span><span class="view"><button class="on" data-view="projects" title="Group by project · ⌘2">projects</button> · <button data-view="activity" title="Recent activity · ⌘1">activity</button></span>';
  $('.plist', side).innerHTML = list.map(p => groupV(p, sel, head, shut.includes(p.name))).join('');
  $('.plist', side).insertAdjacentHTML('afterend', `<div class="alist">${activityV(list, sel)}</div>`);
  iconize(side);
  setView(side, side.dataset.view || 'projects');
}
function setView(side, v) {
  side.dataset.view = v;
  $$('.view button', side).forEach(b => b.classList.toggle('on', b.dataset.view === v));
  $('[data-role=vlabel]', side).textContent = v === 'activity' ? 'Activity' : 'Projects';
}
$$('.side[data-sel]').forEach(drawSide);

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
const LNAME = { none: 'None', low: 'Low', medium: 'Medium', high: 'High', xhigh: 'Extra high', max: 'Max' };
const levelsOf = box => box.dataset.levels.split(' ');
function buildSlider(box) {
  const lv = levelsOf(box), n = lv.length, at = k => n > 1 ? k / (n - 1) * 100 : 0;
  box.innerHTML = '<span class="trk"></span><span class="fill"></span>' + lv.map((_, k) => `<span class="stop" style="left:${at(k)}%"></span>`).join('') + '<span class="th"></span>';
  const names = $('.lvls', box.closest('.effort')); if (names) names.innerHTML = lv.map(l => `<span>${l}</span>`).join('');
}
function paintSlider(box, level) {
  const lv = levelsOf(box), n = lv.length, i = Math.max(0, lv.indexOf(level)), pct = n > 1 ? i / (n - 1) * 100 : 0;
  box.dataset.level = lv[i];
  $('.fill', box).style.width = pct + '%'; $('.th', box).style.left = pct + '%';
  $$('.stop', box).forEach((d, k) => d.classList.toggle('in', k < i));
  const root = box.closest('.effort');
  $$('.lvls span', root).forEach((sp, k) => sp.classList.toggle('on', k === i));
  const t = $('[data-role=efftitle]', root); if (t) t.textContent = LNAME[lv[i]];
  const r = $('[data-act=effreset]', root); if (r) r.classList.toggle('dis', lv[i] === (box.dataset.base || 'high'));
}
$$('[data-role=slider]').forEach(b => { buildSlider(b); paintSlider(b, b.dataset.level || 'high'); });
function setEffort(win, box, level) {
  paintSlider(box, level);
  if (!win) return;
  const e = $('[data-role=effname]', win); if (e) e.textContent = LNAME[box.dataset.level];
}
const draftModels = $('#draftModels'), modelChip = $('[data-role=modelchip]', winB);
function pickModel(row) {
  const menu = row.closest('.pop'), box = $('[data-role=slider]', menu), eff = box.closest('.effort'), lv = row.dataset.levels;
  $$('.mrow .ck', menu).forEach(c => c.innerHTML = '');
  $('.ck', row).innerHTML = svg('check');
  $$('.mrow', menu).forEach(r => r.classList.toggle('cur', r === row));
  // A model with no effort levels gets no effort word and no track; one with other levels keeps the level, or its lowest.
  eff.classList.toggle('none', !lv);
  if (lv && lv !== box.dataset.levels) {
    const was = box.dataset.level; box.dataset.levels = lv; buildSlider(box);
    const L = levelsOf(box); paintSlider(box, L.includes(was) ? was : L[0]);
  }
  if (menu.classList.contains('static')) return;
  // On a new session the model decides the harness: the chip's mark says which one the session starts on.
  const h = row.closest('.hgrp').dataset.h, hm = $('[data-role=hmark]', modelChip);
  hm.className = `hm ${h}`; hm.title = HNAME[h];
  $('[data-role=modelname]', modelChip).textContent = row.dataset.model === 'Default' ? 'Default model' : row.dataset.model;
  const en = $('[data-role=effname]', modelChip); en.hidden = !lv; if (lv) en.textContent = LNAME[box.dataset.level];
  $('#draftSendB').title = `Start a ${HNAME[h]} session`;
  if (menu.classList.contains('open')) placeBelow(menu, modelChip);
}
// A build that cannot start Codex: its entries are off, and its models are listed dimmed.
function setCodex(on) {
  $$('[data-codex]').forEach(el => el.classList.toggle('dis', !on));
  $$('[data-codex-note]').forEach(el => el.hidden = on);
  const g = $('.hgrp[data-h=codex]', draftModels);
  g.classList.toggle('later', !on);
  $$('.mrow', g).forEach(r => r.classList.toggle('dis', !on));
  $('.hnote', g).textContent = on ? '' : 'in a later version';
  if (!on && $('.ck svg', g)) pickModel($('.mrow[data-model="Opus 5.5"]', draftModels));
}
$$('#codexSeg button').forEach(b => b.addEventListener('click', () => setCodex(b.dataset.codexSet === 'on')));
document.addEventListener('keydown', e => {
  if (!draftModels.classList.contains('open')) return;
  const box = $('[data-role=slider]', draftModels), k = e.key;
  if (k === 'ArrowLeft' || k === 'ArrowRight') {
    if (!box.closest('.effort').classList.contains('none')) {
      const L = levelsOf(box), i = L.indexOf(box.dataset.level) + (k === 'ArrowRight' ? 1 : -1);
      if (i >= 0 && i < L.length) setEffort(winB, box, L[i]);
    }
  } else if (k === 'ArrowDown' || k === 'ArrowUp') {
    const rows = $$('.mrow:not(.dis)', draftModels); let i = rows.findIndex(r => r.classList.contains('cur'));
    if (i < 0) i = rows.findIndex(r => $('.ck svg', r));
    i = (i + (k === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length;
    rows.forEach((r, n) => r.classList.toggle('cur', n === i));
  } else if (k === 'Enter') {
    const c = $('.mrow.cur', draftModels); if (c && !$('.ck svg', c)) pickModel(c);
    closeAll();
  } else return;
  e.preventDefault(); e.stopImmediatePropagation();
}, true);
const draftText = $('#draftTextB'), draftSend = $('#draftSendB');
draftText.addEventListener('input', () => draftSend.classList.toggle('ready', draftText.value.trim().length > 0));

/* ---------- the project's colour, from the menu ---------- */
const TONE = { rose: 'Rose', orchid: 'Orchid', aqua: 'Aqua', mint: 'Mint', sage: 'Sage', lemon: 'Lemon', none: 'None' };
function setTone(sw) {
  const k = sw.dataset.tone, v = k === 'none' ? 'var(--fg-2)' : `var(--${k})`;
  PROJECTS[0].tone = v;
  $$('.swt', sw.parentElement).forEach(x => x.classList.toggle('on', x === sw));
  $('[data-role=tonename]', sw.closest('.pop')).textContent = TONE[k];
  $$('.ppage[data-proj=loom], #winB .draftpage').forEach(el => el.style.setProperty('--tone', v));
  $$('.side[data-sel]').forEach(drawSide);
}

/* ---------- frame C: second-brain, or a project with no sessions ---------- */
$$('#cSeg button').forEach(b => b.addEventListener('click', () => {
  const name = b.dataset.cproj;
  $$('.ppage[data-cpage]', winC).forEach(p => p.hidden = p.dataset.cpage !== name);
  const side = $('.side', winC); side.dataset.head = name; drawSide(side);
}));

/* ---------- one delegated listener for clicks ---------- */
document.addEventListener('click', e => {
  const t = e.target, win = t.closest('.win');
  if (t.closest('[data-open]')) return;
  const vb = t.closest('.side .view button'); if (vb) return setView(vb.closest('.side'), vb.dataset.view);
  const jump = t.closest('[data-jump]'); if (jump) { $(jump.dataset.jump).scrollIntoView({ behavior: 'smooth', block: 'start' }); return; }
  const tab = t.closest('.ptabs .itab');
  if (tab) {
    const page = tab.closest('.ppage');
    $$('.ptabs .itab', page).forEach(x => x.classList.toggle('on', x === tab));
    $$('.ppanel', page).forEach(p => p.hidden = p.dataset.ptab !== tab.dataset.ptab);
    page.scrollTop = 0; return;
  }
  const sw = t.closest('.swt'); if (sw && !sw.closest('.static')) return setTone(sw);
  const model = t.closest('.mrow[data-model]'); if (model) { if (!model.classList.contains('dis')) pickModel(model); return; }
  const slider = t.closest('[data-role=slider]');
  if (slider) {
    const r = slider.getBoundingClientRect(), L = levelsOf(slider), i = Math.round(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * (L.length - 1));
    setEffort(slider.closest('.static') ? null : win, slider, L[i]); return;
  }
  const reset = t.closest('[data-act=effreset]');
  if (reset && !reset.classList.contains('dis')) { const b = $('[data-role=slider]', reset.closest('.effort')); setEffort(reset.closest('.static') ? null : win, b, b.dataset.base || 'high'); }
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
const placeAllPins = () => [winA, winB, winC].forEach(placePins);
document.addEventListener('scroll', e => { const w = e.target instanceof Element && e.target.closest('.win'); if (w) placePins(w); }, true);
// The page's own switches (the theme, the sharks, the pins, the size, the build) leave a frame's popover open.
[$('header.top'), $('#codexSeg')].forEach(el => el.addEventListener('click', e => e.stopPropagation()));
const relayout = () => requestAnimationFrame(() => { placeOpen(); placeAllPins(); });
$('#swPins').parentElement.addEventListener('click', relayout);
addEventListener('resize', relayout);
new ResizeObserver(relayout).observe(document.body);
document.addEventListener('click', () => requestAnimationFrame(placeAllPins));

/* ---------- start: the new-session frame opens with its popover showing ---------- */
const settle = () => { draftModels.classList.add('open'); placeOpen(); placeAllPins(); };
requestAnimationFrame(() => requestAnimationFrame(settle));
addEventListener('load', settle);
