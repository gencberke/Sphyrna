/* ============================================================
   The edge and system states. Everything the windows
   show is drawn here, so a switch draws it again.
   ============================================================ */
const iconize = root => $$('[data-i]', root).forEach(el => { if (!el.querySelector(':scope>svg')) el.insertAdjacentHTML('afterbegin', svg(el.dataset.i)); });
const HNAME = { claude: 'Claude Code', codex: 'Codex' };
const hmark = h => `<span class="hm ${h}" title="${HNAME[h]}"></span>`;
const APPICON = '<!--ICON-->';
const paintIcons = root => $$('img.appicon', root).forEach(i => { i.src = APPICON; });
const paintMarks = root => $$('[data-mb]', root).forEach(el => {
  $$(':scope>svg.mbmark', el).forEach(n => n.remove());
  el.insertAdjacentHTML('afterbegin', markSVG('front', { badge: el.dataset.badge || '', px: +(el.dataset.px || 20) }));
});
// The status column's marks, with the two rings: State unknown and Identity unclear.
const mk = st => st === 'unknown' ? '<span class="ring"></span>' : st === 'unclear' ? '<span class="ring attn"></span>' : mark(st);
const winH = $('#winH'), winE = $('#winE'), winB = $('#winB'), winD = $('#winD');

/* ---------- the sidebar: projects as the project page draws them, or none yet ---------- */
const PJ = { loom: { name: 'loom', tone: 'var(--orchid)' }, sb: { name: 'second-brain', tone: 'var(--aqua)' }, api: { name: 'backend-api', tone: 'var(--mint)' } };
const DOT_OF = { fail: 'fail', attn: 'attn', unclear: 'attn', unv: 'unv' };
const projDot = list => ['fail', 'attn', 'unv'].find(c => list.some(s => DOT_OF[s.st] === c));
const USAGE = '<button class="usage" title="Plan limits: 5-hour 62% left, weekly 74% left"><span>5h</span><span class="meter"><i style="width:62%"></i></span><span class="v">62%</span><span>·</span><span>wk</span><span class="v">74%</span></button>';
// The sidebar is the shared v4 one (side4.js); a state says only whether projects exist and which row is selected.
function drawSide(side, o) {
  side.toggleAttribute('data-i4none', !!(o.groups && o.groups.length === 0));
  if (o.sel === 'home') side.dataset.i4side = 'home'; else delete side.dataset.i4side;
  if (o.sel === 'ink') side.dataset.i4sel = 'ink'; else delete side.dataset.i4sel;
  i4sidebar(side);
}
const S = (id, t, st, meta, h) => ({ id, t, st, meta, h });

/* ============================================================
   01 First launch and Home: five states of one window.
   ============================================================ */
const H = { state: 'first', checking: false };
const homeSide = $('[data-role=side]', winH), homeBody = $('[data-role=home]', winH);
const FIRST_TEXT = 'Add the folder you work in. Its Claude sessions then appear in the sidebar and here, and new sessions start inside it.';
const NOCLAUDE_TEXT = "Sphyrna starts sessions with the claude command and could not use the one on your terminal's PATH. Install Claude Code or fix the PATH, then choose Check Again. You can add a project now.";
const checkBtn = (cls = 'sec') => H.checking
  ? `<button class="btn ${cls}" data-act="check" disabled><span class="spin">⠋</span>Checking…</button>`
  : `<button class="btn ${cls}" data-act="check">Check Again</button>`;
const codexCol = '<div class="acol"><button class="btn sec" disabled>New Codex Session</button><small>Codex comes in a later version</small></div>';
function firstRun(noClaude) {
  return `<div class="firstrun">
    ${noClaude ? '<span class="sym" data-i="warn"></span>' : '<span class="aic"><img class="appicon" alt=""></span>'}
    <h3>${noClaude ? 'Sphyrna could not find Claude' : 'No projects yet'}</h3>
    <p>${noClaude ? NOCLAUDE_TEXT : FIRST_TEXT}</p>
    <div class="acts"><button class="btn pri">Add Project…</button>${noClaude ? checkBtn() : '<button class="btn sec">New Claude Session</button>'}${codexCol}</div>
  </div>`;
}
const hrowOf = (s, p, extra = '') => `<div class="hrow ${extra}" style="--tone:${p.tone}"><span class="ind">${mk(s.st)}</span><span class="t">${hmark(s.h || 'claude')}${s.t}<span class="pj"><span class="pmark sm">${initial(p.name)}</span>${p.name}</span></span>`;
const NEEDS_EMPTY = '<article class="card lc"><div class="lc-h">Needs you</div><div class="hrow blank">A session that waits for an answer, or finished while you were away, is listed here.</div></article>';
const LIMITS = (at = '14:06') => `<article class="card sc"><div class="sc-h"><b>Plan limits</b><span>updated ${at}</span></div>
  <div class="pace"><div class="l"><b>5-hour</b><span>62% left</span></div><div class="ptrack"><i style="width:62%"></i><em style="left:58%"></em></div><small>Resets 16:40 · at this pace it lasts</small></div>
  <div class="pace"><div class="l"><b>Weekly</b><span>74% left</span></div><div class="ptrack"><i style="width:74%"></i><em style="left:71%"></em></div><small>Resets Monday 09:00 · at this pace it lasts</small></div></article>`;
