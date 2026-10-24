#!/usr/bin/env python3
"""Chat stream cost cell (Release B evaluation, step 4; V2-CONCEPT §5.7, first row): one isolated Loom instance, one or more
Chat sessions on the fake provider streaming Markdown text at a fixed rate (`/scenario stream <seconds> <chars/s>`), and
Loom's CPU, total CPU, idle wakeups and footprint sampled over a 60 s window with the matrix cells' sampler
(scripts/cp5-d-measure.py: the app's `resource:…:snapshot`, a sample every 5 s, `interval_metrics`; Chat adds the session
children, which that sampler counts as run leaders outside the pool, to the total).
HEAVY: opens the app window for about two minutes per cell. Run it only when the user says the Mac is idle, inside the
build slot, after the thermal gate, with Finder in front (the script runs `open -a Finder` for a visible cell):
  LOOM_SLOT_TIMEOUT=21600 scripts/with-build-slot.sh scripts/perf/chat_stream_cost.py --app <package>.app --fixtures <dir> \\
      --run-dir <dir> --name chat-visible-600-r1 [--rate 600] [--hidden | --sessions 3 | --long | --variant fence300]
Modes (all at 1220x780):
  (default)    window visible and uncovered, one Chat session.
  --hidden     window closed, one Chat session (no layout, no timers expected).
  --sessions N N Chat sessions streaming at once, window hidden.
  --idle       Chat sessions at rest (combine with --hidden or --sessions N; the window stays visible unless --hidden):
               each runs one short stream turn first (IDLE_TURN_SECONDS at --rate) and the window samples them with no
               turn running; the cell checks that no assistant record falls inside the window.
  --long       the seeded long session: a Chat session is made and stopped, scripts/perf/chat_long_session.py writes about
               10,000 records into its transcript, the app is quit and started again, the session is opened (cold open)
               and resumed, and the stream goes into it; window visible. The open times are recorded.
  --variant V  long blocks in the stream (`/scenario stream <s> <rate> <V>`), window visible, one session: `fence300`
               (cell chat-fence300-<rate>) a 300-line code fence after every third ordinary block; `nested-fence` (cell
               chat-nested-fence-<rate>) a four-backtick fence holding three-backtick fences. The transcript check allows the
               longer gap between assistant records that a long block makes (VARIANT_BLOCK_CHARACTERS).
<fixtures> holds loom-fake-provider (and loom-test-child), outside ~/Documents. --app is a package under
Loom-Dev/packages/<name> (never the installed app). The cell is run-dir/cells/<name>/ (result.json, samples.json,
manifest.json, app.log, the app's evidence files and its isolated data/ root); an existing cell of that name is moved aside.
The stream outlasts the window by --tail seconds. Content is counted, never recorded. Exit 0 when the cell is valid.
  scripts/perf/chat_stream_cost.py --summarize <run-dir>   prints one line per cell."""
import argparse, atexit, datetime, hashlib, json, os, pathlib, signal, statistics, subprocess, sys, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import perf_paths
from perf_paths import REPO, load_module

SIZE = (1220, 780)
IDLE_TURN_SECONDS = 2
# The variants' long block, in characters (an upper bound): a message cannot end inside it, so the gap between two assistant
# records can grow by its streaming time.
VARIANT_BLOCK_CHARACTERS = {'fence300': 12000, 'nested-fence': 4500}


