/* ============================================================
   Ink v4 (B0): the sidebar's two views, the status bar, the
   header's tab variant and the small live bits. The markup of
   the windows is in body.html; everything repeated four times
   (sidebar, status bar) is built here.
   ============================================================ */

// The standalone document opens on v4, so its bar must say so (the reference page paints it through the bridge).
$$('#inkSeg button').forEach(b => b.classList.toggle('on', b.dataset.inkSet === (document.documentElement.dataset.ink || 'v3')));

const I4_WORD = { work:'Working', attn:'Needs you', unv:'Finished', fail:'Failed' };

const I4_PROJECTS = [
  { name:'loom', tone:'var(--orchid)', letter:'L', sessions:[
    { id:'ink', t:'Port the sidebar to Ink tokens', st:'work', time:'37s', br:'ui/ink-sidebar', h:'claude', sel:true,
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

function i4card(s, p, view) {
  const third = view === 'activity'
    ? `<span class="i4scr">${s.why}</span>`
    : `<span class="i4scb"><span class="i4brn">${s.br}</span><span class="hm ${s.h}"></span></span>`;
  return `<div class="i4sc${s.sel ? ' sel' : ''}" style="--tone:${p.tone}" data-s="${s.id}">
    <span class="i4sct"><span class="i4pmark">${p.letter}</span><span class="pn">${p.name}</span>${i4st(s.st, s.time)}</span>
    <span class="i4scti">${s.t}</span>
    ${third}
    ${s.subs ? i4subs(s.subs) : ''}
  </div>`;
}

function i4phead(p, hovered) {
  return `<div class="i4phead${hovered ? ' hov' : ''}" style="--tone:${p.tone}">
    <span class="i4pmark">${p.letter}</span><span class="pn">${p.name}</span>
    <span class="i4pacts"><span class="i4pact">${svg('chev-d')}</span><span class="i4pact">${svg('plus')}</span><span class="i4pact">${svg('more')}</span></span>
  </div>`;
}

function i4projects() {
  return I4_PROJECTS.map((p, i) => `<div class="i4pgroup">${i4phead(p, i === 1)}${p.sessions.map(s => i4card(s, p, 'projects')).join('')}</div>`).join('');
}

function i4activity() {
  const all = [];
  I4_PROJECTS.forEach(p => p.sessions.forEach(s => all.push({ s, p })));
  const byId = Object.fromEntries(all.map(x => [x.s.id, x]));
  const today = I4_ACTIVITY.filter(id => id !== 'lb').map(id => i4card(byId[id].s, byId[id].p, 'activity')).join('');
  const monday = i4card(byId.lb.s, byId.lb.p, 'activity');
  return `<div class="i4day">Today</div>${today}<div class="i4day">Monday</div>${monday}`;
}

function i4sidebar(el) {
  const home = el.dataset.i4side === 'home';
  const view = el.dataset.view || 'projects';
  el.dataset.view = view;
  el.innerHTML = `
    <div class="i4lights"><i></i><i></i><i></i></div>
    <div class="i4stop"><button class="i4search" data-open="palette">${svg('search')}<span>Search</span><kbd class="i4key">⌘K</kbd></button></div>
    <div class="i4nav">
      <button class="i4navr${home ? ' on' : ''}">${svg('home')}<span class="t">Home</span><span class="i4count">1</span></button>
      <button class="i4navr">${svg('plus')}<span class="t">New session</span><kbd class="i4key">⌘N</kbd></button>
    </div>
    <div class="i4sech">
      <span class="i4lab i4labp">Projects</span><span class="i4lab i4laba">Activity</span><span class="sp"></span>
      <button class="i4ib" data-i4view title="${view === 'activity' ? 'Show projects' : 'Show activity'}">${svg(view === 'activity' ? 'side-l' : 'list')}</button>
      <button class="i4ib" title="New session">${svg('plus')}</button>
    </div>
    <div class="i4plist">${i4projects()}</div>
    <div class="i4alist">${i4activity()}</div>
    <div class="i4sfoot"><button class="i4ib" title="Settings">${svg('gear')}</button><button class="i4ib" title="Help">${svg('question')}</button></div>`;
}

function i4hgroup(h, label, p1, r1, p2, r2) {
  return `<span class="i4sgrp"><span class="i4smeter${p1 < 20 ? ' low' : ''}"><i style="width:${p1}%"></i></span><b class="${p1 < 20 ? 'low' : ''}">${p1}%</b><span class="rs">· ${r1}</span></span>
    <span class="i4sgrp"><span class="i4smeter"><i style="width:${p2}%"></i></span><b>${p2}%</b><span class="rs">· ${r2}</span></span>`;
}

function i4statusbar(el) {
  el.innerHTML = `
    <button class="i4sseg" title="Claude Code plan limits"><span class="hm claude"></span>${i4hgroup('claude', 'Claude Code', 4, '3h 39m', 38, '5d')}</button>
    <button class="i4sseg" title="Codex plan limits"><span class="hm codex"></span>${i4hgroup('codex', 'Codex', 61, '2d', 24, '6d')}</button>
    <span class="sp"></span>
    <span class="i4swork"><span class="spin">⠋</span>3 working</span>
    <button class="i4keep"><span class="i4sw on"></span>Keep Mac Awake</button>
    <button class="i4supd" title="pi has a newer CLI">${svg('down')}pi update</button>`;
}

$$('[data-i4side]').forEach(i4sidebar);
$$('[data-i4status]').forEach(i4statusbar);

// Q6: the same session tabs, moved into the 52-high header. The row keeps its markup; the header gets a copy.
$$('.i4hdtabs').forEach(nav => {
  const row = nav.closest('.i4main') && nav.closest('.i4main').querySelector('.i4tabrow');
  if (row) nav.innerHTML = $$('.i4tab', row).map(t => t.outerHTML).join('');
});

// The sidebar's two views switch in place, as the app's do.
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
