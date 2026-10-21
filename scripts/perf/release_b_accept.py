#!/usr/bin/env python3
"""Release B acceptance, app level (checks 9 to 13), on a package, with a real Claude (Haiku) under the isolated profile.
REAL MODEL TURNS (about 7 in all, see each check). HEAVY-ish: opens the app window, waits up to 90 s for the terminal's
idle reminder. Run it inside the build slot and only when the Mac may show the Loom window:
  LOOM_SLOT_TIMEOUT=21600 scripts/with-build-slot.sh scripts/perf/release_b_accept.py --app <package>.app --check b9b10
Checks (one app instance each; the instance is quit however the script ends, and its folder is deleted by nobody):
  b9b10  chat start from the draft, one turn, Stop, a send resumes in Chat (9); Continue in Terminal, the transcript
         holds the whole turn, the terminal remembers it (10).                          3 turns
  b11    a terminal turn, wait for the idle reminder, Stop, Resume in Chat; the stream shows the turn once (11).  1 turn
  b12    Chat, /clear, a send on the new card, Quit: the app exits and leaves no owned process (12).   1 turn
  b13    window-only shots: Ask with a refusal, and a real approval card (13).                          2 turns
Only counts, kinds, booleans and file shapes are recorded: no prompt text, answer text or account data. Window shots are
window-only (`screencapture -l`). Output: <out>/<check>/{evidence,data}/ (app state), <out>/<check>.json (results) and
<out>/shots/*.png."""
import argparse, atexit, json, os, pathlib, re, signal, subprocess, sys, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import perf_paths
from perf_paths import REPO as ROOT, load_module as module

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--app', type=pathlib.Path, required=True, help='the package under Loom-Dev/packages/<name>')
parser.add_argument('--check', choices=['dry', 'b9b10', 'b11', 'b12', 'b13'], required=True)
parser.add_argument('--out', type=pathlib.Path,
                    default=pathlib.Path.home() / 'Library/Caches/loom-v2/evidence/release-b-accept')
parser.add_argument('--idle-wait', type=float, default=75, help='seconds to wait after the terminal turn (b11)')
args = parser.parse_args()
app = perf_paths.refuse_documents('App path', args.app)
if app.resolve() == perf_paths.DEFAULT_APP.resolve():
    sys.exit('refusing the installed dev app')
if 'Loom-Dev/packages/' not in str(app):
    sys.exit('the app must be a package under Loom-Dev/packages/')
OUT = perf_paths.refuse_documents('Out', args.out)
CONFIG = perf_paths.PROBE / 'claude-config'
measure = module('measure', ROOT / 'scripts/cp5-d-measure.py')
own = module('own', ROOT / 'scripts/cp5-own-native.py')

stamp = time.strftime('%Y%m%dT%H%M%S')
base = OUT / 'runs' / f'{args.check}-{stamp}'
evidence, data = base / 'evidence', base / 'data'
evidence.mkdir(parents=True); data.mkdir()
(OUT / 'shots').mkdir(exist_ok=True)
TOKENS = ['Try', 'esc to interrupt', 'LOOM_ACC_B11', 'ZEBRAKIWI']
results = {'check': args.check, 'steps': [], 'modelTurns': 0, 'passed': {}}
app_pid = None
quit_done = False


def step(text):
    line = f'[{args.check}] {text}'
    print(line, flush=True)
    results['steps'].append(text)


def verdict(name, ok, detail=None):
    results['passed'][name] = {'pass': bool(ok), 'detail': detail}
    step(f'RESULT {name}: {"pass" if ok else "FAIL"}' + (f' ({detail})' if detail is not None else ''))


def turn(purpose):
    results['modelTurns'] += 1
    step(f'model turn {results["modelTurns"]} of this run: {purpose}')


def write_results():
    (OUT / f'{args.check}-{stamp}.json').write_text(json.dumps(results, indent=1, default=str))


# ---- app control ------------------------------------------------------------------------------------------------
def cmd(text):
    measure.send(text, evidence)


def fresh(command, filename, timeout=25):
    p = evidence / filename; p.unlink(missing_ok=True)
    cmd(command)
    return measure.wait_json(p, timeout)


def snap(label='s'):
    return fresh('snapshot:' + label, f'state-{label}.json', 20)


def catalog(label='s'):
    return snap(label)['catalog']


def chat_state(label='cs'):
    return fresh(f'chat-state:{label}', f'chat-state-{label}.json')


