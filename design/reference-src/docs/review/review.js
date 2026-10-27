/* ============================================================
   The review surfaces. The Changes tab at 556 with
   its comments, the Agents tab's transcript in two voices, and
   the sheet family with its keys. Everything the windows show
   is drawn here, so a reset draws it again.
   ============================================================ */
const iconize = root => $$('[data-i]', root).forEach(el => { if (!el.querySelector(':scope>svg')) el.insertAdjacentHTML('afterbegin', svg(el.dataset.i)); });
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const HNAME = { claude: 'Claude Code', codex: 'Codex' };
const hmark = h => `<span class="hm ${h}" title="${HNAME[h]}"></span>`;
const winC = $('#winC'), winG = $('#winG'), winS = $('#winS');
const SIDEBAR_W = 260, PANE_MIN = 480;

/* ---------- the sidebar, as the project page draws it, at two moments of the session ---------- */
const LOOM = {
  ready: () => [
    { id: 'ink', t: 'Port the sidebar to Ink tokens', st: '', h: 'claude', meta: 'now' },
    { id: 'gate', t: 'Review the gate failure', st: 'attn', h: 'claude', meta: 'now' },
    { id: 'rc', t: 'Release C health check', st: 'unv', h: 'claude', meta: '12m' },
    { id: 'lb', t: 'Remora spike S10', st: '', h: 'codex', meta: '2h' },
    { id: 'p2', t: 'Draw the Ink reference', st: '', h: 'claude', meta: '4h' }
  ],
  work: () => {
    const done = AG.list.filter(a => a.st === 'done').length;
    const run = AG.list.filter(a => a.st !== 'done').map(a => ({ st: a.st === 'wait' ? 'attn' : 'work', type: a.type, d: a.d, e: '1m' }));
    return [
      { id: 'ink', t: 'Port the sidebar to Ink tokens', st: 'attn', h: 'claude', meta: 'now', subs: [...run, { st: 'done', type: `${done} finished` }] },
      { id: 'gate', t: 'Review the gate failure', st: 'attn', h: 'claude', meta: 'now' },
      { id: 'rc', t: 'Release C health check', st: 'unv', h: 'claude', meta: '12m' },
      { id: 'lb', t: 'Remora spike S10', st: '', h: 'codex', meta: '2h' },
      { id: 'p2', t: 'Draw the Ink reference', st: '', h: 'claude', meta: '4h' }
    ];
  },
  working: () => LOOM.ready().map(s => s.id === 'ink' ? { ...s, st: 'work' } : s)
};
const OTHERS = [
  [{ id: 'vm', t: 'Weekly vault maintenance', st: 'work', h: 'claude', meta: 'now' }, { id: 'th', t: 'Thesis outline', st: 'unv', h: 'codex', meta: '25m' }],
  [{ id: 'jwt', t: 'Migrate auth to JWT', st: 'fail', h: 'codex', meta: '3h' }, { id: 'rl', t: 'Rate limiter tests', st: '', h: 'codex', meta: '2d' }]
];
const rowV = (s, sel) => `<div class="row srow${s.id === sel ? ' sel' : ''}" data-s="${s.id}"><span class="ind">${mark(s.st)}</span>${hmark(s.h)}<span class="t">${s.t}</span><span class="meta">${s.meta}</span></div>` + (s.subs ? subs(s.subs, 1, []) : '');
const groupV = (p, list, sel) => `<div class="pgroup" style="--tone:${p.tone}">
    <div class="proj-head"><span class="pmark">${initial(p.name)}</span><span class="pn">${p.name}</span>${p.dot ? `<i class="dot ${p.dot}" style="width:6px;height:6px"></i>` : ''}<span class="chev" data-i="chev-d"></span></div>
    ${list.map(s => rowV(s, sel)).join('')}
  </div>`;
function drawSidebar(side) {
  side.innerHTML = sidebar(side.dataset.sel);
  $('.side-sec', side).innerHTML = '<span class="label">Projects</span><span class="view"><button class="on" title="Group by project · ⌘2">projects</button> · <button title="Recent activity · ⌘1">activity</button></span>';
  const lists = [LOOM[side.dataset.v || 'ready'](), ...OTHERS];
  $('.plist', side).innerHTML = PROJECTS.map((p, i) => groupV(p, lists[i], side.dataset.sel)).join('');
  iconize(side);
}

/* ============================================================
   The changes. Each hunk is its @@ line (old start, new start),
   then its lines: " " context, "-" removed, "+" added. The counts,
   the numbers and the stats are worked out from the lines.
   ============================================================ */
