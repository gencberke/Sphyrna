#!/usr/bin/env python3
"""Real-Claude deletion check (CP4-E, contract section 8, checkpoint 4 acceptance A7). Claude only.
REAL MODEL TURNS: 2 short turns (haiku, set by the probe profile's settings.json) in the isolated probe profile
<probe-root>/claude-config, never the real ~/.claude. Conversation A is asked to use a subagent to create a file;
conversation B (same project) gets one short reply. Then A is deleted through the evidence `delete:` command.
Checks: no file named for A is left in the Claude folder (or its temporary root); every other file of the Claude
folder (B's included) keeps its hash except the files Claude itself rewrites (listed by name, never by content);
history.jsonl keeps all of its earlier lines; A and B rows in the catalog (A gone, B kept); A is not in the
snapshot and does not come back after a normal Quit and relaunch; `claude --resume <A id>` reports no conversation
without a model call (run only after the files are gone, short timeout, outcome category only).
The evidence file is value-free: names with the two ids replaced by <A>/<B>, counts, hashes, booleans.
Usage: scripts/cp4-deletion-real.py --app <package>/'Loom Dev.app' [--run-dir DIR] [--probe-root DIR] [--out FILE]
Output: <run-dir>/{evidence,evidence-relaunch,data}/ and --out (default plans/experiments/run1-CP4E-real-deletion.json);
the run directory must not exist yet."""
import argparse, hashlib, json, os, pathlib, re, signal, sqlite3, subprocess, sys, time, uuid
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / 'perf'))
import perf_paths
from perf_paths import REPO as ROOT, load_module as module

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
perf_paths.add_common_arguments(parser, 'cp4e-real-deletion')
parser.add_argument('--probe-root', type=pathlib.Path, default=perf_paths.PROBE,
                    help='holds claude-config/ (isolated profile) and workspace/ (default: Loom-Dev/probe)')
parser.add_argument('--out', type=pathlib.Path, default=ROOT / 'plans/experiments/run1-CP4E-real-deletion.json')
args = parser.parse_args()
app, run_dir = perf_paths.resolve_common(args, 'cp4e-real-deletion')
PROBE = perf_paths.refuse_documents('Probe root', args.probe_root)
CONFIG = PROBE / 'claude-config'
HOME = pathlib.Path.home()
for forbidden in (HOME / '.claude', HOME / '.codex'):
    if CONFIG.resolve() == forbidden.resolve():
        sys.exit(f'{CONFIG} is the real {forbidden.name} folder; use the isolated probe profile')
if not CONFIG.is_dir(): sys.exit(f'{CONFIG} is not a directory')
measure = module('measure', ROOT / 'scripts/cp5-d-measure.py')

base = run_dir
evidence, evidence2, data = base / 'evidence', base / 'evidence-relaunch', base / 'data'
for d in (evidence, evidence2, data): d.mkdir(parents=True)
workspace = PROBE / 'workspace' / f'cp4e-{time.strftime("%Y%m%dT%H%M%S")}'
workspace.mkdir(parents=True)
TOKENS = 'Try,esc to interrupt,Do you want'
report = {'checks': {}, 'details': {}, 'modelTurns': 0, 'model': 'haiku (probe settings.json)'}
IDS = {}  # id -> placeholder used in evidence names

def check(name, ok, detail=None):
    report['checks'][name] = bool(ok)
    if detail is not None: report['details'][name] = detail

def label(text):
    """Value-free form of a path or name: the two conversation ids become <A> and <B>."""
    for i, p in IDS.items(): text = re.sub(re.escape(i), p, text, flags=re.I)
    return re.sub(r'-Users-[^/]*?-Library-Application-Support-Loom-Dev-probe', '<probe>', text)

def snap(directory, name):
    p = directory / f'state-{name}.json'; p.unlink(missing_ok=True)
    measure.send('snapshot:' + name, directory); return measure.wait_json(p, 15)

