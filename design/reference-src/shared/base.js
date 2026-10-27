const $ = (s, r = document) => r.querySelector(s), $$ = (s, r = document) => [...r.querySelectorAll(s)];

/* ---------- icons (16 pt, 1.4 stroke) ---------- */
const ICON = {
  search:'<circle cx="7" cy="7" r="4.6"/><path d="m10.5 10.5 3.5 3.5"/>',
  home:'<path d="M2.6 7.2 8 2.9l5.4 4.3V13a.9.9 0 0 1-.9.9H9.7V10.2H6.3v3.7H3.5a.9.9 0 0 1-.9-.9z"/>',
  plus:'<path d="M8 3.2v9.6M3.2 8h9.6"/>',
  'chev-d':'<path d="m4.6 6.4 3.4 3.4 3.4-3.4"/>',
  'chev-r':'<path d="m6.4 4.6 3.4 3.4-3.4 3.4"/>',
  'side-l':'<rect x="2" y="3" width="12" height="10" rx="2.2"/><path d="M6.2 3v10"/>',
  'side-r':'<rect x="2" y="3" width="12" height="10" rx="2.2"/><path d="M9.8 3v10"/>',
  gear:'<circle cx="8" cy="8" r="2"/><path d="M8 1.9v1.7M8 12.4v1.7M14.1 8h-1.7M3.6 8H1.9M12.3 3.7l-1.2 1.2M4.9 11.1l-1.2 1.2M12.3 12.3l-1.2-1.2M4.9 4.9 3.7 3.7"/><circle cx="8" cy="8" r="4.4"/>',
  more:'<circle cx="3.6" cy="8" r=".95" fill="currentColor" stroke="none"/><circle cx="8" cy="8" r=".95" fill="currentColor" stroke="none"/><circle cx="12.4" cy="8" r=".95" fill="currentColor" stroke="none"/>',
  branch:'<circle cx="5" cy="3.9" r="1.4"/><circle cx="5" cy="12.1" r="1.4"/><circle cx="11" cy="6" r="1.4"/><path d="M5 5.3v5.4M11 7.4c0 2.3-2.1 2.7-4.7 3.7"/>',
  x:'<path d="m4.6 4.6 6.8 6.8M11.4 4.6l-6.8 6.8"/>',
  check:'<path d="m3.6 8.4 2.9 2.9 5.9-6.6"/>',
  up:'<path d="M8 12.6V3.6M4.3 7.2 8 3.5l3.7 3.7"/>',
  copy:'<rect x="5.6" y="5.6" width="7.8" height="7.8" rx="1.6"/><path d="M10.4 5.6V4c0-.8-.6-1.4-1.4-1.4H4c-.8 0-1.4.6-1.4 1.4v5c0 .8.6 1.4 1.4 1.4h1.6"/>',
  open:'<path d="M9.2 2.8h4v4M13.2 2.8 7.8 8.2M11.6 9.6v2.7c0 .5-.4.9-.9.9H3.7a.9.9 0 0 1-.9-.9V5.3c0-.5.4-.9.9-.9h2.7"/>',
  folder:'<path d="M2.3 4.7c0-.7.6-1.3 1.3-1.3h2.5l1.4 1.5h4.9c.7 0 1.3.6 1.3 1.3v5.6c0 .7-.6 1.3-1.3 1.3H3.6c-.7 0-1.3-.6-1.3-1.3z"/>',
  shield:'<path d="M8 2.2 13 4v3.6c0 3-2.1 5.1-5 6.2-2.9-1.1-5-3.2-5-6.2V4z"/>',
  clock:'<circle cx="8" cy="8" r="5.6"/><path d="M8 5v3.2l2.1 1.3"/>',
  pencil:'<path d="M10.6 2.9a1.5 1.5 0 0 1 2.1 2.1l-7.4 7.4-2.8.7.7-2.8z"/>',
  trash:'<path d="M3 4.6h10M6.4 4.6V3.2h3.2v1.4M4.3 4.6l.6 8.2c0 .6.5 1 1.1 1h4c.6 0 1.1-.4 1.1-1l.6-8.2"/>',
  claude:'<path d="M8 1.8 8.9 6l3.6-2.4L10.1 7.1 14.3 8l-4.2.9 2.4 3.5-3.6-2.4L8 14.2 7.1 10l-3.6 2.4L5.9 8.9 1.7 8l4.2-.9-2.4-3.5L7.1 6z" fill="#D97757" stroke="none"/>',
  codex:'<path d="M8 2.2 13 5.1v5.8L8 13.8 3 10.9V5.1z"/><path d="M8 2.2v11.6M3 5.1l10 5.8M13 5.1 3 10.9"/>',
  eye:'<path d="M1.9 8s2.3-4.3 6.1-4.3S14.1 8 14.1 8s-2.3 4.3-6.1 4.3S1.9 8 1.9 8z"/><circle cx="8" cy="8" r="1.9"/>',
  rewind:'<path d="M5.4 5.4h4.4a3.3 3.3 0 0 1 0 6.6H6.6"/><path d="M7.4 3.1 5.1 5.4l2.3 2.3"/>',
  doc:'<path d="M4.3 2.4h4.8l2.6 2.6v7.6c0 .6-.4 1-1 1H4.3c-.6 0-1-.4-1-1V3.4c0-.6.4-1 1-1z"/><path d="M9 2.5v2.7h2.7M5.7 8.2h4.6M5.7 10.6h3.2"/>',
  docplus:'<path d="M4.3 2.4h4.8l2.6 2.6v7.6c0 .6-.4 1-1 1H4.3c-.6 0-1-.4-1-1V3.4c0-.6.4-1 1-1z"/><path d="M9 2.5v2.7h2.7M7.5 7.4v4M5.5 9.4h4"/>',
  file:'<path d="M4.3 2.4h4.8l2.6 2.6v7.6c0 .6-.4 1-1 1H4.3c-.6 0-1-.4-1-1V3.4c0-.6.4-1 1-1z"/><path d="M9 2.5v2.7h2.7"/>',
  term:'<rect x="2" y="3" width="12" height="10" rx="2"/><path d="m4.9 6.3 2 1.7-2 1.7M8.6 10h2.6"/>',
  agent:'<circle cx="8" cy="5.5" r="2.4"/><path d="M3.4 13.2c.5-2.3 2.3-3.7 4.6-3.7s4.1 1.4 4.6 3.7"/>',
  after:'<path d="M4 3.4v4.3c0 1.2.9 2.1 2.1 2.1h6.2"/><path d="m10 7.5 2.4 2.3-2.4 2.3"/>',
  pause:'<path d="M6 4.2v7.6M10 4.2v7.6"/>',
  play:'<path d="M5.6 3.8v8.4L12 8z"/>',
  bubble:'<path d="M3 4.6c0-1 .7-1.7 1.7-1.7h6.6c1 0 1.7.7 1.7 1.7v4.4c0 1-.7 1.7-1.7 1.7H7.4L4.6 13v-2.3C3.7 10.6 3 9.9 3 9z"/>',
  penline:'<path d="M10.3 2.9a1.4 1.4 0 0 1 2 2L6.6 10.6l-2.7.7.7-2.7z"/><path d="M8.4 13.3h4.8"/>',
  bolt:'<path d="M9 1.9 4.3 9h3.4l-.6 5.1L11.7 7H8.3z"/>',
  excl:'<circle cx="8" cy="8" r="5.6"/><path d="M8 5v3.4"/><circle cx="8" cy="10.8" r=".8" fill="currentColor" stroke="none"/>',
  list:'<rect x="2.2" y="3" width="11.6" height="10" rx="2"/><path d="M7 6.3h4.4M7 9.7h4.4"/><circle cx="4.9" cy="6.3" r=".75" fill="currentColor" stroke="none"/><circle cx="4.9" cy="9.7" r=".75" fill="currentColor" stroke="none"/>',
  clip:'<path d="m12.4 7.5-4.6 4.6a2.9 2.9 0 0 1-4.1-4.1l4.9-4.9a1.9 1.9 0 0 1 2.7 2.7L6.6 10.5a1 1 0 0 1-1.4-1.4L9.5 4.8"/>',
  at:'<circle cx="8" cy="8" r="2.4"/><path d="M10.4 8v.9c0 1 .7 1.7 1.6 1.7s1.6-.8 1.6-2.4a5.6 5.6 0 1 0-2.6 4.7"/>',
  slash:'<path d="M10.4 2.8 5.6 13.2"/>',
  sparkle:'<path d="m7 2.4 1.1 3.1 3.1 1.1-3.1 1.1L7 10.8 5.9 7.7 2.8 6.6l3.1-1.1z"/><path d="m11.8 9.6.5 1.4 1.4.5-1.4.5-.5 1.4-.5-1.4-1.4-.5 1.4-.5z"/>',
  question:'<circle cx="8" cy="8" r="5.6"/><path d="M6.3 6.4a1.8 1.8 0 0 1 3.5.5c0 1.2-1.8 1.5-1.8 2.6"/><circle cx="8" cy="11.1" r=".8" fill="currentColor" stroke="none"/>',
  warn:'<path d="M7.1 3.1a1 1 0 0 1 1.8 0l4.9 8.6a1 1 0 0 1-.9 1.5H3.1a1 1 0 0 1-.9-1.5z"/><path d="M8 6.4v2.8"/><circle cx="8" cy="11" r=".75" fill="currentColor" stroke="none"/>',
  down:'<path d="M8 3.4v9.1M4.3 8.8 8 12.5l3.7-3.7"/>',
  wrap:'<path d="M2.8 4.3h10.4M2.8 8h8.4a2 2 0 0 1 0 4H8.4"/><path d="m9.8 10.6-1.4 1.4 1.4 1.4M2.8 12h3.2"/>',
  bell:'<path d="M4.4 10.9V7.5a3.6 3.6 0 0 1 7.2 0v3.4l1.2 1.3H3.2z"/><path d="M6.7 13.6a1.4 1.4 0 0 0 2.6 0"/>',
  plug:'<path d="M6.5 2.7H4.3c-.6 0-1 .4-1 1V6c.9-.4 2 .2 2 1.2S4.2 8.8 3.3 8.4v2.3c0 .6.4 1 1 1h2.3c-.4-.9.2-2 1.2-2s1.6 1.1 1.2 2h2.3c.6 0 1-.4 1-1V8.4c.9.4 2-.2 2-1.2s-1.1-1.6-2-1.2V3.7c0-.6-.4-1-1-1H9c.4-.9-.2-2-1.2-2s-1.6 1.1-1.3 2z"/>',
  globe:'<circle cx="8" cy="8" r="5.6"/><path d="M2.4 8h11.2M8 2.4c1.5 1.6 2.3 3.5 2.3 5.6S9.5 12 8 13.6C6.5 12 5.7 10.1 5.7 8S6.5 4 8 2.4z"/>',
  refresh:'<path d="M12.8 7.5A4.8 4.8 0 1 0 11.4 11"/><path d="M13 3.7v3.8H9.2"/>',
  compose:'<path d="M12.6 9.4v2.9c0 .7-.6 1.3-1.3 1.3H3.7c-.7 0-1.3-.6-1.3-1.3V4.7c0-.7.6-1.3 1.3-1.3h2.9"/><path d="M11.3 2.5a1.4 1.4 0 0 1 2 2L8.1 9.7l-2.6.7.7-2.6z"/>',
  book:'<path d="M2.4 3.3c2-.7 3.9-.4 5.6.9v9.1c-1.7-1.3-3.6-1.6-5.6-.9z"/><path d="M13.6 3.3c-2-.7-3.9-.4-5.6.9v9.1c1.7-1.3 3.6-1.6 5.6-.9z"/>',
  mvup:'<path d="M8 12.8V4M4.6 7.3 8 3.9l3.4 3.4"/>',
  mvdown:'<path d="M8 3.2V12M4.6 8.7 8 12.1l3.4-3.4"/>',
  swatch:'<rect x="2.6" y="2.6" width="4.6" height="4.6" rx="1.2"/><rect x="8.8" y="2.6" width="4.6" height="4.6" rx="1.2"/><rect x="2.6" y="8.8" width="4.6" height="4.6" rx="1.2"/><rect x="8.8" y="8.8" width="4.6" height="4.6" rx="1.2"/>',
  info:'<circle cx="8" cy="8" r="5.8"/><path d="M8 7.3v3.5M8 5.2v.05"/>',
  minus:'<path d="M4 8h8"/>',
  updown:'<path d="M5.3 6.3 8 3.6l2.7 2.7M5.3 9.7 8 12.4l2.7-2.7"/>',
  'chev-l':'<path d="M10 3.5 5.5 8l4.5 4.5"/>',
  wifi:'<path d="M2.1 6.5a8.7 8.7 0 0 1 11.8 0M4.2 8.8a5.7 5.7 0 0 1 7.6 0M6.3 11a2.7 2.7 0 0 1 3.4 0"/><circle cx="8" cy="12.9" r=".75" fill="currentColor" stroke="none"/>',
  battery:'<rect x="1.4" y="4.9" width="12" height="6.2" rx="1.9"/><path d="M14.7 7v2"/><rect x="2.8" y="6.3" width="7.4" height="3.4" rx=".9" fill="currentColor" stroke="none"/>',
  toggles:'<rect x="2" y="2.9" width="12" height="4.3" rx="2.15"/><circle cx="11.85" cy="5.05" r="1.25" fill="currentColor" stroke="none"/><rect x="2" y="8.8" width="12" height="4.3" rx="2.15"/><circle cx="4.15" cy="10.95" r="1.25" fill="currentColor" stroke="none"/>',
  mail:'<rect x="2" y="3.6" width="12" height="8.8" rx="1.6"/><path d="m2.7 4.6 5.3 4.1 5.3-4.1"/>',
  cal:'<rect x="2.4" y="3.2" width="11.2" height="10" rx="1.8"/><path d="M2.4 6.4h11.2M5.4 2v2.4M10.6 2v2.4"/>',
  qdiamond:'<path d="M8 1.9 14.1 8 8 14.1 1.9 8z"/><path d="M6.7 6.7a1.35 1.35 0 1 1 1.9 1.25c-.38.18-.6.48-.6.88v.27"/><circle cx="8" cy="10.9" r=".7" fill="currentColor" stroke="none"/>',
  ask:'<path d="M3 3.5h10a1 1 0 0 1 1 1V10a1 1 0 0 1-1 1H8.2L5.4 13.2V11H3a1 1 0 0 1-1-1V4.5a1 1 0 0 1 1-1z"/><path d="M5 6.4h6M5 8.5h3.6"/>',
  arr:'<path d="M3.5 8h8.6M8.8 4.6 12.2 8l-3.4 3.4"/>'
};
const svg = n => `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">${ICON[n] || ''}</svg>`;

