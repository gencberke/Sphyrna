#!/usr/bin/env python3
"""Sphyrna 1.8.0 live acceptance with real CLIs (r9 acc): ordinary Claude session, Claude->Codex and Codex->Claude managed
child tasks, Changes comments sent to a Claude and a Codex terminal session.

REAL MODEL TURNS (cheap models only: Claude haiku/low, Codex gpt-6-luna/low; isolated profiles; work dirs under
/private/tmp/loom-real/acc/). Every submitted input is counted from the provider's own transcript afterwards and written to
<run>/turns.json and appended to <evidence root>/TURNS.md. Nothing resends a prompt that the provider recorded.

The script packages nothing. It takes a packaged app, makes a fresh evidence/data root per launch, launches through
LaunchServices with --evidence/--data-root/--claude-config/--codex-home, drives the evidence command channel, reads its JSON
state and always quits its own app (atexit + SIGINT/SIGTERM: `quit`, wait, then kill that pid after ~10 s).

Usage:
  scripts/acceptance/r9_live.py --app "<package>/Loom Dev.app" [--cells ordinary,claude-codex,codex-claude,changes]
      [--evidence-root ~/Library/Caches/loom-v2/evidence/r9/acc] [--rounds 3]
"""
import argparse, atexit, ctypes, datetime, glob, hashlib, json, os, pathlib, signal, subprocess, sys, time, uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts/perf'))
import perf_paths  # noqa: E402

HOME = pathlib.Path.home()
CLAUDE_CONFIG = HOME / 'Library/Application Support/Loom-Dev/probe/claude-config'
CODEX_HOME = HOME / '.loom-dev/codex-home'
WORK_ROOT = pathlib.Path('/private/tmp/loom-real/acc')
FORBIDDEN_APPS = [HOME / 'Library/Application Support/Loom-Dev/app/Loom Dev.app', pathlib.Path('/Applications/Loom.app')]
TOKENS = ['Try', 'shortcuts', 'trust this folder', 'external imports', 'Do you trust', 'Sphyrna:']
CLAUDE_MODEL, CLAUDE_EFFORT = 'haiku', 'low'
CODEX_MODEL, CODEX_EFFORT = 'gpt-6-luna', 'low'

libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]


def now():
    return datetime.datetime.now().strftime('%Y%m%dT%H%M%S')


def log(*parts):
    print(time.strftime('%H:%M:%S'), *parts, flush=True)


# ---------------------------------------------------------------- processes

