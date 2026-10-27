/* ============================================================
   Ink v4 (B0): the sidebar's two views, the status bar, the
   header's tab variant and the small live bits. The markup of
   the windows is in body.html; everything repeated four times
   (sidebar, status bar) is built here.
   ============================================================ */

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
    ? `<span class="i4scb"><span class="i4scr">${s.why}</span><span class="hm ${s.h}"></span></span>`
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

// The model and the effort (06): two chips, the model panel and the effort menu, drawn four ways from one list.
ICON.effort = '<path d="M8 3.6v9"/><path d="M8 3.6C7.6 2.7 6.6 2.3 5.7 2.6c-.8.2-1.3.9-1.4 1.6-.9.2-1.6 1-1.6 2 0 .4.1.8.3 1.1-.6.4-.9 1-.9 1.7 0 .9.6 1.7 1.4 2 0 1 .8 1.8 1.8 1.9.9.1 1.7-.3 2.1-1.1"/><path d="M8 3.6c.4-.9 1.4-1.3 2.3-1 .8.2 1.3.9 1.4 1.6.9.2 1.6 1 1.6 2 0 .4-.1.8-.3 1.1.6.4.9 1 .9 1.7 0 .9-.6 1.7-1.4 2 0 1-.8 1.8-1.8 1.9-.9.1-1.7-.3-2.1-1.1"/><path d="M5.6 6.3c.8 0 1.5.5 1.6 1.3M10.4 6.3c-.8 0-1.5.5-1.6 1.3"/>';
$$('[data-i4i]').forEach(el => el.innerHTML = svg(el.dataset.i4i));
const I4_LEVEL_NOTE = { Low:'Quick edits, least thinking', Medium:'Everyday work', High:'Harder problems', 'Extra high':'Long agentic runs', Max:'Thinks as long as it needs' };
const I4_LEVELS = ['Low', 'Medium', 'High', 'Extra high', 'Max'];
const I4_MODELS = [
  { h:'claude', name:'Claude Code', models:[
    { n:'Opus 5.5', d:'Long agentic coding', ctx:'200K', eff:I4_LEVELS, def:'Medium', cur:true },
    { n:'Fable 5.1', d:'Hardest, long-horizon work', ctx:'1M', eff:I4_LEVELS, def:'High' },
    { n:'Sonnet 5.5', d:'Fast, everyday work', ctx:'200K', eff:['Low', 'Medium', 'High', 'Max'], def:'Medium' },
    { n:'Haiku 5.5', d:'Quick answers', ctx:'200K' } ]},
  { h:'codex', name:'Codex', models:[
    { n:'GPT-6 Astra', d:'Most capable', ctx:'400K', eff:['Low', 'Medium', 'High', 'Extra high'], def:'Medium' },
    { n:'GPT-6.1 Sol', d:'Near Astra, for less', ctx:'400K', eff:['Low', 'Medium', 'High'], def:'Medium' } ]},
  { h:'pi', name:'pi', models:[
    { n:'DeepSeek V4.1', d:'Through OpenRouter', ctx:'200K', eff:['Low', 'High', 'Max'], def:'High' },
    { n:'Kimi K3', d:'Through Moonshot', ctx:'256K' },
    { n:'Qwen 4 Coder', d:'On this Mac, with Ollama', ctx:'128K' } ]}
];
const I4_UNSET = [
  { h:'opencode', name:'opencode', st:'Not found on this Mac', act:'Install…' },
  { h:'agy', name:'agy', st:'Off', act:'Turn On…' }
];

function i4mrow(m, h, o = {}) {
  const nm = o.q ? m.n.replace(new RegExp(o.q, 'i'), x => `<b>${x}</b>`) : m.n;
  return `<div class="i4mr${o.mark ? ' wm' : ''}${m.cur ? ' cur' : ''}${o.hi ? ' hi' : ''}">${o.mark ? `<span class="hm ${h}"></span>` : ''}<span class="nm">${nm}</span><span class="d">${m.d}</span><span class="ctx">${m.ctx}</span><span class="ck">${m.cur ? svg('check') : ''}</span></div>`;
}