const today = (tok, n, cache) => `<article class="card sc"><div class="sc-h"><b>Today</b></div><div class="today"><b>${tok}</b> tokens · <b>${n}</b> sessions · <b>${cache}</b> from cache</div></article>`;
const hero = (when, sentence, counts) => `<div class="hero"><div class="eyebrow">${when}</div><h1>${sentence}</h1><p>${counts}</p></div>`;
const NOTICE = () => `<div class="hnote"><div class="notice"><span class="ic" data-i="warn"></span><b>Sphyrna could not find Claude</b><p>New sessions cannot start until the claude command works from your terminal's PATH. Sessions already listed stay readable.</p><div class="row2">${checkBtn('sec sm')}</div></div></div>`;
const CONT = [[S('ink', 'Port the sidebar to Ink tokens', '', ''), PJ.loom], [S('vm', 'Weekly vault maintenance', '', ''), PJ.sb]];
function homeState(state) {
  if (state === 'first' || state === 'noclaude') return firstRun(state === 'noclaude');
  if (state === 'quiet') return `<div class="home">${hero('tuesday 20 october · 14:06', 'One session is working. Nothing needs you.', '<b>1</b> working · <b>5</b> sessions today')}
    <div class="hcols"><div>${NEEDS_EMPTY}</div><div>${LIMITS()}${today('16.1K', 5, '40%')}</div></div></div>`;
  if (state === 'noclaude2') return `<div class="home">${hero('tuesday 20 october · 14:06', 'Nothing is working or waiting.', '<b>3</b> sessions today')}
    ${NOTICE()}<div class="hcols"><div>${NEEDS_EMPTY}</div><div>${today('9.4K', 3, '38%')}</div></div></div>`;
  return `<div class="home">${hero('tuesday 20 october · 09:02', 'Nothing is working or waiting.', '<b>2</b> to continue · <b>7</b> sessions yesterday')}
    <div class="hcols"><div>
      <article class="card lc"><div class="lc-h">Continue<span class="n">2</span></div><div class="lead">These sessions were running when Sphyrna quit.</div>
        ${CONT.map(([s, p], k) => hrowOf(s, p, 'one cont' + (k ? '' : ' hov')) + '<span class="age">Last active 11h ago</span><span class="acts"><button class="btn pri sm">Resume</button></span></div>').join('')}
      </article>${NEEDS_EMPTY}</div><div>${LIMITS('09:02')}</div></div></div>`;
}
const SIDE_LISTS = {
  quiet: [[PJ.loom, [S('ink', 'Port the sidebar to Ink tokens', 'work', 'now'), S('lb', 'Remora spike S10', '', '2h', 'codex'), S('p2', 'Draw the Ink reference', '', '4h')]],
    [PJ.sb, [S('vm', 'Weekly vault maintenance', '', '1h'), S('th', 'Thesis outline', '', '25m', 'codex')]], [PJ.api, [S('rl', 'Rate limiter tests', '', '2d', 'codex')]]],
  noclaude2: [[PJ.loom, [S('ink', 'Port the sidebar to Ink tokens', '', '1h'), S('lb', 'Remora spike S10', '', '2h', 'codex')]],
    [PJ.sb, [S('vm', 'Weekly vault maintenance', '', '3h')]], [PJ.api, [S('rl', 'Rate limiter tests', '', '2d', 'codex')]]],
  quit: [[PJ.loom, [S('ink', 'Port the sidebar to Ink tokens', '', '11h'), S('lb', 'Remora spike S10', '', '1d', 'codex')]],
    [PJ.sb, [S('vm', 'Weekly vault maintenance', '', '11h'), S('th', 'Thesis outline', '', '1d', 'codex')]], [PJ.api, []]]
};
function drawHome() {
  const st = H.state, empty = st === 'first' || st === 'noclaude';
  drawSide(homeSide, { sel: 'home', groups: empty ? [] : SIDE_LISTS[st], newOff: st === 'noclaude' || st === 'noclaude2', usage: !empty && st !== 'noclaude2' });
  homeBody.innerHTML = homeState(st);
  iconize(homeBody); paintIcons(homeBody);
  $$('#homeSeg button').forEach(b => b.classList.toggle('on', b.dataset.h === st));
  requestAnimationFrame(placeAll);
}
$$('#homeSeg button').forEach(b => b.addEventListener('click', () => { H.state = b.dataset.h; H.checking = false; drawHome(); }));
$('#homeReplay').addEventListener('click', () => { H.state = 'first'; drawHome(); });
// Check Again asks again; here it finds Claude, so Home becomes itself.
winH.addEventListener('click', e => {
  const b = e.target.closest('[data-act=check]'); if (!b || H.checking) return;
  H.checking = true; drawHome();
  setTimeout(() => { H.checking = false; H.state = H.state === 'noclaude' ? 'first' : 'quiet'; drawHome(); }, 1500);
});
drawHome();