def chat_view(session, label='cv'):
    return fresh(f'chat-view:{session}:{label}', f'chat-view-{label}.json')


def until(predicate, timeout, what, step_s=1.0):
    end = time.monotonic() + timeout; last = None
    while time.monotonic() < end:
        try:
            last = predicate()
        except (TimeoutError, ValueError, KeyError):
            last = None
        if last:
            return last
        time.sleep(step_s)
    raise RuntimeError('timeout: ' + what)


def front():
    subprocess.run(['osascript', '-e', f'tell application "System Events" to set frontmost of (first process whose unix id is {app_pid}) to true'],
                   capture_output=True, timeout=15)
    time.sleep(.8)


def window_id():
    js = ("ObjC.import('CoreGraphics'); var l = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0)));"
          f"JSON.stringify(l.filter(function(w){{return w.kCGWindowOwnerPID=={app_pid} && w.kCGWindowLayer==0}})"
          ".map(function(w){return {id:w.kCGWindowNumber,w:w.kCGWindowBounds.Width,h:w.kCGWindowBounds.Height}}))")
    out = subprocess.run(['osascript', '-l', 'JavaScript', '-e', js], capture_output=True, text=True, timeout=20).stdout
    windows = json.loads(out or '[]')
    return max(windows, key=lambda w: w['w'] * w['h'])['id'] if windows else None


PNG_TOOL = pathlib.Path.home() / 'Library/Caches/loom-v2/build/acc-tools/png_redact'


def png_tool():
    if not PNG_TOOL.exists():
        PNG_TOOL.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['swiftc', '-O', '-o', str(PNG_TOOL), str(pathlib.Path(__file__).resolve().parent / 'png_redact.swift')],
                       check=True, timeout=300)
    return str(PNG_TOOL)


def shot(name, terminal=False):
    """Window-only capture of the app's main window. The sidebar footer (usage figures) is cut off; on a terminal face the
    CLI's banner (it names the plan) is painted over. Nothing else of the screen is in the file."""
    front()
    wid = window_id()
    path = OUT / 'shots' / f'{name}.png'
    if wid is None:
        step(f'shot {name}: no window found'); return None
    subprocess.run(['screencapture', '-x', '-o', '-l', str(wid), str(path)], check=False, timeout=30)
    if path.exists():
        rects = ['800', '70', '1640', '150'] if terminal else []
        subprocess.run([png_tool(), str(path), '95'] + rects, check=False, timeout=60)
    ok = path.exists() and path.stat().st_size > 5000
    step(f'shot {name}: {"saved" if ok else "FAILED"} ({path.stat().st_size if path.exists() else 0} bytes)')
    return path if ok else None


def launch(project_name):
    global app_pid
    if subprocess.run(['pgrep', '-f', str(app / 'Contents/MacOS/Loom Dev')], stdout=subprocess.DEVNULL).returncode == 0:
        sys.exit('this package is already running')
    perf_paths.seed_remora_off(data)
    subprocess.run(['open', '-n', '-a', str(app), '--args', '--evidence', str(evidence), '--data-root', str(data),
                    '--claude-config', str(CONFIG), '--codex-home', str(pathlib.Path.home() / '.loom-dev/codex-home'),
                    '--evidence-tokens', ','.join(TOKENS)], check=True)
    app_pid = measure.wait_json(evidence / 'launched.json', 40)['pid']
    until(lambda: (lambda c: c['ready'] and c['actionsAvailable'])(catalog('ready')), 60, 'app ready')
    cmd('view-mode:activity')
    work = perf_paths.real_work_dir(CONFIG, 'acc', project_name)
    cmd('add-project:' + str(work))
    project = until(lambda: (catalog('project')['projects'] or [None])[0], 30, 'project added')
    step(f'app launched (pid recorded), project added ({work.name})')
    return work, project['id']


def quit_app(wait=60):
    """Normal Quit through the command channel; waits for the exit; returns (exited, seconds)."""
    global quit_done
    if not app_pid or quit_done:
        return None, 0.0
    started = time.monotonic()
    try:
        cmd('quit')
    except Exception as error:  # the channel is gone with the app
        step(f'quit command failed: {type(error).__name__}')
    exited = own.wait_until(lambda: measure.identity(app_pid) is None, wait)
    quit_done = bool(exited)
    return bool(exited), time.monotonic() - started