def ps_table():
    out = subprocess.run(['ps', '-axo', 'pid=,ppid=,lstart=,command='], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        parts = line.split(None, 7)
        if len(parts) < 8:
            continue
        pid, ppid = int(parts[0]), int(parts[1])
        rows[pid] = {'pid': pid, 'ppid': ppid, 'start': ' '.join(parts[2:7]), 'command': parts[7]}
    return rows


def coalition(pid):
    buffer = (ctypes.c_uint64 * 5)()
    return buffer[0] if libproc.proc_pidinfo(pid, 20, 0, buffer, 40) == 40 else None


def owned_processes(app_pid):
    """The app's descendants plus every process in a coalition one of them leads (run scopes are coalitions)."""
    table = ps_table()
    children = {}
    for row in table.values():
        children.setdefault(row['ppid'], []).append(row['pid'])
    found, stack = set(), [app_pid]
    while stack:
        pid = stack.pop()
        for child in children.get(pid, []):
            if child not in found:
                found.add(child)
                stack.append(child)
    app_coalition = coalition(app_pid)
    coalitions = {coalition(pid) for pid in found} - {None, app_coalition}
    if coalitions:
        for pid in table:
            if pid != app_pid and coalition(pid) in coalitions:
                found.add(pid)
    result = []
    for pid in sorted(found):
        row = table.get(pid)
        if row:
            command = row['command']
            name = os.path.basename(command.split(' --')[0].split(' ')[0]) if command else ''
            result.append({'pid': pid, 'start': row['start'], 'name': name[:60],
                           'socket': next((a for a in command.split() if a.endswith('.sock')), None)})
    return result


def alive(entry):
    row = ps_table().get(entry['pid'])
    return bool(row and row['start'] == entry['start'])


def unix_sockets(pids):
    if not pids:
        return []
    out = subprocess.run(['lsof', '-a', '-U', '-F', 'n', '-p', ','.join(map(str, pids))],
                         capture_output=True, text=True).stdout
    return sorted({line[1:] for line in out.splitlines() if line.startswith('n/')})


# ---------------------------------------------------------------- transcripts (isolated profiles only; no text is stored)

def claude_records(native_id):
    for path in glob.glob(str(CLAUDE_CONFIG / 'projects' / '*' / f'{native_id}.jsonl')):
        for line in pathlib.Path(path).read_text(errors='replace').splitlines():
            try:
                yield json.loads(line)
            except ValueError:
                continue


def claude_text(record):
    content = record.get('message', {}).get('content')
    if isinstance(content, list):
        return ' '.join(str(x.get('text', '') or x.get('content', '') or json.dumps(x.get('input', ''))) for x in content
                        if isinstance(x, dict))
    return content if isinstance(content, str) else ''


def claude_prompts(native_id):
    """User inputs Claude recorded (typed prompts, pointers, wakes), not tool results."""
    return [r for r in claude_records(native_id) if r.get('type') == 'user' and not r.get('isMeta')
            and isinstance(r.get('message', {}).get('content'), str)]


def claude_usage(native_id):
    seen, total, models = set(), {'input': 0, 'cacheRead': 0, 'cacheWrite': 0, 'output': 0}, set()
    for r in claude_records(native_id):
        if r.get('type') != 'assistant':
            continue
        message = r.get('message', {})
        models.add(message.get('model'))
        if message.get('id') in seen:
            continue
        seen.add(message.get('id'))
        usage = message.get('usage') or {}
        total['input'] += usage.get('input_tokens', 0)
        total['cacheRead'] += usage.get('cache_read_input_tokens', 0)
        total['cacheWrite'] += usage.get('cache_creation_input_tokens', 0)
        total['output'] += usage.get('output_tokens', 0)
    return total, sorted(m for m in models if m)


def claude_tool_uses(native_id):
    return [x for r in claude_records(native_id) if r.get('type') == 'assistant'
            for x in (r.get('message', {}).get('content') or []) if isinstance(x, dict) and x.get('type') == 'tool_use']


def claude_has(native_id, text, role):
    return any(r.get('type') == role and text in claude_text(r) for r in claude_records(native_id))


def codex_rollout(thread_id):
    files = glob.glob(str(CODEX_HOME / 'sessions' / '*' / '*' / '*' / f'rollout-*{thread_id}.jsonl'))
    return pathlib.Path(files[0]) if files else None


def codex_records(thread_id):
    path = codex_rollout(thread_id)
    if not path:
        return []
    out = []
    for line in path.read_text(errors='replace').splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return out


def codex_summary(thread_id):
    records = codex_records(thread_id)
    meta = next((r['payload'] for r in records if r.get('type') == 'session_meta'), {})
    contexts = [r['payload'] for r in records if r.get('type') == 'turn_context']
    started = [r['payload'].get('turn_id') for r in records
               if r.get('type') == 'event_msg' and r.get('payload', {}).get('type') == 'task_started']
    usage = [r['payload'].get('info') for r in records
             if r.get('type') == 'event_msg' and r.get('payload', {}).get('type') == 'token_count' and r['payload'].get('info')]
    limits = [r['payload'].get('rate_limits') for r in records
              if r.get('type') == 'event_msg' and r.get('payload', {}).get('type') == 'token_count']
    total = (usage[-1] or {}).get('total_token_usage') if usage else None
    primary = ((limits[-1] or {}).get('primary') or {}) if limits else {}
    return {'rollout': bool(records), 'cwd': meta.get('cwd'), 'cliVersion': meta.get('cli_version'),
            'models': sorted({c.get('model') for c in contexts if c.get('model')}),
            'efforts': sorted({c.get('effort') for c in contexts if c.get('effort')}),
            'approvalPolicies': sorted({str(c.get('approval_policy')) for c in contexts}),
            'turnsStarted': len(started), 'turnIDs': started, 'tokens': total,
            'weeklyUsedPercent': primary.get('used_percent')}


def codex_texts(thread_id, role):
    for r in codex_records(thread_id):
        p = r.get('payload', {})
        if r.get('type') == 'response_item' and p.get('type') == 'message' and p.get('role') == role:
            yield ' '.join(c.get('text', '') for c in p.get('content', []) if isinstance(c, dict))


def codex_tool_inputs(thread_id):
    for r in codex_records(thread_id):
        p = r.get('payload', {})
        if r.get('type') == 'response_item' and p.get('type') in ('function_call', 'custom_tool_call', 'local_shell_call'):
            yield json.dumps(p.get('arguments') or p.get('input') or p.get('action') or '')


# ---------------------------------------------------------------- one app instance

LAUNCHED = []


class App:
    def __init__(self, app_path, base, data=None, label='app'):
        self.app_path, self.base = app_path, base
        self.evidence = base / f'evidence-{label}'
        self.data = data or (base / 'data')
        self.pid = None
        self.evidence.mkdir(parents=True, exist_ok=True)
        self.data.mkdir(parents=True, exist_ok=True)

    def launch(self):
        perf_paths.seed_remora_off(self.data)  # an evidence run with --claude-config could reach the real CLI
        subprocess.run(['open', '-n', '-a', str(self.app_path), '--args', '--evidence', str(self.evidence),
                        '--data-root', str(self.data), '--claude-config', str(CLAUDE_CONFIG),
                        '--codex-home', str(CODEX_HOME), '--evidence-tokens', ','.join(TOKENS)], check=True)
        LAUNCHED.append(self)
        self.pid = self.wait_json('launched.json', 40)['pid']
        log('launched pid', self.pid, self.evidence)
        self.until('ready', lambda s: s['catalog']['ready'] and s['catalog']['actionsAvailable'], 60)
        self.send('live-chat:off')
        self.send('resize:1280x820')
        self.send('view-mode:activity')
        return self

    def send(self, text):
        expression = ("ObjC.import('Foundation'); $.NSDistributedNotificationCenter.defaultCenter."
                      "postNotificationNameObjectUserInfoDeliverImmediately("
                      + json.dumps(perf_paths.command_channel(self.evidence)) + ", " + json.dumps(text) + ", $(), true)")
        subprocess.run(['osascript', '-l', 'JavaScript', '-e', expression], check=True, capture_output=True, timeout=15)

    def wait_json(self, name, timeout):
        path, end = self.evidence / name, time.monotonic() + timeout
        while time.monotonic() < end:
            if path.exists():
                try:
                    return json.loads(path.read_text())
                except (OSError, ValueError):
                    pass
            time.sleep(.05)
        raise TimeoutError(name)

    def request(self, command, name, timeout=20):
        (self.evidence / name).unlink(missing_ok=True)
        self.send(command)
        return self.wait_json(name, timeout)

    def snap(self, label):
        return self.request('snapshot:' + label, f'state-{label}.json')

    def tasks(self, label):
        return self.request('task-state:' + label, f'task-state-{label}.json')

    def changes(self, session, label):
        return self.request(f'changes-state:{session}:{label}', f'changes-state-{label}.json')

    def until(self, label, predicate, timeout, every=1.0, source=None):
        source = source or self.snap
        end, value = time.monotonic() + timeout, None
        while time.monotonic() < end:
            value = source(label)
            if predicate(value):
                return value
            time.sleep(every)
        raise TimeoutError(f'timeout:{label}')

    def quit(self):
        if not self.pid:
            return True
        try:
            self.send('quit')
        except Exception:
            pass
        end = time.monotonic() + 60
        while time.monotonic() < end:
            if not pid_alive(self.pid):
                break
            time.sleep(.3)
        if pid_alive(self.pid):
            log('app still alive after quit, killing', self.pid)
            os.kill(self.pid, signal.SIGKILL)
            time.sleep(1)
            self.pid = None
            return False
        self.pid = None
        return True


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def quit_all():
    for app in LAUNCHED:
        if app.pid:
            app.quit()


atexit.register(quit_all)
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda *_: sys.exit(130))