const FILES = {
  theme: { path: 'Sources/LoomCatalogUI/LoomTheme+Sidebar.swift', st: 'M', hunks: [[
    '@@ -4 +4 @@ extension LoomTheme {',
    '     enum Sidebar {',
    '-        static let cardRowHeight: CGFloat = 44',
    '-        static let stripeWidth: CGFloat = 3',
    '+        static let rowHeight: CGFloat = 28',
    '+        static let statusSlot: CGFloat = 12',
    '+        static let columnGap: CGFloat = 8',
    '+        static let markSize: CGFloat = 16',
    '         static let rowInset: CGFloat = 10',
    '         static let sectionGap: CGFloat = 18',
    '-        static let selected = Surface.selected',
    "+        // A selected row takes its project's tint, not grey.",
    '+        static let selectedTint: Double = 0.14',
    '+        static let selectedEdge: Double = 0.34',
    '     }',
    ' }']] },
  row: { path: 'Sources/LoomCatalogUI/SidebarRow.swift', st: 'M', hunks: [[
    '@@ -13 +13 @@ struct SidebarRow: View',
    '     let selected: Bool',
    '-    let tint: Color',
    '+    let project: ProjectTone',
    ' ',
    '     var body: some View {',
    '-        HStack(spacing: 8) {',
    '-            Rectangle().fill(tint).frame(width: 3)',
    '+        HStack(spacing: LoomTheme.Sidebar.columnGap) {',
    '+            StatusMark(row.indicator)',
    '+            ProjectMark(project, size: .small)',
    '             Text(row.title)',
    '         }',
    '-        .frame(minHeight: 44)',
    '+        .frame(height: LoomTheme.Sidebar.rowHeight)',
    '         .background(tint)'], [
    '@@ -38 +39 @@ struct SidebarRow: View',
    '     private var tint: Color {',
    '-        selected ? LoomTheme.Sidebar.selected : .clear',
    '+        guard selected else { return .clear }',
    '+        return project.tint(LoomTheme.Sidebar.selectedTint)',
    '     }']] },
  foot: { path: 'Sources/LoomCatalogUI/SidebarFooter.swift', st: 'M', hunks: [[
    '@@ -9 +9 @@ struct SidebarFooter: View',
    '         HStack(spacing: 6) {',
    '-            Image(systemName: "gearshape").opacity(0.6)',
    '+            Image(systemName: "gearshape")',
    '+                .foregroundStyle(LoomTheme.Text.secondary)',
    '             Spacer()',
    '-            Text("Sphyrna").font(.caption)',
    '+            Text("Sphyrna").font(LoomTheme.Typography.caption)',
    '         }',
    '-        .padding(.horizontal, 12)',
    '+        .padding(.horizontal, LoomTheme.Sidebar.rowInset)',
    '         .frame(height: 36)']] },
  tests: { path: 'Tests/LoomCatalogUITests/SidebarInkTests.swift', st: 'A', hunks: [[
    '@@ -0 +1 @@',
    '+import XCTest',
    '+@testable import LoomCatalogUI',
    '+',
    '+final class SidebarInkTests: XCTestCase {',
    '+    func testRowIsTwentyEightPoints() {',
    '+        XCTAssertEqual(LoomTheme.Sidebar.rowHeight, 28)',
    '+    }',
    '+',
    '+    func testSelectedRowTakesTheProjectTint() {',
    '+        let tint = SidebarRow.tint(.orchid, selected: true)',
    '+        XCTAssertEqual(tint, LoomTheme.Sidebar.selectedTint)',
    '+    }',
    '+}']] },
  core: { path: 'Sources/LoomCatalogUI/LoomTheme.swift', st: 'M', hunks: [[
    '@@ -61 +61 @@ enum LoomTheme {',
    '     enum Surface {',
    '         static let canvas = Color("Canvas")',
    '-        static let card = Color("Card")',
    '+        static let raise1 = Color("Raise1")',
    '+        static let raise2 = Color("Raise2")',
    '+        static let card = raise1',
    '         static let selected = Color("Selected")']] },
  card: { path: 'Sources/LoomCatalogUI/SidebarCardRow.swift', st: 'D', hunks: [[
    '@@ -1 +0 @@',
    '-import SwiftUI',
    '-',
    '-/// The two-row session card with its 3 pt project stripe.',
    '-struct SidebarCardRow: View {',
    '-    let row: SessionRowModel',
    '-    var body: some View {',
    '-        SidebarRow(row: row, selected: false, tint: .clear)',
    '-    }',
    '-}']] },
  rename: { path: 'Tests/LoomCatalogUITests/SidebarRowTests.swift', old: 'SidebarCardRowTests.swift', st: 'R', hunks: [[
    '@@ -3 +3 @@',
    ' @testable import LoomCatalogUI',
    ' ',
    '-final class SidebarCardRowTests: XCTestCase {',
    '+final class SidebarRowTests: XCTestCase {',
    '     func testTitleKeepsOneLine() {',
    '-        let row = SidebarCardRow(row: .fixture, tint: .clear)',
    '+        let row = SidebarRow(row: .fixture, project: .orchid)',
    '         XCTAssertEqual(row.titleLineLimit, 1)']] }
};
// Rows with their numbers, and each file's +/− counts.
for (const f of Object.values(FILES)) {
  f.rows = []; f.added = 0; f.removed = 0;
  for (const h of f.hunks) {
    const m = /^@@ -(\d+) \+(\d+) @@ ?(.*)$/.exec(h[0]);
    let o = +m[1], n = +m[2];
    const rows = h.slice(1).map(l => {
      const k = l[0], tx = l.slice(1);
      if (k === '+') { f.added++; return { k: 'a', o: null, n: n++, tx }; }
      if (k === '-') { f.removed++; return { k: 'r', o: o++, n: null, tx }; }
      return { k: 'c', o: o++, n: n++, tx };
    });
    const oc = rows.filter(r => r.k !== 'a').length, nc = rows.filter(r => r.k !== 'r').length;
    f.rows.push({ k: 'h', tx: `@@ -${m[1]},${oc} +${m[2]},${nc} @@${m[3] ? ' ' + m[3] : ''}` }, ...rows);
  }
  f.rows.forEach(r => { if (r.k !== 'h') { r.side = r.k === 'r' ? 'o' : 'n'; r.line = r.side === 'o' ? r.o : r.n; r.key = r.side + r.line; } });
}
const fname = p => p.slice(p.lastIndexOf('/') + 1), fdir = p => p.slice(0, p.lastIndexOf('/'));
const pm = (a, r) => `<span class="pm">${a ? `<span class="add">+${a}</span>` : ''}${r ? `<span class="del">−${r}</span>` : ''}</span>`;
const totals = ids => ids.reduce((t, id) => [t[0] + FILES[id].added, t[1] + FILES[id].removed], [0, 0]);
// Folders first, then files, by name, as the chat's changed-files card lists them.
function tree(ids) {
  const dirs = new Map();
  ids.forEach(id => { const d = fdir(FILES[id].path); if (!dirs.has(d)) dirs.set(d, []); dirs.get(d).push(id); });
  return [...dirs.keys()].sort().map(d => ({ dir: d, files: dirs.get(d).sort((a, b) => fname(FILES[a].path).localeCompare(fname(FILES[b].path), 'en', { sensitivity: 'base' })) }));
}
const SCOPES = { last: 'Last turn', session: 'Whole session', branch: 'Branch' };
const EDITS_NOTE = "Claude's file edits. Shell commands and subagents show under Branch.";

/* ============================================================
   The Changes tab: one state per window. The draft lives per
   scope, as in ChangesState: a saved comment is anchored to the
   file, the line (the old side's number for a removed line) and
   the line's text.
   ============================================================ */