def until(directory, name, pred, timeout, step=.5):
    end = time.monotonic() + timeout; s = None
    while time.monotonic() < end:
        s = snap(directory, name)
        if pred(s): return s
        time.sleep(step)
    raise RuntimeError('timeout:' + name)

def term(s, owner): return next((t for t in s.get('conversationTerminals', []) if t.get('owner') == owner), None)
def token(owner, name): return lambda s: (term(s, owner) or {}).get('tokenPresence', {}).get(name) is True
def rows(s): return s['catalog'].get('activityRowDetails', [])
def row(s, owner): return next((r for r in rows(s) if r['id'] == owner), None)

def provider_ids(owner, s=None):
    ids = {owner.lower()}
    r = row(s, owner) if s else None
    if r and r.get('conversationID'): ids.add(r['conversationID'].lower())
    return ids

def transcripts(ids):
    return [f for i in ids for f in (CONFIG / 'projects').glob(f'*/{i}.jsonl')] + \
           [f for i in ids for f in (CONFIG / 'projects').glob(f'*/{i.upper()}.jsonl')]

def transcript_records(ids):
    for f in transcripts(ids):
        for line in f.read_text(errors='replace').splitlines():
            try: yield json.loads(line)
            except ValueError: continue

def transcript_has(ids, text, role):
    for r in transcript_records(ids):
        c = r.get('message', {}).get('content') if r.get('type') == role else None
        if isinstance(c, list): c = ' '.join(x.get('text', '') for x in c if isinstance(x, dict))
        if isinstance(c, str) and text in c: return True
    return False

def tool_names(ids):
    names = set()
    for r in transcript_records(ids):
        c = r.get('message', {}).get('content') if r.get('type') == 'assistant' else None
        for x in c if isinstance(c, list) else []:
            if isinstance(x, dict) and x.get('type') == 'tool_use': names.add(str(x.get('name')))
    return sorted(names)

def prompt(owner, ids, text):
    """Type, press Return, poll until the provider transcript holds the text (a short turn can finish in ~1 s)."""
    measure.send(f'type:{owner}:{text}', evidence); time.sleep(1.5)
    for attempt in range(3):
        measure.send(f'type:{owner}:', evidence)
        end = time.monotonic() + 8
        while time.monotonic() < end:
            if transcript_has(ids, text, 'user'): return
            time.sleep(.3)
    raise RuntimeError('prompt-not-submitted')

def finish_turn(owner, ids, marker, timeout=300):
    """Wait for the assistant's marker in the transcript and a quiet indicator; answer approvals with Return
    (option 1 is the one-time Yes). Returns {'approvals': n, 'indicators': [...]}."""
    seen, approvals, end, last_approval = [], 0, time.monotonic() + timeout, 0
    while time.monotonic() < end:
        s = snap(evidence, 'turn'); ind = s['catalog'].get('selectedIndicator')
        if not seen or seen[-1] != ind: seen.append(ind)
        if ind == 'Needs approval' and time.monotonic() - last_approval > 2:
            measure.send(f'type:{owner}:', evidence); approvals += 1; last_approval = time.monotonic()
        if transcript_has(ids, marker, 'assistant') and ind in ('Finished', 'Ready'): return {'approvals': approvals, 'indicators': seen}
        time.sleep(.5)
    raise RuntimeError('turn-timeout:' + marker)

# ---- filesystem views (names and hashes only) -------------------------------------------------------------

def sha(path):
    h = hashlib.sha256()
    try:
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 20), b''): h.update(chunk)
    except OSError: return 'unreadable'
    return h.hexdigest()

def tree_hashes(root):
    out = {}
    for dirpath, dirs, files in os.walk(root):
        for n in files + [d for d in dirs if os.path.islink(os.path.join(dirpath, d))]:
            p = pathlib.Path(dirpath, n); rel = str(p.relative_to(root))
            out[rel] = 'symlink' if p.is_symlink() else sha(p)
        for n in dirs:
            if not os.path.islink(os.path.join(dirpath, n)): out[str(pathlib.Path(dirpath, n).relative_to(root)) + '/'] = 'dir'
    return out