# ---------------------------------------------------------------- catalog helpers

def row(state, sid):
    for r in state.get('catalog', {}).get('activityRowDetails', []) or []:
        if r.get('id') == sid:
            return r
    return None


def indicator(state, sid):
    return (row(state, sid) or {}).get('indicator')


def owners(state):
    return [t['owner'] for t in state.get('conversationTerminals', [])]


def work_dir(name, claude=True, codex=True):
    path = WORK_ROOT / name
    resolved = path.resolve()
    if HOME.resolve() in resolved.parents:
        raise SystemExit('work dir under HOME')
    path.mkdir(parents=True, exist_ok=False)
    os.chmod(path, 0o700)
    for file, text in (('alpha.txt', 'alpha\n'), ('beta.txt', 'beta\n')):
        (path / file).write_text(text)
    subprocess.run(['git', 'init', '-q', '-b', 'main', str(path)], check=True)
    subprocess.run(['git', '-C', str(path), '-c', 'user.name=acc', '-c', 'user.email=acc@invalid', 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(path), '-c', 'user.name=acc', '-c', 'user.email=acc@invalid', 'commit', '-qm', 'init'],
                   check=True)
    if claude:
        perf_paths.trust_probe_workspace(CLAUDE_CONFIG, path)
    if codex:
        trust_codex(path)
    return path


def trust_codex(path):
    """The isolated Codex profile trusts the fresh work dir (as earlier real runs did) instead of answering the question."""
    config = CODEX_HOME / 'config.toml'
    text = config.read_text()
    for variant in {str(path), str(path).replace('/private/tmp/', '/tmp/', 1)}:
        header = f'[projects."{variant}"]'
        if header not in text:
            text += f'\n{header}\ntrust_level = "trusted"\n'
    tmp = config.with_suffix('.toml.acctmp')
    tmp.write_text(text)
    tmp.replace(config)