function i4chips(model, h, level, open) {
  const chev = svg('chev-d').replace('<svg', '<svg class="chv"');
  return `<div class="i4mchips"><span class="i4pkc${open === 'model' ? ' on' : ''}"><span class="hm ${h}"></span>${model}${chev}</span>`
    + (level ? `<span class="i4pkc${open === 'effort' ? ' on' : ''}">${svg('effort')}${level}${chev}</span>` : '') + `</div>`;
}

function i4effort(m, current, hi) {
  return `<div class="i4emenu"><div class="i4emh"><span class="i4lab">Effort</span><span class="m">${m.n}</span></div>`
    + m.eff.map(l => `<div class="i4emr${l === current ? ' cur' : ''}${l === hi ? ' hi' : ''}"><span class="nm">${l}</span><span class="d">${I4_LEVEL_NOTE[l]}</span>${l === m.def ? '<span class="tag">Default</span>' : '<span></span>'}<span class="ck">${l === current ? svg('check') : ''}</span></div>`).join('')
    + `</div>`;
}

function i4modelpanel(el) {
  const frame = el.dataset.i4model;
  const find = n => I4_MODELS.flatMap(g => g.models).find(m => m.n === n);
  if (frame === 'effort' || frame === 'effort2') {
    const m = frame === 'effort' ? find('Opus 5.5') : find('GPT-6.1 Sol');
    const cur = frame === 'effort' ? 'Extra high' : 'Medium';
    el.innerHTML = i4chips(m.n, frame === 'effort' ? 'claude' : 'codex', cur, 'effort') + i4effort(m, cur, frame === 'effort' ? 'Extra high' : 'High');
    const chip = el.querySelectorAll('.i4pkc')[1];
    el.querySelector('.i4emenu').style.marginLeft = chip.offsetLeft - el.querySelector('.i4mchips').offsetLeft + 'px';
    return;
  }
  const rail = active => {
    const item = (cls, inner, tip) => `<button class="i4mri${cls}">${inner}${tip || ''}</button>`;
    return `<div class="i4mrl">${item(active === 'recent' ? ' on' : '', svg('clock'))}<i class="sep"></i>`
      + I4_MODELS.map(g => item(active === g.h ? ' on' : '', `<span class="hm ${g.h}"></span>`)).join('')
      + `<i class="sep"></i>`
      + I4_UNSET.map(u => item(' off', `<span class="hm ${u.h}"></span>`, frame === 'search' && u.h === 'opencode' ? `<span class="i4mtip">opencode <em>· Not found on this Mac</em></span>` : '')).join('')
      + `</div>`;
  };
  const group = (g, hi) => `<div class="i4mgh"><span class="hm ${g.h}"></span><span class="i4lab">${g.name}</span><span class="n">${g.models.length}</span></div>`
    + g.models.map(m => i4mrow(m, g.h, { hi: m.n === hi })).join('');
  const unset = `<div class="i4mgh na"><span class="i4lab">Not set up</span></div>`
    + I4_UNSET.map(u => `<div class="i4mr na"><span class="hm ${u.h}"></span><span class="nm">${u.name}</span><span class="d">${u.st}</span><button class="i4btn gh h24">${u.act}</button></div>`).join('');
  let search, list, active;
  if (frame === 'search') {
    search = `${svg('search')}<span class="q">so</span><span class="i4caret"></span>`;
    list = i4mrow(find('Sonnet 5.5'), 'claude', { mark: true, q: 'so', hi: true }) + i4mrow(find('GPT-6.1 Sol'), 'codex', { mark: true, q: 'so' })
      + `<div class="i4mskip">Not searched: opencode (not found), agy (off).</div>`;
    active = '';
  } else {
    search = `${svg('search')}<span class="i4caret"></span><span class="i4ph">Search models</span>`;
    list = I4_MODELS.map(g => group(g, 'Opus 5.5')).join('') + unset;
    active = 'claude';
  }
  el.innerHTML = i4chips('Opus 5.5', 'claude', 'Extra high', 'model')
    + `<div class="i4mpop"><div class="i4msr">${search}</div><div class="i4mbody">${rail(active)}<div class="i4mlst">${list}</div></div></div>`;
}

$$('[data-i4model]').forEach(i4modelpanel);
$$('[data-i4side]').forEach(i4sidebar);
$$('[data-i4status]').forEach(i4statusbar);

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
