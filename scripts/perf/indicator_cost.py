#!/usr/bin/env python3
"""R1: working-indicator cost on a package with a fake Claude in a long silent '/work' turn. App CPU and
package idle wakeups per WINDOW-second (env WINDOW, default 60) window via proc_pid_rusage, in: idle visible
window with no working session; animating (visible+active+sidebar open, 3 repeats); sidebar collapsed; app
inactive (Finder frontmost); N=3 working. The Reduce Motion state is the system's and is not changed.
HEAVY-ish (about 12 minutes on screen, launches the app, brings Finder to front): run only when the user
says the Mac is idle and the window may stay visible.
Usage: scripts/perf/indicator_cost.py <fixtures-dir> [--run-dir DIR] [--app 'Loom Dev.app']
  <fixtures-dir> holds loom-fake-provider and loom-test-child (copied from the release bin dir; outside ~/Documents).
Output: <run-dir>/indicator/{evidence/,data/,result.json}."""
import argparse, json, os, pathlib, subprocess, sys, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import perf_paths
from indicator_cost_lib import WINDOW, usage, channel, send, snap, until, measure

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('fixtures', type=pathlib.Path)
perf_paths.add_common_arguments(parser, 'indicator')
args = parser.parse_args()
app_path, run_dir = perf_paths.resolve_common(args, 'indicator')
fixtures = perf_paths.refuse_documents('Fixtures directory', args.fixtures)
root = run_dir / 'indicator'
app = str(app_path)

def main():
    root.mkdir(parents=True, exist_ok=True)
    d = str(root / 'evidence'); data = str(root / 'data')
    os.makedirs(d, exist_ok=True)
    if subprocess.run(['pgrep', '-f', app + '/Contents/MacOS/Loom Dev'], capture_output=True).stdout:
        raise SystemExit('Loom Dev already running')
    subprocess.run(['open', '-n', '-a', app, '--args', '--evidence', d, '--data-root', data, '--fake-providers', str(fixtures)], check=True)
    end = time.time() + 30
    while not (pathlib.Path(d) / 'launched.json').exists():
        if time.time() > end: raise TimeoutError('launch')
        time.sleep(0.2)
    pid = int(subprocess.run(['pgrep', '-f', app + '/Contents/MacOS/Loom Dev'], capture_output=True, text=True).stdout.split()[0])
    results = {'pid': pid, 'windowSeconds': WINDOW, 'rows': []}
    try:
        until(d, 'ready', lambda s: s['catalog']['ready'] and s['catalog']['actionsAvailable'], 30)
        subprocess.run(['open', '-a', app]); time.sleep(4)
        send(d, 'live-chat:off'); time.sleep(1)  # a start follows Settings 'Sessions run in' (Chat by default); these cells measure terminal sessions
        time.sleep(5)
        results['rows'].append(measure(pid, 'idle-visible-active-no-session')); results['rows'][-1]['windowState'] = {k: snap(d, 'w-idle').get(k) for k in ('appActive', 'windowVisible', 'windowOcclusionVisible')}
        send(d, 'start:claude:none')
        s = until(d, 'live1', lambda s: len(s.get('conversationTerminals', [])) == 1 and 'READY' in s['conversationTerminals'][0]['screenTail'], 30)
        owner = s['conversationTerminals'][0]['owner']
        send(d, f'type:{owner}:/work 1200000')
        until(d, 'working1', lambda s: s['catalog'].get('selectedIndicator') == 'Working', 20)
        time.sleep(5)
        for r in (1, 2, 3):
            results['rows'].append(measure(pid, f'working1-visible-active-sidebar-open-r{r}')); results['rows'][-1]['windowState'] = {k: snap(d, f'w-open{r}').get(k) for k in ('appActive', 'windowVisible', 'windowOcclusionVisible')}
        send(d, 'toggle-sidebar'); time.sleep(3)
        results['rows'].append(measure(pid, 'working1-visible-active-sidebar-collapsed')); results['rows'][-1]['windowState'] = {k: snap(d, 'w-collapsed').get(k) for k in ('appActive', 'windowVisible', 'windowOcclusionVisible')}
        send(d, 'toggle-sidebar'); time.sleep(3)
        subprocess.run(['open', '-a', 'Finder']); time.sleep(3)
        st = snap(d, 'inactive')
        row = measure(pid, 'working1-app-inactive'); row['windowState'] = {k: st.get(k) for k in ('appActive', 'windowVisible', 'windowOcclusionVisible')}
        results['rows'].append(row)
        subprocess.run(['open', '-a', app]); time.sleep(3)
        for i in (2, 3):
            send(d, 'start:claude:none'); time.sleep(4)
            s = until(d, f'live{i}', lambda s, i=i: len(s.get('conversationTerminals', [])) == i and all('READY' in t['screenTail'] for t in s['conversationTerminals']), 30)
            new = [t['owner'] for t in s['conversationTerminals'] if t['owner'] != owner and 'WORKING' not in t['screenTail']][0]
            send(d, f'type:{new}:/work 1200000'); time.sleep(2)
        time.sleep(5)
        results['rows'].append(measure(pid, 'working3-visible-active-sidebar-open')); results['rows'][-1]['windowState'] = {k: snap(d, 'w-three').get(k) for k in ('appActive', 'windowVisible', 'windowOcclusionVisible')}
        results['final'] = snap(d, 'final').get('catalog', {}).get('selectedIndicator')
    finally:
        send(d, 'quit')
        time.sleep(8)
        subprocess.run(['pkill', '-f', str(fixtures / 'loom-fake-provider')], capture_output=True)  # only this run's fixture copy
        (root / 'result.json').write_text(json.dumps(results, indent=1))
main()