function makeChanges(panel, data, hooks = {}) {
  const S = {};
  const reset = () => Object.assign(S, {
    scope: data.scope || 'last', sel: { ...data.sel }, read: { last: true, session: true, branch: false },
    comments: { last: (data.comments || []).map(c => ({ ...c })), session: [], branch: [] },
    compose: data.compose ? { ...data.compose } : null, hov: data.hov || null, waiting: false
  });
  reset();
  panel.innerHTML = `<div class="chs" data-role="scroll">
      <div class="chtop"><div class="seg" data-role="scope">${Object.entries(SCOPES).map(([k, v]) => `<button data-s="${k}">${v}</button>`).join('')}</div></div>
      <p class="chnote" data-role="note"></p>
      <div data-role="body"></div>
      <div class="empty chwait" data-role="wait" hidden><h6>Reading the branch…</h6><p class="mono" style="font-size:11px">git diff --numstat -M 3f2a9c1 · <span data-role="clock">0</span> s</p></div>
      <div class="empty chwait" data-role="none" hidden><h6 data-role="nonetext"></h6></div>
    </div>
    <div class="chfoot" data-role="foot" hidden></div>`;
  const R = n => $(`[data-role=${n}]`, panel);
  const files = () => data.scopes[S.scope];
  const cur = () => S.sel[S.scope] || tree(files())[0].files[0];
  const count = scope => data.scopes[scope].length;

  function draw() {
    $$('[data-s]', R('scope')).forEach(b => b.classList.toggle('on', b.dataset.s === S.scope));
    const list = files();
    R('note').textContent = S.scope === 'branch' ? (S.waiting ? '' : 'Your working tree against main.') : EDITS_NOTE;
    R('note').hidden = S.scope === 'branch' && S.waiting;
    R('wait').hidden = !S.waiting;
    R('none').hidden = S.waiting || list.length > 0;
    if (!list.length) R('nonetext').textContent = S.scope === 'last' ? 'Claude has not edited files in the last turn.' : S.scope === 'session' ? 'Claude has not edited files in this session.' : 'No changes against main.';
    R('body').innerHTML = S.waiting || !list.length ? '' : fileList(list) + diffCard(FILES[cur()], cur());
    iconize(R('body'));
    drawFoot();
    hooks.count && hooks.count(S.waiting ? null : list.length);
    hooks.changed && hooks.changed();
  }
  function fileList(list) {
    const cs = S.comments[S.scope];
    return `<div class="files">${tree(list).map(g => `<div class="fdir"><span data-i="chev-d"></span>${g.dir}</div>` + g.files.map(id => {
      const f = FILES[id], n = cs.filter(c => c.file === id).length, sel = id === cur();
      const name = f.old ? `<span class="old">${f.old} →</span> ${fname(f.path)}` : fname(f.path);
      return `<div class="frow${sel ? ' on' : ''}" data-file="${id}" style="--d:1"><span class="st">${f.st}</span><span class="nm">${name}</span>${pm(f.added, f.removed)}${n ? `<span class="cm">· ${n} comment${n === 1 ? '' : 's'}</span>` : ''}<button class="op" title="Open in Editor" data-act="open" data-i="open"></button></div>`;
    }).join('')).join('')}</div>`;
  }
  function diffCard(f, id) {
    const cs = S.comments[S.scope].filter(c => c.file === id), comp = S.compose && S.compose.scope === S.scope && S.compose.file === id ? S.compose : null;
    const seen = new Set();
    const rows = f.rows.map(r => {
      if (r.k === 'h') return `<div class="dl h"><span class="tx">${esc(r.tx)}</span></div>`;
      const sg = r.k === 'a' ? '+' : r.k === 'r' ? '−' : '';
      let html = `<div class="dl${r.k === 'c' ? '' : ' ' + r.k}${S.hov === r.key && id === cur() ? ' hov' : ''}" data-key="${r.key}"><span>${r.o ?? ''}</span><span>${r.n ?? ''}</span><span class="sg">${sg}</span><span class="tx">${esc(r.tx) || ' '}</span><span class="plus" aria-hidden="true">+</span></div>`;
      if (!seen.has(r.key)) {
        seen.add(r.key);
        if (comp && comp.key === r.key) html += composeBox(comp);
        else { const c = cs.find(c => c.key === r.key); if (c) html += savedBox(c); }
      }
      return html;
    }).join('');
    const orphans = cs.filter(c => !f.rows.some(r => r.key === c.key)).map(c => savedBox(c, 'Line changed since')).join('');
    return `<div class="diff" data-role="diff"><div class="diff-h"><span data-i="doc"></span><span class="p">${f.path}</span><span class="grow"></span><button class="lk2" data-act="open">Open in Editor</button></div><div class="dlist">${rows}${orphans}</div></div>`;
  }
  const label = c => `Your comment · line ${c.line}`;
  const composeBox = c => `<div class="cbox edit" data-role="compose"><div class="ch"><span data-i="bubble"></span>${label(c)}<span class="grow"></span></div><textarea placeholder="Comment for Claude" rows="2" aria-label="Comment on line ${c.line}">${esc(c.text)}</textarea><div class="ca"><button class="btn sec sm" data-act="cancel">Cancel</button><button class="btn pri sm" data-act="add"${c.text.trim() ? '' : ' disabled'}>Add Comment</button></div></div>`;
  const savedBox = (c, lbl) => `<div class="cbox saved" data-role="saved" data-key="${c.key}" data-file="${c.file}"><div class="ch"><span data-i="bubble"></span>${lbl || label(c)}<span class="grow"></span><button data-act="edit">Edit</button><button data-act="remove">Remove</button></div><div class="ct">${esc(c.text)}</div></div>`;
  function drawFoot() {
    const foot = R('foot'), cs = S.comments[S.scope];
    foot.hidden = !cs.length || S.waiting;
    if (foot.hidden) return;
    const nf = new Set(cs.map(c => c.file)).size;
    foot.innerHTML = `<span class="fi" data-i="bubble"></span><span class="sum">${cs.length} comment${cs.length === 1 ? '' : 's'} in ${nf} file${nf === 1 ? '' : 's'}</span><span class="grow"></span><button class="btn sec sm" data-act="discard">Discard</button><button class="btn pri sm" data-act="send">Send to Claude</button>`;
    iconize(foot);
  }
  function setScope(scope) {
    S.scope = scope;
    if (scope === 'branch' && !S.read.branch) {
      S.waiting = true; draw();
      let t = 0; const clock = R('clock'); clock.textContent = '0';
      const tick = setInterval(() => { t++; clock.textContent = t; }, 1000);
      setTimeout(() => { clearInterval(tick); S.read.branch = true; S.waiting = false; if (S.scope === 'branch') draw(); }, 1700);
      return;
    }
    S.waiting = false; draw();
  }
  function rowOf(key) {
    const id = cur();
    return { id, r: FILES[id].rows.find(r => r.key === key) };
  }
  function begin(key) {
    const { id, r } = rowOf(key); if (!r) return;
    const saved = S.comments[S.scope].find(c => c.file === id && c.key === key);
    S.compose = { scope: S.scope, file: id, key, line: r.line, side: r.side, lineText: r.tx, text: saved ? saved.text : '' };
    S.hov = null; draw();
    const ta = $('[data-role=compose] textarea', panel); if (ta) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); }
  }
  function save() {
    const c = S.compose; if (!c || !c.text.trim()) return;
    const list = S.comments[c.scope], i = list.findIndex(x => x.file === c.file && x.key === c.key);
    const saved = { file: c.file, key: c.key, line: c.line, side: c.side, lineText: c.lineText, text: c.text.trim() };
    if (i >= 0) list[i] = saved; else list.push(saved);
    S.compose = null; draw();
  }
  // The message: the scope, then path:line, the line quoted, the comment; by file as the list shows them, then by line.
  function message() {
    const order = tree(files()).flatMap(g => g.files);
    const cs = [...S.comments[S.scope]].sort((a, b) => order.indexOf(a.file) - order.indexOf(b.file) || a.line - b.line);
    const name = S.scope === 'branch' ? 'Branch vs main' : SCOPES[S.scope];
    return [`Comments on the changes (${name}):`, ...cs.map(c => `${FILES[c.file].path}:${c.line}\n> ${c.lineText.trim()}\n${c.text}`)].join('\n\n');
  }
  panel.addEventListener('click', e => {
    const t = e.target;
    const scopeBtn = t.closest('[data-role=scope] [data-s]'); if (scopeBtn) return setScope(scopeBtn.dataset.s);
    const act = t.closest('[data-act]')?.dataset.act;
    if (act === 'open') { e.stopPropagation(); return; }
    if (act === 'cancel') { S.compose = null; return draw(); }
    if (act === 'add') return save();
    if (act === 'edit') { const b = t.closest('[data-role=saved]'); return begin(b.dataset.key); }
    if (act === 'remove') { const b = t.closest('[data-role=saved]'); S.comments[S.scope] = S.comments[S.scope].filter(c => !(c.file === b.dataset.file && c.key === b.dataset.key)); return draw(); }
    if (act === 'discard') { S.comments[S.scope] = []; if (S.compose && S.compose.scope === S.scope) S.compose = null; return draw(); }
    if (act === 'send') { const text = message(); S.comments[S.scope] = []; draw(); return hooks.send && hooks.send(text); }
    const row = t.closest('.frow[data-file]'); if (row) { S.sel[S.scope] = row.dataset.file; S.hov = null; return draw(); }
    const line = t.closest('.dl[data-key]'); if (line) return begin(line.dataset.key);
  });
  panel.addEventListener('input', e => {
    if (!e.target.matches('[data-role=compose] textarea') || !S.compose) return;
    S.compose.text = e.target.value;
    $('[data-act=add]', panel).disabled = !S.compose.text.trim();
  });
  panel.addEventListener('keydown', e => {
    if (!e.target.matches('[data-role=compose] textarea')) return;
    if (e.key === 'Enter' && !e.shiftKey && !e.altKey && !e.isComposing) { e.preventDefault(); save(); }
    else if (e.key === 'Escape') { e.preventDefault(); S.compose = null; draw(); }
  });
  panel.addEventListener('mouseover', e => {
    if (!S.hov || !e.target.closest('.dlist')) return;
    S.hov = null; $$('.dl.hov', panel).forEach(r => r.classList.remove('hov'));
  });
  return { draw, reset: () => { reset(); draw(); }, setScope, state: S, count };
}