def id_paths(ids, root=CONFIG):
    """find <root> -iname '*<id>*' (files and folders)."""
    found = []
    for dirpath, dirs, files in os.walk(root):
        for n in dirs + files:
            if any(i in n.lower() for i in ids): found.append(str(pathlib.Path(dirpath, n).relative_to(root)))
    return sorted(found)

def tmp_paths(ids):
    root = pathlib.Path(f'/private/tmp/claude-{os.getuid()}')
    return id_paths(ids, root) if root.is_dir() else []

def history_lines():
    p = CONFIG / 'history.jsonl'
    return [hashlib.sha256(l).hexdigest() for l in p.read_bytes().splitlines()] if p.exists() else []

def catalog_hits(ids, label_name):
    """Rows that mention an id in any text column of any table, plus byte matches in the database and its WAL."""
    hits, total = {}, 0
    for db in sorted(data.glob('*.sqlite3')):
        con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
        try:
            for (table,) in con.execute("select name from sqlite_master where type='table' and name not like 'sqlite_%'"):
                cols = [c[1] for c in con.execute(f'pragma table_info("{table}")')]
                for i in ids:
                    n = sum(con.execute(f'select count(*) from "{table}" where ' + ' or '.join(f'lower(cast("{c}" as text)) like ?' for c in cols),
                                        [f'%{i}%'] * len(cols)).fetchone()[0:1]) if cols else 0
                    n += sum(con.execute(f'select count(*) from "{table}" where ' + ' or '.join(f'hex("{c}") like ?' for c in cols),
                                         [f'%{uuid.UUID(i).hex}%'.upper()] * len(cols)).fetchone()[0:1]) if cols else 0
                    if n: hits[table] = hits.get(table, 0) + n; total += n
        finally: con.close()
    raw = {}
    for f in sorted(data.glob('*.sqlite3*')):
        blob = f.read_bytes().lower()
        n = sum(blob.count(i.encode()) + blob.count(uuid.UUID(i).bytes) + blob.count(i.encode('utf-16-le')) for i in ids)
        if n: raw[f.name] = n
    return {'rowsByTable': hits, 'rows': total, 'rawByteMatchesByFile': raw, 'rawByteMatches': sum(raw.values())}

def registry_pids(ids):
    """Claude's live-session registry (sessions/<pid>.json): pids of processes that hold one of these session ids."""
    pids = []
    for f in (CONFIG / 'sessions').glob('*.json'):
        try: d = json.loads(f.read_text())
        except (OSError, ValueError): continue
        if str(d.get('sessionId', '')).lower() in ids and f.stem.split('.')[0].isdigit(): pids.append(int(f.stem.split('.')[0]))
    return sorted(pids)

def alive(pid):
    try: return measure.identity(pid) is not None
    except Exception: return True

def ps_with(needles):
    out = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True).stdout
    return [int(l.split()[0]) for l in out.splitlines() if any(n in l for n in needles) and str(os.getpid()) != l.split()[0]]

# ---- app lifecycle ---------------------------------------------------------------------------------------

