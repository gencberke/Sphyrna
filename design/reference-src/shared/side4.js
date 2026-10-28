/* ============================================================
   Ink v4 shared (B0b): the sidebar in its two views, its session
   cards and project heads, the status bar, and the view switch.
   Every window that draws a sidebar or a status bar builds them
   here (DESIGN.md §0.5). The options are the element's data:
     data-view="projects|activity"  the view (projects by default)
     data-i4side="home"             Home is the selected nav row
     data-i4sel="<session id>"      that session's card is selected
     data-i4open="<project name>"   that project's head is open
     data-i4hover="<index>"         that project's head is under the pointer
     data-i4idle="<session id>"     that session is ready: no status, no subagents
     data-i4none                    no projects yet (an empty sidebar)
   The markup of each window is in its own document.
   ============================================================ */

const I4_WORD = { work:'Working', attn:'Needs you', unv:'Finished', fail:'Failed' };

const I4_PROJECTS = [
  { name:'loom', tone:'var(--orchid)', letter:'L', sessions:[
    { id:'ink', t:'Port the sidebar to Ink tokens', st:'work', time:'37s', br:'ui/ink-sidebar', h:'claude',
      why:'Editing <span class="mono">SidebarCard.swift</span> · 61 lines',
      subs:[ { st:'work', type:'explorer', d:'Map every sidebar token', e:'2m' },
             { st:'work', type:'implementer', d:'Port SidebarCard', e:'now' } ] },
    { id:'gate', t:'Review the gate failure', st:'attn', time:'3m', br:'fix/gate-timeout', h:'claude',
      why:'Claude asks to run <span class="mono">scripts/check.sh --full</span>.' },
    { id:'lb', t:'Remora spike S10', st:'', time:'2d', br:'remora/s10', h:'codex',
      why:'Last active Monday · no prompt since' }
  ]},
  { name:'edd-backend', tone:'var(--mint)', letter:'B', sessions:[
    { id:'config', t:'Remove Task Config Status', st:'work', time:'3m', br:'feature/bg/EDDP-20625', h:'claude',
      why:'Editing <span class="mono">TaskConfig.swift</span>' },
    { id:'jwt', t:'Migrate auth to JWT', st:'fail', time:'3h', br:'fix/auth-jwt', h:'codex',
      why:'Failed at <span class="mono">tests/auth.spec.ts:214</span>' }
  ]},
  { name:'second-brain', tone:'var(--aqua)', letter:'S', sessions:[
    { id:'vm', t:'Weekly vault maintenance', st:'work', time:'1m', br:'main', h:'claude',
      why:'Reading <span class="mono">Inbox/2026-10-27.md</span>' },
    { id:'th', t:'Thesis outline', st:'unv', time:'25m', br:'thesis/outline', h:'codex',
      why:'Finished · <span class="mono">outline.md</span> · 4 notes' }
  ]}
];

const I4_ACTIVITY = ['ink', 'vm', 'gate', 'config', 'th', 'jwt', 'lb'];

function i4st(st, time) {
  if (st === 'work') return `<span class="i4stt work"><span class="spin">⠋</span>${I4_WORD.work} <b>${time}</b></span>`;
  if (st) return `<span class="i4stt ${st}"><i class="dot ${st}"></i>${I4_WORD[st]} <b>${time}</b></span>`;
  return `<span class="i4time">${time}</span>`;
}

function i4subs(list) {
  return `<div class="i4subs">${list.map(a => `<div class="i4sub"><span class="ind">${a.st === 'done' ? svg('check') : mark(a.st)}</span><b>${a.type}</b><span>${a.d || ''}</span><em>${a.e || ''}</em></div>`).join('')}</div>`;
}