/* ---------- status marks ---------- */
const mark = st => st === 'work' ? '<span class="spin" aria-hidden="true">⠋</span>' : st ? `<i class="dot ${st}"></i>` : '';

/* ---------- the sidebar, the same in every frame ---------- */
const PROJECTS = [
  { name:'loom', tone:'var(--orchid)', dot:'attn', sessions:[
    { id:'ink', t:'Port the sidebar to Ink tokens', st:'work', h:'claude', meta:'now', subs:[
      { st:'work', type:'explorer', d:'Map every sidebar token', e:'2m' },
      { st:'work', type:'implementer', d:'Port SidebarRow to Ink', e:'now', subs:[
        { st:'work', type:'explorer', d:'Find the footer tokens', e:'now' } ] },
      { st:'done', type:'2 finished' } ] },
    { id:'gate', t:'Review the gate failure', st:'attn', h:'claude', meta:'now' },
    { id:'rc', t:'Release C health check', st:'unv', h:'claude', meta:'12m' },
    { id:'lb', t:'Remora spike S10', st:'', h:'codex', meta:'2h' },
    { draft:true, t:'Try a lighter inspector…' } ] },
  { name:'second-brain', tone:'var(--aqua)', dot:'unv', sessions:[
    { id:'vm', t:'Weekly vault maintenance', st:'work', h:'claude', meta:'now' },
    { id:'th', t:'Thesis outline', st:'unv', h:'codex', meta:'25m' } ] },
  { name:'backend-api', tone:'var(--mint)', dot:'fail', sessions:[
    { id:'jwt', t:'Migrate auth to JWT', st:'fail', h:'codex', meta:'3h' },
    { id:'rl', t:'Rate limiter tests', st:'', h:'codex', meta:'2d' } ] }
];
// A subagent row branches from its parent's status column: one branch per row, the last one curving, and a guide that runs on
// for every ancestor that still has a sibling below.
const STEP = 19;
function subs(list, depth, cont) {
  return list.map((a, k) => {
    const last = k === list.length - 1, x = 22 + (depth - 1) * STEP;
    const guides = cont.map((on, d) => on ? `<i class="g" style="left:${22 + d * STEP}px"></i>` : '').join('');
    const ind = a.st === 'done' ? '<span class="ind ck" data-i="check"></span>' : `<span class="ind">${mark(a.st)}</span>`;
    return `<div class="sub${a.st === 'done' ? ' done' : ''}" style="padding-left:${x + 13}px">${guides}<i class="br ${last ? 'last' : 'mid'}" style="left:${x}px"></i>${ind}<span class="ty">${a.type}</span><span class="de">${a.d || ''}</span><span class="el">${a.e || ''}</span></div>`
      + (a.subs ? subs(a.subs, depth + 1, [...cont, !last]) : '');
  }).join('');
}
const initial = name => name.replace(/[^a-z]/gi, '').charAt(0).toUpperCase();
function projectGroup(p, sel) {
  return `<div class="pgroup" style="--tone:${p.tone}">
    <div class="proj-head"><span class="pmark">${initial(p.name)}</span><span class="pn">${p.name}</span>${p.dot ? `<i class="dot ${p.dot}" style="width:6px;height:6px"></i>` : ''}<span class="chev" data-i="chev-d"></span></div>
    ${p.sessions.map(s => s.draft
      ? `<div class="row srow draft"><span class="ind"></span><span class="t">${s.t}</span><span class="x" data-i="x"></span></div>`
      : `<div class="row srow${s.id === sel ? ' sel' : ''}" data-s="${s.id}"><span class="ind">${mark(s.st)}</span>${s.h ? `<span class="hm ${s.h}"></span>` : ''}<span class="t">${s.t}</span><span class="meta">${s.meta}</span></div>` + (s.subs ? subs(s.subs, 1, []) : '')
    ).join('')}
  </div>`;
}
function sidebar(sel) {
  return `
    <div class="side-top"><div class="lights"><i></i><i></i><i></i></div><button class="ib" title="Hide the sidebar" data-i="side-l"></button></div>
    <button class="search" data-open="palette"><span data-i="search"></span><span>Search</span><kbd>⌘K</kbd></button>
    <div class="nav">
      <div class="row${sel === 'home' ? ' sel' : ''}"><span class="ic" data-i="home"></span><span class="t">Home</span><span class="badge attn">1</span></div>
      <div class="row act"><span class="ic" data-i="plus"></span><span class="t">New session</span><kbd>⌘N</kbd></div>
    </div>
    <div class="side-sec"><span class="label">Projects</span><span class="view"><b>projects</b> · activity</span></div>
    <div class="plist">${PROJECTS.map(p => projectGroup(p, sel)).join('')}</div>
    <div class="side-foot">
      <button class="ib" data-open="plus" data-i="plus" title="New"></button>
      <button class="usage" title="Plan limits: 5-hour 62% left, weekly 74% left"><span>5h</span><span class="meter"><i style="width:62%"></i></span><span class="v">62%</span><span>·</span><span>wk</span><span class="v">74%</span></button>
      <button class="ib" data-i="gear" title="Settings" style="margin-left:auto"></button>
    </div>`;
}
$$('.side[data-sel]').forEach(el => el.innerHTML = sidebar(el.dataset.sel));
$$('[data-tree]').forEach(el => el.innerHTML = projectGroup(PROJECTS[0], el.dataset.tree));
$$('[data-mark]').forEach(el => el.innerHTML = mark(el.dataset.mark));
$$('[data-i]').forEach(el => el.insertAdjacentHTML('afterbegin', svg(el.dataset.i)));