def safety_net():
    """The EXIT trap: quit the app however the script ends, wait for it, kill that pid only if it is still there."""
    global quit_done
    if app_pid and not quit_done:
        try:
            cmd('quit')
        except Exception:
            pass
        if not own.wait_until(lambda: measure.identity(app_pid) is None, 12):
            step('app still alive 12 s after quit: killing its pid')
            try: os.kill(app_pid, signal.SIGKILL)
            except OSError: pass
            own.wait_until(lambda: measure.identity(app_pid) is None, 10)
        quit_done = True
    try: write_results()
    except Exception: pass


atexit.register(safety_net)
for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(_sig, lambda *_: sys.exit(130))


# ---- transcripts ------------------------------------------------------------------------------------------------
def transcript_path(conversation):
    found = list((CONFIG / 'projects').glob(f'*/{conversation}.jsonl'))
    return found[0] if found else None


def records(conversation):
    path = transcript_path(conversation)
    if not path:
        return []
    out = []
    for line in path.read_text(errors='replace').splitlines():
        try: out.append(json.loads(line))
        except ValueError: pass
    return out


def text_of(record):
    content = record.get('message', {}).get('content')
    if isinstance(content, str): return content
    if isinstance(content, list):
        return ' '.join(x.get('text', '') for x in content if isinstance(x, dict) and x.get('type') == 'text')
    return ''


def prompts(conversation):
    """Real prompts: user records whose content is text and not a tool result or a meta record."""
    out = []
    for r in records(conversation):
        if r.get('type') != 'user' or r.get('isMeta') or r.get('isSidechain'): continue
        content = r.get('message', {}).get('content')
        if isinstance(content, str) or (isinstance(content, list) and any(x.get('type') == 'text' for x in content if isinstance(x, dict))):
            out.append(r)
    for r in records(conversation):
        a = r.get('attachment')
        if isinstance(a, dict) and a.get('type') == 'queued_command' and a.get('commandMode') == 'prompt':
            out.append(r)
    return out


def assistant_texts(conversation):
    return [text_of(r) for r in records(conversation) if r.get('type') == 'assistant']


def integrity(conversation):
    """The transcript on disk: every line parses, the last record is whole, every tool_use has its tool_result."""
    path = transcript_path(conversation)
    if not path:
        return {'file': False}
    raw = path.read_text(errors='replace')
    lines = [l for l in raw.split('\n') if l]
    parsed, bad = [], 0
    for l in lines:
        try: parsed.append(json.loads(l))
        except ValueError: bad += 1
    uses, results_ = set(), set()
    kinds = {}
    for r in parsed:
        kinds[r.get('type', '?')] = kinds.get(r.get('type', '?'), 0) + 1
        content = r.get('message', {}).get('content')
        if isinstance(content, list):
            for x in content:
                if isinstance(x, dict) and x.get('type') == 'tool_use': uses.add(x.get('id'))
                if isinstance(x, dict) and x.get('type') == 'tool_result': results_.add(x.get('tool_use_id'))
    last = parsed[-1] if parsed else {}
    return {'file': True, 'lines': len(lines), 'unparsable': bad, 'endsWithNewline': raw.endswith('\n'),
            'lastRecordType': last.get('type'), 'lastRecordKeys': sorted(last.keys())[:12], 'recordKinds': kinds,
            'toolUses': len(uses), 'toolResultsForThem': len(uses & results_), 'toolUsesWithoutResult': len(uses - results_)}


def session_row(session):
    rows = catalog('rows')['activityRowDetails']
    return next((r for r in rows if r['id'] == session), None)


def conversation_from_catalog(session):
    """The provider conversation id the catalog has for a card (read-only; the sidebar's row details are empty in the projects view)."""
    import sqlite3
    path = data / 'catalog.sqlite3'
    if not path.exists():
        return None
    try:
        db = sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=5)
        try:
            row = db.execute('SELECT provider_conversation_id FROM sessions WHERE upper(id) = upper(?)', (session,)).fetchone()
        finally:
            db.close()
    except sqlite3.Error:
        return None
    return row[0] if row and row[0] else None


def conversation_of(session):
    row = session_row(session)
    return (row or {}).get('conversationID') or conversation_from_catalog(session) or session


def new_session_id(before_ids):
    """A session the catalog did not know before: active ones first, then the selected one."""
    c = catalog('new')
    ids = [i for i in c.get('activeSessionIDs', []) if i not in before_ids]
    if not ids and c.get('selectedSessionID') and c['selectedSessionID'] not in before_ids:
        ids = [c['selectedSessionID']]
    return ids[0] if ids else None