function i4card(s, p, view, o = {}) {
  const idle = o.idle === s.id;
  const third = view === 'activity'
    ? `<span class="i4scb"><span class="i4scr">${s.why}</span><span class="hm ${s.h}"></span></span>`
    : `<span class="i4scb"><span class="i4brn">${s.br}</span><span class="hm ${s.h}"></span></span>`;
  return `<div class="i4sc${o.sel === s.id ? ' sel' : ''}" style="--tone:${p.tone}" data-s="${s.id}">
    <span class="i4sct"><span class="i4pmark">${p.letter}</span><span class="pn">${p.name}</span>${i4st(idle ? '' : s.st, s.time)}</span>
    <span class="i4scti">${s.t}</span>
    ${third}
    ${s.subs && !idle ? i4subs(s.subs) : ''}
  </div>`;
}

function i4phead(p, hovered, open) {
  return `<div class="i4phead${hovered ? ' hov' : ''}${open ? ' open' : ''}" style="--tone:${p.tone}">
    <span class="i4pmark">${p.letter}</span><span class="pn">${p.name}</span>
    <span class="i4pacts"><span class="i4pact">${svg('chev-d')}</span><span class="i4pact">${svg('plus')}</span><span class="i4pact">${svg('more')}</span></span>
  </div>`;
}

function i4projects(o) {
  return I4_PROJECTS.map((p, i) => `<div class="i4pgroup">${i4phead(p, o.hover === String(i), o.open === p.name)}${p.sessions.map(s => i4card(s, p, 'projects', o)).join('')}</div>`).join('');
}

function i4activity(o) {
  const all = [];
  I4_PROJECTS.forEach(p => p.sessions.forEach(s => all.push({ s, p })));
  const byId = Object.fromEntries(all.map(x => [x.s.id, x]));
  const today = I4_ACTIVITY.filter(id => id !== 'lb').map(id => i4card(byId[id].s, byId[id].p, 'activity', o)).join('');
  const monday = i4card(byId.lb.s, byId.lb.p, 'activity', o);
  return `<div class="i4day">Today</div>${today}<div class="i4day">Monday</div>${monday}`;
}

function i4sidebar(el) {
  const d = el.dataset, home = d.i4side === 'home', none = el.hasAttribute('data-i4none');
  const view = d.view || 'projects';
  const o = { sel: d.i4sel, open: d.i4open, hover: d.i4hover, idle: d.i4idle };
  el.dataset.view = view;
  el.innerHTML = `
    <div class="i4lights"><i></i><i></i><i></i></div>
    <div class="i4stop"><button class="i4search" data-open="palette">${svg('search')}<span>Search</span><kbd class="i4key">⌘K</kbd></button></div>
    <div class="i4nav">
      <button class="i4navr${home ? ' on' : ''}">${svg('home')}<span class="t">Home</span>${none ? '' : '<span class="i4count">1</span>'}</button>
      <button class="i4navr">${svg('plus')}<span class="t">New session</span><kbd class="i4key">⌘N</kbd></button>
    </div>
    <div class="i4sech">
      <span class="i4lab i4labp">Projects</span><span class="i4lab i4laba">Activity</span><span class="sp"></span>
      <button class="i4ib" data-i4view title="${view === 'activity' ? 'Show projects' : 'Show activity'}">${svg(view === 'activity' ? 'side-l' : 'list')}</button>
      <button class="i4ib" data-open="plus" title="New session">${svg('plus')}</button>
    </div>
    <div class="i4plist">${none ? '<div class="i4none">No projects yet.</div>' : i4projects(o)}</div>
    <div class="i4alist">${none ? '<div class="i4none">No sessions yet.</div>' : i4activity(o)}</div>
    <div class="i4sfoot"><button class="i4ib" title="Settings">${svg('gear')}</button><button class="i4ib" title="Help">${svg('question')}</button></div>`;
}

function i4hgroup(p1, r1, p2, r2) {
  return `<span class="i4sgrp"><span class="i4smeter${p1 < 20 ? ' low' : ''}"><i style="width:${p1}%"></i></span><b class="${p1 < 20 ? 'low' : ''}">${p1}%</b><span class="rs">· ${r1}</span></span>
    <span class="i4sgrp"><span class="i4smeter"><i style="width:${p2}%"></i></span><b>${p2}%</b><span class="rs">· ${r2}</span></span>`;
}