/* ============================================================
   02 The ended session: the terminal's last screen, the record,
   and the stopped chat.
   ============================================================ */
const E = { face: 'term', rec: 'ended', phase: 'ended' };
const ePane = $('[data-role=pane]', winE), eBody = $('[data-role=body]', winE), eSide = $('[data-role=side]', winE);
const KEPT = `<span class="w">⏺</span> The sidebar now reads the Ink tokens. Every row is 28 pt with one status column,
  the project shows as its mark, and the selected session takes its project's tint.

<span class="g">⏺</span> <span class="b">Bash</span>(scripts/check.sh --suite SidebarInkTests)
  <span class="d">⎿  Executed 48 tests, with 0 failures (0 unexpected) in 6.214 (6.390) seconds</span>

<span class="w">⏺</span> All 48 sidebar tests pass. The subagent rows still draw the old guide;
  that's the next step, if you want it.

<span class="trule"></span><span class="u">&gt; </span>
<span class="trule"></span>  <span class="d">? for shortcuts</span>                                       <span class="d">Opus 5.5 · ui/ink-sidebar</span>

<span class="d">Resume this session with:</span>
<span class="d" data-role="lastline">claude --resume 3f2a9c1e-5b7d-4e08-9a61-c2d4f0b8e715</span>`;
const LIVE = `<span class="o"> ▐▛███▜▌</span>   <span class="b">Claude Code</span> <span class="d">v2.1.300</span>
<span class="o">▝▜█████▛▘</span>  <span class="d">Opus 5.5 · Claude Max</span>
<span class="o">  ▘▘ ▝▝</span>    <span class="d">~/Library/Caches/loom-v2/wt/ink</span>

<span class="u">&gt; Port the sidebar rows to the Ink tokens: one status column, 28 pt rows,
  the project as its mark. Keep the pill. Run the sidebar tests after.</span>

<span class="w">⏺</span> All 48 sidebar tests pass. The subagent rows still draw the old guide;
  that's the next step, if you want it.

<span class="trule"></span><span class="u">&gt; </span><span class="cur"></span>
<span class="trule"></span>  <span class="d">? for shortcuts</span>`;
const ENDLINE = details => `<div class="endnote in" data-role="endnote"><span class="tx" data-role="endtx">This session is not running.</span><span class="grow"></span>${details ? '<button class="btn sec" data-act="details">Show Details</button>' : ''}<button class="btn pri" data-act="resume">Resume</button></div>`;
const RNOTE = {
  away: { tone: 'unv', i: 'check', t: 'Finished while you were away', p: 'Claude reported a completed turn.' },
  failed: { tone: 'fail', i: 'warn', t: 'Claude reported a failure', p: 'API Error: 529 Overloaded. Claude stopped the turn before it ended.' },
  stopunv: { tone: 'fail', i: 'warn', t: 'Stop could not be verified', p: 'Process cleanup was not verified. Last process check: 1 remaining.' },
  problem: { tone: 'fail', i: 'warn', t: 'This session has a problem', p: "Sphyrna is not receiving events from Claude, so this session's status may be wrong. The session itself is not affected." },
  unclear: { tone: 'attn', i: 'qdiamond', t: 'Session identity is not certain', p: 'Sphyrna could not tell which Claude session this is, so it changed nothing.' }
};
const rnote = n => `<div class="rnote ${n.tone}"><span class="ic" data-i="${n.i}"></span><b>${n.t}</b><p>${n.p}</p></div>`;
const PILL = {
  away: '<span class="state unv"><i class="dot unv"></i>Finished</span>',
  failed: '<span class="state fail"><i class="dot fail"></i>Failed</span>',
  stopunv: '<span class="state fail"><i class="dot fail"></i>Stop not verified</span>',
  problem: '<span class="state fail"><i class="dot fail"></i>Problem</span>',
  unclear: '<span class="state attn"><span class="ring attn"></span>Identity unclear</span>',
  unknown: '<span class="state idle">State unknown</span>',
  ready: '<span class="state idle">Ready</span>'
};
const STATUS = { ended: 'Not running', away: 'Finished', failed: 'Failed', stopunv: 'Stop not verified', problem: 'Problem', unclear: 'Identity unclear', unknown: 'State unknown' };
const MARK_OF = { ended: '', away: 'unv', failed: 'fail', stopunv: 'fail', problem: 'fail', unclear: 'unclear', unknown: 'unknown' };
const RESUME_TEXT = 'Resume continues this Claude session in its folder. If Claude no longer has it, Sphyrna says so.';
function record() {
  const r = E.rec, busy = E.phase === 'resuming';
  return `<div class="record"><div class="rcol">
    ${RNOTE[r] ? rnote(RNOTE[r]) : ''}
    <div class="rstate"><h3 data-role="rhead">${busy ? '<span class="spin">⠋</span>Resuming…' : 'Not running'}</h3><p>${RESUME_TEXT}</p>
      <div class="acts"><button class="btn pri" data-act="resume"${busy ? ' disabled' : ''}>Resume</button>${r === 'stopunv' ? '<button class="btn sec">Stop</button>' : ''}<button class="btn sec">Rename…</button></div></div>
    <dl class="rfacts">
      <div class="fr"><dt>Status</dt><dd>${mk(MARK_OF[r])}${STATUS[r]}</dd></div>
      <div class="fr"><dt>Project</dt><dd><span class="pmark sm" style="--tone:var(--orchid)">L</span>loom</dd></div>
      <div class="fr"><dt>Working directory</dt><dd class="m">~/Library/Caches/loom-v2/wt/ink</dd></div>
      <div class="fr"><dt>Claude session ID</dt><dd class="m">3f2a9c1e-5b7d-4e08-9a61-c2d4f0b8e715</dd></div>
      <div class="fr"><dt>Created</dt><dd>Yesterday at 14:02</dd></div>
      <div class="fr"><dt>Last activity</dt><dd>Yesterday at 14:52</dd></div>
      <div class="fr"><dt>Last used</dt><dd>Yesterday at 14:53</dd></div>
    </dl></div></div>`;
}
const UNSENT = 'Also run the footer tests when the suite passes.';
const CHAT = `<div class="chat" data-view="normal">
  <div class="scroller"><div class="col">
    <div class="marker">Session started · Opus 5.5 · high · Ask before edits · ui/ink-sidebar</div>
    <div class="you"><div class="bubble">Port the sidebar rows to the Ink tokens: one status column, 28 pt rows, the project as its mark. Keep the pill. Run the sidebar tests after.</div><div class="you-foot"><span class="tm">14:02</span></div></div>
    <div class="tfold"><div class="foldrow" role="button"><span class="cv" data-i="chev-r"></span>Worked for <span class="mono">3m 40s</span> · changed 3 files</div></div>
    <div class="reply"><div class="prose"><p>The rows read the Ink tokens now: 28 pt, one status column, and the project as its mark. Next I run the sidebar suite, which asks first in Ask before edits.</p></div></div>
  </div></div>
  <div class="dock"><div class="dock-in">
    <div class="pinned"><div class="pcard cut" data-card="cutoff">
      <div class="pc-h"><span data-i="warn"></span>Allow this command?</div>
      <div class="pc-says" style="margin-top:8px"><b>Claude stopped before you answered</b></div>
      <div class="pc-sub">scripts/check.sh --suite SidebarInkTests</div>
      <div class="pc-acts"><span class="grow"></span><button class="btn pri" data-act="resume">Resume</button></div>
    </div></div>
    <div class="undeliv"><span data-i="after"></span><b>Not delivered: 1 message</b><span>It comes back in the composer when the session runs again.</span><button class="lk2" data-i="copy">Copy</button></div>
    <div class="composer">
      <textarea placeholder="Message Claude, or / for commands, @ for files" aria-label="Message"></textarea>
      <div class="cbar">
        <button class="cchip" title="Attach, mention or run a command" data-i="plus"></button>
        <button class="cchip mode" style="--mt:var(--m-abe)"><span data-i="shield"></span><span>Ask before edits</span></button>
        <span class="grow"></span>
        <button class="cchip mdl" title="Model and effort"><span class="hm claude"></span><span>Opus 5.5</span><span class="eff">High</span><span class="cv" data-i="chev-d"></span></button>
        <button class="send" title="Send · return. Sending resumes the session."><span data-i="up"></span></button>
      </div>
    </div>
  </div></div>
</div>`;
function drawEnded() {
  const f = E.face, live = E.phase === 'live';
  const st = f === 'record' ? MARK_OF[E.rec] : '';
  // Only the CLI canvas stays dark; the shared header and tabs follow the window's appearance.
  delete ePane.dataset.theme;
  drawSide(eSide, { sel: 'ink', groups: [[PJ.loom, [S('ink', 'Port the sidebar to Ink tokens', live ? '' : st, live ? 'now' : '1h'), S('gate', 'Review the gate failure', 'attn', 'now'), S('lb', 'Remora spike S10', '', '2h', 'codex')]], [PJ.sb, [S('vm', 'Weekly vault maintenance', '', '3h')]], [PJ.api, [S('rl', 'Rate limiter tests', '', '2d', 'codex')]]], badge: 1 });
  $('[data-role=pill]', winE).innerHTML = live ? PILL.ready : f === 'record' && PILL[E.rec] ? PILL[E.rec] : '';
  $('[data-role=tabmark]', winE).innerHTML = live ? '' : mk(st);
  $('[data-role=cgroup]', winE).innerHTML = (live || (f === 'record' && E.rec === 'stopunv') ? '<button><span class="stopsq"></span>Stop</button><span class="div"></span>' : '') + '<button class="more" data-i="more" title="More"></button>';
  if (f === 'term') eBody.innerHTML = live ? `<div class="term">${LIVE}</div>` : ENDLINE(true) + `<div class="term kept" aria-label="Last screen of the session">${KEPT}</div>`;
  else if (f === 'record') eBody.innerHTML = record();
  else {
    eBody.innerHTML = CHAT;
    if (live) {
      $$('.pinned, .undeliv', eBody).forEach(n => n.remove());
      $('.composer textarea', eBody).value = UNSENT;
    } else if (E.phase === 'resuming') {
      const b = $('.pcard.cut [data-act=resume]', eBody); b.disabled = true; b.innerHTML = '<span class="spin">⠋</span>Resuming…';
    }
  }
  iconize(winE);
  if (E.phase === 'resuming' && f === 'term') {
    const tx = $('[data-role=endtx]', winE); tx.innerHTML = '<span class="spin">⠋</span>Resuming…';
    $$('[data-role=endnote] button', winE).forEach(b => { b.disabled = true; });
  }
  $$('#endSeg button').forEach(b => b.classList.toggle('on', b.dataset.e === f));
  $('#recSeg').hidden = f !== 'record';
  $$('#recSeg button').forEach(b => b.classList.toggle('on', b.dataset.r === E.rec));
  const sc = $('.scroller', winE); if (sc) sc.scrollTop = sc.scrollHeight;
  const kept = $('.term.kept', winE); if (kept) kept.scrollTop = kept.scrollHeight;
  requestAnimationFrame(placeAll);
}
let resumeT = 0;
function resume() {
  if (E.phase !== 'ended') return;
  E.phase = 'resuming'; drawEnded();
  clearTimeout(resumeT);
  resumeT = setTimeout(() => { E.phase = 'live'; if (E.face === 'record') E.face = 'term'; drawEnded(); }, 1600);
}
function resetEnded(face) { clearTimeout(resumeT); E.phase = 'ended'; if (face) E.face = face; drawEnded(); }
$$('#endSeg button').forEach(b => b.addEventListener('click', () => resetEnded(b.dataset.e)));
$$('#recSeg button').forEach(b => b.addEventListener('click', () => { E.rec = b.dataset.r; resetEnded('record'); }));
$('#endReset').addEventListener('click', () => { E.rec = 'ended'; resetEnded('term'); });
winE.addEventListener('click', e => {
  if (e.target.closest('[data-act=resume]')) resume();
  else if (e.target.closest('[data-act=details]')) { E.rec = 'ended'; resetEnded('record'); }
});
$('[data-role=allnotes]').innerHTML = ['away', 'failed', 'stopunv', 'problem', 'unclear'].map(k => rnote(RNOTE[k])).join('');
iconize($('[data-role=allnotes]'));
drawEnded();