/* ============================================================
   The subagents of the session's second turn. The explorer that
   checks the tree colour is live: its entries come in while the
   window is on screen, then it finishes with its result.
   ============================================================ */
const AGENTS0 = [
  { id: 'offsets', type: 'explorer', d: 'Find every tree offset', st: 'done', time: '1m 40s',
    brief: 'Find every offset the sidebar tree reads: where a branch starts, how far each depth steps, and the curve. List each with its file and line.',
    items: [['t', "I'll search the sidebar for the tree's sizes."], ['c', 'Grep', '"branch|guide" in Sources/LoomCatalogUI'], ['r', 'Found 3 files', 3], ['c', 'Read', 'Sources/LoomCatalogUI/SubagentTree.swift'], ['r', 'import SwiftUI', 142], ['k', 2],
      ['res', 'Three offsets matter: the 22 pt start, the 19 pt step and the 7 pt curve, all in LoomTheme+Sidebar.swift, lines 31 to 33. Nothing else in the sidebar reads them.']] },
  { id: 'tests', type: 'general-purpose', d: 'List the sidebar tests', st: 'done', time: '18s',
    brief: 'List the tests that cover the sidebar rows and the subagent tree, and what each one checks.',
    items: [['c', 'Bash', 'swift test list | grep -i -e sidebar -e subagenttree'], ['r', 'LoomCatalogUITests.SidebarInkTests/testRowIsTwentyEightPoints', 9],
      ['res', 'Nine tests: two in SidebarInkTests (the row height and the tint), four in SubagentTreeTests (the step, the guide, the depth and the last branch) and three in SidebarRowTests.']] },
  { id: 'contrast', type: 'explorer', d: "Check the tree colour's contrast", st: 'work', time: '1m', done: '1m 34s',
    brief: 'Check whether the Paper tree colour #C4C2BE meets 3:1 against the sidebar canvas, and whether a branch counts as a mark or a hairline under DESIGN §3. Report both ratios and what to change.',
    items: [['t', "I'll read the tree's colour tokens first, then the contrast rule in DESIGN."], ['c', 'Read', 'Sources/LoomCatalogUI/LoomTheme+Sidebar.swift'], ['r', 'enum Sidebar {', 64], ['c', 'Grep', '"tree" in Sources/LoomCatalogUI'], ['r', 'Found 4 files', 4], ['k', 4], ['c', 'Read', 'design/DESIGN.md'], ['r', '# Sphyrna design', 712]],
    live: [['t', "DESIGN §3 asks 3:1 for marks and nothing for hairlines. A branch's turn is drawn with the line, but it ties a subagent to its session, so it carries meaning."],
      ['c', 'Bash', 'swift scripts/contrast.swift "#C4C2BE" "#F7F6F3"'], ['r', '1.62:1', 1], ['c', 'Bash', 'swift scripts/contrast.swift "#8E8B86" "#F7F6F3"'], ['r', '3.41:1', 1], ['k', 3],
      ['res', "The Paper tree colour #C4C2BE reads 1.62:1 on the canvas, under the 3:1 floor for marks. Treat a branch as a mark: #8E8B86 reads 3.41:1 and still sits below the rows' text. Ink's #3B3B41 needs the same check."]] },
  { id: 'branch', type: 'implementer', d: 'Draw the branch shape', st: 'wait', time: '1m',
    brief: 'Draw each subagent branch inside its row as a BranchShape: the 22 pt start, a 19 pt step per depth and a 7 pt curve. Keep the guide running for each ancestor that has a sibling below.',
    items: [['t', "I'll draw the branch as a shape inside the row, so it scrolls with it."], ['c', 'Read', 'Sources/LoomCatalogUI/SubagentRow.swift'], ['r', 'import SwiftUI', 88], ['c', 'Edit', 'Sources/LoomCatalogUI/SubagentRow.swift']] }
];
const AG = { list: [], open: 'contrast', width: 556, voice: 'two', step: 0, timer: 0 };
const resetAgents = () => { AG.list = AGENTS0.map(a => ({ ...a, items: [...a.items] })); AG.open = 'contrast'; AG.step = 0; clearInterval(AG.timer); AG.timer = 0; };
resetAgents();
$$('.side[data-sel]').forEach(drawSidebar);
const agent = id => AG.list.find(a => a.id === id);
function entry(it, fresh) {
  const f = fresh ? ' fresh' : '';
  switch (it[0]) {
    case 't': return `<div class="te t${f}"><span class="g">⏺</span><div class="x">${esc(it[1])}</div></div>`;
    case 'res': return `<div class="te t res${f}"><span class="g">⏺</span><div class="x"><span class="label">Result</span>${esc(it[1])}</div></div>`;
    case 'c': return `<div class="te c${f}"><span class="g">⏺</span><div class="x"><b>${it[1]}</b><span class="a">(${esc(it[2])})</span></div></div>`;
    case 'r': return `<div class="te r${f}"><span class="g">⎿</span><div class="x">${esc(it[1])}${it[2] > 1 ? `<span class="more">  (+${it[2] - 1} lines)</span>` : ''}</div></div>`;
    case 'k': return `<div class="te k${f}"><span class="g">✻</span><div class="x">Thought for ${it[1]}s</div></div>`;
  }
  return '';
}
const pill = a => a.st === 'done' ? `<span class="state idle">Finished ${a.time}</span>` : `<span class="state"><span class="spin">⠋</span>Running ${a.time}</span>`;
const agRow = a => `<button class="arow2" data-ag="${a.id}"><span class="ind">${a.st === 'work' ? '<span class="spin">⠋</span>' : a.st === 'wait' ? '<i class="dot attn"></i>' : ''}</span><span class="ty">${a.type}</span><span class="el">${a.time}</span><span class="de">${esc(a.d)}</span>${a.st === 'wait' ? '<span class="nt attn">Waiting for you</span>' : ''}</button>`;
function agentsList() {
  const run = AG.list.filter(a => a.st !== 'done'), fin = AG.list.filter(a => a.st === 'done');
  if (!run.length && !fin.length) return '<p class="tnote">No subagents. They appear here while the session runs them.</p>';
  return (run.length ? `<div class="agsec"><div class="isech"><span class="label">Running</span><span class="n">${run.length}</span></div>${run.map(agRow).join('')}</div>` : '')
    + (fin.length ? `<div class="agsec"><div class="isech"><span class="label">Finished</span><span class="n">${fin.length}</span></div>${fin.map(agRow).join('')}</div>` : '');
}
function agentDetail(a) {
  const notice = a.st === 'wait' ? '<div class="agnote"><i class="dot attn"></i><span>Waiting for you: answer it in the chat</span><button class="lk2 acc" data-act="showreq">Show the Request</button></div>' : '';
  const tail = a.st === 'work' ? '<div class="te tail"><span class="g"><span class="spin">⠋</span></span><div class="x">Running…</div></div>'
    : a.st === 'wait' ? '<div class="te tail wait"><span class="g"><i class="dot attn"></i></span><div class="x">Waiting for you</div></div>' : '';
  return `<div class="agp"><div class="agh"><div class="agh-r"><button class="back" data-act="back" title="Back to the list of agents"><span data-i="chev-l"></span>Agents</button>${pill(a)}</div><h4>${a.type} · ${esc(a.d)}</h4>${notice}</div>
    <div class="tr ${AG.voice}" data-role="tr"><div class="te brief"><span class="g"></span><div class="x"><span class="label">Brief</span><span class="bt">${esc(a.brief)}</span></div></div>${a.items.map(it => entry(it)).join('')}${tail}</div></div>`;
}