class Cell:
    def __init__(self, name, args):
        self.name, self.args = name, args
        self.base = args.evidence_root / f'{name}-{now()}'
        self.base.mkdir(parents=True)
        self.checks, self.details, self.turns = {}, {}, []
        self.result = 'NOT RUN'

    def check(self, key, ok, detail=None):
        self.checks[key] = bool(ok)
        if detail is not None:
            self.details[key] = detail
        log(f'[{self.name}] {"PASS" if ok else "FAIL"} {key}', '' if detail is None else json.dumps(detail, default=str)[:300])
        return ok

    def save(self):
        self.result = 'PASS' if self.checks and all(self.checks.values()) else ('FAIL' if self.checks else self.result)
        out = {'cell': self.name, 'result': self.result, 'checks': self.checks, 'details': self.details, 'turns': self.turns,
               'source': SOURCE, 'approvals': APPROVALS}
        (self.base / 'result.json').write_text(json.dumps(out, indent=1, default=str))
        return out


def start_from_draft(app, project, harness, model, effort, mode, text):
    """The draft page: a new draft, the model/effort/mode chips, the first message, Send. Returns (session id, requested)."""
    before = set(owners(app.snap('before-start')))
    app.send(f'new-session:{project}')
    time.sleep(1)
    requested = app.request(f'draft-choice:{project}:{harness}:{model}:{effort}:{mode}', 'ack-draft-choice.json')
    app.send(f'draft-text:{project}:{text}')
    time.sleep(.6)
    app.send(f'draft-send:{project}')
    state = app.until('started', lambda s: set(owners(s)) - before, 120)
    return (set(owners(state)) - before).pop(), requested


def native_id(state, sid):
    return (row(state, sid) or {}).get('conversationID') or None


def pending_tool_input(sid_native, harness):
    if not sid_native:
        return ''
    if harness == 'claude':
        uses = claude_tool_uses(sid_native)
        return json.dumps(uses[-1].get('input', {})) if uses else ''
    inputs = list(codex_tool_inputs(sid_native))
    return inputs[-1] if inputs else ''


def answer_once(app, state, sid, harness, allow_words=('SPHYRNA_CLI', 'sphyrna')):
    """One tool approval answered the way the user would in this run: Allow when the pending command (read from the isolated
    transcript) is a Sphyrna command, Deny otherwise. Returns 'accept', 'deny' or None (nothing to answer)."""
    if indicator(state, sid) != 'Needs approval' or state.get('openRequests'):
        return None
    pending = pending_tool_input(native_id(state, sid), harness)
    app.send(f'select:{sid}')
    time.sleep(.5)
    decision = 'accept' if any(w in pending for w in allow_words) else 'deny'
    app.send(f'answer:{sid}:{decision}')
    APPROVALS.append({'session': sid, 'harness': harness, 'decision': decision, 'at': now()})
    time.sleep(2.5)
    return decision


APPROVALS = []


def accept_sphyrna_bash(app, sid, harness, label, timeout, done, allow_words=('SPHYRNA_CLI', 'sphyrna')):
    """Answers the session's tool approvals (answer_once) until `done(state)` holds or the timeout passes."""
    end, answered, denied = time.monotonic() + timeout, 0, 0
    state = None
    while time.monotonic() < end:
        state = app.snap(label)
        if done(state):
            break
        decision = answer_once(app, state, sid, harness, allow_words)
        answered += decision == 'accept'
        denied += decision == 'deny'
        time.sleep(1)
    return state, answered, denied


def type_prompt(app, sid, text):
    app.send(f'select:{sid}')
    time.sleep(.4)
    app.send(f'type:{sid}:{text}')


# ---------------------------------------------------------------- cells

