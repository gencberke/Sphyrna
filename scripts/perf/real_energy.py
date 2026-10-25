#!/usr/bin/env python3
"""r7 (RESCUE-PLAN Phase B): the user's real scenarios, measured the way Activity Monitor shows them.

Each cell runs WINDOW seconds (default 60) and records, for the app process: CPU % of one core and idle wakeups/s
(proc_pid_rusage), and the energy score `top` reports in its POWER column (the number Activity Monitor's Energy tab shows).
The session processes the app started (run hosts, the fake provider) and WindowServer are recorded apart, so the app's own
cost is never mixed with a provider's.

Cells: home idle; the new-session page idle; typing on that page (the draft grows by one
character every 200 ms); one terminal session working silently; one terminal session streaming about 1 MiB/s; Home while
another session's transcript grows. `--terminal-app` adds Terminal.app showing the same 1 MiB/s output, as the baseline a
plain terminal sets. `--sidebar transparent` launches the app with the Transparent sidebar (the style is a launch flag,
`--evidence-transparency`, not a command), and `--cells a,b` measures only the named cells.

HEAVY (about 12 minutes per package on screen, launches the app, brings it to the front): run only when the user says the
Mac is idle. Keeps the display awake with caffeinate while it runs.
Usage: scripts/perf/real_energy.py <fixtures-dir> --app '<package>/Loom Dev.app' [--label NAME] [--terminal-app]
Output: <run-dir>/<label>/{evidence/,data/,result.json}."""
import argparse, json, os, pathlib, re, subprocess, sys, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import perf_paths
from indicator_cost_lib import WINDOW, usage, send, snap, until

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('fixtures', type=pathlib.Path)
parser.add_argument('--label', default='energy')
parser.add_argument('--terminal-app', action='store_true', help='also measure Terminal.app with the same output')
parser.add_argument('--sidebar', choices=['solid', 'transparent'], default='solid')
parser.add_argument('--cells', default='', help='comma-separated cell labels to measure (default: all)')
perf_paths.add_common_arguments(parser, 'energy')
args = parser.parse_args()
app_path, run_dir = perf_paths.resolve_common(args, 'energy')
fixtures = perf_paths.refuse_documents('Fixtures directory', args.fixtures)
root = run_dir / args.label
app = str(app_path)
STREAM_TEXT = 'stream output line 0123456789 abcdefghijklmnopqrstuvwxyz 0123456789\r\n'


def pids_of(pattern):
    out = subprocess.run(['pgrep', '-f', pattern], capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]


def session_pids(exclude):
    """The processes this run started besides the app: run hosts under the package and the fixture copies."""
    found = set(pids_of(re.escape(str(fixtures))) + pids_of(re.escape(app + '/Contents/Library')) + pids_of('LoomRunHost'))
    return sorted(p for p in found if p not in exclude)


def top_power(pids, seconds):
    """Starts `top` for the window; returns a function that waits for it and gives {pid: (power, cpu)}."""
    command = ['top', '-l', '2', '-s', str(int(seconds)), '-stats', 'pid,power,cpu']
    for p in pids:
        command += ['-pid', str(p)]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def finish():
        text = process.communicate()[0]
        # The second sample is the one that covers the window.
        sample = text.split('PID')[-1] if text.count('PID') >= 2 else ''
        result = {}
        for line in sample.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 3 and parts[0].isdigit():
                try:
                    result[int(parts[0])] = (float(parts[1]), float(parts[2]))
                except ValueError:
                    pass
        return result
    return finish


def cpu_seconds(pids):
    total = 0.0
    for p in pids:
        try:
            total += usage(p)['cpu']
        except OSError:
            pass
    return total