/* ============================================================
   The inspector: four view tabs, each at its width. Changes and
   an open transcript take the review width; a pane that would
   keep under 480 beside it gets the inspector drawn over it.
   ============================================================ */
function makeInspector(el, opts) {
  const win = el.closest('.win');
  el.innerHTML = `<div class="itabs">
      <button class="itab" data-t="ov">Overview</button>
      <button class="itab" data-t="ch">Changes <span class="n" data-role="chn"></span></button>
      <button class="itab" data-t="ag">Agents <span class="n" data-role="agn"></span></button>
      <button class="itab" data-t="sd">Side</button></div>
    <div class="ipanel" data-t="ov"></div>
    <div class="ipanel flush" data-t="ch"></div>
    <div class="ipanel flush" data-t="ag"></div>
    <div class="ipanel" data-t="sd"><div class="empty" style="margin-top:56px"><p style="max-width:300px;margin:10px auto 0;font-size:12.5px;line-height:1.5;color:var(--fg-2)">Ask on the side. A side chat is a copy of this session: it sees the session up to now, and the main session never sees it.</p></div>
      <div class="minic" style="margin-top:auto"><div class="ph">Ask on the side</div><div class="bar"><button class="btn gh sm">Close</button><span class="lbl">Opus 5.5</span><span class="sp"></span><span class="lbl">Allow edits<span class="sw"></span></span><button class="ib" data-i="more" style="width:24px;height:24px"></button><button class="send" data-i="up"></button></div></div></div>`;
  const P = t => $(`.ipanel[data-t=${t}]`, el);
  const I = { tab: opts.tab };
  I.changes = makeChanges(P('ch'), opts.changes, { count: n => { $('[data-role=chn]', el).textContent = n || ''; }, send: opts.send, changed: () => placeAll() });
  function overview() {
    const last = opts.changes.scopes.last;
    P('ov').innerHTML = `<div class="isec"><div class="ihead"><span class="label">Session</span></div>
        <dl class="facts"><dt>State</dt><dd>${opts.state()}</dd><dt>Started</dt><dd><span class="m">14:02 today</span></dd><dt>Claude</dt><dd><span data-i="claude"></span><span class="m">Claude Code 2.1.300</span></dd><dt>Model</dt><dd>Opus 5.5 <span class="m">· high</span></dd><dt>Mode</dt><dd style="color:var(--m-abe)"><span data-i="shield"></span>Ask before edits</dd></dl></div>
      <div class="isec"><div class="ihead"><span class="label">Worktree</span></div>
        <dl class="facts"><dt>Project</dt><dd><span class="chip proj" style="--tone:var(--orchid)"><span class="pmark sm">L</span>loom</span></dd><dt>Branch</dt><dd><span class="m">ui/ink-sidebar → main</span></dd><dt>Folder</dt><dd><span class="m">~/…/loom-v2/wt/ink</span></dd></dl></div>
      <div class="isec"><div class="ihead"><span class="label">Changes · last turn</span><button class="lk" data-goto="ch">Open<span data-i="chev-r"></span></button></div>
        ${last.length ? last.map(id => `<div class="mini"><span class="f">${fname(FILES[id].path)}</span>${pm(FILES[id].added, FILES[id].removed)}</div>`).join('') : '<div class="mini"><span class="f" style="color:var(--fg-3)">No file edits yet</span></div>'}</div>
      <div class="isec"><div class="ihead"><span class="label">Agents · ${opts.agents ? AG.list.filter(a => a.st !== 'done').length + ' running' : 'none'}</span><button class="lk" data-goto="ag">Open<span data-i="chev-r"></span></button></div>
        ${opts.agents ? AG.list.filter(a => a.st !== 'done').map(a => `<div class="arow"><span class="ind">${a.st === 'wait' ? '<i class="dot attn"></i>' : '<span class="spin">⠋</span>'}</span><span class="ty">${a.type}</span><span class="de">${esc(a.d)}</span><span class="el">${a.time}</span></div>`).join('') : ''}</div>`;
    iconize(P('ov'));
  }
  function agents() {
    const p = P('ag');
    if (!opts.agents) { p.innerHTML = `<div class="chs"><p class="tnote">${opts.agentsEmpty}</p></div>`; return; }
    const a = AG.open && agent(AG.open);
    p.innerHTML = a ? agentDetail(a) : `<div class="chs">${agentsList()}</div>`;
    iconize(p);
    const tr = $('[data-role=tr]', p); if (tr) tr.scrollTop = tr.scrollHeight;
    $('[data-role=agn]', el).textContent = opts.agents ? AG.list.length : '';
  }
  function width() {
    const reading = I.tab === 'ag' && opts.agents && AG.open;
    const w = I.tab === 'ch' ? 556 : I.tab === 'sd' ? 392 : reading && AG.width === 556 ? 556 : 328;
    const pane = +win.dataset.w - SIDEBAR_W;
    el.style.setProperty('--iw', Math.min(w, pane) + 'px');
    el.classList.toggle('over', pane - w < PANE_MIN);
  }
  function show(tab) {
    I.tab = tab;
    $$('.itab', el).forEach(t => t.classList.toggle('on', t.dataset.t === tab));
    $$('.ipanel', el).forEach(p => p.hidden = p.dataset.t !== tab);
    if (tab === 'ov') overview();
    if (tab === 'ag') agents();
    width();
    placeAll();
  }
  el.addEventListener('click', e => {
    const tab = e.target.closest('.itab'); if (tab) return show(tab.dataset.t);
    const go = e.target.closest('[data-goto]'); if (go) return show(go.dataset.goto);
    const row = e.target.closest('.arow2[data-ag]'); if (row) { AG.open = row.dataset.ag; drawAgents(); return; }
    const act = e.target.closest('[data-act]')?.dataset.act;
    if (act === 'back') { AG.open = null; drawAgents(); }
    if (act === 'showreq') showRequest();
  });
  I.show = show; I.agents = agents; I.width = width; I.overview = overview;
  I.changes.draw();
  $('[data-role=agn]', el).textContent = opts.agents ? AG.list.length : '';
  show(opts.tab);
  return I;
}