/* ============================================================
   03 Banners: the top stack, one at a time, by weight.
   ============================================================ */
const BANS0 = [
  { id: 'start', tone: 'fail', i: 'warn', t: 'Claude could not be started. claude was not found on the PATH of your terminal environment (14 folders searched).', x: true },
  { id: 'helper', tone: 'attn', i: 'excl', t: "New sessions are turned off because Sphyrna's process helper is missing. Without it Sphyrna cannot make sure Stop and Quit end all of a session's background work. Reinstall Sphyrna to fix this.", x: false },
  { id: 'dup', tone: '', i: 'info', t: '“loom” is already in Sphyrna.', x: true }
];
const B = { list: [], open: false };
const bStack = $('[data-role=stack]', winB);
function drawStack() {
  const n = B.list.length, shown = B.open ? B.list : B.list.slice(0, 1);
  bStack.innerHTML = shown.map((b, k) => `<div class="banner ${b.tone}${!B.open && n > 1 ? ' stack' : ''}" data-b="${b.id}"><span data-i="${b.i}"></span><span class="bt">${b.t}</span>`
    + (k === 0 && n > 1 ? `<button class="peek" data-act="peek" title="${B.open ? 'Show one' : 'Show all'}">${B.open ? 'Show Fewer' : '+' + (n - 1)}</button>` : '')
    + (b.x ? '<button class="ib sm" data-i="x" data-act="close" title="Dismiss message"></button>' : '') + '</div>').join('');
  iconize(bStack);
  requestAnimationFrame(placeAll);
}
function resetBanners() { B.list = BANS0.map(b => ({ ...b })); B.open = false; drawStack(); }
winB.addEventListener('click', e => {
  if (e.target.closest('[data-act=peek]')) { B.open = !B.open; drawStack(); return; }
  const x = e.target.closest('[data-act=close]');
  if (x) { const id = x.closest('.banner').dataset.b; B.list = B.list.filter(b => b.id !== id); if (B.list.length < 2) B.open = false; drawStack(); }
});
$('#banReset').addEventListener('click', resetBanners);
drawSide($('[data-role=side]', winB), { sel: 'ink', groups: [[PJ.loom, [S('ink', 'Port the sidebar to Ink tokens', '', '1h'), S('gate', 'Review the gate failure', 'attn', 'now'), S('lb', 'Remora spike S10', '', '2h', 'codex')]], [PJ.sb, [S('vm', 'Weekly vault maintenance', '', '3h')]], [PJ.api, [S('rl', 'Rate limiter tests', '', '2d', 'codex')]]], badge: 1, newOff: true });
$('[data-role=kept]', winB).innerHTML = KEPT;
resetBanners();

