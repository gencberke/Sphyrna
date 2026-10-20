/* ============================================================
   The chat's behaviour. Listeners are delegated, so a
   frame's reset (its first markup put back) keeps working.
   ============================================================ */
const iconize = root => $$('[data-i]', root).forEach(el => { if (!el.querySelector(':scope>svg')) el.insertAdjacentHTML('afterbegin', svg(el.dataset.i)); });
const esc = s => s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const fmt = s => s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`;
const winB = $('#winB'), winC = $('#winC');
const chatOf = el => el && el.closest('.chat');

/* ---------- the parts sheet shows the frames' own menus ---------- */
$$('[data-clone]').forEach(ph => {
  const src = $(ph.dataset.clone); if (!src) return;
  const c = src.cloneNode(true);
  c.classList.add('static'); c.classList.remove('open');
  ['data-pop', 'id', 'data-place'].forEach(a => c.removeAttribute(a));
  ['left', 'top', 'bottom', 'right'].forEach(p => c.style[p] = '');
  ph.replaceWith(c);
});

/* ---------- the sidebar: each session's harness, and the two views ---------- */
const HNAME = { claude: 'Claude Code', codex: 'Codex' };
const hmark = h => `<span class="hm ${h}" title="${HNAME[h]}"></span>`;
// What the sidebar knows beyond the shared rows: the harness, the branch, minutes since the last activity, and a reason.
const MORE = {
  ink: { h: 'claude', br: 'ui/ink-sidebar', ago: 0 },
  gate: { h: 'claude', br: 'fix/side-chat-race', ago: 0 },
  vm: { h: 'claude', br: 'main', ago: 1 },
  rc: { h: 'claude', br: 'release/c', ago: 12 },
  th: { h: 'codex', br: 'main', ago: 25 },
  lb: { h: 'codex', br: 'spike/remora-s10', ago: 120 },
  jwt: { h: 'codex', br: 'feat/jwt-auth', ago: 180, why: 'Failed: codex exited with code 1' },
  rl: { h: 'codex', br: 'main', ago: 2880, day: 'Sunday' }
};
PROJECTS.forEach(p => p.sessions.forEach(s => { if (s.id) Object.assign(s, MORE[s.id]); }));
const LIVE = ['work', 'attn', 'unv', 'fail'];
const rowV = (s, sel) => `<div class="row srow${s.id === sel ? ' sel' : ''}" data-s="${s.id}"><span class="ind">${mark(s.st)}</span>${hmark(s.h)}<span class="t">${s.t}</span><span class="meta">${s.meta}</span></div>` + (s.subs ? subs(s.subs, 1, []) : '');
const draftV = (s, p, withMark) => `<div class="row srow draft"${withMark ? ` style="--tone:${p.tone}"` : ''}><span class="ind"></span><span class="t">${s.t}</span>${withMark ? `<span class="pmark xs">${initial(p.name)}</span>` : ''}<span class="x" data-i="x"></span></div>`;
function groupV(p, sel, over) {
  return `<div class="pgroup" style="--tone:${p.tone}">
    <div class="proj-head"><span class="pmark">${initial(p.name)}</span><span class="pn">${p.name}</span>${p.dot ? `<i class="dot ${p.dot}" style="width:6px;height:6px"></i>` : ''}<span class="chev" data-i="chev-d"></span></div>
    ${p.sessions.map(s => s.draft ? draftV(s, p, false) : rowV({ ...s, ...over[s.id] }, sel)).join('')}
  </div>`;
}
// A card: the harness's mark, the title and the time; in Active, the reason; then the branch and the project.
const cardV = (s, p, sel, active) => `<div class="scard${s.id === sel ? ' sel' : ''}${s.subs ? ' tree' : ''}" data-s="${s.id}" style="--tone:${p.tone}">
    <div class="c1"><span class="ind">${mark(s.st)}</span>${hmark(s.h)}<span class="t">${s.t}</span><span class="meta">${s.meta}</span></div>
    ${active ? `<div class="why"${s.why ? '' : ' hidden'}>${s.why || ''}</div>` : ''}
    <div class="c3"><span class="bi" data-i="branch"></span><span class="bn">${s.br}</span><span class="pj"><span class="pmark xs">${initial(p.name)}</span>${p.name}</span></div>
  </div>` + (s.subs ? subs(s.subs, 1, []) : '');
function activityV(sel, over) {
  const all = PROJECTS.flatMap(p => p.sessions.map(s => ({ s: s.draft ? s : { ...s, ...over[s.id] }, p })));
  const drafts = all.filter(x => x.s.draft), rows = all.filter(x => !x.s.draft).sort((a, b) => a.s.ago - b.s.ago);
  // Active: a run under way or an end nobody read; the selected session is held until another one is selected.
  const isActive = x => LIVE.includes(x.s.st) || x.s.id === sel;
  const active = rows.filter(isActive), days = [];
  rows.filter(x => !isActive(x)).forEach(x => { const d = x.s.day || 'Today'; let g = days.find(g => g.d === d); if (!g) days.push(g = { d, list: [] }); g.list.push(x); });
  const head = (t, n) => `<div class="ahead">${t}${n ? `<span class="n">${n}</span>` : ''}</div>`;
  return (drafts.length ? head('Drafts', drafts.length) + drafts.map(({ s, p }) => draftV(s, p, true)).join('') : '')
    + head('Active', active.length) + active.map(({ s, p }) => cardV(s, p, sel, true)).join('')
    + days.map(g => head(g.d) + g.list.map(({ s, p }) => cardV(s, p, sel, false)).join('')).join('');
}
function drawSide(side) {
  const sel = side.dataset.sel, idle = side.dataset.idle, over = idle ? { [idle]: { st: '', meta: '14:06', subs: null } } : {};
  side.innerHTML = sidebar(sel);
  $('.side-sec', side).innerHTML = '<span class="label" data-role="vlabel">Projects</span><span class="view"><button class="on" data-view="projects" title="Group by project · ⌘2">projects</button> · <button data-view="activity" title="Recent activity · ⌘1">activity</button></span>';
  $('.plist', side).innerHTML = PROJECTS.map(p => groupV(p, sel, over)).join('');
  $('.plist', side).insertAdjacentHTML('afterend', `<div class="alist">${activityV(sel, over)}</div>`);
  iconize(side);
}
function setView(side, v) {
  side.dataset.view = v;
  $$('.view button', side).forEach(b => b.classList.toggle('on', b.dataset.view === v));
  $('[data-role=vlabel]', side).textContent = v === 'activity' ? 'Activity' : 'Projects';
}
$$('.side[data-sel]').forEach(drawSide);
setView($('.side', winB), 'activity');

/* ---------- frame C is the same session after its first turn ---------- */
(() => {
  const src = $('.col', winA), dst = $('[data-copy-from]', winC);
  for (const n of src.children) { dst.appendChild(n.cloneNode(true)); if (n.classList.contains('ccard')) break; }
  const you = $('.you', dst); you.classList.add('hov');
  const rw = $('.lk2[data-i=rewind]', you); rw.classList.remove('dis'); rw.title = 'Rewind Files to Before This Message';
  $('.reply', dst).classList.add('hov');
})();

/* ---------- state: the header's pill, the open tab and the sidebar row agree ---------- */
function setState(win, kind, text) {
  const st = $('.dhead [data-role=state]', win);
  const m = { working: ['state', mark('work') + 'Working'], ready: ['state idle', 'Ready'], attn: ['state attn', '<i class="dot attn"></i>' + (text || 'Needs approval')] }[kind];
  if (st && m) { st.hidden = false; st.className = m[0]; st.innerHTML = m[1]; }
  if (st && kind === 'ended') st.hidden = true;
  const ind = kind === 'working' ? mark('work') : kind === 'attn' ? mark('attn') : '';
  const tab = $('.tab.on .ind', win); if (tab) tab.innerHTML = ind;
  $$('.side .srow.sel .ind, .side .scard.sel .ind', win).forEach(r => r.innerHTML = ind);
}

/* ---------- the composer: Send says what Return does ---------- */
let metaHeld = false, activeChat = $('.chat', winA);
const HINTS = {
  idle: ['<b>↵</b> send', '<b>⇧↵</b> new line', '<b>@</b> files and sessions', '<b>/</b> commands and skills', '<b>↑</b> earlier messages'],
  working: ['<b>↵</b> send now', '<b>⌘↵</b> after this turn', '<b>esc</b> interrupt', '<b>@</b> files and sessions', '<b>/</b> commands and skills'],
  waiting: ['<b>↵</b> send now', '<b>⌘↵</b> after this turn', '<b>@</b> files and sessions', '<b>/</b> commands and skills'],
  editing: ['<b>↵</b> update', '<b>esc</b> cancel the edit', '<b>⇧↵</b> new line']
};
function sendState(chat) {
  const ta = $('[data-role=text]', chat), text = ta ? ta.value.trim() : '', run = chat.dataset.run;
  if (chat.classList.contains('compact')) return 'card';
  if (chat.dataset.editing) return 'update';
  if (run === 'working' || run === 'waiting') return text ? (metaHeld ? 'after' : 'now') : (run === 'working' ? 'stop' : 'off');
  const q = $('[data-role=queue]', chat);
  if (!text && q && q.classList.contains('paused') && $('.qrow', q)) return 'resume';
  return text ? 'send' : 'off';
}
function paintSend(chat) {
  const b = $('[data-role=send]', chat); if (!b) return;
  const st = sendState(chat), [cls, icon, word, title] = {
    off: ['', 'up', '', 'Send'], send: ['ready', 'up', '', 'Send · ↵'], stop: ['stop', '', '', 'Interrupt · esc'],
    now: ['word', 'up', 'Send Now', 'Claude reads it after the current step · ↵'], after: ['word', 'after', 'After this turn', 'Into the queue · ⌘↵'],
    update: ['word', 'check', 'Update', 'Update the queued message · ↵'], resume: ['word', 'play', 'Resume', 'Send the paused queue'],
    card: ['', 'up', '', 'Answer the request on its card']
  }[st];
  b.className = 'send' + (cls ? ' ' + cls : '');
  b.disabled = st === 'off' || st === 'card';
  b.innerHTML = st === 'stop' ? '<span class="sq"></span>' : svg(icon) + word;
  b.title = title; b.dataset.state = st;
  const keys = $('[data-role=keys]', chat);
  if (keys) {
    const k = st === 'update' ? 'editing' : (st === 'stop' || st === 'now' || st === 'after') ? 'working' : chat.dataset.run === 'waiting' ? 'waiting' : 'idle';
    keys.innerHTML = HINTS[k].map(h => `<span>${h}</span>`).join('');
  }
  const ta = $('[data-role=text]', chat);
  if (ta && !chat.classList.contains('compact')) ta.placeholder = chat.dataset.editing ? 'Edit the queued message'
    : (chat.dataset.run === 'working' || chat.dataset.run === 'waiting') ? 'Message Claude; it reads it after the current step' : 'Message Claude, or / for commands, @ for files';
}
function grow(ta) {
  const chat = chatOf(ta), base = chat && chat.classList.contains('compact') ? 22 : 44;
  ta.style.height = 'auto'; ta.style.height = Math.min(176, Math.max(base, ta.scrollHeight)) + 'px';
}
const youHTML = (text, marks) => `<div class="you"${marks.includes('Waiting') ? ' data-role="sent"' : ''}><div class="bubble">${esc(text)}</div>`
  + (marks ? `<div class="you-mark">${marks}</div>` : '')
  + `<div class="you-foot"><span class="tm">now</span><button class="ib sm" title="Copy" data-i="copy"></button></div></div>`;
const WAIT = '<i>·</i><span data-role="wait">Waiting for the current step</span><button class="lk2 acc" data-act="readnow">Read Now</button>';
function insertBeforeLive(chat, html) {
  const col = $('.col', chat), live = $('.col>[data-live]', chat);
  const box = document.createElement('div'); box.innerHTML = html; iconize(box);
  const nodes = [...box.children];
  nodes.forEach(n => live ? col.insertBefore(n, live) : col.appendChild(n));
  return nodes[0];
}
function liveHTML(verb, arg) {
  return `<div data-live><div class="live"><span class="mk2"><span class="spin">${SPIN[si]}</span></span>${verb}${arg ? ` <span class="ar">${arg}</span>` : ''}<i>·</i><span class="clk" data-clock="0">0s</span></div></div>`;
}
function scrollEnd(chat, smooth) { const sc = $('.scroller', chat); if (sc) sc.scrollTo({ top: sc.scrollHeight, behavior: smooth ? 'smooth' : 'auto' }); }

/* ---------- pins: each sits by the part it names, and hides when that part scrolls away ---------- */
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
      const sc = t.closest('.scroller');
      if (sc) {
        // A part cut by the stream's edge keeps its pin inside the stream.
        const sr = sc.getBoundingClientRect(), top = (sr.top - wr.top) / s + 6, bottom = (sr.bottom - wr.top) / s - 24;
        vis = r.bottom > sr.top + 12 * s && r.top < sr.bottom - 12 * s;
        p.style.top = Math.min(bottom, Math.max(top, parseFloat(p.style.top))) + 'px';
      }
    }
    p.style.visibility = vis ? '' : 'hidden';
  });
}
const placeAllPins = () => [winA, winB, winC].forEach(placePins);
function startTurn(chat, text, marks) {
  const win = chat.closest('.win');
  insertBeforeLive(chat, youHTML(text, marks || ''));
  $$('.col>[data-live]', chat).forEach(n => n.remove());
  $('.col', chat).insertAdjacentHTML('beforeend', liveHTML('Thinking'));
  chat.dataset.run = 'working';
  setState(win, 'working');
  paintSend(chat); scrollEnd(chat, true);
}
function send(chat, how) {
  const ta = $('[data-role=text]', chat), text = ta.value.trim(); if (!text) return;
  const st = sendState(chat);
  if (st === 'card') return;
  if (st === 'update') return updateQueued(chat);
  ta.value = ''; grow(ta);
  if (how === 'after' || st === 'after') { queueAdd(chat, text); }
  else if (st === 'now' || chat.dataset.run === 'working') { insertBeforeLive(chat, youHTML(text, '<span>Sent while Claude worked</span>' + WAIT)); scrollEnd(chat, true); }
  else startTurn(chat, text);
  paintSend(chat);
}
function interrupt(chat) {
  if (chat.dataset.run !== 'working') return;
  const win = chat.closest('.win'), clk = $('.col>[data-live] [data-clock]', chat), secs = clk ? +clk.dataset.clock : 0;
  chat.dataset.run = 'stopped';
  $$('.col>[data-live]', chat).forEach(n => n.remove());
  $('.col', chat).insertAdjacentHTML('beforeend', `<div class="marker">You stopped after ${fmt(secs)}</div>`);
  $$('.acard.work', chat).forEach(c => {
    c.classList.remove('work'); $('.ind', c).innerHTML = '<i class="ring"></i>'; $('.el', c).textContent = 'stopped';
    const nw = $('[data-role=newest]', c); if (nw) nw.textContent = 'Stopped with the turn.';
    const ft = $('.ft', c); if (ft) ft.remove();
    const h = $('.agents-h', c.parentElement); if (h) h.lastChild.textContent = '2 agents · 1 stopped · 1 done';
  });
  // A message Claude had not read comes back to the composer, in front of what you typed.
  const ta = $('[data-role=text]', chat), back = [];
  $$('[data-role=sent]', chat).forEach(s => { if ($('[data-role=wait]', s)) { back.push($('.bubble', s).textContent); s.remove(); } });
  if (back.length) { ta.value = [...back, ta.value.trim()].filter(Boolean).join('\n\n'); grow(ta); }
  const q = $('[data-role=queue]', chat); if (q && $('.qrow', q)) q.classList.add('paused');
  setState(win, 'ready');
  paintSend(chat); scrollEnd(chat, true);
}

/* ---------- the queue ---------- */
function queueCount(chat) {
  const q = $('[data-role=queue]', chat); if (!q) return;
  const n = $$('.qrow', q).length; const c = $('[data-role=qcount]', q); if (c) c.textContent = n;
  q.hidden = n === 0; if (!n) q.classList.remove('paused');
}
function queueAdd(chat, text) {
  const q = $('[data-role=queue]', chat); if (!q) return;
  q.insertAdjacentHTML('beforeend', `<div class="qrow"><span class="wi" data-i="after"></span><span class="t">${esc(text)}</span><span class="qa"><button class="btn gh sm" data-act="qedit">Edit</button><button class="btn gh sm" data-act="qsend">Send Now</button><button class="ib sm" title="Remove" data-act="qremove" data-i="x"></button></span></div>`);
  iconize(q); q.classList.remove('shut'); queueCount(chat);
}
let editRow = null, savedDraft = '';
function editQueued(chat, row) {
  const ta = $('[data-role=text]', chat);
  savedDraft = ta.value; editRow = row; row.classList.add('editing');
  chat.dataset.editing = '1'; ta.value = $('.t', row).textContent; grow(ta); ta.focus({ preventScroll: true });
  paintSend(chat);
}
function endEdit(chat, keep) {
  const ta = $('[data-role=text]', chat);
  if (editRow) { if (keep && ta.value.trim()) $('.t', editRow).textContent = ta.value.trim(); editRow.classList.remove('editing'); }
  editRow = null; delete chat.dataset.editing; ta.value = savedDraft; savedDraft = ''; grow(ta); paintSend(chat);
}
function updateQueued(chat) { endEdit(chat, true); }

/* ---------- views: Normal, Thinking, Verbose (⌃O) ---------- */
const VIEWS = ['normal', 'thinking', 'verbose'], VNAME = { normal: 'Normal', thinking: 'Thinking', verbose: 'Verbose' };
function cycleView(chat) {
  const next = VIEWS[(VIEWS.indexOf(chat.dataset.view) + 1) % 3];
  if (next === 'verbose') $$('.witem:not(.open), .tfold:not(.open)', chat).forEach(n => { if ($(':scope>.wkids, :scope>.wbody, :scope>.foldbody', n)) { n.classList.add('open'); n.dataset.vopen = '1'; } });
  if (chat.dataset.view === 'verbose') $$('[data-vopen]', chat).forEach(n => { n.classList.remove('open'); delete n.dataset.vopen; });
  chat.dataset.view = next;
  const nm = $('[data-role=viewname]', chat); if (nm) nm.textContent = VNAME[next];
}
function chipFit(chat) {
  const chip = $('.viewchip', chat); if (!chip) return;
  const compact = chat.offsetWidth < 700;
  chip.classList.toggle('compact', compact);
  const nm = $('[data-role=viewname]', chat); if (nm) nm.hidden = compact;
}

/* ---------- popovers from the composer: placed above their control ---------- */
function place(pop, anchor) {
  const win = anchor.closest('.win'); if (!win) return;
  const wr = win.getBoundingClientRect(), s = wr.width / win.offsetWidth || 1, ar = anchor.getBoundingClientRect();
  const x0 = (ar.left - wr.left) / s, x1 = (ar.right - wr.left) / s, y0 = (ar.top - wr.top) / s;
  pop.style.top = 'auto'; pop.style.right = 'auto';
  pop.style.bottom = (win.offsetHeight - y0 + 6) + 'px';
  const w = pop.offsetWidth, right = (pop.dataset.place || '').endsWith('right');
  pop.style.left = Math.max(8, Math.min(win.offsetWidth - w - 8, right ? x1 - w : x0)) + 'px';
}
function openPop(win, id, anchor) {
  const pop = $(`[data-pop="${id}"]`, win); if (!pop) return;
  if (!pop.classList.contains('open')) { closeAll(); pop.classList.add('open'); }
  place(pop, anchor);
}
const MODES = {
  ask: ['bubble', 'Ask', '--m-ask'], abe: ['shield', 'Ask before edits', '--m-abe'], acc: ['penline', 'Accept edits', '--m-acc'],
  auto: ['bolt', 'Auto', '--m-auto'], full: ['excl', 'Full access', '--m-full'], plan: ['list', 'Plan', '--m-plan']
};
function setModeChip(chip, key) {
  const [icon, name, tone] = MODES[key];
  chip.style.setProperty('--mt', `var(${tone})`);
  chip.innerHTML = svg(icon) + `<span data-role="modename">${name}</span>`;
}
function marker(chat, text) { insertBeforeLive(chat, `<div class="marker">${text}</div>`); }
const LNAME = { none: 'None', low: 'Low', medium: 'Medium', high: 'High', xhigh: 'Extra high', max: 'Max' };
const levelsOf = box => box.dataset.levels.split(' ');
// The track, its stops and the names under it, for the levels the model takes (Claude Code's five, Codex's six).
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

/* ---------- the menus that typing opens: / at the start, @ anywhere ---------- */
function typedMenus(chat, ta) {
  const win = chat.closest('.win'); if (!win || !$('[data-pop=slashA]', win)) return;
  const v = ta.value, comp = $('.composer', chat);
  const slash = /^\/\S*$/.test(v), at = /(^|\s)@\S*$/.test(v);
  const want = slash ? 'slashA' : at ? 'atA' : null;
  ['slashA', 'atA'].forEach(id => { if (id !== want) $(`[data-pop=${id}]`, win).classList.remove('open'); });
  if (want) openPop(win, want, comp);
}
function menuPick(win, chat) {
  const pop = $('[data-pop=slashA].open, [data-pop=atA].open', win); if (!pop) return false;
  const ta = $('[data-role=text]', chat);
  if (pop.dataset.pop === 'slashA') ta.value = '/review ';
  else ta.value = ta.value.replace(/@\S*$/, '@Sources/LoomCatalogUI/SubagentRow.swift ');
  pop.classList.remove('open'); grow(ta); paintSend(chat); return true;
}
function menuMove(win, dir) {
  const pop = $('[data-pop=slashA].open, [data-pop=atA].open', win); if (!pop) return false;
  const rows = $$('.pr2:not(.dis)', pop), i = rows.findIndex(r => r.classList.contains('cur'));
  const n = rows[(i + dir + rows.length) % rows.length]; rows.forEach(r => r.classList.toggle('cur', r === n)); return true;
}

/* ---------- requests (frame B) ---------- */
const REQ = {
  approval: { state: 'Needs approval', note: 'If you deny, Claude gets this as your note.', ph: 'Note for Claude, sent if you deny' },
  question: { state: 'Waiting for you', note: 'Claude gets this as your own answer.', ph: 'Or write your own answer' },
  plan: { state: 'Waiting for you', note: 'If you keep planning, Claude gets this as feedback.', ph: 'Or say what to change in the plan' },
  cutoff: { state: null, note: null, ph: 'Message Claude, or / for commands, @ for files' }
};
let guard = false;
// The sidebar's reason line for the session in frame B, in the activity view.
function whyLine(html) { $$('.side .scard[data-s=gate] .why', winB).forEach(w => { w.innerHTML = html; w.hidden = !html; }); }
function setReq(kind) {
  winB.dataset.req = kind;
  const chat = $('.chat', winB), r = REQ[kind], ta = $('[data-role=text]', chat), cut = kind === 'cutoff';
  const card = !cut && !guard;
  $$('[data-card]', winB).forEach(c => c.hidden = cut ? c.dataset.card !== 'cutoff' : (!card || c.dataset.card !== kind));
  $$('[data-req-only]', winB).forEach(el => el.hidden = !el.dataset.reqOnly.split(' ').includes(kind));
  $('.held', winB).hidden = !(guard && !cut);
  chat.classList.toggle('compact', card);
  chat.dataset.run = cut ? 'stopped' : 'waiting';
  $('[data-role=cnote]', winB).hidden = !card;
  if (r.note) $('[data-role=cnotetext]', winB).textContent = r.note;
  ta.placeholder = card ? r.ph : cut ? r.ph : 'Message Claude; it reads it after the current step';
  ta.style.height = '';
  const live = $('[data-role=live]', winB); if (live) live.hidden = cut;
  if (cut) setState(winB, 'ended'); else setState(winB, 'attn', r.state);
  if (cut) { const t = $('.tab.on .ind', winB); if (t) t.innerHTML = ''; $$('.side .srow.sel .ind, .side .scard.sel .ind', winB).forEach(s => s.innerHTML = ''); }
  setModeChip($('[data-role=mode]', chat), kind === 'plan' ? 'plan' : 'abe');
  whyLine({ approval: `Allow: <span class="mono">${esc(CMD)}</span>`, question: 'Asks: Which fix should I make?', plan: 'Plan ready for review', cutoff: '' }[kind]);
  $$('.opt', winB).forEach(o => o.classList.remove('on'));
  const sub = $('[data-answer=submit]', winB); if (sub) sub.disabled = true;
  paintSend(chat);
  requestAnimationFrame(() => scrollEnd(chat));
}
const CMD = 'for i in $(seq 10); do swift test --filter SideChatFlowTests || break; done';
function answer(how) {
  const chat = $('.chat', winB), ta = $('[data-role=text]', chat), note = ta.value.trim();
  if (how === 'resume') return setReq('approval');
  const pick = $('.opt.on', winB), mode = $('[data-role=buildmode] .on', winB);
  const R = {
    once: ['check', `Allowed once: <span class="ar">${esc(CMD)}</span>`],
    session: ['check', `Allowed for this session: <span class="ar">Bash(swift test:*)</span>`],
    deny: ['x', `Denied: <span class="ar">${esc(CMD)}</span>${note ? `<span class="rt">· ${esc(note)}</span>` : ''}`],
    denystop: ['x', `Denied: <span class="ar">${esc(CMD)}</span>${note ? `<span class="rt">· ${esc(note)}</span>` : ''}`],
    submit: ['question', `Asked: Which fix should I make? <span class="rt">· You chose: ${esc(pick ? pick.dataset.opt : note)}</span>`],
    approve: ['list', `Approved the plan <span class="rt">· then ${mode ? mode.textContent.trim() : 'Ask before edits'}</span>`],
    keep: ['list', `Kept planning${note ? `<span class="rt">· ${esc(note)}</span>` : ''}`]
  }[how];
  if (!R) return;
  closeAll(); whyLine('');
  const recs = $('[data-role=records]', chat);
  recs.insertAdjacentHTML('beforeend', `<div class="witem"><div class="wrow flat"><span class="wi" data-i="${R[0]}"></span>${R[1]}</div></div>`);
  if (how === 'approve') recs.insertAdjacentHTML('beforeend', `<div class="marker">Mode changed to ${mode ? mode.textContent.trim() : 'Ask before edits'}</div>`);
  iconize(recs);
  ta.value = ''; ta.style.height = '';
  $$('[data-card]', winB).forEach(c => c.hidden = true); $('.held', winB).hidden = true;
  const done = $('[data-role=answered]', winB);
  $('[data-role=answeredtext]', done).innerHTML = R[1]; done.hidden = false; iconize(done);
  setTimeout(() => { done.hidden = true; }, 4000);
  chat.classList.remove('compact'); $('[data-role=cnote]', winB).hidden = true;
  const live = $('[data-role=live]', chat);
  if (how === 'denystop') {
    live.remove(); recs.insertAdjacentHTML('beforeend', '<div class="marker">You stopped after 2m 14s</div>');
    chat.dataset.run = 'stopped'; setState(winB, 'ready');
  } else {
    const [verb, arg] = how === 'once' || how === 'session' ? ['Running', esc(CMD)] : how === 'approve' ? ['Editing', 'Tests/LoomCatalogUITests/SideChatFlowTests.swift'] : ['Thinking', ''];
    live.className = 'live'; live.removeAttribute('data-role');
    live.innerHTML = `<span class="mk2"><span class="spin">${SPIN[si]}</span></span>${verb}${arg ? ` <span class="ar">${arg}</span>` : ''}<i>·</i><span class="clk" data-clock="0">0s</span>`;
    chat.dataset.run = 'working'; setState(winB, 'working');
    setModeChip($('[data-role=mode]', chat), how === 'approve' ? { 'Accept edits': 'acc', 'Auto': 'auto' }[mode && mode.textContent.trim()] || 'abe' : 'abe');
  }
  paintSend(chat); scrollEnd(chat, true);
}

/* ---------- the quick question (frame C) ---------- */
const QQA = [
  [/tint|colou?r|tone/i, '<p>The selected row takes its project\'s tone at 14 %, with a 34 % edge. Grey is kept for Home and for rows that are not sessions.</p>'],
  [/test/i, '<p><code>SidebarInkTests</code> covers the row height, the mark and the tint in both looks; all 14 passed at 14:06.</p>'],
  [/./, '<p>From this session: the sidebar now reads the Ink tokens. Claude changed four files and the sidebar\'s tests pass; the subagent rows are the next step.</p>']
];
let qqTimer = 0;
function qqAsk(qq) {
  const ta = $('[data-role=qqtext]', qq), q = ta.value.trim(); if (!q || qqTimer) return;
  ta.value = '';
  $('[data-role=qqq]', qq).textContent = q;
  $('[data-role=qqa]', qq).hidden = true; $('[data-role=qqacts]', qq).hidden = true;
  const w = $('[data-role=qqwait]', qq), sec = $('[data-role=qqsec]', qq); w.hidden = false; let n = 1; sec.textContent = n;
  qqTimer = setInterval(() => {
    n++; sec.textContent = n;
    if (n >= 3) {
      clearInterval(qqTimer); qqTimer = 0; w.hidden = true;
      const a = $('[data-role=qqa]', qq); a.innerHTML = QQA.find(([re]) => re.test(q))[1]; a.hidden = false; $('[data-role=qqacts]', qq).hidden = false;
    }
  }, 1000);
}
function qqToggle(open) {
  const qq = $('[data-role=qq]', winC), on = open ?? !qq.classList.contains('open');
  qq.classList.toggle('open', on);
  if (on) setTimeout(() => $('[data-role=qqtext]', qq).focus({ preventScroll: true }), 30);
}

/* ---------- one delegated listener for clicks ---------- */
document.addEventListener('pointerdown', e => { const c = chatOf(e.target); if (c) activeChat = c; }, true);
document.addEventListener('click', e => {
  const t = e.target, win = t.closest('.win');
  const opener = t.closest('[data-open]');
  if (opener && win) {
    const pop = $(`[data-pop="${opener.dataset.open}"]`, win);
    if (pop && pop.classList.contains('open') && pop.dataset.place) {
      const inPop = opener.closest('.pop');
      place(pop, inPop ? ($(`.cbar [data-open="${opener.dataset.open}"]`, win) || opener) : opener);
    }
    return;
  }
  const vb = t.closest('.side .view button'); if (vb) return setView(vb.closest('.side'), vb.dataset.view);
  const reset = t.closest('[data-reset]'); if (reset) return resetFrame(reset.dataset.reset);
  const ans = t.closest('[data-answer]'); if (ans && win === winB) return answer(ans.dataset.answer);
  const opt = t.closest('.opt');
  if (opt) {
    const on = !opt.classList.contains('on');
    $$('.opt', opt.parentElement).forEach(o => o.classList.toggle('on', on && o === opt));
    if (on && win) { const ta = $('[data-role=text]', win); if (ta) ta.value = ''; }
    const sub = $('[data-answer=submit]', opt.closest('.pcard')); if (sub) sub.disabled = !on;
    return;
  }
  const mode = t.closest('.pr2[data-mode]');
  if (mode) {
    const menu = mode.closest('.pop');
    $$('.pr2[data-mode] .ck', menu).forEach(c => c.innerHTML = '');
    $('.ck', mode).innerHTML = svg('check');
    if (win && !menu.classList.contains('static')) {
      const chat = $('.chat', win), chip = $('[data-role=mode]', chat), key = mode.dataset.mode;
      if ($('[data-role=modename]', chip).textContent !== MODES[key][1]) { setModeChip(chip, key); marker(chat, `Mode changed to ${MODES[key][1]}`); scrollEnd(chat, true); }
      closeAll();
    }
    return;
  }
  const model = t.closest('.mrow[data-model]');
  if (model) { if (!model.classList.contains('dis')) pickModel(model, win); return; }
  const slider = t.closest('[data-role=slider]');
  if (slider) {
    const r = slider.getBoundingClientRect(), L = levelsOf(slider), i = Math.round(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * (L.length - 1));
    setEffort(slider.closest('.static') ? null : win, slider, L[i]); return;
  }
  const row = t.closest('.wrow');
  if (row && !row.classList.contains('flat')) {
    const item = row.parentElement;
    if (item.classList.contains('witem') && $(':scope>.wkids, :scope>.wbody', item)) {
      const sc = row.closest('.scroller'), end = sc && sc.scrollHeight - sc.scrollTop - sc.clientHeight < 40;
      item.classList.toggle('open'); if (end) scrollEnd(chatOf(sc));
    }
    return;
  }
  const fr = t.closest('.foldrow'); if (fr) { fr.parentElement.classList.toggle('open'); return; }
  const vc = t.closest('.viewchip'); if (vc) { const c = chatOf(vc); if (c) cycleView(c); return; }
  const insp = t.closest('[data-role=insp]');
  if (insp && win) {
    const panel = $('.insp', win); panel.hidden = !panel.hidden; insp.classList.toggle('on', !panel.hidden);
    chipFit($('.chat', win)); return;
  }
  const sendB = t.closest('[data-role=send]');
  if (sendB && !sendB.disabled) {
    const chat = chatOf(sendB), st = sendB.dataset.state;
    if (st === 'stop') interrupt(chat);
    else if (st === 'resume') resumeQueue(chat);
    else send(chat, st === 'after' ? 'after' : null);
    return;
  }
  const a = t.closest('[data-act]'); if (!a) return;
  const chat = chatOf(a), act = a.dataset.act;
  if (act === 'copy') {
    const lbl = [...a.childNodes].find(n => n.nodeType === 3 && n.textContent.trim());
    if (lbl && !a.dataset.busy) { a.dataset.busy = '1'; const was = lbl.textContent; lbl.textContent = 'Copied'; setTimeout(() => { lbl.textContent = was; delete a.dataset.busy; }, 1200); }
  } else if (act === 'wrap') { a.closest('.code').classList.toggle('wrap'); a.classList.toggle('on'); }
  else if (act === 'changes' || act === 'agents') {
    if (!win) return;
    const panel = $('.insp', win); panel.hidden = false; const tg = $('[data-role=insp]', win); if (tg) tg.classList.add('on');
    showTab(panel, act === 'changes' ? 'ch' : 'ag'); chipFit($('.chat', win));
  } else if (act === 'readnow') {
    const m = a.closest('.you-mark'); const w = $('[data-role=wait]', m); if (w) { w.textContent = 'Read'; w.removeAttribute('data-role'); } a.remove();
  } else if (act === 'jump') scrollEnd(chat, true);
  else if (act === 'qtoggle') a.closest('.qstrip').classList.toggle('shut');
  else if (act === 'qedit') editQueued(chat, a.closest('.qrow'));
  else if (act === 'qremove') { const r = a.closest('.qrow'); if (r === editRow) endEdit(chat, false); r.remove(); queueCount(chat); paintSend(chat); }
  else if (act === 'qsend') {
    const r = a.closest('.qrow'), text = $('.t', r).textContent; r.remove(); queueCount(chat);
    if (chat.dataset.run === 'working') { insertBeforeLive(chat, youHTML(text, '<span>From the queue</span>' + WAIT)); scrollEnd(chat, true); }
    else startTurn(chat, text, '<span>From the queue</span>');
    paintSend(chat);
  } else if (act === 'resume') resumeQueue(chat);
  else if (act === 'qclear') { $$('.qrow', a.closest('.qstrip')).forEach(r => r.remove()); queueCount(chat); paintSend(chat); }
  else if (act === 'effreset') { const b = $('[data-role=slider]', a.closest('.effort')); if (!a.classList.contains('dis')) setEffort(win && !a.closest('.static') ? win : null, b, b.dataset.base || 'high'); }
  else if (act === 'fullplan') { const b = $('.pd-b', a.closest('.plandoc')); b.classList.toggle('full'); a.textContent = b.classList.contains('full') ? 'Show Less' : 'Show Full Plan'; }
  else if (act === 'showheld') { guard = false; $('#swGuard').classList.remove('on'); setReq(winB.dataset.req); }
  else if (act === 'qqclose') qqToggle(false);
  else if (act === 'qqask') qqAsk(a.closest('.qq'));
  else if (act === 'note') { a.disabled = true; a.innerHTML = svg('check') + 'Sent to the main session'; }
});
function pickModel(row, win) {
  const menu = row.closest('.pop'), box = $('[data-role=slider]', menu), eff = box.closest('.effort'), lv = row.dataset.levels;
  $$('.mrow .ck', menu).forEach(c => c.innerHTML = '');
  $('.ck', row).innerHTML = svg('check');
  $$('.mrow', menu).forEach(r => r.classList.toggle('cur', r === row));
  // A model with no effort levels gets no effort word and no track; one with other levels keeps the nearest level below.
  eff.classList.toggle('none', !lv);
  if (lv && lv !== box.dataset.levels) {
    const was = box.dataset.level; box.dataset.levels = lv; buildSlider(box);
    const L = levelsOf(box); paintSlider(box, L.includes(was) ? was : L[0]);
  }
  if (!win || menu.classList.contains('static')) return;
  const chat = $('.chat', win), name = row.dataset.model, label = name === 'Default' ? 'Default model' : name;
  const nm = $('[data-role=modelname]', chat);
  if (nm.textContent !== label) { nm.textContent = label; marker(chat, `Model changed to ${label}`); scrollEnd(chat, true); }
  const en = $('[data-role=effname]', chat); en.hidden = !lv; if (lv) en.textContent = LNAME[box.dataset.level];
}
function resumeQueue(chat) {
  const q = $('[data-role=queue]', chat); if (!q) return;
  q.classList.remove('paused');
  const r = $('.qrow', q); if (!r) return paintSend(chat);
  const text = $('.t', r).textContent; r.remove(); queueCount(chat);
  startTurn(chat, text, '<span>From the queue</span>');
}
// "Show Full Message" on a long message in the parts sheet
document.addEventListener('click', e => {
  const b = e.target.closest('.you>.lk2.acc'); if (!b) return;
  const bub = $('.bubble', b.parentElement); if (!bub) return;
  const open = bub.classList.toggle('long') === false; b.textContent = open ? 'Show Less' : 'Show Full Message';
});

/* ---------- keys in the model popover ---------- */
document.addEventListener('keydown', e => {
  const mp = $('[data-pop=modelA].open'); if (!mp) return;
  const win = mp.closest('.win'), box = $('[data-role=slider]', mp), k = e.key;
  if (k === 'ArrowLeft' || k === 'ArrowRight') {
    if (!box.closest('.effort').classList.contains('none')) {
      const L = levelsOf(box), i = L.indexOf(box.dataset.level) + (k === 'ArrowRight' ? 1 : -1);
      if (i >= 0 && i < L.length) setEffort(win, box, L[i]);
    }
  } else if (k === 'ArrowDown' || k === 'ArrowUp') {
    const rows = $$('.mrow:not(.dis)', mp); let i = rows.findIndex(r => r.classList.contains('cur'));
    if (i < 0) i = rows.findIndex(r => $('.ck svg', r));
    i = (i + (k === 'ArrowDown' ? 1 : -1) + rows.length) % rows.length;
    rows.forEach((r, n) => r.classList.toggle('cur', n === i));
  } else if (k === 'Enter') {
    const c = $('.mrow.cur', mp); if (c && !$('.ck svg', c)) pickModel(c, win);
    closeAll();
  } else return;
  e.preventDefault(); e.stopImmediatePropagation();
}, true);

/* ---------- typing and keys ---------- */
document.addEventListener('input', e => {
  const ta = e.target;
  if (ta.matches('[data-role=text]')) {
    const chat = chatOf(ta); activeChat = chat;
    if (chat.closest('#winB')) $$('.opt.on', winB).forEach(o => o.classList.remove('on')), ($('[data-answer=submit]', winB) || {}).disabled = !ta.value.trim();
    grow(ta); paintSend(chat); typedMenus(chat, ta);
  }
});
document.addEventListener('keydown', e => {
  if (e.key === 'Meta' && !metaHeld) { metaHeld = true; if (activeChat) paintSend(activeChat); }
  const ta = e.target;
  if (ta.matches && ta.matches('[data-role=qqtext]')) {
    if (e.key === 'Enter' && !e.shiftKey && !e.altKey && !e.isComposing) { e.preventDefault(); qqAsk(ta.closest('.qq')); }
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); qqToggle(false); }
    return;
  }
  if (ta.matches && ta.matches('[data-role=text]')) {
    const chat = chatOf(ta), win = chat.closest('.win');
    if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && win && menuMove(win, e.key === 'ArrowDown' ? 1 : -1)) { e.preventDefault(); return; }
    if ((e.key === 'Enter' || e.key === 'Tab') && !e.shiftKey && win && menuPick(win, chat)) { e.preventDefault(); return; }
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      if (chat.classList.contains('compact')) return;
      send(chat, e.metaKey && (chat.dataset.run === 'working' || chat.dataset.run === 'waiting') ? 'after' : null);
    }
  }
}, true);
document.addEventListener('keyup', e => { if (e.key === 'Meta') { metaHeld = false; if (activeChat) paintSend(activeChat); } });
addEventListener('blur', () => { if (metaHeld) { metaHeld = false; if (activeChat) paintSend(activeChat); } });
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') {
    if ($('.pop.open, .palette.open')) return;            // the menu closes first
    if ($('[data-role=qq].open', winC) && activeChat === $('.chat', winC)) { qqToggle(false); return; }
    const chat = activeChat; if (!chat) return;
    if (chat.dataset.editing) { endEdit(chat, false); return; }
    if (chat.dataset.run === 'working' && !chat.classList.contains('compact')) interrupt(chat);
    return;
  }
  if (e.ctrlKey && !e.metaKey && e.key.toLowerCase() === 'o') { if (activeChat) { e.preventDefault(); cycleView(activeChat); } return; }
  if ((e.metaKey || e.ctrlKey) && e.key === ';') { e.preventDefault(); activeChat = $('.chat', winC); qqToggle(); return; }
  const inField = e.target.matches && e.target.matches('textarea, input');
  if (!inField && /^[1-3]$/.test(e.key) && activeChat === $('.chat', winB) && winB.dataset.req === 'question' && !guard) {
    const o = $$('[data-card=question] .opt', winB)[+e.key - 1]; if (o) o.click();
  }
}, true);

/* ---------- the scroll latch: Jump to Latest ---------- */
document.addEventListener('scroll', e => {
  const sc = e.target; if (!(sc instanceof Element) || !sc.classList.contains('scroller')) return;
  const jump = $('.jump', sc.closest('.chat')); if (!jump) return;
  const away = sc.scrollHeight - sc.scrollTop - sc.clientHeight > 40;
  clearTimeout(sc._jt);
  if (away) sc._jt = setTimeout(() => jump.classList.add('on'), 150); else jump.classList.remove('on');
}, true);
document.addEventListener('scroll', e => { const w = e.target instanceof Element && e.target.closest('.win'); if (w) placePins(w); }, true);
$('#swPins').parentElement.addEventListener('click', () => requestAnimationFrame(placeAllPins));
addEventListener('resize', () => requestAnimationFrame(placeAllPins));
document.addEventListener('click', () => requestAnimationFrame(placeAllPins));

/* ---------- clocks: one label a second, only while it can be seen ---------- */
setInterval(() => {
  if (document.hidden) return;
  $$('.chat[data-run=working] .col>[data-live] [data-clock], .chat[data-run=working] [data-role=records]~.live [data-clock], [data-role=live]:not([hidden]) [data-clock][data-tick]').forEach(c => { const s = +c.dataset.clock + 1; c.dataset.clock = s; c.textContent = fmt(s); });
  $$('.chat[data-run=working] [data-agentclock]').forEach(c => { const s = (+c.dataset.s || 52) + 1; c.dataset.s = s; c.textContent = fmt(s); });
}, 1000);

/* ---------- start, and reset a frame to its first state ---------- */
const FIRST = new Map();
[winA, winB].forEach(w => { const c = $('.chat', w); FIRST.set(w, { html: c.innerHTML, view: c.dataset.view, run: c.dataset.run, cls: c.className }); });
function resetFrame(id) {
  const w = document.getElementById(id), c = $('.chat', w), f = FIRST.get(w); if (!f) return;
  closeAll(); editRow = null;
  c.innerHTML = f.html; c.dataset.view = f.view; c.dataset.run = f.run; c.className = f.cls; delete c.dataset.editing;
  if (w === winA) {
    setState(winA, 'working'); paintSend(c); chipFit(c); requestAnimationFrame(() => scrollEnd(c));
    // The model popover sits outside the chat: bring it back to the session's first model and effort.
    const mp = $('[data-pop=modelA]', winA); pickModel($('.mrow[data-model="Opus 5.5"]', mp), winA); setEffort(winA, $('[data-role=slider]', mp), 'high');
  }
  else setReq(winB.dataset.req);
}
$$('#reqSeg button').forEach(b => b.addEventListener('click', () => { resetFrame('winB'); setReq(b.dataset.req); }));
sw('#swGuard', on => { guard = on; resetFrame('winB'); });
$$('.chat').forEach(c => { paintSend(c); chipFit(c); });
setReq('approval');
const settle = () => { [winA, winB, winC].forEach(w => { const sc = $('.scroller', w); if (sc.dataset.start === 'top') sc.scrollTop = 0; else scrollEnd($('.chat', w)); }); placeAllPins(); };
requestAnimationFrame(() => requestAnimationFrame(settle));
addEventListener('load', settle);