/* ---------- section 01: the window after a turn, with comments under way ---------- */
const chatC = $('[data-role=col]', winC), chatC0 = chatC.innerHTML;
const DATA_C = {
  scopes: { last: ['theme', 'row', 'foot', 'tests'], session: ['core', 'theme', 'row', 'foot', 'tests'], branch: ['core', 'theme', 'card', 'row', 'foot', 'tests', 'rename'] },
  sel: { last: 'row' }, hov: 'n20',
  comments: [{ file: 'row', key: 'n22', line: 22, side: 'n', lineText: '        .frame(height: LoomTheme.Sidebar.rowHeight)', text: 'Keep a minimum of 28 here, so a larger text size can still grow the row.' }],
  compose: { scope: 'last', file: 'row', key: 'n18', line: 18, side: 'n', lineText: '            StatusMark(row.indicator)', text: "The spinner is 14 pt in this 12 pt slot. Check that it isn't clipped." }
};
const stC = $('.dhead [data-role=state]', winC);
const setStateC = working => {
  stC.className = working ? 'state' : 'state idle';
  stC.innerHTML = working ? '<span class="spin">⠋</span>Working' : 'Ready';
  $('.tab.on .ind', winC).innerHTML = working ? mark('work') : '';
  const side = $('.side', winC); side.dataset.v = working ? 'working' : 'ready'; drawSidebar(side);
};
function drawCard() {
  const ids = DATA_C.scopes.last, [a, r] = totals(ids);
  const card = $('[data-role=ccard]', winC);
  card.innerHTML = `<div class="ccard-h">${ids.length} files changed${pm(a, r)}<button class="lk2" data-act="changes">Open in Changes<span data-i="chev-r"></span></button></div>`
    + tree(ids).map(g => `<div class="fdir"><span data-i="chev-d"></span>${g.dir}</div>` + g.files.map(id => `<div class="frow"><span class="st">${FILES[id].st}</span>${fname(FILES[id].path)}${pm(FILES[id].added, FILES[id].removed)}</div>`).join('')).join('');
  iconize(card);
}
function wireChatC() {
  drawCard();
  iconize(chatC);
}
const inspC = makeInspector($('.insp', winC), {
  tab: 'ch', changes: DATA_C, agents: false, agentsEmpty: 'Agents show while the session runs.',
  state: () => stC.classList.contains('idle') ? 'Ready' : '<span class="spin">⠋</span>Working',
  send: text => {
    chatC.insertAdjacentHTML('beforeend', `<div class="you sent"><div class="bubble">${esc(text)}</div><div class="you-foot"><span class="tm">14:12</span></div></div><div class="wnow"><span class="spin">⠋</span>Working</div>`);
    setStateC(true);
    const sc = chatC.parentElement; sc.scrollTop = sc.scrollHeight;
  }
});
wireChatC();
winC.addEventListener('click', e => {
  const act = e.target.closest('[data-act]')?.dataset.act;
  if (act === 'changes') { inspC.show('ch'); inspC.changes.setScope('last'); }
  if (act === 'rewind') openSheetOver(winC, 'rewind');
});
$('#chReset').addEventListener('click', () => {
  chatC.innerHTML = chatC0; wireChatC(); setStateC(false); closeSheetOver(winC);
  inspC.changes.reset(); inspC.show('ch');
});
$$('#chWidth button').forEach(b => b.addEventListener('click', () => {
  winC.dataset.w = b.dataset.w; fit(); inspC.width(); requestAnimationFrame(placeAll);
}));

/* ---------- section 03: the second turn, with its subagents ---------- */
const DATA_G = {
  scopes: { last: [], session: DATA_C.scopes.session, branch: DATA_C.scopes.branch },
  sel: {}
};
const inspG = makeInspector($('.insp', winG), {
  tab: 'ag', changes: DATA_G, agents: true,
  state: () => '<i class="dot attn"></i>Needs approval'
});
function drawAgentCard() {
  const box = $('[data-role=agcard]', winG), run = AG.list.filter(a => a.st !== 'done').length;
  const newest = a => { const t = [...a.items].reverse().find(i => i[0] === 't' || i[0] === 'res' || i[0] === 'c'); return t ? (t[0] === 'c' ? `${t[1]}(${t[2]})` : t[1]) : a.d; };
  box.innerHTML = `<div class="agents-h"><span class="wi" data-i="agent"></span>${AG.list.length} agents · ${run} working · ${AG.list.length - run} done</div>`
    + AG.list.map(a => `<div class="acard ${a.st === 'done' ? 'done' : 'work'}" data-open-ag="${a.id}"><span class="ind">${a.st === 'done' ? svg('check') : a.st === 'wait' ? '<i class="dot attn"></i>' : '<span class="spin">⠋</span>'}</span><span class="hd"><span class="ty">${a.type}</span><span class="de">${esc(a.d)}</span></span><span class="el">${a.time}</span>`
      + `<span class="nw${a.st === 'wait' ? ' attn' : ''}">${a.st === 'wait' ? 'Waiting for you: Allow this edit?' : esc(newest(a))}</span>`
      + (a.st !== 'done' ? `<span class="ft"><button class="lk2" data-open-ag="${a.id}">Open in Agents<span data-i="chev-r"></span></button></span>` : '') + '</div>').join('');
  iconize(box);
}
function drawAgents() {
  inspG.agents(); inspG.width(); inspG.overview();
  drawAgentCard();
  drawSidebar($('.side', winG));
  placeAll();
}
winG.addEventListener('click', e => {
  const o = e.target.closest('[data-open-ag]'); if (!o) return;
  AG.open = o.dataset.openAg; inspG.show('ag'); drawAgents();
});
function showRequest() {
  const card = $('[data-role=pinned] .pcard', winG);
  card.classList.remove('flash'); void card.offsetWidth; card.classList.add('flash');
}
// The live explorer: one entry every 2.2 s while the window is on screen.
function stepAgent() {
  const a = agent('contrast');
  if (!a || a.st === 'done') { clearInterval(AG.timer); AG.timer = 0; return; }
  const it = a.live[AG.step++];
  if (!it) return;
  a.items.push(it);
  if (it[0] === 'res') { a.st = 'done'; a.time = a.done; clearInterval(AG.timer); AG.timer = 0; }
  const tr = AG.open === 'contrast' && inspG.tab === 'ag' && $('.ipanel[data-t=ag] [data-role=tr]', winG);
  if (tr && a.st !== 'done') {
    const atEnd = tr.scrollTop + tr.clientHeight >= tr.scrollHeight - 24;
    $('.te.tail', tr).insertAdjacentHTML('beforebegin', entry(it, true));
    if (atEnd) tr.scrollTop = tr.scrollHeight;
    drawAgentCard(); placeAll();
  } else drawAgents();
}
function playAgents() { if (!AG.timer) AG.timer = setInterval(stepAgent, 2200); }
new IntersectionObserver(es => { if (es[0].isIntersecting && agent('contrast').st !== 'done') playAgents(); else if (!es[0].isIntersecting) { clearInterval(AG.timer); AG.timer = 0; } }, { threshold: .3 }).observe(winG);
$('#agReplay').addEventListener('click', () => { resetAgents(); inspG.show('ag'); drawAgents(); playAgents(); });
$$('#agWidth button').forEach(b => b.addEventListener('click', () => { AG.width = +b.dataset.aw; inspG.width(); requestAnimationFrame(placeAll); }));
$$('#agVoice button').forEach(b => b.addEventListener('click', () => {
  AG.voice = b.dataset.voice;
  $$('[data-role=tr]', winG).forEach(tr => { tr.classList.toggle('two', AG.voice === 'two'); tr.classList.toggle('mono', AG.voice === 'mono'); });
  requestAnimationFrame(placeAll);
}));
document.addEventListener('keydown', e => {
  if (e.key !== 'Escape' || e.defaultPrevented || !winG.contains(document.activeElement) && !winG.matches(':hover')) return;
  if (inspG.tab === 'ag' && AG.open) { AG.open = null; drawAgents(); }
});
drawAgents();
if (location.search.includes('agdone')) { const a = agent('contrast'); a.items.push(...a.live); a.st = 'done'; a.time = a.done; drawAgents(); }