def launch(directory):
    if subprocess.run(['pgrep', '-f', str(app / 'Contents/MacOS/Loom Dev')], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('a process of this package is already running')
    subprocess.run(['open', '-n', '-a', str(app), '--args', '--evidence', str(directory), '--data-root', str(data),
                    '--claude-config', str(CONFIG), '--codex-home', str(HOME / '.loom-dev/codex-home'),
                    '--evidence-tokens', TOKENS], check=True)
    pid = measure.wait_json(directory / 'launched.json', 30)['pid']
    until(directory, 'ready', lambda s: s['catalog']['ready'] and s['catalog']['actionsAvailable'], 30)
    return pid

def quit_app(directory, pid):
    measure.send('quit', directory)
    end = time.monotonic() + 60
    while time.monotonic() < end:
        if measure.identity(pid) is None: return True
        time.sleep(.5)
    return False

def resume_category(session_id):
    """`claude --resume <id> --print` with no prompt and no stdin: category of the outcome, never its content.
    A conversation that no longer exists is reported before any model call."""
    env = dict(os.environ, CLAUDE_CONFIG_DIR=str(CONFIG))
    try:
        p = subprocess.run(['claude', '--resume', session_id, '--print'], cwd=workspace, env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=45)
        text = (p.stdout + p.stderr).lower()
        cat = 'no-conversation' if 'no conversation found' in text else \
              'input-required' if 'input must be provided' in text else 'other'
        return {'mode': 'print', 'exit': p.returncode, 'category': cat}
    except subprocess.TimeoutExpired:
        return {'mode': 'print', 'exit': None, 'category': 'timeout'}

def resume_category_interactive(session_id):
    """Interactive equivalent through a pty (my own child, stopped by pid): only whether the screen says no conversation."""
    import pty, select
    env = dict(os.environ, CLAUDE_CONFIG_DIR=str(CONFIG))
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(workspace); os.execvpe('claude', ['claude', '--resume', session_id], env)
    out, end, status = b'', time.monotonic() + 30, None
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], .5)
        if r:
            try: chunk = os.read(fd, 65536)
            except OSError: chunk = b''
            if not chunk: break
            out += chunk
        if b'no conversation found' in out.lower(): break
        done, st = os.waitpid(pid, os.WNOHANG)
        if done: status = st; break
    exited = status is not None
    if not exited:
        try: os.kill(pid, signal.SIGTERM); os.waitpid(pid, 0)
        except OSError: pass
    return {'mode': 'interactive', 'category': 'no-conversation' if b'no conversation found' in out.lower() else 'other', 'exitedOnItsOwn': exited}