def measure(label, app_pid, d=None, during=None, window=None):
    window = window or WINDOW
    if args.cells and label not in args.cells.split(','):
        return None
    window_server = pids_of('/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer')
    children = session_pids({app_pid}) if app_pid else []
    watched = ([app_pid] if app_pid else []) + children + window_server
    finish = top_power(watched, window)
    a = usage(app_pid) if app_pid else None
    child_a = cpu_seconds(children)
    start = time.monotonic()
    if during:
        during(window)
    else:
        time.sleep(window)
    elapsed = time.monotonic() - start
    b = usage(app_pid) if app_pid else None
    child_b = cpu_seconds(children)
    power = finish()
    row = {'label': label, 'seconds': round(elapsed, 1)}
    if app_pid:
        row.update(appCPUPercent=round(100 * (b['cpu'] - a['cpu']) / elapsed, 2),
                   appIdleWakeupsPerSec=round((b['idleWakeups'] - a['idleWakeups']) / elapsed, 1),
                   appFootprintMiB=round(b['footprint'] / 2**20, 1),
                   appPower=power.get(app_pid, (None, None))[0])
    row.update(sessionCPUPercent=round(100 * (child_b - child_a) / elapsed, 2), sessionPids=len(children),
               sessionPower=round(sum(power.get(p, (0, 0))[0] for p in children), 1),
               windowServerPower=round(sum(power.get(p, (0, 0))[0] for p in window_server), 1),
               windowServerCPU=round(sum(power.get(p, (0, 0))[1] for p in window_server), 1))
    if d:
        state = snap(d, f'w-{label}')
        row['window'] = {k: state.get(k) for k in ('appActive', 'windowVisible', 'windowOcclusionVisible')}
    print(json.dumps(row), flush=True)
    return row


def add(results, row):
    if row:
        results['rows'].append(row)


def front(path):
    subprocess.run(['open', '-a', 'Finder'])
    time.sleep(1)
    subprocess.run(['open', '-a', path])
    time.sleep(3)


def seed_preferences(data):
    """Remora on as the user keeps it, with the brief only on request so no cell makes a call; the rest as shipped."""
    path = pathlib.Path(data) / 'ui-preferences.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    stored = json.loads(path.read_text()) if path.exists() else {}
    stored['remora'] = (stored.get('remora') or {}) | {'isOn': True, 'briefMode': 'whenIAsk'}
    path.write_text(json.dumps(stored, indent=2, sort_keys=True) + '\n')