def cell_ordinary(args):
    cell = Cell('ordinary', args)
    work = work_dir(f'ordinary-{now()}', codex=False)
    app = App(args.app, cell.base, label='a').launch()
    try:
        app.send(f'add-project:{work}')
        project = app.until('project', lambda s: len(s['catalog']['projects']) == 1, 30)['catalog']['projects'][0]['id']
        nonce = uuid.uuid4().hex[:6].upper()
        text = (f'Create a file named result.txt containing the single word OK{nonce}, then reply with the word DONE '
                f'followed by the number 4 times 7.')
        sid, requested = start_from_draft(app, project, 'claude', CLAUDE_MODEL, CLAUDE_EFFORT, 'default', text)
        cell.details['requested'] = requested
        seen = []

        def done(s):
            seen.append(indicator(s, sid))
            nid = native_id(s, sid)
            return bool(nid) and claude_has(nid, 'DONE 28', 'assistant') and indicator(s, sid) in ('Ready', 'Finished')
        state, accepted, denied = accept_sphyrna_bash(app, sid, 'claude', 'turn1', 240, done,
                                                      allow_words=('result.txt',))
        nid = native_id(state, sid)
        cell.details['indicatorsSeen'] = [x for i, x in enumerate(seen) if i == 0 or seen[i - 1] != x]
        cell.check('workingSeen', 'Working' in seen)
        cell.check('readyAfterTurn', indicator(state, sid) in ('Ready', 'Finished'), indicator(state, sid))
        cell.check('realOutputReply', bool(nid) and claude_has(nid, 'DONE 28', 'assistant'))
        cell.check('realOutputFile', (work / 'result.txt').exists() and f'OK{nonce}' in (work / 'result.txt').read_text())
        cell.details['approvals'] = {'accepted': accepted, 'denied': denied}
        usage, models = claude_usage(nid) if nid else ({}, [])
        cell.details['reported'] = {'models': models, 'effort': 'not reported by Claude transcript',
                                    'mode': 'see requested; CLI argv not read'}
        cell.check('reportedModelIsHaiku', any('haiku' in m for m in models), models)
        cell.turns.append({'harness': 'claude', 'model': models, 'purpose': 'ordinary first message',
                           'prompts': len(claude_prompts(nid)), 'tokens': usage})
        run_before = (row(state, sid) or {}).get('live')
        app.send(f'stop:{sid}')
        stopped = app.until('stopped', lambda s: not (row(s, sid) or {}).get('live')
                            and sid not in s.get('runtime', {}).get('runningSessions', []), 60)
        cell.check('stopVerified', run_before and not (row(stopped, sid) or {}).get('live'),
                   {'indicator': indicator(stopped, sid), 'lifecycle': (row(stopped, sid) or {}).get('lifecycle')})
        prompts_before = len(claude_prompts(nid))
        app.send(f'resume:{sid}')
        resumed = app.until('resumed', lambda s: (row(s, sid) or {}).get('live') and indicator(s, sid) in ('Ready', 'Idle'), 90)
        time.sleep(15)
        resumed = app.snap('resumed-settled')
        cell.check('resumeSameNative', native_id(resumed, sid) == nid, {'before': nid, 'after': native_id(resumed, sid)})
        cell.check('resumeZeroInput', len(claude_prompts(nid)) == prompts_before)
        cell.check('quit1', app.quit())
        app2 = App(args.app, cell.base, data=app.data, label='b').launch()
        relaunched = app2.snap('relaunched')
        r = row(relaunched, sid)
        cell.check('relaunchKeepsSession', bool(r) and r.get('conversationID') == nid,
                   {'present': bool(r), 'live': (r or {}).get('live'), 'indicator': (r or {}).get('indicator')})
        cell.check('quit2', app2.quit())
    except Exception as error:
        cell.check('noException', False, repr(error))
    finally:
        quit_all()
        cell.save()
    return cell


def child_task(app, parent):
    page = app.tasks('lookup')
    return next((t for t in page.get('tasks', []) if t['parent'] == parent), None)


def drive_child_rounds(cell, app, parent, parent_harness, child_harness, rounds):
    """Prompts typed into the parent ask it to create/reply/interrupt/stop; returns the last task state."""
    app.parent_harness = parent_harness
    allow = ('SPHYRNA_CLI', 'sphyrna')
    child_allow = {'accepted': 0}

    def settle(label, predicate, timeout):
        """Parent approvals for Sphyrna commands, child permission cards allowed, until predicate(task) holds."""
        end, task = time.monotonic() + timeout, None
        while time.monotonic() < end:
            state = app.snap(label)
            answer_once(app, state, parent, parent_harness, allow)
            for request in state.get('openRequests', []):
                if request.get('phase') == 'waiting' and request.get('requester') == parent:
                    cell.details.setdefault('taskCards', []).append(request.get('id'))
                    app.send(f'open-approve:{request["id"]}')
                    time.sleep(2)
            task = child_task(app, parent)
            if task and task.get('presentation') and task['presentation'].get('permissions'):
                ack = app.request(f'task-allow:{task["child"]}', 'ack-task-answer.json')
                child_allow['accepted'] += bool(ack.get('answered'))
                cell.details.setdefault('childPermissionAnswers', []).append(ack)
            if task and predicate(task, state):
                return task, state
            time.sleep(1.5)
        raise TimeoutError(label)

    def completed_events(task):
        return [e for e in task.get('events', []) if e['kind'] == 'completed']

    def parent_idle(state):
        return indicator(state, parent) in ('Ready', 'Finished', 'Waiting for you')

    snapshots = []
    task, state = settle('r1', lambda t, s: len(completed_events(t)) >= 1 and parent_idle(s), 420)
    snapshots.append(task)
    cell.check('round1Completed', len(completed_events(task)) >= 1, task['rounds'])
    if rounds >= 2:
        type_prompt(app, parent, ('Round 2: send a follow-up to the same child task with "$SPHYRNA_CLI" task reply --task '
                                  '<the task id> --message - (stdin text: "Round 2. Run the shell command sleep 45, then '
                                  'report completed with one short sentence naming a yellow fruit."). Then run "$SPHYRNA_CLI" '
                                  'task status --task <the task id> until the new round is active and tell me its round id.'))
        task, state = settle('r2', lambda t, s: len(t['rounds']) >= 2 and t['rounds'][-1]['phase'] == 'active'
                             and parent_idle(s), 300)
        snapshots.append(task)
        type_prompt(app, parent, ('Interrupt that exact active round with "$SPHYRNA_CLI" task interrupt --task <the task id> '
                                  '--round <the active round id> --message - (stdin text: "Round 3 update: skip the sleep and '
                                  'report completed with one short sentence naming a red fruit."). Then wait for its event '
                                  'with "$SPHYRNA_CLI" task wait --task <the task id> --revision <current revision> and '
                                  'tell me the result in one line.'))
        task, state = settle('r3', lambda t, s: len(t['rounds']) >= 3 and len(completed_events(t)) >= 2
                             and parent_idle(s), 420)
        snapshots.append(task)
    type_prompt(app, parent, 'Now stop the child: run "$SPHYRNA_CLI" task stop --task <the task id> and tell me the output.')
    task, state = settle('stop', lambda t, s: t['lifecycle'] in ('stopped', 'stopUnverified') and parent_idle(s), 240)
    snapshots.append(task)
    cell.details['childPermissionsAccepted'] = child_allow['accepted']
    return task, state, snapshots