# ---- the run ---------------------------------------------------------------------------------------------
app_pid = None
try:
    app_pid = launch(evidence)
    measure.send('view-mode:projects', evidence)
    measure.send('add-project:' + str(workspace), evidence)
    project = until(evidence, 'project', lambda s: any(p['name'] == workspace.name for p in s['catalog']['projects']), 30)
    project = next(p['id'] for p in project['catalog']['projects'] if p['name'] == workspace.name)
    known = {t['owner'] for t in snap(evidence, 'before').get('conversationTerminals', [])}

    def start():
        measure.send(f'start:claude:{project}', evidence)
        s = until(evidence, 'bound', lambda s: any(t['owner'] not in known for t in s.get('conversationTerminals', [])), 120)
        owner = next(t['owner'] for t in s['conversationTerminals'] if t['owner'] not in known)
        known.add(owner)
        measure.send(f'select:{owner}', evidence)
        until(evidence, 'tui-ready', token(owner, 'Try'), 90); time.sleep(2)
        return owner

    # Conversation A: subagent plus file edit in one short turn.
    A = start(); IDS[A.lower()] = '<A>'
    A_MARK = 'LOOM_CP4A_DONE'
    prompt(A, {A.lower()}, 'Use a subagent to create a file named loom-cp4-a.txt containing OK, then reply with exactly ' + A_MARK)
    report['modelTurns'] += 1
    turn_a = finish_turn(A, {A.lower()}, A_MARK)
    sA = snap(evidence, 'a-done'); A_IDS = provider_ids(A, sA)
    for i in A_IDS: IDS.setdefault(i, '<A>')
    # Conversation B in the same project.
    B = start(); IDS[B.lower()] = '<B>'
    B_MARK = 'LOOM_CP4B_OK'
    prompt(B, {B.lower()}, 'Reply with exactly the single word ' + B_MARK)
    report['modelTurns'] += 1
    turn_b = finish_turn(B, {B.lower()}, B_MARK)
    sB = snap(evidence, 'b-done'); B_IDS = provider_ids(B, sB)
    for i in B_IDS: IDS.setdefault(i, '<B>')
    time.sleep(3)
    check('assistantRepliedA', transcript_has(A_IDS, A_MARK, 'assistant'))
    check('assistantRepliedB', transcript_has(B_IDS, B_MARK, 'assistant'))
    sub_files = [f for i in A_IDS for f in (CONFIG / 'projects').glob(f'*/{i}/subagents/*')] + \
                [f for i in A_IDS for f in (CONFIG / 'projects').glob(f'*/{i.upper()}/subagents/*')]
    tools = tool_names(A_IDS)
    subagent = bool(sub_files) or any(t in ('Agent', 'Task') for t in tools)
    check('subagentCreated', subagent, {'subagentFiles': len(sub_files), 'toolUseNames': tools})
    check('fileEditByTurnA', (workspace / 'loom-cp4-a.txt').exists(), {'approvals': turn_a['approvals']})

    # Before-state: hashes of every file, shared files, history lines, catalog rows.
    before = tree_hashes(CONFIG)
    a_paths_before = id_paths(A_IDS); b_paths_before = id_paths(B_IDS)
    b_files = sorted(p for p in before if any(i in p.lower() for i in B_IDS))
    shared = ['history.jsonl', '.claude.json'] + sorted(p for p in before if '/memory/' in p or p.endswith('/memory/'))
    h_before = history_lines()
    a_pids, b_pids = registry_pids(A_IDS), registry_pids(B_IDS)
    # Claude removes its own registry entry (sessions/<pid>.json and its .key) when the stopped process exits.
    a_registry = {n for pid in a_pids for n in (f'sessions/{pid}.json',) + tuple(
        f'sessions/{f.name}' for f in (CONFIG / 'sessions').glob(f'{pid}.*.key'))}
    report['before'] = {
        'aPaths': [label(p) for p in a_paths_before], 'aPathCount': len(a_paths_before),
        'bPaths': [label(p) for p in b_paths_before], 'bFileCount': len(b_files),
        'sharedFiles': [label(p) for p in shared], 'historyLines': len(h_before),
        'tmpPathsA': [label(p) for p in tmp_paths(A_IDS)],
        'catalogA': catalog_hits(A_IDS, 'A'), 'catalogB': catalog_hits(B_IDS, 'B'),
        'aRegistryPids': len(a_pids), 'bRegistryPids': len(b_pids),
        'aAlive': [alive(p) for p in a_pids], 'bAlive': [alive(p) for p in b_pids],
        'turnA': turn_a, 'turnB': turn_b, 'configFileCount': len(before)}
    check('aFilesExistBeforeDelete', bool(a_paths_before))
    check('registryPidsFound', bool(a_pids) and bool(b_pids) and all(alive(p) for p in a_pids + b_pids))
    sizes_before = {p['id']: p['count'] for p in snap(evidence, 'counts')['catalog']['projects']}
    check('aTranscriptBeforeDelete', bool(transcripts(A_IDS)))

    # Delete A through the evidence command.
    t0 = time.monotonic()
    measure.send(f'delete:{A}', evidence)
    s = until(evidence, 'confirm', lambda s: (s['deletions'].get('confirmation') or {}).get('phase') in ('ready', 'unavailable'), 30)
    conf = s['deletions']['confirmation']
    report['confirmation'] = {k: conf['detail'].get(k) for k in ('fileCount', 'byteCount', 'isRunning', 'unreachable')} if conf['phase'] == 'ready' else {'phase': conf['phase']}
    check('confirmationReady', conf['phase'] == 'ready' and conf['canConfirm'])
    measure.send('delete-confirm', evidence)
    def finished(s):
        d = s['deletions']
        counts = {p['id']: p['count'] for p in s['catalog']['projects']}
        gone = counts.get(project) == sizes_before[project] - 1
        return gone and not d['inProgress'] and A not in [p['id'] for p in d['pending']] and not d.get('confirmation')
    try:
        s = until(evidence, 'deleted', finished, 120)
        check('deletionCompleted', True, {'seconds': round(time.monotonic() - t0, 1)})
    except RuntimeError:
        s = snap(evidence, 'deleted-timeout')
        check('deletionCompleted', False, {'pending': [(p['state'], p['lastFailure']) for p in s['deletions']['pending']],
                                          'recoveryFailure': s['deletions']['recoveryFailure']})
        raise
    time.sleep(3)
    measure.send('view-mode:activity', evidence)
    s = until(evidence, 'after-delete', lambda s: s['catalog']['viewMode'] == 'activity' and s['catalog']['activityRows'] > 0, 30)
    report['deletions'] = {'pending': len(s['deletions']['pending']), 'recoveryFailure': s['deletions']['recoveryFailure'],
                           'bannerError': s['catalog'].get('errorMessage')}

    # After-state.
    after = tree_hashes(CONFIG)
    left = id_paths(A_IDS)
    check('noPathNamedForA', not left, [label(p) for p in left])
    check('noTmpPathNamedForA', not tmp_paths(A_IDS), [label(p) for p in tmp_paths(A_IDS)])
    removed = sorted(p for p in before if p not in after); added = sorted(p for p in after if p not in before)
    changed = sorted(p for p in before if p in after and before[p] != after[p] and not p.endswith('/'))
    a_owned = {p for p in before if any(i in p.lower() for i in A_IDS)}
    # a removed subtree's children carry the folder's id in their path only through the folder: count by prefix
    a_prefixes = tuple(p for p in a_owned if p.endswith('/')) + tuple(a_owned)
    removed_not_a = [p for p in removed if p not in a_owned and not p.startswith(a_prefixes) and p not in a_registry]
    report['removedRegistryEntriesOfA'] = len([p for p in removed if p in a_registry])
    check('onlyAFilesRemoved', not removed_not_a, [label(p) for p in removed_not_a])
    check('b_filesPresentAndUnchanged', all(after.get(p) == before[p] for p in b_files),
          {'bFiles': len(b_files), 'changed': [label(p) for p in b_files if after.get(p) != before[p]]})
    check('memoryFilesUnchanged', all(after.get(p) == before[p] for p in shared if '/memory/' in p or p.endswith('/memory/')))
    shared_files = ['history.jsonl', '.claude.json']
    h_after = history_lines(); h_after_set = set(h_after)
    check('historyKeepsEarlierLines', all(l in h_after_set for l in h_before), {'before': len(h_before), 'after': len(h_after)})
    others = [p for p in changed if p not in b_files and p not in shared_files]
    report['otherChangedFiles'] = [label(p) for p in others]
    report['addedFiles'] = [label(p) for p in added]
    # Only Claude's own shared files may change (B is live and rewrites them); nothing else changes or appears.
    check('sharedRewrittenByClaudeOnly', not others and not added,
          {'shared': {p: ('changed' if after.get(p) != before.get(p) else 'same') for p in shared_files},
           'otherChanged': len(others), 'added': len(added)})
    report['removedFileCount'] = len(removed)
    report['removedNotNamedForA'] = [label(p) for p in removed_not_a]
    check('bTranscriptStillHasItsReply', transcript_has(B_IDS, B_MARK, 'assistant'))
    check('projectFileOfTurnAKept', (workspace / 'loom-cp4-a.txt').exists())
    report['after'] = {'catalogA': catalog_hits(A_IDS, 'A'), 'catalogB': catalog_hits(B_IDS, 'B'),
                       'aAlive': [alive(p) for p in a_pids], 'bAlive': [alive(p) for p in b_pids]}
    check('catalogHasNoARows', report['after']['catalogA']['rows'] == 0, report['after']['catalogA']['rowsByTable'])
    check('catalogKeepsBRows', report['after']['catalogB']['rows'] > 0)
    check('noIdBytesInDatabaseFilesAfterDelete', report['after']['catalogA']['rawByteMatches'] == 0,
          report['after']['catalogA']['rawByteMatchesByFile'])
    check('aProcessGone', not any(report['after']['aAlive']))
    check('bStillRunning', all(report['after']['bAlive']) and term(s, B) is not None)
    check('aNotInSnapshot', row(s, A) is None and A not in [t['owner'] for t in s.get('conversationTerminals', [])])
    check('bInSnapshot', row(s, B) is not None)
    check('aNotInProjectCount', s['catalog']['activityRows'] == 1, {'activityRows': s['catalog']['activityRows']})

    # `claude --resume <A id>` only now that the files are gone; plus a never-existing id as the control.
    gone_ids_exist = bool(id_paths(A_IDS))
    if not gone_ids_exist:
        n_tr, h_n = len(list((CONFIG / 'projects').glob('*/*.jsonl'))), len(history_lines())
        rA = resume_category(sorted(A_IDS)[0]); rC = resume_category(str(uuid.uuid4()))
        if rA['category'] == 'input-required':
            rA = resume_category_interactive(sorted(A_IDS)[0]); rC = resume_category_interactive(str(uuid.uuid4()))
        report['resume'] = {'A': rA, 'neverExistedControl': rC,
                            'transcriptCountUnchanged': len(list((CONFIG / 'projects').glob('*/*.jsonl'))) == n_tr,
                            'historyLinesUnchanged': len(history_lines()) == h_n, 'aPathsAfterResume': len(id_paths(A_IDS))}
        check('resumeReportsNoConversation', rA['category'] == 'no-conversation' and rA['category'] == rC['category'])
        check('resumeCreatedNothing', report['resume']['transcriptCountUnchanged'] and report['resume']['aPathsAfterResume'] == 0)
    else:
        check('resumeReportsNoConversation', False, 'skipped: files still present')

    # Normal Quit and relaunch: A stays gone, B stays.
    check('appQuit', quit_app(evidence, app_pid)); app_pid = None
    app_pid = launch(evidence2)
    measure.send('view-mode:activity', evidence2)
    r = until(evidence2, 'relaunch', lambda s: s['catalog']['viewMode'] == 'activity' and s['catalog']['activityRows'] > 0, 30)
    check('relaunchHasNoA', row(r, A) is None and r['deletions']['pending'] == [] and r['deletions']['recoveryFailure'] is None)
    check('relaunchKeepsB', row(r, B) is not None and r['catalog']['activityRows'] == 1)
    report['relaunch'] = {'rows': len(rows(r)), 'projectCounts': [p['count'] for p in r['catalog']['projects'] if p['name'] == workspace.name]}
    check('relaunchCatalogNoARows', catalog_hits(A_IDS, 'A')['rows'] == 0)
    check('relaunchAFilesGone', not id_paths(A_IDS))
finally:
    if app_pid:
        d = evidence2 if (evidence2 / 'launched.json').exists() else evidence
        report['finalQuit'] = quit_app(d, app_pid)
    report['checks'].setdefault('appQuit', report.get('finalQuit', False))
    report['leftoverRunHosts'] = len(ps_with([str(app) + '/']))
    report['allChecksPassed'] = bool(report['checks']) and all(report['checks'].values())
    report['package'] = {'binarySha256': sha(app / 'Contents/MacOS/Loom Dev') if (app / 'Contents/MacOS/Loom Dev').exists() else None}
    text = json.dumps(report, indent=1, default=str)
    (base / 'result.json').write_text(text)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(text + '\n')
    print(json.dumps({'checks': report['checks'], 'modelTurns': report['modelTurns']}))