/* ============================================================
   The sheets. One template per sheet; the keys follow one rule:
   a filled button is the one Return presses, and only a sheet
   that saves has one.
   ============================================================ */
const ICON128 = '<!--ICON128-->';
const quote = '“Port the sidebar rows to the Ink tokens: one status column, 28 pt rows, the project as its mark.”';
const SHEETS = {
  rename: { save: true, html: () => `<h4>Rename session</h4>
      <div class="field focus"><input value="Port the sidebar to Ink tokens" aria-label="Session title" maxlength="400"></div>
      <div class="cnt"><span class="n" data-role="n">30/160</span><span>Longer titles are shortened. An empty title returns to the automatic one.</span></div>
      <div class="sbtn"><span class="grow"></span><button class="btn sec" data-k="cancel">Cancel</button><button class="btn pri" data-k="save">Save</button></div>` },
  'delete-ready': { html: () => `<h4>Delete this session?</h4><div class="sn">Port the sidebar to Ink tokens</div>
      <p>Sphyrna removes it and its 2 side chats from Sphyrna, and deletes Claude's local files for them. This can't be undone.</p>
      <div class="sl"><span class="label">Removed</span><ul><li>The transcript and the subagent transcripts</li><li>File snapshots and session folders</li></ul><p class="m" style="margin:5px 0 0 13px">214 files · 18.2 MB · in ~/.claude</p></div>
      <div class="sl"><span class="label">Kept</span><ul><li>Your prompts in Claude's shared prompt history</li><li>Project files and worktrees</li><li>Anything already sent to Anthropic</li></ul></div>
      <div class="sbtn"><span class="grow"></span><button class="btn sec focus" data-k="cancel">Cancel</button><button class="btn dtint" data-k="delete">Delete Permanently</button></div>` },
  'delete-check': { html: () => `<h4>Delete this session?</h4><div class="sn">Port the sidebar to Ink tokens</div>
      <div class="busy"><span class="spin">⠋</span>Checking what Claude has kept for this session…</div>
      <div class="sbtn"><span class="grow"></span><button class="btn sec focus" data-k="cancel">Cancel</button><button class="btn dtint" disabled>Delete Permanently</button></div>` },
  'delete-blocked': { html: () => `<h4>Delete this session?</h4><div class="sn">Rate limiter tests</div>
      <p>Sphyrna removes it from Sphyrna, and deletes Claude's local files for it. This can't be undone.</p>
      <div class="sl"><span class="label">Removed</span><ul><li>The transcript and the subagent transcripts</li><li>File snapshots and session folders</li></ul><p class="m" style="margin:5px 0 0 13px">38 files · 2.4 MB · in ~/.claude</p></div>
      <div class="sl"><span class="label">Kept</span><ul><li>Your prompts in Claude's shared prompt history</li><li>Project files and worktrees</li><li>Anything already sent to Anthropic</li></ul></div>
      <p class="bad">Deleting cannot finish: Sphyrna cannot look inside ~/claude-work (it is a link or on another disk), so it cannot tell whether Claude keeps files for this session there. Nothing was removed. You can remove the session from Sphyrna only; Claude's files stay where they are.</p>
      <div class="sbtn"><button class="btn sec" data-k="only" title="Removes the session from Sphyrna. Claude's files are not touched.">Remove from Sphyrna Only</button><span class="grow"></span><button class="btn sec focus" data-k="cancel">Cancel</button><button class="btn dtint" disabled>Delete Permanently</button></div>` },
  remove: { alert: true, html: () => `<img class="ai" src="${ICON128}" alt="">
      <h4>Remove this session from Sphyrna?</h4>
      <p>Sphyrna forgets the session and its own data for it. Claude's files stay where they are, and Sphyrna can't bring the session back.</p>
      <div class="sbtn"><button class="btn sec focus" data-k="cancel">Cancel</button><button class="btn dtint" data-k="remove">Remove</button></div>` },
  discard: { html: () => `<h4>Discard this side chat?</h4><div class="sn">Will the project's mark still read in Paper?</div>
      <p>Sphyrna deletes its copy of the session. The main session is not touched.</p>
      <div class="sbtn"><span class="grow"></span><button class="btn sec focus" data-k="cancel">Cancel</button><button class="btn dtint" data-k="discard">Discard</button></div>` },
  rewind: { w480: true, html: () => { const ids = DATA_C.scopes.last, [a, r] = totals(ids); return `<h4>Rewind files to before this message?</h4><div class="sn">${quote}</div>
      <div class="rtot"><span>${ids.length} files</span>${pm(a, r)}</div>
      <div class="rlist">${ids.map(id => FILES[id].path).sort().map(p => `<div class="rrow">${p}${p.endsWith('SidebarRow.swift') ? '<span class="mk">Changed since Claude\'s last edit</span>' : ''}</div>`).join('')}</div>
      <p class="hon">Restores the files Claude changed with its file tools to how they were before this message. Changes made by shell commands and subagents stay. Sphyrna keeps a copy of these files, so you can undo this.</p>
      <p class="warn">This turn's file changes can only come back through Undo.</p>
      <div class="sbtn"><span class="grow"></span><button class="btn sec focus" data-k="cancel">Cancel</button><button class="btn atint" data-k="rewind">Rewind Files</button></div>`; } },
  'rewind-cannot': { w480: true, html: () => `<h4>Rewind files to before this message?</h4><div class="sn">“Run the whole UI suite and list the three slowest tests.”</div>
      <p class="bad">No file checkpoint for this message</p>
      <div class="sbtn"><span class="grow"></span><button class="btn sec focus" data-k="cancel">Cancel</button></div>` },
  'rewind-copy': { w480: true, html: () => `<h4>Rewind files to before this message?</h4><div class="sn">“Regenerate the large transcript fixture.”</div>
      <div class="rtot"><span>1 file</span>${pm(41022, 39870)}</div>
      <div class="rlist"><div class="rrow">Tests/Fixtures/transcript-large.jsonl</div></div>
      <p class="bad">These files are too large to keep a copy for Undo</p>
      <div class="sbtn"><span class="grow"></span><button class="btn sec focus" data-k="cancel">Cancel</button><button class="btn atint" disabled>Rewind Files</button></div>` }
};
const KEYNAME = { cancel: 'Cancel', save: 'Save', delete: 'Delete Permanently', only: 'Remove from Sphyrna Only', remove: 'Remove', discard: 'Discard', rewind: 'Rewind Files' };
function drawSheet(el, kind, log, done) {
  const def = SHEETS[kind];
  el.className = 'sheet' + (def.alert ? ' alert' : '') + (def.w480 ? ' w480' : '') + (el.classList.contains('at') ? ' at' : '');
  el.innerHTML = def.html(); el.tabIndex = -1;
  iconize(el);
  const first = () => def.save ? $('input', el) : $('[data-k=cancel]', el);
  const say = html => { if (!log) return; log.innerHTML = html; log.classList.remove('flash'); void log.offsetWidth; log.classList.add('flash'); };
  let via = '';
  const press = k => { say(`${via ? `<b>${via}</b> → ` : ''}<b>${KEYNAME[k] || k}</b> ${k === 'cancel' ? '· the sheet closes' : k === 'save' ? '· the title is saved' : '· pressed'}`); via = ''; done && done(k); };
  const ring = () => { $$('.btn', el).forEach(b => b.classList.toggle('focus', b === document.activeElement)); if (!el.contains(document.activeElement) && !def.save) first()?.classList.add('focus'); };
  el.addEventListener('focusin', ring);
  el.addEventListener('focusout', () => requestAnimationFrame(ring));
  el.addEventListener('pointerdown', e => { if (!e.target.closest('button,input')) { e.preventDefault(); first()?.focus(); } });
  el.addEventListener('click', e => { const b = e.target.closest('[data-k]'); if (b && !b.disabled) press(b.dataset.k); });
  el.addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.isComposing) {
      e.preventDefault();
      if (def.save) { via = 'Return'; press('save'); }
      else say('<b>Return</b> · nothing happens: no button is filled');
    } else if (e.key === 'Escape') { e.preventDefault(); via = 'Esc'; press('cancel'); }
    else if (e.key === ' ' && document.activeElement?.matches('.btn')) via = 'Space';
    else if (e.key === 'Tab') requestAnimationFrame(() => { const b = document.activeElement; if (el.contains(b) && b.matches('.btn')) say(`<b>Tab</b> → the focus moves to ${b.textContent}`); });
  });
  const input = $('input', el);
  if (input) input.addEventListener('input', () => { const n = input.value.length, c = $('[data-role=n]', el); c.textContent = `${n}/160`; c.classList.toggle('over', n > 160); });
  ring();
}
$$('.parts .sheet[data-sheet]').forEach(el => drawSheet(el, el.dataset.sheet, $(`[data-log="${el.dataset.sheet}"]`)));
drawSheet($('.sheet[data-sheet]', winS), 'delete-ready');
// A sheet over a live window: the Rewind link in section 01's chat opens it.
function openSheetOver(win, kind) {
  closeSheetOver(win);
  win.insertAdjacentHTML('beforeend', '<div class="scrim" data-role="scrim"></div><div class="sheet at" data-role="sheet"></div>');
  const el = $('[data-role=sheet]', win);
  drawSheet(el, kind, null, k => {
    if (k === 'rewind') {
      chatC.insertAdjacentHTML('beforeend', '<div class="marker">Files rewound to before “Port the sidebar rows to the…” · 14:12 <button class="lk2" data-act="undo">Undo</button></div>');
      const sc = chatC.parentElement; sc.scrollTop = sc.scrollHeight;
    }
    closeSheetOver(win);
  });
  $('[data-k=cancel]', el).focus();
}
function closeSheetOver(win) { $$('[data-role=scrim],[data-role=sheet]', win).forEach(n => n.remove()); }
winC.addEventListener('click', e => { if (e.target.closest('[data-act=undo]')) { const m = e.target.closest('.marker'); m.innerHTML = 'Rewind undone'; } });