def cell_cross(args, parent_harness, child_harness):
    name = f'{parent_harness}-{child_harness}'
    cell = Cell(name, args)
    work = work_dir(f'{name}-{now()}')
    app = App(args.app, cell.base, label='a').launch()
    try:
        app.send(f'add-project:{work}')
        project = app.until('project', lambda s: len(s['catalog']['projects']) == 1, 30)['catalog']['projects'][0]['id']
        child_model, child_effort = (CODEX_MODEL, CODEX_EFFORT) if child_harness == 'codex' else (CLAUDE_MODEL, CLAUDE_EFFORT)
        first = ('Delegate a small job to a managed child agent through Sphyrna. Run this Bash command exactly once: '
                 f'printf "Round 1. Reply with one short sentence naming a green vegetable, and report it as completed." | '
                 f'"$SPHYRNA_CLI" task create --name acc-helper --harness {child_harness} --model {child_model} '
                 f'--effort {child_effort} --message - . It prints the task id and then pending until I approve it in '
                 'Sphyrna. After that, run "$SPHYRNA_CLI" task wait --task <the task id> --revision 0 --seconds 60 '
                 '(at most three times until an event arrives), then "$SPHYRNA_CLI" task status --task <the task id>, '
                 'and tell me the child result in one line. Do not do anything else.')
        if parent_harness == 'claude':
            parent, requested = start_from_draft(app, project, 'claude', CLAUDE_MODEL, CLAUDE_EFFORT, 'default', first)
        else:
            parent, requested = start_from_draft(app, project, 'codex', CODEX_MODEL, CODEX_EFFORT, '-', first)
        cell.details['parentRequested'] = requested
        live = []

        def sample():
            s = app.snap('owned')
            procs = owned_processes(app.pid)
            live.extend(p for p in procs if p not in live)
            return s
        task, state, snaps = drive_child_rounds(cell, app, parent, parent_harness, child_harness, args.rounds)
        sample()
        rounds = task['rounds']
        cell.details['rounds'] = rounds
        cell.details['events'] = task['events']
        cell.details['counters'] = {k: task[k] for k in ('childInputLimit', 'childInputsUsed', 'parentWakeLimit',
                                                         'parentWakesUsed', 'parentWakesConsumed', 'uncertainChildEffects',
                                                         'uncertainWakeEffects', 'lifecycle')}
        cell.check('taskCardApproved', bool(cell.details.get('taskCards')))
        cell.check('childHarness', task['harness'] == child_harness, task['harness'])
        cell.check('distinctRoundIDs', len({r['id'] for r in rounds}) == len(rounds) >= min(3, args.rounds + (args.rounds > 1)),
                   [r['id'] for r in rounds])
        child_binding = task.get('childBinding') or {}
        child_native = child_binding.get('nativeSessionID')
        cell.check('childNativeIdentity', bool(child_native), child_binding)
        cell.check('requestedChildSettings', task['requested'].get('model') == child_model, task['requested'])
        cell.details['childEffective'] = task['effective']
        cell.check('childEffectiveModelReported', bool(task['effective'].get('model')), task['effective'])
        parent_state = state
        parent_native = native_id(parent_state, parent)
        if child_harness == 'codex':
            summary = codex_summary(child_native) if child_native else {}
            cell.details['childRollout'] = {k: v for k, v in summary.items() if k != 'turnIDs'}
            cell.check('childRolloutInOwnedProfile', summary.get('rollout') and
                       os.path.realpath(summary.get('cwd') or '') == os.path.realpath(work), summary.get('cwd'))
            cell.check('childModelIsLuna', summary.get('models') == [CODEX_MODEL], summary.get('models'))
            native_turns = set(summary.get('turnIDs') or [])
            cell.check('roundTurnsAreNative', all(r.get('nativeTurnID') in native_turns for r in rounds
                                                  if r.get('nativeTurnID')),
                       [r.get('nativeTurnID') for r in rounds])
            cell.turns.append({'harness': 'codex', 'model': summary.get('models'), 'purpose': 'child rounds',
                               'prompts': summary.get('turnsStarted'), 'tokens': summary.get('tokens'),
                               'weeklyUsedPercent': summary.get('weeklyUsedPercent')})
        else:
            usage, models = claude_usage(child_native) if child_native else ({}, [])
            cell.check('childTranscriptInOwnedProfile', bool(list(claude_records(child_native))) if child_native else False)
            cell.check('childModelIsHaiku', any('haiku' in m for m in models), models)
            cell.turns.append({'harness': 'claude', 'model': models, 'purpose': 'child rounds',
                               'prompts': len(claude_prompts(child_native)) if child_native else 0, 'tokens': usage})
        if parent_harness == 'claude':
            usage, models = claude_usage(parent_native) if parent_native else ({}, [])
            cell.turns.append({'harness': 'claude', 'model': models, 'purpose': 'parent prompts, wakes',
                               'prompts': len(claude_prompts(parent_native)) if parent_native else 0, 'tokens': usage})
        else:
            summary = codex_summary(parent_native) if parent_native else {}
            cell.turns.append({'harness': 'codex', 'model': summary.get('models'), 'purpose': 'parent prompts, wakes',
                               'prompts': summary.get('turnsStarted'), 'tokens': summary.get('tokens'),
                               'weeklyUsedPercent': summary.get('weeklyUsedPercent')})
        child_row = row(parent_state, task['child'])
        cell.details['childRow'] = child_row
        cell.check('childRowOpenedByParent', bool(child_row) and child_row.get('openedBy') == parent, child_row)
        cell.check('childStopped', task['lifecycle'] == 'stopped', task['lifecycle'])
        cell.check('quit', app.quit())
        gone = [p for p in live if alive(p)]
        cell.details['ownedProcessesSeen'] = len(live)
        sockets = sorted({p['socket'] for p in live if p.get('socket')})
        cell.check('ownedProcessesGone', not gone, gone)
        cell.check('ownedSocketsGone', not [s for s in sockets if os.path.exists(s)], sockets)
    except Exception as error:
        cell.check('noException', False, repr(error))
        try:
            cell.details['lastTasks'] = app.tasks('failure') if app.pid else None
            cell.details['lastState'] = {'rows': app.snap('failure')['catalog']['activityRowDetails']} if app.pid else None
        except Exception:
            pass
    finally:
        quit_all()
        cell.save()
    return cell