def known_ids():
    c = catalog('known')
    return set(c.get('activeSessionIDs', [])) | {r['id'] for r in c.get('activityRowDetails', [])} | (
        {c['selectedSessionID']} if c.get('selectedSessionID') else set())


def leftover_processes(before_claude):
    """Run hosts of this package and Claude children that carry the probe profile, left after the app exited."""
    hosts = measure.host_pids(app)
    claude = []
    for pid in own.pids():
        if pid <= 0 or pid in before_claude: continue
        path = own.path(pid)
        if path.endswith('/claude') or '/claude/' in path:
            env = subprocess.run(['ps', 'eww', '-o', 'command=', '-p', str(pid)], capture_output=True, text=True).stdout
            if f'CLAUDE_CONFIG_DIR={CONFIG}' in env:
                claude.append(pid)
    return hosts, claude


def claude_pids_now():
    return {pid for pid in own.pids() if pid > 0 and (own.path(pid).endswith('/claude') or '/claude/' in own.path(pid))}


def chat_idle(label='idle'):
    s = chat_state(label)
    return s if s.get('driver') and s.get('phase') == 'ready' and not s.get('turnRunning') else None


# ---- the checks -------------------------------------------------------------------------------------------------
def check_dry():
    """No model turn: launch, open a draft, one window shot, Quit. Proves the harness plumbing."""
    work, project = launch('app-dry')
    cmd(f'new-session:{project}')
    cmd(f'draft-text:{project}:a draft that is never sent')
    time.sleep(1.5)
    front()
    c = catalog('dry')
    step(f'route {c.get("route")}, view-mode {c.get("viewMode")}, window key/visible: {c.get("windowIsActive")}/{c.get("windowIsVisible")}')
    shot('dry-draft')
    cmd(f'draft-discard:{project}')
    exited, seconds = quit_app(60)
    verdict('dry.quit', exited is True, {'seconds': round(seconds, 1)})


