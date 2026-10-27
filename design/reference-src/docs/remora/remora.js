/* ============================================================
   Remora, Home's assistant: the brief, the face that fades in with
   it, the asking, the memory, the quick question and a new session's
   brief. The face is still (DESIGN §9, §20); no surface draws art.
   ============================================================ */
const iconize = root => $$('[data-i]', root).forEach(el => { if (!el.querySelector(':scope>svg')) el.insertAdjacentHTML('afterbegin', svg(el.dataset.i)); });
const HNAME = { claude: 'Claude Code', codex: 'Codex' };
const hmark = h => `<span class="hm ${h}" title="${HNAME[h]}"></span>`;
const winR = $('#winR'), winA = $('#winA'), winM = $('#winM'), winK = $('#winK'), winN = $('#winN');
// The pins are placed once everything below is drawn.
let ready = false;

const PJ = { loom: { name: 'loom', tone: 'var(--orchid)' }, sb: { name: 'second-brain', tone: 'var(--aqua)' }, api: { name: 'backend-api', tone: 'var(--mint)' }, web: { name: 'dotfiles', tone: 'var(--rose)' } };

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

/* ---------- the brief's face (DESIGN §9): Front, still, at its place; a new brief fades it in ---------- */
const sent = $('.bsent', winR);
sent.innerHTML = sent.textContent.trim().split(/\s+/).map(w => `<span class="w">${w}</span>`).join(' ');
const words = $$('.w', sent), tiles = $$('.tile', winR);
const foot = $('[data-role=foot]', winR), quiet = $('[data-role=quiet]', winR), prop = $('[data-role=prop]', winR);
const face = $('.rface', winR);
// The reading takes 3.5 s; then the sentence comes word by word, the tiles one by one, and the rest.
const TL = { fade: .6, readEnd: 3.5, word: .034, tile: .13, rest: .5 };
TL.writeEnd = TL.readEnd + words.length * TL.word + .1;
TL.tilesEnd = TL.writeEnd + (tiles.length - 1) * TL.tile + .26;
TL.end = TL.tilesEnd + TL.rest + .3;
const BEATS = [['Fades in', 0, TL.fade], ['Reads', TL.fade, TL.readEnd], ['Writes', TL.readEnd, TL.end]];
$('#tline').innerHTML = BEATS.map(([n, a, b]) => `<span style="flex:${(b - a).toFixed(2)} 0 0"><b>${a.toFixed(1)}</b>${n}</span>`).join('');

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
  timers.forEach(clearTimeout); timers = [];
  winR.classList.remove('reading');
  words.forEach(w => w.classList.remove('in')); tiles.forEach(x => x.classList.add('wait'));
  [quiet, prop, foot].forEach(e => e.classList.add('wait'));
}
// The remora at rest, with nothing new to read: the states with no new brief, and the end of a played one.
function restRemora() {
  $('#tline').classList.remove('on'); $('#tclock').textContent = 'at rest';
}
// A new brief: the face fades in at its place (at once under Reduce Motion), then the reading, then the sentence and the tiles.
function play() {
  resetBrief();
  $('#tline').classList.add('on');
  winR.classList.add('reading');
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
    $('#tclock').textContent = 'still';
    timers.push(setTimeout(showAll, 1200));
    return;
  }
  $('#tclock').textContent = '0.0 s';
  face.animate([{ opacity: 0 }, { opacity: 1 }], { duration: TL.fade * 1000, easing: 'ease-out' });
  reveal(TL.readEnd);
}
// The sentence comes in word by word from t seconds, the tiles one by one, and the rest after them.
function reveal(t) {
  words.forEach((w, i) => timers.push(setTimeout(() => w.classList.add('in'), (t + i * TL.word) * 1000)));
  timers.push(setTimeout(() => winR.classList.remove('reading'), t * 1000));
  tiles.forEach((x, i) => timers.push(setTimeout(() => x.classList.remove('wait'), (TL.writeEnd + i * TL.tile) * 1000)));
  timers.push(setTimeout(() => [quiet, prop, foot].forEach(e => e.classList.remove('wait')), TL.tilesEnd * 1000));
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
  $('#callGrp').style.visibility = h === 'morning' ? '' : 'hidden';
  const plan = h === 'later' ? PLAN.later : h === 'morning' && R.call === 'limit' ? PLAN.limit : PLAN.morning;
  const side = $('.i4side', winR); side.toggleAttribute('data-i4none', h === 'none'); i4sidebar(side);
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

/* ---------- start: the arrival plays when the brief comes into view, once; ?h=, ?c= and ?seek= hold a state for checking ---------- */
const q = new URLSearchParams(location.search);
if (q.get('h')) { R.home = q.get('h'); setSeg($('#homeSeg'), 'h', R.home); }
if (q.get('c')) { R.call = q.get('c'); setSeg($('#callSeg'), 'c', R.call); }
if (q.get('k')) { K.view = 'answer'; K.scope = q.get('k'); setSeg($('#kSeg'), 'k', 'answer'); setSeg($('#kScope'), 's', K.scope); drawK(); }
if (q.get('n')) { N.state = q.get('n'); drawN(); }
if (q.get('m')) { const b = $(`#memSeg [data-m=${q.get('m')}]`); setSeg($('#memSeg'), 'm', q.get('m')); $$('.mpane', winM).forEach(p => { p.hidden = p.dataset.m !== b.dataset.m; }); }
resetBrief(); restRemora();
if (R.home !== 'morning' || R.call !== 'ok') drawR();
else new IntersectionObserver((es, io) => { if (es[0].isIntersecting) { io.disconnect(); drawR(); } }, { threshold: .45 }).observe(winR);
ready = true;
requestAnimationFrame(placeAll);