def cell_changes(args, harness):
    cell = Cell(f'changes-{harness}', args)
    work = work_dir(f'changes-{harness}-{now()}')
    app = App(args.app, cell.base, label='a').launch()
    try:
        app.send(f'add-project:{work}')
        project = app.until('project', lambda s: len(s['catalog']['projects']) == 1, 30)['catalog']['projects'][0]['id']
        model, effort, mode = (CLAUDE_MODEL, CLAUDE_EFFORT, 'default') if harness == 'claude' else (CODEX_MODEL, CODEX_EFFORT, '-')
        sid, requested = start_from_draft(app, project, harness, model, effort, mode,
                                          'Reply with the single word READY and nothing else.')
        state = app.until('first-ready', lambda s: indicator(s, sid) in ('Ready', 'Finished') and native_id(s, sid), 240)
        nid = native_id(state, sid)
        (work / 'alpha.txt').write_text('alpha\nalpha two\n')
        (work / 'beta.txt').write_text('beta\nbeta two\n')
        app.send(f'select:{sid}')
        app.send('inspector:changes')
        time.sleep(1)
        app.send(f'changes-scope:{sid}:branch')
        ch = app.until('ch-read', lambda c: c['read'] == 'ready' and c['fileCount'] == 2, 60,
                       source=lambda label: app.changes(sid, label))
        for index, text in ((0, 'Please keep this line.'), (1, 'Please explain this line.')):
            end = time.monotonic() + 30
            while time.monotonic() < end:
                if app.request(f'changes-comment:{sid}:{index}:{text}', 'ack-changes-comment.json').get('ok'):
                    break
                time.sleep(1)
        ch = app.until('ch-comments', lambda c: c['commentCount'] == 2 and c['availability'] == 'terminal', 60,
                       source=lambda label: app.changes(sid, label))
        cell.check('twoCommentsTwoFiles', ch['commentFileIndexes'] == [0, 1], ch)
        cell.check('sendOfferedForTerminal', ch['sendOffered'] and ch['availability'] == 'terminal', ch)
        prompts_before = len(claude_prompts(nid)) if harness == 'claude' else codex_summary(nid)['turnsStarted']
        app.send(f'changes-send:{sid}')
        sent = app.until('ch-sent', lambda c: c['sendStatus'] in ('sent', 'delivered', 'failed'), 30,
                         source=lambda label: app.changes(sid, label))
        cell.check('footerSent', sent['sendStatus'] in ('sent', 'delivered'), sent['sendStatus'])

        def delivered(s):
            return app.changes(sid, 'ch-watch')['sendStatus'] == 'delivered' and indicator(s, sid) in ('Ready', 'Finished')
        state, accepted, denied = accept_sphyrna_bash(app, sid, harness, 'ch-deliver', 300, delivered)
        final = app.changes(sid, 'ch-final')
        cell.check('footerDelivered', final['sendStatus'] == 'delivered', final['sendStatus'])
        cell.check('exactlySentCommentsCleared', final['commentCount'] == 0, final['commentCount'])
        if harness == 'claude':
            pointers = [r for r in claude_prompts(nid) if 'Sphyrna:' in claude_text(r)]
            inbox_calls = [u for u in claude_tool_uses(nid) if 'inbox' in json.dumps(u.get('input', {}))]
            usage, models = claude_usage(nid)
            prompts = len(claude_prompts(nid))
        else:
            pointers = [t for t in codex_texts(nid, 'user') if 'Sphyrna:' in t]
            inbox_calls = [t for t in codex_tool_inputs(nid) if 'inbox' in t]
            summary = codex_summary(nid)
            usage, models, prompts = summary['tokens'], summary['models'], summary['turnsStarted']
        cell.check('onePointer', len(pointers) == 1, len(pointers))
        cell.check('inboxReadOnce', len(inbox_calls) == 1, len(inbox_calls))
        cell.details['inputsAfterSend'] = prompts - prompts_before
        cell.details['approvals'] = {'accepted': accepted, 'denied': denied}
        cell.turns.append({'harness': harness, 'model': models, 'purpose': 'first message + pointer turn',
                           'prompts': prompts, 'tokens': usage})
        cell.check('quit', app.quit())
    except Exception as error:
        cell.check('noException', False, repr(error))
    finally:
        quit_all()
        cell.save()
    return cell