def check_b9b10():
    work, project = launch('app-b9')
    (work / 'notes.txt').write_text('codeword: ZEBRAKIWI\n')
    ids_before = known_ids()
    # 9. The draft in Chat (the default face).
    cmd(f'new-session:{project}')
    cmd(f'draft-text:{project}:Use the Read tool on notes.txt and tell me the codeword it holds, in one word.')
    time.sleep(1.5)
    c = catalog('draft')
    verdict('b9.draftOpened', c.get('route') in ('draft', 'newSession') or bool(c.get('drafts')), {'route': c.get('route'), 'drafts': c.get('drafts'), 'newSessionFace': c.get('newSessionFace')})
    front()
    turn('B9 first turn from the draft (Read)')
    cmd('key:return')
    session = until(lambda: new_session_id(ids_before), 90, 'new session row')
    step('session created from the draft')
    cmd(f'select:{session}')
    until(lambda: chat_idle('first') if (chat_state('first').get('sessionID') == session) else None, 150, 'first turn finished')
    s = chat_state('first')
    verdict('b9.startedInChat', s.get('driver') is True and s.get('route') in ('chat', 'liveChat', None) or s.get('driver') is True,
            {'route': s.get('route'), 'turns': s.get('turns'), 'phase': s.get('phase'), 'permissionMode': s.get('permissionMode')})
    owner = catalog('owner').get('owningFaces')
    step(f'owning faces after start: {owner if not isinstance(owner, dict) else {k[:8]: v for k, v in owner.items()}}')
    conv = conversation_of(session)
    tr = integrity(conv)
    verdict('b9.firstTurnInTranscript', tr.get('file') and tr.get('toolUses', 0) >= 1 and tr.get('toolUsesWithoutResult') == 0 and any('ZEBRAKIWI' in t for t in assistant_texts(conv)), tr)
    shot('b9-chat-first-turn')
    # Stop, then type in the stopped composer and send.
    cmd(f'chat-stop:{session}')
    until(lambda: (lambda st: st if st.get('phase') == 'stopped' else None)(chat_state('stopped')), 60, 'stopped')
    verdict('b9.stopped', True, {'phase': chat_state('stopped2').get('phase')})
    turn('B9 send from the stopped composer (resume)')
    cmd(f'composer-focus:{session}')
    cmd(f'composer-type:{session}:Reply with the single word: resumed')
    time.sleep(1)
    front()
    cmd('key:return')
    def resumed():
        st = chat_state('resume')
        return st if st.get('driver') and st.get('phase') in ('ready',) and len(st.get('turns') or []) >= 2 and not st.get('turnRunning') else None
    try:
        until(resumed, 150, 'resumed turn finished')
        ok = True
    except RuntimeError:
        ok = False
    st = chat_state('resume-final')
    verdict('b9.resumeInChat', ok and st.get('turns', [])[-1:] == ['succeeded'], {'turns': st.get('turns'), 'phase': st.get('phase'), 'route': st.get('route')})
    files = list((CONFIG / 'projects').glob(f'*/{conv}.jsonl'))
    pr = prompts(conv)
    verdict('b9.sameTranscript', len(files) == 1 and len(pr) >= 2, {'files': len(files), 'prompts': len(pr)})
    shot('b9-chat-resumed')
    # 10. Chat to Terminal.
    cmd(f'continue-in:{session}:terminal')
    try:
        s2 = until(lambda: (lambda x: x if any(t.get('owner') == session for t in x.get('conversationTerminals', [])) else None)(snap('toterm')), 120, 'terminal attached')
        cat = s2['catalog']
        verdict('b10.handedToTerminal', True, {'owningFaces': cat.get('owningFaces') if not isinstance(cat.get('owningFaces'), dict) else {k[:8]: v for k, v in cat['owningFaces'].items()}, 'handovers': cat.get('handovers'), 'route': cat.get('route')})
    except RuntimeError:
        verdict('b10.handedToTerminal', False, {'handovers': catalog('toterm-fail').get('handovers')})
        return
    time.sleep(8)
    tr = integrity(conv)
    complete = (tr.get('file') and tr.get('unparsable') == 0 and tr.get('endsWithNewline') and tr.get('toolUsesWithoutResult') == 0
                and tr.get('toolUses', 0) >= 1)
    verdict('b10.transcriptWhole', complete and any('ZEBRAKIWI' in t for t in assistant_texts(conv)) and len(prompts(conv)) >= 2, tr)
    shot('b10-terminal-after-handover', terminal=True)
    cmd(f'select:{session}')
    turn('B10 ask the terminal about the earlier turn')
    question = 'In one word, which codeword did notes.txt hold when you read it earlier in this session?'
    seen_before = len(assistant_texts(conv))
    cmd(f'type:{session}:{question}'); time.sleep(1.5)
    for attempt in range(3):
        cmd(f'type:{session}:')
        if own.wait_until(lambda: any(question[:30] in text_of(r) for r in records(conv) if r.get('type') == 'user'), 10): break
    submitted = any(question[:30] in text_of(r) for r in records(conv) if r.get('type') == 'user')
    remembered = own.wait_until(lambda: any('ZEBRAKIWI' in t for t in assistant_texts(conv)[seen_before:]), 120)
    verdict('b10.terminalRemembers', submitted and bool(remembered), {'submitted': submitted, 'answerNamesTheCodeword': bool(remembered)})
    shot('b10-terminal-answer', terminal=True)