/* ============================================================
   Pins: each sits on the inspector's left edge beside what it
   names, or beside the sheet's part. A pin whose part is not on
   screen hides.
   ============================================================ */
function pinTo(win, id, target, fx, fy, dx, dy) {
  const pin = $('#' + id); if (!pin) return;
  const ok = target && target.getClientRects().length;
  pin.style.visibility = ok ? '' : 'hidden';
  if (!ok) return;
  const wr = win.getBoundingClientRect(), s = wr.width / win.offsetWidth || 1, r = target.getBoundingClientRect();
  pin.style.left = Math.round((r.left - wr.left) / s + (r.width / s) * fx + dx) + 'px';
  pin.style.top = Math.round((r.top - wr.top) / s + (r.height / s) * fy + dy) + 'px';
}
function edgePin(win, id, insp, target) {
  const pin = $('#' + id); if (!pin) return;
  let ok = target && target.getClientRects().length && insp.getClientRects().length;
  if (ok) {
    const wr = win.getBoundingClientRect(), s = wr.width / win.offsetWidth || 1, r = target.getBoundingClientRect(), ir = insp.getBoundingClientRect();
    const top = (r.top - wr.top) / s + Math.min(r.height / s, 40) / 2 - 9;
    ok = top > (ir.top - wr.top) / s - 4 && top < (ir.bottom - wr.top) / s - 18;
    pin.style.left = Math.round((ir.left - wr.left) / s - 13) + 'px';
    pin.style.top = Math.round(top) + 'px';
  }
  pin.style.visibility = ok ? '' : 'hidden';
}
function placeAll() {
  if (!document.body.classList.contains('pins')) return;
  const ic = $('.insp', winC), ch = $('.ipanel[data-t=ch]', ic), ig = $('.insp', winG), ag = $('.ipanel[data-t=ag]', ig), sh = $('.sheet', winS);
  if (!ch || !ag || !sh) return;
  const chOn = !ch.hidden, agOn = !ag.hidden;
  edgePin(winC, 'pinC1', ic, chOn && $('.itabs', ic));
  edgePin(winC, 'pinC2', ic, chOn && $('[data-role=scope]', ch));
  edgePin(winC, 'pinC3', ic, chOn && $('.files', ch));
  edgePin(winC, 'pinC4', ic, chOn && $('.diff-h', ch));
  edgePin(winC, 'pinC5', ic, chOn && $('.dl.hov', ch));
  edgePin(winC, 'pinC6', ic, chOn && $('[data-role=compose]', ch));
  edgePin(winC, 'pinC7', ic, chOn && $('[data-role=saved]', ch));
  edgePin(winC, 'pinC8', ic, chOn && !$('[data-role=foot]', ch).hidden && $('[data-role=foot]', ch));
  edgePin(winG, 'pinA1', ig, agOn && $('.agh', ag));
  edgePin(winG, 'pinA2', ig, agOn && $('.te.brief', ag));
  edgePin(winG, 'pinA3', ig, agOn && $('.te.t:not(.res)', ag));
  edgePin(winG, 'pinA4', ig, agOn && $('.te.c', ag));
  edgePin(winG, 'pinA5', ig, agOn && $('.te.k', ag));
  edgePin(winG, 'pinA6', ig, agOn && ($('.te.tail', ag) || $('.te.res', ag)));
  edgePin(winG, 'pinA7', ig, agOn && $('.agsec', ag));
  edgePin(winG, 'pinA8', ig, agOn && $('.arow2 .nt.attn', ag)?.closest('.arow2'));
  pinTo(winS, 'pinS1', sh, 0, 0, -12, -10);
  pinTo(winS, 'pinS2', $('h4', sh), 0, .5, -48, -9);
  pinTo(winS, 'pinS3', $('.sl', sh), 0, 0, -48, -2);
  pinTo(winS, 'pinS4', $('[data-k=cancel]', sh), .5, 1, -11, 7);
  pinTo(winS, 'pinS5', $('[data-k=delete]', sh), .5, 1, -11, 7);
}
addEventListener('resize', () => requestAnimationFrame(placeAll));
document.addEventListener('scroll', e => { if (e.target instanceof Element && e.target.closest('.win')) placeAll(); }, true);
$('#swPins').parentElement.addEventListener('click', () => requestAnimationFrame(placeAll));
new ResizeObserver(() => requestAnimationFrame(placeAll)).observe(document.body);
if (location.search.includes('pins')) { $('#swPins').classList.add('on'); document.body.classList.add('pins'); }

let waitT = 1; setInterval(() => { if (document.hidden) return; waitT = waitT % 9 + 1; const c = $('[data-role=waitclock]'); if (c) c.textContent = waitT; }, 1000);
requestAnimationFrame(placeAll);