# ---------------------------------------------------------------- main

def binary_hashes(app):
    macos = app / 'Contents/MacOS'
    out = {}
    for path in sorted(macos.iterdir()):
        if path.is_file():
            out[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    info = subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Print :LoomRevision', str(app / 'Contents/Info.plist')],
                          capture_output=True, text=True).stdout.strip()
    return {'app': str(app), 'LoomRevision': info, 'binaries': out}


SOURCE = {}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', type=pathlib.Path, required=True)
    parser.add_argument('--evidence-root', type=pathlib.Path,
                        default=HOME / 'Library/Caches/loom-v2/evidence/r9/acc')
    parser.add_argument('--cells', default='ordinary,claude-codex,codex-claude,changes-claude,changes-codex')
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    args.app = perf_paths.refuse_documents('App', args.app)
    if any(args.app == p.resolve() for p in FORBIDDEN_APPS if p.exists()):
        raise SystemExit('refusing the user\'s own app')
    running = subprocess.run(['pgrep', '-fl', 'Loom Dev.app/Contents/MacOS/Loom Dev|Loom.app/Contents/MacOS|Sphyrna.app'],
                             capture_output=True, text=True).stdout.strip()
    if running:
        raise SystemExit(f'a Loom/Sphyrna app is running; not running real UI cells:\n{running}')
    args.evidence_root.mkdir(parents=True, exist_ok=True)
    WORK_ROOT.mkdir(parents=True, exist_ok=True)
    SOURCE.update(binary_hashes(args.app))
    results = []
    for name in args.cells.split(','):
        log('=== cell', name)
        if name == 'ordinary':
            cell = cell_ordinary(args)
        elif name in ('claude-codex', 'codex-claude'):
            p, c = name.split('-')
            cell = cell_cross(args, p, c)
        elif name.startswith('changes-'):
            cell = cell_changes(args, name.split('-', 1)[1])
        else:
            raise SystemExit(f'unknown cell {name}')
        results.append(cell.save())
        with open(args.evidence_root / 'TURNS.md', 'a') as ledger:
            for turn in cell.turns:
                ledger.write(f'| {now()} | {cell.name} | {turn["harness"]} | {turn.get("model")} | {turn["purpose"]} | '
                             f'{turn.get("prompts")} inputs recorded | {json.dumps(turn.get("tokens"))} | {cell.result} |\n')
    summary = [{'cell': r['cell'], 'result': r['result'],
                'failed': [k for k, v in r['checks'].items() if not v]} for r in results]
    (args.evidence_root / f'summary-{now()}.json').write_text(json.dumps({'source': SOURCE, 'cells': summary}, indent=1))
    print(json.dumps(summary, indent=1))


if __name__ == '__main__':
    main()