def summarize(run_dir):
    for path in sorted((run_dir / 'cells').glob('*/result.json')):
        if '.invalid-' in path.parent.name:
            continue
        r = json.loads(path.read_text()); m = r.get('metrics', {}); f = m.get('appFootprintMiB') or {}
        t = m.get('totalFootprintMiB') or {}
        fmt = lambda v: 'n/a' if v is None else f'{v:.2f}'
        print(f"{path.parent.name:<34} {'valid' if r.get('valid') else 'INVALID':<8} app {fmt(m.get('appCPUPercentOfOneCore'))}  "
              f"total {fmt(m.get('totalLoomCPUPercentOfOneCore'))}  idle wakeups/s app {fmt(m.get('appIdleWakeupsPerSecond'))} "
              f"total {fmt(m.get('totalIdleWakeupsPerSecond'))}  footprint MiB app {fmt(f.get('median'))} total {fmt(t.get('median'))}"
              + ('' if r.get('valid') else '  ' + '; '.join(r.get('invalidReasons', []))[:160]))


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--summarize', type=pathlib.Path, default=None, help='print the cells of a run dir and exit')
parser.add_argument('--app', type=pathlib.Path, help='the package (Loom Dev.app) under test')
parser.add_argument('--fixtures', type=pathlib.Path, help='directory with loom-fake-provider')
parser.add_argument('--run-dir', type=pathlib.Path, default=None)
parser.add_argument('--name', default=None, help='cell name (default: chat-<visible|hidden|sessionsN|long>-<rate>)')
parser.add_argument('--rate', type=int, default=600, help='characters per second of the stream')
parser.add_argument('--warmup', type=float, default=10)
parser.add_argument('--duration', type=float, default=60, help='sample window, seconds')
parser.add_argument('--sample-every', type=float, default=5)
parser.add_argument('--tail', type=float, default=20, help='seconds the stream outlasts the window')
parser.add_argument('--hidden', action='store_true')
parser.add_argument('--sessions', type=int, default=1)
parser.add_argument('--long', action='store_true')
parser.add_argument('--idle', action='store_true', help='Chat sessions at rest after one short turn each')
parser.add_argument('--variant', choices=sorted(VARIANT_BLOCK_CHARACTERS), default=None,
                    help='a stream with long blocks (visible, one session)')
parser.add_argument('--records', type=int, default=10000, help='transcript records of the long session')
parser.add_argument('--screenshot', action='store_true',
                    help='after the window, while the stream goes on: Loom\'s own window-only capture (screenshot-window.window.png in the cell)')
parser.add_argument('--activate', action='store_true', help='make the app frontmost (the matrix cells do not)')
parser.add_argument('--ack-timeout', type=float, default=30)
args = parser.parse_args()
if args.summarize:
    summarize(args.summarize); sys.exit(0)
if not args.app or not args.fixtures:
    parser.error('--app and --fixtures are required')
if args.long and (args.hidden or args.sessions > 1):
    parser.error('--long is a visible, single-session cell')
if args.sessions < 1 or args.rate < 1 or min(args.warmup, args.duration, args.tail) < 0 or args.sample_every <= 0:
    parser.error('sessions, rate, durations must be positive')
if args.long and args.idle:
    parser.error('--long and --idle do not combine')
if args.variant and (args.long or args.idle or args.hidden or args.sessions > 1):
    parser.error('--variant is a visible, single-session stream cell')
if args.sessions > 1 and not args.idle:
    args.hidden = True      # several streaming sessions are measured with the window hidden
app, run_dir = perf_paths.resolve_common(argparse.Namespace(app=args.app, run_dir=args.run_dir), 'chat-stream')
fixtures = perf_paths.refuse_documents('Fixtures directory', args.fixtures)
if not (fixtures / 'loom-fake-provider').is_file():
    sys.exit(f'{fixtures}/loom-fake-provider is missing')
executable = app / 'Contents/MacOS/Loom Dev'
if not executable.is_file():
    sys.exit(f'not a Loom Dev package: {executable}')

measure = load_module('cp5_d_measure', REPO / 'scripts/cp5-d-measure.py')
visibility = 'hidden' if args.hidden else 'visible'
name = args.name or ((f'chat-idle-sessions{args.sessions}-{visibility}' if args.sessions > 1 else f'chat-idle-{visibility}')
                     if args.idle else 'chat-long-%d' % args.rate if args.long
                     else f'chat-{args.variant}-{args.rate}' if args.variant
                     else f'chat-sessions{args.sessions}-{args.rate}' if args.sessions > 1 else f'chat-{visibility}-{args.rate}')
cell = run_dir / 'cells' / name
if cell.exists():
    cell.rename(cell.with_name(name + f'.invalid-{int(time.time())}'))