/* ---------- frames: fit to the page, or 100 % ---------- */
let zoom = false;
function fit() {
  $$('.stage').forEach(st => {
    const win = st.firstElementChild, w = +win.dataset.w, h = +win.dataset.h;
    win.style.width = w + 'px'; win.style.height = h + 'px';
    const avail = st.clientWidth, s = zoom ? 1 : Math.min(1, avail / w);
    win.style.transform = `scale(${s})`;
    win.style.left = (!zoom && avail > w) ? (avail - w) / 2 + 'px' : '0';
    st.style.height = Math.ceil(h * s) + (zoom ? 14 : 0) + 'px';
    st.classList.toggle('zoomed', zoom);
  });
}
addEventListener('resize', fit); fit();
new ResizeObserver(fit).observe(document.body);

/* ---------- switches ---------- */
const sw = (id, fn) => { const el = $(id); el.parentElement.addEventListener('click', () => { el.classList.toggle('on'); fn(el.classList.contains('on')); }); };
sw('#swAmbient', on => { ambient = on; oceans.forEach(o => o.sync()); });
sw('#swPins', on => document.body.classList.toggle('pins', on));
sw('#swZoom', on => { zoom = on; fit(); });
$$('#themeSeg button').forEach(b => b.addEventListener('click', () => {
  document.documentElement.dataset.theme = b.dataset.themeSet;
  $$('#themeSeg button').forEach(x => x.classList.toggle('on', x === b));
  oceans.forEach(o => { o.readInk(); o.draw(); });
}));
// v3 or the v4 proposal (B0): every token has a v4 answer, and the page passes the choice to every frame.
$$('#inkSeg button').forEach(b => b.addEventListener('click', () => {
  document.documentElement.dataset.ink = b.dataset.inkSet;
  $$('#inkSeg button').forEach(x => x.classList.toggle('on', x === b));
}));
$$('.seg').forEach(s => { if (s.id !== 'themeSeg') s.addEventListener('click', e => { const b = e.target.closest('button'); if (!b) return; $$('button', s).forEach(x => x.classList.toggle('on', x === b)); }); });
$$('.spec .sw, .minic .sw').forEach(s => s.addEventListener('click', () => s.classList.toggle('on')));