function i4statusbar(el) {
  el.innerHTML = `
    <button class="i4sseg" data-usage="claude" title="Claude Code plan limits"><span class="hm claude"></span>${i4hgroup(4, '3h 39m', 38, '5d')}</button>
    <button class="i4sseg" data-usage="codex" title="Codex plan limits"><span class="hm codex"></span>${i4hgroup(61, '2d', 24, '6d')}</button>
    <span class="sp"></span>
    <span class="i4swork"><span class="spin">⠋</span>3 working</span>
    <button class="i4keep"><span class="i4sw on"></span>Keep Mac Awake</button>
    <button class="i4supd" title="pi has a newer CLI">${svg('down')}pi update</button>`;
}

$$('.i4side').forEach(i4sidebar);
$$('.i4status').forEach(i4statusbar);

// One usage popover for every window, not just the first session example.
function i4usage(bar, harness) {
  const claude = harness === 'claude', name = claude ? 'Claude Code' : 'Codex';
  const values = claude ? [[4, '21:05'], [38, 'Mon 10:00']] : [[61, 'Thu 10:00'], [24, 'Mon 10:00']];
  let pop = $('.i4stpop', bar);
  if (!pop) { pop = document.createElement('div'); pop.className = 'i4stpop'; bar.appendChild(pop); }
  pop.dataset.harness = harness;
  pop.innerHTML = `<div class="i4stph"><span class="hm ${harness}"></span><b>${name}</b><span class="i4stpr">Read 17:20</span><button class="i4ib" data-usage-close title="Close">${svg('x')}</button></div>`
    + values.map(([left, reset], i) => `<div class="i4strow"><span class="k">${i ? 'Weekly' : '5-hour window'}</span><span class="i4meter${left < 20 ? ' low' : ''}"><i style="width:${left}%"></i></span><b class="${left < 20 ? 'low' : ''}">${left}% left</b><span class="rs">resets ${reset}</span></div>`).join('')
    + `<div class="i4stpn">Read from ${name}'s own usage. No model call.</div><div class="i4stpf"><button class="btn out sm" data-usage-check>Check Again</button><button class="btn gh sm" data-usage-page>Open Usage</button><span class="sp"></span><span class="mono">17:20</span></div>`;
}
$$('.i4status[data-usage-open]').forEach(bar => i4usage(bar, bar.dataset.usageOpen));
document.addEventListener('click', e => {
  const segment = e.target.closest('[data-usage]');
  if (segment) {
    const bar = segment.closest('.i4status'), old = $('.i4stpop', bar), open = old?.dataset.harness === segment.dataset.usage;
    $$('.i4stpop').forEach(p => p.remove());
    if (!open) i4usage(bar, segment.dataset.usage);
    return;
  }
  if (e.target.closest('[data-usage-close]')) e.target.closest('.i4stpop').remove();
  if (e.target.closest('[data-usage-check]')) e.target.closest('.i4stpop').querySelector('.i4stpr').textContent = 'Read just now';
  if (e.target.closest('[data-usage-page]')) {
    const pane = $('.swin .spane[data-stab=usage]');
    if (pane) $('.swin [data-stab=usage]').click();
    else if (parent !== window) parent.postMessage({ref:'chapter', chapter:'settings'}, '*');
  }
  const keep = e.target.closest('.i4keep');
  if (keep) $('.i4sw', keep).classList.toggle('on');
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') $$('.i4stpop').forEach(p => p.remove()); });

// The sidebar's two views switch in place, as the app's do; the switches and the segments of the v4 parts toggle here too.
document.addEventListener('click', e => {
  const b = e.target.closest('[data-i4view]');
  if (b) {
    const side = b.closest('.i4side'), act = side.dataset.view === 'activity';
    side.dataset.view = act ? 'projects' : 'activity';
    b.innerHTML = svg(act ? 'list' : 'side-l');
    b.title = act ? 'Show activity' : 'Show projects';
    return;
  }
  const seg = e.target.closest('.i4seg button');
  if (seg) { $$('button', seg.parentElement).forEach(x => x.classList.toggle('on', x === seg)); return; }
  const sw = e.target.closest('.i4sw');
  if (sw && !sw.closest('.i4keep')) sw.classList.toggle('on');
});