def check_b11():
    work, project = launch('app-b11')
    before = known_ids()
    cmd('live-chat:off')
    cmd(f'start:claude:{project}')
    session = until(lambda: new_session_id(before), 120, 'terminal session row')
    cmd(f'select:{session}')
    def term(s): return next((t for t in s.get('conversationTerminals', []) if t.get('owner') == session), None)
    until(lambda: (lambda s: (term(s) or {}).get('tokenPresence', {}).get('Try') is True)(snap('tui')), 120, 'TUI ready')
    time.sleep(2)
    cmd('live-chat:on')
    turn('B11 terminal turn')
    prompt = 'Reply with exactly the single word LOOM_ACC_B11 and nothing else'
    cmd(f'type:{session}:{prompt}'); time.sleep(1.5)
    for attempt in range(3):
        cmd(f'type:{session}:')
        if own.wait_until(lambda: any(prompt[:30] in text_of(r) for r in records(session) if r.get('type') == 'user'), 8): break
    done = own.wait_until(lambda: any('LOOM_ACC_B11' in t for t in assistant_texts(session)), 120)
    verdict('b11.terminalTurn', bool(done))
    replied = time.monotonic()
    indicators = []
    while time.monotonic() - replied < args.idle_wait:
        ind = catalog('idle').get('selectedIndicator')
        if not indicators or indicators[-1][1] != ind:
            indicators.append((round(time.monotonic() - replied), ind))
        time.sleep(2)
    step(f'indicator over the idle wait (seconds after the reply, label): {indicators}')
    shot('b11-terminal-idle', terminal=True)
    # The terminal-to-Chat move is gone (D-3): the session stops in the terminal and resumes in Chat, as the switch says.
    cmd(f'stop:{session}')
    until(lambda: None if term(snap('stopping')) else True, 60, 'terminal run stopped')
    cmd(f'resume:{session}')
    try:
        until(lambda: (lambda c, st: c if c.get('route') == 'chat' and st.get('driver') and st.get('sessionID') == session else None)(catalog('tochat'), chat_state('tochat')), 120, 'chat owns the session')
        resumed = True
    except RuntimeError:
        resumed = False
    c = catalog('tochat-final')
    verdict('b11.resumedInChat', resumed, {'route': c.get('route'), 'owningFaces': c.get('owningFaces'), 'errorMessage': c.get('errorMessage'), 'infoMessage': c.get('infoMessage')})
    if not resumed:
        return
    until(lambda: chat_state('c1').get('driver') and chat_state('c1').get('phase') == 'ready' or None, 120, 'chat ready')
    view = until(lambda: (lambda v: v if v.get('attached') and v.get('phase') == 'ready' else None)(chat_view(session, 'join')), 60, 'chat view attached')
    time.sleep(3)
    view = chat_view(session, 'join2')
    kinds = view.get('rowKinds') or {}
    pr = prompts(session)
    answers = [t for t in assistant_texts(session) if t.strip()]
    step(f'stream rows by kind: {kinds}; unique ids {view.get("uniqueRowIDs")}; entries {view.get("entries")}; transcript prompts {len(pr)}, assistant texts {len(answers)}')
    once = (kinds.get('user', 0) == len(pr) and kinds.get('user', 0) == 1 and (kinds.get('answer', 0) + kinds.get('prose', 0)) == len(answers)
            and view.get('uniqueRowIDs') is True)
    verdict('b11.streamShowsTheTurnOnce', once, {'rowKinds': kinds, 'uniqueRowIDs': view.get('uniqueRowIDs'), 'transcriptPrompts': len(pr), 'transcriptAssistantTexts': len(answers), 'turns': view.get('turns'), 'unknownRecords': view.get('unknownRecords')})
    shot('b11-chat-after-handover')


def rows_summary():
    c = catalog('rows-summary')
    return {'selected': (c.get('selectedSessionID') or '')[:8], 'active': [i[:8] for i in c.get('activeSessionIDs', [])],
            'rows': [(r['id'][:8], r['conversationID'][:8], r['live'], r['lifecycle']) for r in c.get('activityRowDetails', [])],
            'route': c.get('route')}


def sidebar_rows():
    """How many rows the sidebar lists for the project (the catalog's loaded rows)."""
    return catalog('sidebar').get('loadedRows')


def journal_events(name):
    """How many journal lines of this event the app under test has written (event names only)."""
    path = data / 'diagnostics' / 'journal.jsonl'
    if not path.exists():
        return 0
    count = 0
    for line in path.read_text(errors='replace').splitlines():
        try:
            count += json.loads(line).get('event') == name
        except ValueError:
            pass
    return count