cell.mkdir(parents=True)
data = cell / 'data'
config = data / 'claude-config'
project = cell / 'project'
project.mkdir()
stream_seconds = IDLE_TURN_SECONDS if args.idle else args.warmup + args.duration + args.tail + 4 * args.sessions
stream_command = f'/scenario stream {stream_seconds} {args.rate}' + (f' {args.variant}' if args.variant else '')
max_record_gap = 8 + VARIANT_BLOCK_CHARACTERS.get(args.variant, 0) / args.rate
report = {'valid': False, 'invalidReasons': []}
state = {'driver': None, 'cleaned': False}


# ---- app control -----------------------------------------------------------------------------------------------------
def make_driver():
    ns = argparse.Namespace(app=app, renderer='coregraphics', material='system', visibility=visibility,
                            ack_timeout=args.ack_timeout, launch_services=False, scenario='chat-stream', output=cell)
    return measure.Driver(ns, cell)


def send(text):
    measure.send(text, cell)


def fresh(command, filename, timeout=25):
    path = cell / filename
    path.unlink(missing_ok=True)
    send(command)
    return measure.wait_json(path, timeout)


def snapshot(label='s'):
    return fresh('snapshot:' + label, f'state-{label}.json', 20)


def until(predicate, timeout, what, interval=0.3):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            value = predicate()
        except (TimeoutError, ValueError, KeyError, TypeError):
            value = None
        if value:
            return value
        time.sleep(interval)
    raise RuntimeError('timeout: ' + what)


def launch(driver):
    for stale in ('launched.json', 'quit.json'):
        (cell / stale).unlink(missing_ok=True)
    if subprocess.run(['pgrep', '-f', '--', str(executable)], stdout=subprocess.DEVNULL).returncode == 0:
        sys.exit('this package is already running; use a package of your own')
    perf_paths.seed_remora_off(data)
    log = (cell / 'app.log').open('ab')
    driver.log = log
    driver.process = subprocess.Popen([str(executable), '--evidence', str(cell), '--data-root', str(data),
                                       '--fake-providers', str(fixtures)], stdout=log, stderr=subprocess.STDOUT)
    launched = measure.wait_json(cell / 'launched.json', args.ack_timeout)
    if launched.get('pid') != driver.process.pid:
        raise ValueError('launched.json does not belong to the app PID')
    driver.app_identity = measure.identity(driver.process.pid)
    until(lambda: (lambda c: c['ready'] and c['actionsAvailable'])(snapshot('ready')['catalog']), 60, 'app ready')


