/* ============================================================
   Ink v4 (B0): the model and the effort of the chapter 06 windows:
   the two chips, the model panel and the effort menu, drawn from
   one list. The sidebar and the status bar are shared (side4.js).
   ============================================================ */

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