/* ============================================================
   04 Outside the window: the mark, its menu, the banner, the Dock.
   ============================================================ */
const R = {
  jwt: { st: 'fail', t: 'Migrate auth to JWT', p: 'backend-api' },
  gate: { st: 'attn', t: 'Review the gate failure', p: 'loom' },
  th: { st: 'unv', t: 'Thesis outline', p: 'second-brain' },
  ink: { t: 'Port the sidebar to Ink tokens', p: 'loom' },
  vm: { t: 'Weekly vault maintenance', p: 'second-brain' }
};
const SC = {
  idle: { badge: '', needs: [], work: [], banner: false },
  work: { badge: 'work', needs: [], work: [R.ink, R.vm], banner: false },
  attn: { badge: 'attn', needs: [R.gate], work: [R.ink, R.vm], banner: true },
  unv: { badge: 'unv', needs: [R.th], work: [R.ink], banner: false },
  fail: { badge: 'fail', needs: [R.jwt, R.gate, R.th], work: [R.ink, R.vm], banner: true }
};
const D = { sc: 'attn', menu: false };
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
function axLabel(sc) {
  const parts = ['Sphyrna'];
  if (sc.needs.length) parts.push(plural(sc.needs.length, 'session needs you', 'sessions need you'));
  if (sc.work.length) parts.push(sc.needs.length ? `${sc.work.length} working` : plural(sc.work.length, 'session working', 'sessions working'));
  return `VoiceOver: “${parts.join(', ')}”`;
}
function menuHTML(sc) {
  let h = '';
  if (!sc.needs.length && !sc.work.length) h += '<div class="it dim" data-role="nothing">Nothing is working or waiting.</div>';
  if (sc.needs.length) h += '<div class="hd" data-role="needs">Needs you</div>' + sc.needs.map(r => `<div class="it"><span class="ind"><i class="dot ${r.st}"></i></span><span class="t">${r.t}</span><span class="meta">${r.p}</span></div>`).join('');
  if (sc.work.length) h += '<div class="hd">Working</div>' + sc.work.map((r, k) => `<div class="it"${k ? '' : ' data-role="work1"'}><span class="ind"><span class="spin0">⠋</span></span><span class="t">${r.t}</span><span class="meta">${r.p}</span></div>`).join('');
  return h + '<hr><div class="it" data-role="newc"><span class="hm claude"></span>New Claude Session<kbd>⌘N</kbd></div><div class="it">Open Sphyrna</div><hr><div class="it">Settings…<kbd>⌘,</kbd></div><div class="it">Quit Sphyrna<kbd>⌘Q</kbd></div>';
}
const dItem = $('[data-role=mbitem]', winD), dMenu = $('[data-role=smenu]', winD), dBan = $('[data-role=nban]', winD), dBadge = $('[data-role=badge]', winD);
function drawDesk() {
  const sc = SC[D.sc];
  dItem.dataset.badge = sc.badge; paintMarks(dItem.parentElement);
  dItem.classList.toggle('open', D.menu);
  dMenu.hidden = !D.menu; dMenu.innerHTML = menuHTML(sc);
  const n = sc.needs.length; dBadge.hidden = !n; dBadge.textContent = n;
  dBan.classList.toggle('off', !sc.banner || D.menu);
  $('[data-role=ax]').textContent = axLabel(sc);
  $('#mbMenu').textContent = D.menu ? 'Close the Menu' : 'Open the Menu';
  $$('#mbSeg button').forEach(b => b.classList.toggle('on', b.dataset.m === D.sc));
  requestAnimationFrame(placeAll);
}
$$('#mbSeg button').forEach(b => b.addEventListener('click', () => { D.sc = b.dataset.m; drawDesk(); }));
$('#mbMenu').addEventListener('click', () => { D.menu = !D.menu; drawDesk(); });
dItem.addEventListener('click', () => { D.menu = !D.menu; drawDesk(); });
$('#mbBanner').addEventListener('click', () => {
  D.menu = false; if (!SC[D.sc].banner) D.sc = 'attn';
  drawDesk(); dBan.classList.add('off');
  setTimeout(() => dBan.classList.remove('off'), 380);
});
drawDesk();