def front(pid):
    subprocess.run(['osascript', '-e', f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'],
                   capture_output=True, timeout=15)
    time.sleep(.8)


def prepare_window(driver, add_project=True):
    """1220x780, the project, and the window state of the mode (hidden: closed; visible: Finder in front, checked)."""
    send('view-mode:activity'); send(f'resize:{SIZE[0]}x{SIZE[1]}'); time.sleep(1.0)
    project_id = None
    if add_project:
        send('add-project:' + str(project))
        project_id = until(lambda: (snapshot('project')['catalog']['projects'] or [None])[0], 30, 'project added')['id']
    else:
        project_id = snapshot('project')['catalog']['projects'][0]['id']
    if args.hidden:
        driver.operation('hide')
    elif args.activate:
        front(driver.process.pid)
    driver.await_initial_visibility()
    return project_id


def quit_driver(driver):
    if state['cleaned'] or driver is None or driver.process is None:
        return None
    state['cleaned'] = True
    return driver.cleanup()


def safety_net():
    """The EXIT trap: quit the app however the script ends; kill its pid only if it is still alive 12 s after Quit."""
    driver = state['driver']
    if driver is not None and driver.process is not None and not state['cleaned']:
        pid = driver.process.pid
        try:
            send('quit')
        except Exception:
            pass
        end = time.monotonic() + 12
        while time.monotonic() < end and measure.identity(pid) == driver.app_identity:
            time.sleep(.2)
        if measure.identity(pid) == driver.app_identity:
            try: os.kill(pid, signal.SIGKILL)
            except OSError: pass
    try:
        (cell / 'result.json').write_text(json.dumps(report, indent=2, default=str))
    except Exception:
        pass


atexit.register(safety_net)
for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(_sig, lambda *_: sys.exit(130))


# ---- Chat sessions -----------------------------------------------------------------------------------------------------
known_sessions = set()


def start_chat(project_id, message=''):
    """chat-start, then the id of the session it made (chat-state reports the newest one)."""
    send(f'chat-start:{project_id}' + (f':{message}' if message else ''))
    def made():
        s = fresh('chat-state:cs', 'chat-state-cs.json', 10)
        return s.get('sessionID') if s.get('driver') and s.get('sessionID') not in known_sessions else None
    sid = until(made, 30, 'chat-start made a session')
    known_sessions.add(sid)
    # chat-start selects the id before the catalog knows the session, which drops it: select it now, as a click does.
    send(f'select:{sid}'); time.sleep(1.0)
    if (cell / 'chat-error-chat-start.json').exists():
        raise RuntimeError('chat-start failed: ' + (cell / 'chat-error-chat-start.json').read_text())
    return sid


def transcript_path(sid):
    found = sorted((config / 'projects').glob(f'*/{sid}.jsonl'))
    return found[0] if found else None


def parse_time(text):
    return datetime.datetime.fromisoformat(text.replace('Z', '+00:00')).timestamp()


def verify_stream(sid, since, expected_chars, window_start, window_end):
    """What the session's transcript says about the stream (counts and times only): characters of assistant text since
    `since` (wall seconds), tool calls, the longest gap between assistant records, and whether the stream ran the whole window."""
    path = transcript_path(sid)
    if path is None:
        return {'session': sid, 'valid': False, 'reason': 'no transcript'}
    chars = tools = 0
    times = []
    for line in path.read_text(errors='replace').splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get('type') != 'assistant' or parse_time(record['timestamp']) < since:
            continue
        times.append(parse_time(record['timestamp']))
        for block in record['message']['content']:
            chars += len(block.get('text', '')) if block.get('type') == 'text' else 0
            tools += block.get('type') == 'tool_use'
    gaps = [b - a for a, b in zip(times, times[1:])]
    ratio = chars / expected_chars if expected_chars else None
    ok = (bool(times) and ratio is not None and 0.95 <= ratio <= 1.05 and tools >= 1 and times[-1] >= window_end and max(gaps, default=0) <= max_record_gap)
    return {'session': sid, 'valid': ok, 'characters': chars, 'expectedCharacters': expected_chars, 'ratio': ratio,
            'toolCalls': tools, 'assistantRecords': len(times), 'maxGapSeconds': max(gaps, default=None),
            'maxGapAllowedSeconds': max_record_gap,
            'firstRecordBeforeWindow': bool(times) and times[0] <= window_start,
            'lastRecordAfterWindow': bool(times) and times[-1] >= window_end}


def verify_idle(sid, since, window_start, window_end):
    """What an idle session's transcript says (counts and times only): its short turn wrote assistant records before the
    window, and none falls inside it."""
    path = transcript_path(sid)
    if path is None:
        return {'session': sid, 'valid': False, 'reason': 'no transcript'}
    times = []
    for line in path.read_text(errors='replace').splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get('type') == 'assistant' and parse_time(record['timestamp']) >= since:
            times.append(parse_time(record['timestamp']))
    inside = [t for t in times if window_start <= t <= window_end]
    return {'session': sid, 'valid': bool(times) and not inside, 'assistantRecords': len(times), 'recordsInWindow': len(inside)}


def chat_view(sid, label='cv'):
    return fresh(f'chat-view:{sid}:{label}', f'chat-view-{label}.json', 10)


# ---- metrics -----------------------------------------------------------------------------------------------------------
def mib(value):
    return value / 2**20


def spread(values):
    return {'median': statistics.median(values), 'max': max(values), 'first': values[0], 'last': values[-1]} if values else None


def chat_metrics(samples):
    """interval_metrics (app, run hosts, WindowServer, footprints) plus the Chat session children: the sampler files them
    under `supervisorRuns` (run leaders) and its total leaves them out."""
    metrics = measure.interval_metrics(samples)
    first, last = samples[0]['result'], samples[-1]['result']
    span = last['uptime'] - first['uptime']
    def cpu(a, b):
        return ((b['userTimeNanoseconds'] + b['systemTimeNanoseconds']) - (a['userTimeNanoseconds'] + a['systemTimeNanoseconds'])) / 1e9 / span * 100
    def wakeups(a, b):
        return (b['packageIdleWakeups'] - a['packageIdleWakeups']) / span
    runs_a = {r['runID']: r for r in first['supervisorRuns']}
    runs_b = {r['runID']: r for r in last['supervisorRuns']}
    if set(runs_a) != set(runs_b) or any(runs_a[k]['identity'] != runs_b[k]['identity'] for k in runs_a):
        raise ValueError('Chat session set changed inside the window')
    members_a, members_b = measure.scope_members(first), measure.scope_members(last)
    chat_cpu = {k: cpu(runs_a[k]['usage'], runs_b[k]['usage']) for k in runs_a}
    host_idle = sum(wakeups(members_a[p]['usage'], members_b[p]['usage']) for p in members_a)
    chat_idle = sum(wakeups(runs_a[k]['usage'], runs_b[k]['usage']) for k in runs_a)
    if metrics['totalLoomCPUPercentOfOneCore'] is None:
        raise ValueError('Loom CPU could not be summed (a scope member has no usage)')
    metrics['totalLoomCPUExcludingChatSessionsPercentOfOneCore'] = metrics['totalLoomCPUPercentOfOneCore']
    metrics['chatSessionCPUPercentOfOneCore'] = list(chat_cpu.values())
    metrics['totalLoomCPUPercentOfOneCore'] = metrics['totalLoomCPUPercentOfOneCore'] + sum(chat_cpu.values())
    metrics['chatSessionCount'] = len(runs_a)
    metrics['appIdleWakeupsPerSecond'] = wakeups(first['appUsage'], last['appUsage'])
    metrics['appInterruptWakeupsPerSecond'] = (last['appUsage']['interruptWakeups'] - first['appUsage']['interruptWakeups']) / span
    metrics['totalIdleWakeupsPerSecond'] = metrics['appIdleWakeupsPerSecond'] + host_idle + chat_idle
    app_fp = [s['result']['appUsage']['physicalFootprintBytes'] for s in samples]
    total_fp = [s['result']['appUsage']['physicalFootprintBytes']
                + sum(m['usage']['physicalFootprintBytes'] for m in measure.scope_members(s['result']).values())
                + sum(r['usage']['physicalFootprintBytes'] for r in s['result']['supervisorRuns']) for s in samples]
    metrics['appFootprintMiB'] = spread([mib(v) for v in app_fp])
    metrics['totalFootprintMiB'] = spread([mib(v) for v in total_fp])
    return metrics


def sample_window(driver):
    """The matrix cells' loop: warm-up already done; a sample every --sample-every for --duration."""
    start = driver.sample()
    start_usage = measure.resource.getrusage(measure.resource.RUSAGE_SELF)
    clock = time.monotonic()
    samples = [start]
    while time.monotonic() - clock < args.duration:
        time.sleep(min(args.sample_every, max(0, args.duration - (time.monotonic() - clock))))
        current = driver.sample()
        if len(current['result']['supervisorRuns']) != args.sessions or not all(
                r['identityMatches'] and r['usage'] for r in current['result']['supervisorRuns']):
            raise ValueError(f'expected {args.sessions} live Chat session children, saw {len(current["result"]["supervisorRuns"])}')
        samples.append(current)
    end_usage = measure.resource.getrusage(measure.resource.RUSAGE_SELF)
    changes = [e for e in samples[-1]['app'].get('visibilityEvents', [])
               if samples[0]['result']['uptime'] <= e['uptime'] <= samples[-1]['result']['uptime']]
    if changes:
        raise ValueError('Visibility changed inside measurement interval')
    (cell / 'samples.json').write_text(json.dumps(samples, indent=2))
    return samples, (end_usage.ru_utime + end_usage.ru_stime) - (start_usage.ru_utime + start_usage.ru_stime)


# ---- the cell ----------------------------------------------------------------------------------------------------------
def run():
    caffeine = subprocess.Popen(['/usr/bin/caffeinate', '-dimsu', '-w', str(os.getpid())])
    try:
        return run_cell()
    finally:
        if caffeine.poll() is None:
            caffeine.terminate()


def run_cell():
    started_wall = time.time()
    if not args.hidden:
        subprocess.run(['open', '-a', 'Finder'], check=False, timeout=30)   # the window must not be covered
        time.sleep(2)
    driver = make_driver()
    state['driver'] = driver
    manifest = {'cell': name, 'mode': {'visibility': visibility, 'sessions': args.sessions, 'long': args.long, 'idle': args.idle,
                                         'variant': args.variant},
                'rate': args.rate, 'streamSeconds': stream_seconds, 'window': f'{SIZE[0]}x{SIZE[1]}',
                'warmup': args.warmup, 'duration': args.duration, 'sampleEvery': args.sample_every,
                'app': str(app), 'binarySHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
                'fakeProviderSHA256': hashlib.sha256((fixtures / 'loom-fake-provider').read_bytes()).hexdigest(),
                'activated': args.activate, 'launch': 'direct exec (as the matrix cells)', 'driverPID': os.getpid()}
    (cell / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    long_info = None
    sessions = []
    launch(driver)
    project_id = prepare_window(driver) if not args.long else None
    if args.long:
        long_info = {}
        project_id = prepare_window(driver)
        sid = start_chat(project_id, 'Seed this session.')
        until(lambda: transcript_path(sid), 30, 'the fake provider wrote its first transcript')
        until(lambda: not fresh('chat-state:cs', 'chat-state-cs.json', 10).get('turnRunning'), 30, 'first turn over')
        send(f'chat-stop:{sid}'); time.sleep(3)
        # The fake's transcript folder is where the app looks: replace the file there by the long one.
        generator = load_module('chat_long_session', pathlib.Path(__file__).resolve().parent / 'chat_long_session.py')
        existing = transcript_path(sid)
        cwd = None
        for line in existing.read_text().splitlines():
            cwd = cwd or json.loads(line).get('cwd')
        cwd = cwd or os.path.realpath(project)
        long_info['seed'] = generator.write_long_transcript(config, cwd, sid, args.records, folder=existing.parent.name)
        if transcript_path(sid) != existing:
            raise RuntimeError('the long transcript went to another folder than the fake provider\'s')
        cleanup_first = quit_driver(driver)
        long_info['firstInstanceQuit'] = cleanup_first
        state['cleaned'] = False
        driver = make_driver(); state['driver'] = driver
        launch(driver)
        project_id = prepare_window(driver, add_project=False)
        # Cold open as the user does it: select the stopped session; time until its chat is built from the transcript tail.
        t0 = time.monotonic()
        send(f'select:{sid}')
        def opened():
            view = chat_view(sid, 'open')
            return view if view.get('feed') and view.get('phase') == 'ready' and view.get('rows', 0) > 0 else None
        try:
            view = until(opened, 60, 'the session opened', interval=0.1)
            long_info['selectToHistoryRowsSeconds'] = time.monotonic() - t0
            long_info['historyRows'] = {k: view.get(k) for k in ('entries', 'rows', 'rowKinds', 'hasOlder', 'phase', 'viewMode')}
        except RuntimeError:
            long_info['selectToHistoryRowsSeconds'] = None
            long_info['historyRows'] = chat_view(sid, 'open-last')
        long_info['transcriptRecords'] = long_info['seed']['records']
        long_info['transcriptBytes'] = long_info['seed']['bytes']
        since = time.time()
        t1 = time.monotonic()
        send(f'chat-send:{sid}:{stream_command}')
        def live():
            view = chat_view(sid, 'live')
            return view if view.get('feed') and 'running' in ' '.join(map(str, view.get('turns', []))).lower() else None
        try:
            view = until(live, 60, 'the resumed session streams', interval=0.1)
            long_info['sendToLiveSeconds'] = time.monotonic() - t1
            long_info['liveRows'] = {k: view.get(k) for k in ('entries', 'rows', 'rowKinds', 'hasOlder', 'turns')}
        except RuntimeError:
            long_info['sendToLiveSeconds'] = None
        sessions = [(sid, since)]
    else:
        for i in range(args.sessions):
            since = time.time()
            sid = start_chat(project_id, stream_command)
            sessions.append((sid, since))
            if args.idle:   # the turn has written, then ended (chat-state reports the newest session: this one)
                until(lambda: transcript_path(sid), 30, 'the short turn wrote its transcript')
                until(lambda: not fresh('chat-state:cs', 'chat-state-cs.json', 10).get('turnRunning'), 30, 'the short turn ended')
            time.sleep(1.0)
    time.sleep(args.warmup)
    window_start = time.time()
    route = snapshot('window')['catalog'].get('route')
    samples, observer_cpu = sample_window(driver)
    window_end = time.time()
    if not args.hidden and route != 'chat':
        report['invalidReasons'].append(f'the selected session was not shown as a Chat (route {route})')
    if args.screenshot and not args.hidden:
        send('screenshot:window'); time.sleep(3)
    if args.long:
        long_info['liveRowsAtWindowEnd'] = chat_view(sessions[0][0], 'end')
    if args.idle:
        verification = [verify_idle(sid, since, window_start, window_end) for sid, since in sessions]
    else:
        # The stream ends by itself; wait for the last of them, then read the transcripts.
        last_end = max(since for _, since in sessions) + stream_seconds
        time.sleep(max(0, last_end + 6 - time.time()))
        verification = [verify_stream(sid, since, stream_seconds * args.rate, window_start, window_end) for sid, since in sessions]
    for item in verification:
        if not item.get('valid'):
            report['invalidReasons'].append(f"{'idle' if args.idle else 'stream'} of session {item['session'][:8]} not as asked: "
                                            f"{json.dumps(item)}")
    report.update({'scenario': 'chat-idle' if args.idle else f'chat-stream-{args.rate}' + (f'-{args.variant}' if args.variant else ''), 'cell': manifest['mode'] | {'name': name, 'rate': args.rate},
                   'sampleSeconds': samples[-1]['result']['uptime'] - samples[0]['result']['uptime'],
                   'warmupSeconds': args.warmup, 'sampleCount': len(samples), 'streamSeconds': stream_seconds,
                   'route': route, 'metrics': chat_metrics(samples), 'streamVerification': verification,
                   'observerCPUSeconds': observer_cpu, 'effectiveSidebarMaterial': driver.effective_material,
                   'windowWallClock': {'start': window_start, 'end': window_end, 'cellStart': started_wall}})
    if long_info is not None:
        report['longSession'] = long_info
    report['cleanup'] = quit_driver(driver)


try:
    run()
except Exception as error:
    report['invalidReasons'].append(f'{type(error).__name__}: {error}')
finally:
    try:
        if state['driver'] is not None and not state['cleaned']:
            report['cleanup'] = quit_driver(state['driver'])
    except Exception as error:
        report['invalidReasons'].append('Cleanup: ' + str(error))
    report['valid'] = not report['invalidReasons']
    (cell / 'result.json').write_text(json.dumps(report, indent=2, default=str))
    print(cell)
    m = report.get('metrics', {})
    print(json.dumps({'valid': report['valid'], 'invalidReasons': report['invalidReasons'],
                      'app': m.get('appCPUPercentOfOneCore'), 'total': m.get('totalLoomCPUPercentOfOneCore'),
                      'appIdleWakeupsPerSecond': m.get('appIdleWakeupsPerSecond')}))
sys.exit(0 if report['valid'] else 1)