def check_b12():
    work, project = launch('app-b12')
    claude_before = claude_pids_now()
    cmd(f'chat-start:{project}')
    session = until(lambda: (lambda s: s.get('sessionID') if s.get('driver') and s.get('phase') == 'ready' else None)(chat_state('start')), 90, 'chat ready')
    cmd(f'select:{session}')
    time.sleep(2)
    before_summary = rows_summary()
    before = known_ids() | {session}
    step(f'before /clear: {before_summary}')
    cmd(f'chat-send:{session}:/clear')
    new = None
    end = time.monotonic() + 45
    while time.monotonic() < end and not new:
        time.sleep(1.5)
        new = new_session_id(before)
    time.sleep(3)  # a second move would come within milliseconds; wait well past that
    after_summary = rows_summary()
    rows_after_clear, moves = sidebar_rows(), journal_events('chat.moved')
    step(f'after /clear: {after_summary}; new card found in the catalog: {new is not None}; sidebar rows {rows_after_clear}; chat.moved {moves}')
    # Release B fix round, F1: one /clear is one move and two rows (the original and the new card), no empty middle card.
    verdict('b12.clearMovesToNewCard', new is not None and rows_after_clear == 2 and moves == 1,
            {'before': before_summary, 'after': after_summary, 'sidebarRows': rows_after_clear, 'chatMoved': moves})
    target = new or session
    cmd(f'select:{target}')
    time.sleep(1.5)
    turn('B12 send on the new card' + ('' if new else ' (old id: no new card was found)'))
    cmd(f'chat-send:{target}:Reply with the single word: pong')
    def answered():
        v = chat_view(target, 'clear')
        return v if (v.get('turns') or [])[-1:] in (['succeeded'], ['failed']) else None
    try:
        v = until(answered, 100, 'turn on the new card')
    except RuntimeError:
        v = chat_view(target, 'clear-late')
    conv = conversation_of(target)
    pongs = [t for t in assistant_texts(conv) if 'pong' in t.lower()] if transcript_path(conv) else []
    rows_after_send = sidebar_rows()
    # The /clear itself ends in a result on the new card, so its turns end with the pong's; the transcript is the card's own.
    verdict('b12.sendOnNewCard', (v.get('turns') or [])[-1:] == ['succeeded'] and bool(pongs) and rows_after_send == 2,
            {'turns': v.get('turns'), 'entries': v.get('entries'), 'rowKinds': v.get('rowKinds'), 'transcriptHasThePong': bool(pongs),
             'sidebarRows': rows_after_send, 'summary': rows_summary()})
    shot('b12-chat-after-clear')
    exited, seconds = quit_app(60)
    hosts, claude = leftover_processes(claude_before)
    verdict('b12.quitAfterClear', exited is True and not hosts and not claude, {'exited': exited, 'seconds': round(seconds, 1), 'runHostsLeft': len(hosts), 'claudeLeft': len(claude)})


def check_b13():
    work, project = launch('app-b13')
    cmd(f'chat-start:{project}')
    session = until(lambda: (lambda s: s.get('sessionID') if s.get('driver') and s.get('phase') == 'ready' else None)(chat_state('start')), 90, 'chat ready')
    cmd(f'select:{session}'); time.sleep(1.5)
    r = fresh(f'composer-mode:{session}:ask', 'composer-last-mode.json', 30)
    step(f'composer mode ask: finished {r.get("changeFinished")}')
    until(lambda: chat_state('askmode').get('permissionMode') == 'dontAsk' or None, 20, 'mode dontAsk')
    turn('B13 Ask refusal')
    cmd(f'chat-send:{session}:Use the Write tool to create made.txt containing hello, then tell me what happened.')
    until(lambda: chat_idle('ask-done') if len(chat_state('ask-done').get('turns') or []) >= 1 else None, 150, 'Ask turn finished')
    v = chat_view(session, 'askview')
    verdict('b13.askRefusal', not (work / 'made.txt').exists() and not chat_state('ask-req').get('requests'), {'madeTxtExists': (work / 'made.txt').exists(), 'rowKinds': v.get('rowKinds'), 'turns': v.get('turns')})
    time.sleep(1.5)
    shot('b13-ask-refusal')
    fresh(f'composer-mode:{session}:default', 'composer-last-mode.json', 30)
    until(lambda: chat_state('defmode').get('permissionMode') == 'default' or None, 20, 'mode default')
    turn('B13 approval card')
    cmd(f'chat-send:{session}:Use the Bash tool to run exactly: touch card.txt')
    until(lambda: (chat_state('card').get('requests') or None), 120, 'approval card')
    time.sleep(2)
    shot('b13-approval-card')
    cs = fresh(f'card-state:{session}:card', 'card-state-card.json', 20)
    step(f'card state keys: {sorted(cs.keys())[:12]}')
    cmd(f'card:{session}:deny:Not needed')
    until(lambda: chat_idle('card-done'), 120, 'turn ended after deny')
    verdict('b13.approvalCardShot', not (work / 'card.txt').exists(), {'cardTxtExists': (work / 'card.txt').exists()})


try:
    {'dry': check_dry, 'b9b10': check_b9b10, 'b11': check_b11, 'b12': check_b12, 'b13': check_b13}[args.check]()
    step('done')
except BaseException as error:
    verdict('script', False, f'{type(error).__name__}: {str(error)[:200]}')
    raise
finally:
    safety_net()
    print(json.dumps({k: v['pass'] for k, v in results['passed'].items()}))