/* ============================================================
   Pins: each sits beside what it names. A pin whose part is not
   on screen hides.
   ============================================================ */
function pinTo(win, id, target, fx, fy, dx, dy) {
  const pin = $('#' + id); if (!pin) return;
  const ok = target && target.getClientRects().length && !target.closest('[hidden]') && !target.closest('.off');
  pin.style.visibility = ok ? '' : 'hidden';
  if (!ok) return;
  const wr = win.getBoundingClientRect(), s = wr.width / win.offsetWidth || 1, r = target.getBoundingClientRect();
  pin.style.left = Math.round((r.left - wr.left) / s + (r.width / s) * fx + dx) + 'px';
  pin.style.top = Math.round((r.top - wr.top) / s + (r.height / s) * fy + dy) + 'px';
}
function placeAll() {
  if (!document.body.classList.contains('pins')) return;
  const h = H.state;
  pinTo(winH, 'pinH1', h === 'first' && $('.firstrun .aic', winH), 1, 0, 4, -6);
  pinTo(winH, 'pinH2', h === 'first' && $('.firstrun .acts', winH), .5, 1, -11, 6);
  pinTo(winH, 'pinH3', $('[data-role=noproj]', winH), 1, .5, -110, -9);
  pinTo(winH, 'pinH4', $('.firstrun small', winH), 1, .5, 8, -9);
  pinTo(winH, 'pinH5', $('.firstrun .sym', winH), 1, 0, 4, -6);
  pinTo(winH, 'pinH6', $('.hero h1', winH), 0, .5, -34, -9);
  pinTo(winH, 'pinH7', $('.hrow.blank', winH), 1, .5, -34, -9);
  pinTo(winH, 'pinH8', $('.hnote .notice', winH), 0, 0, -12, -9);
  pinTo(winH, 'pinH9', $('.lc .lead', winH), 1, .5, -34, -9);
  const f = E.face;
  pinTo(winE, 'pinE1', f === 'term' && $('[data-role=endtx]', winE), 1, .5, 8, -9);
  pinTo(winE, 'pinE2', f === 'term' && $('[data-role=endnote] [data-act=resume]', winE), .5, 1, -11, 6);
  pinTo(winE, 'pinE3', f === 'term' && $('.term.kept [data-role=lastline]', winE), 1, .5, 8, -9);
  pinTo(winE, 'pinE4', $('[data-role=cgroup]', winE), .5, 1, -11, 6);
  pinTo(winE, 'pinE5', f === 'record' && $('[data-role=rhead]', winE), 0, .5, -34, -9);
  pinTo(winE, 'pinE6', f === 'record' && $('.record .rnote', winE), 0, 0, -12, -9);
  pinTo(winE, 'pinE7', f === 'chat' && $('.composer', winE), 1, 0, -12, -9);
  pinTo(winE, 'pinE8', f === 'chat' && $('.pcard.cut', winE), 0, 0, -12, -9);
  pinTo(winE, 'pinE9', f === 'chat' && $('.undeliv', winE), 0, .5, -34, -9);
  const top = $('.banner', bStack);
  pinTo(winB, 'pinB1', top && $('[data-act=peek]', top), .5, 0, -11, -16);
  pinTo(winB, 'pinB2', top && $(':scope>span[data-i]', top), .5, 0, -11, -16);
  pinTo(winB, 'pinB3', top && $('.bt', top), .4, 0, -11, -16);
  pinTo(winB, 'pinB4', top && $('[data-act=close]', top), .5, 1, -11, 4);
  pinTo(winB, 'pinB5', bStack.children.length && bStack, .25, 1, -11, -1);
  pinTo(winD, 'pinD1', dItem, 0, .5, -30, -9);
  pinTo(winD, 'pinD2', D.menu && $('[data-role=needs]', dMenu), 0, .5, -30, -9);
  pinTo(winD, 'pinD3', D.menu && $('[data-role=work1]', dMenu), 0, .5, -30, -9);
  pinTo(winD, 'pinD4', D.menu && $('[data-role=newc]', dMenu), 0, .5, -30, -9);
  pinTo(winD, 'pinD5', D.menu && $('[data-role=nothing]', dMenu), 0, .5, -30, -9);
  pinTo(winD, 'pinD6', dBan, 0, 0, -12, -9);
  pinTo(winD, 'pinD7', !dBadge.hidden && dBadge, 1, 0, 2, -12);
}
addEventListener('resize', () => requestAnimationFrame(placeAll));
document.addEventListener('scroll', e => { if (e.target instanceof Element && e.target.closest('.win')) placeAll(); }, true);
$('#swPins').parentElement.addEventListener('click', () => requestAnimationFrame(placeAll));
new ResizeObserver(() => requestAnimationFrame(placeAll)).observe(document.body);
if (location.search.includes('pins')) { $('#swPins').classList.add('on'); document.body.classList.add('pins'); }
paintIcons(document); paintMarks(document);
requestAnimationFrame(placeAll);

/* ---------- states from the address, for checking a frame: ?h=quiet&e=record&r=failed&m=fail&menu&bopen ---------- */
const q = new URLSearchParams(location.search);
if (q.get('h')) { H.state = q.get('h'); drawHome(); }
if (q.get('e') || q.get('r')) { E.face = q.get('e') || 'record'; E.rec = q.get('r') || 'ended'; drawEnded(); }
if (q.has('bopen')) { B.open = true; drawStack(); }
if (q.get('m')) D.sc = q.get('m');
if (q.has('menu')) D.menu = true;
if (q.get('m') || q.has('menu')) drawDesk();