def sphyrna_cells(results):
    d = str(root / 'evidence'); data = str(root / 'data')
    os.makedirs(d, exist_ok=True)
    if pids_of(re.escape(app + '/Contents/MacOS/Loom Dev')):
        raise SystemExit('Loom Dev already running')
    seed_preferences(data)
    project = perf_paths.WORK_ROOT / f'{args.label}-project'
    project.mkdir(parents=True, exist_ok=True)
    subprocess.run(['git', 'init', '-q', str(project)], check=False)
    subprocess.run(['open', '-n', '-a', app, '--args', '--evidence', d, '--data-root', data, '--fake-providers', str(fixtures),
                    '--evidence-transparency', args.sidebar], check=True)
    end = time.time() + 30
    while not (pathlib.Path(d) / 'launched.json').exists():
        if time.time() > end:
            raise TimeoutError('launch')
        time.sleep(0.2)
    pid = pids_of(re.escape(app + '/Contents/MacOS/Loom Dev'))[0]
    results['pid'] = pid
    try:
        until(d, 'ready', lambda s: s['catalog']['ready'] and s['catalog']['actionsAvailable'], 30)
        send(d, 'live-chat:off')  # 1.6.2 starts in Chat by default; these cells measure the terminal face
        send(d, f'add-project:{project}')
        state = until(d, 'project', lambda s: len(s['catalog']['projects']) >= 1, 20)
        project_id = state['catalog']['projects'][0]['id']
        front(app)
        send(d, 'show-home'); time.sleep(5)
        add(results, measure('home-idle', pid, d))
        send(d, f'new-session:{project_id}'); time.sleep(5)
        add(results, measure('newsession-idle', pid, d))

        def typing(seconds):
            text = ''
            stop = time.monotonic() + seconds
            words = 'bu bir deneme metni ve yeni oturum sayfasinda yaziliyor '
            i = 0
            while time.monotonic() < stop:
                text += words[i % len(words)]; i += 1
                send(d, f'draft-text:{project_id}:{text}')
                time.sleep(0.2)
        add(results, measure('newsession-typing', pid, d, during=typing))
        send(d, f'draft-discard:{project_id}')
        send(d, 'show-home'); time.sleep(2)

        # Another session's transcript grows while Home shows (the usage watcher's path).
        profiles = [p for p in pathlib.Path(data).rglob('projects') if p.is_dir()]
        if profiles:
            folder = profiles[0] / '-private-tmp-r7-other'
            folder.mkdir(parents=True, exist_ok=True)
            transcript = folder / '00000000-0000-4000-8000-000000000001.jsonl'
            line = json.dumps({'type': 'assistant', 'timestamp': '2026-10-25T23:00:00.000Z',
                               'message': {'id': 'm', 'model': 'claude-opus-5-5', 'role': 'assistant',
                                           'content': [{'type': 'text', 'text': 'x' * 2000}],
                                           'usage': {'input_tokens': 1, 'output_tokens': 1}}}) + '\n'

            def grow(seconds):
                stop = time.monotonic() + seconds
                with open(transcript, 'a') as handle:
                    while time.monotonic() < stop:
                        handle.write(line); handle.flush(); time.sleep(0.2)
            add(results, measure('home-idle-transcript-growing', pid, d, during=grow))
        else:
            results['skipped'] = 'no projects folder in the run profile'

        send(d, f'start:claude:{project_id}')
        state = until(d, 'live', lambda s: len(s.get('conversationTerminals', [])) == 1
                      and 'READY' in (s['conversationTerminals'][0]['screenTail'] or ''), 40)
        owner = state['conversationTerminals'][0]['owner']
        send(d, f'type:{owner}:/work 300000'); time.sleep(5)
        add(results, measure('terminal-working-silent', pid, d))
        send(d, f'stop:{owner}'); time.sleep(4)
        send(d, f'resume:{owner}')
        until(d, 'live2', lambda s: len(s.get('conversationTerminals', [])) == 1
              and 'READY' in (s['conversationTerminals'][0]['screenTail'] or ''), 40)
        send(d, f'type:{owner}:/stream {WINDOW + 20}'); time.sleep(5)
        add(results, measure('terminal-stream-1MiBps', pid, d))
    finally:
        send(d, 'quit')
        time.sleep(8)
        subprocess.run(['pkill', '-f', str(fixtures / 'loom-fake-provider')], capture_output=True)


def terminal_app_cells(results):
    generator = root / 'stream_gen.py'
    generator.write_text('import sys, time\n'
                         f'text = {json.dumps(STREAM_TEXT * 220)}\n'
                         'end = time.time() + float(sys.argv[1])\n'
                         'while time.time() < end:\n'
                         '    sys.stdout.write(text); sys.stdout.flush(); time.sleep(0.015)\n')
    was_running = bool(pids_of('/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal'))
    subprocess.run(['osascript', '-e', 'tell application "Terminal" to do script "python3 -I ' + "'" + str(generator) + "'" + f' {WINDOW + 20}"'],
                   check=True, capture_output=True)
    time.sleep(1)
    subprocess.run(['osascript', '-e', 'tell application "Terminal" to activate'], capture_output=True)
    time.sleep(4)
    terminal = pids_of('/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal')
    if terminal:
        add(results, measure('terminalapp-stream-1MiBps', terminal[0]))
    time.sleep(20)
    subprocess.run(['osascript', '-e', 'tell application "Terminal" to close front window'], capture_output=True)
    if not was_running:
        subprocess.run(['osascript', '-e', 'tell application "Terminal" to quit'], capture_output=True)


def main():
    root.mkdir(parents=True, exist_ok=True)
    awake = subprocess.Popen(['caffeinate', '-dimsu'])
    results = {'app': app, 'windowSeconds': WINDOW, 'sidebar': args.sidebar, 'rows': []}
    try:
        sphyrna_cells(results)
        if args.terminal_app:
            terminal_app_cells(results)
    finally:
        awake.terminate()
        (root / 'result.json').write_text(json.dumps(results, indent=1))
        print('result:', root / 'result.json')


main()
