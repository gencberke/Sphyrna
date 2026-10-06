#!/usr/bin/env python3
"""Real-Claude check on a package (Claude only; Codex is paused and not in the first release).
REAL MODEL TURNS: 2 short turns on the user's Claude account through the isolated probe profile
(<probe-root>/claude-config); HEAVY-ish (launches the app, 60 s idle observer window): run only when the
user says the Mac is idle and the window may stay visible.
1) start in project, one short turn, indicator Working -> Finished/Ready;
2) app CPU / wakeups with one idle Claude session, 60 s (observer cost);
3) COLORTERM=truecolor present in the Claude process environment (key only);
4) background job via approved Bash, Stop empties the run scope;
5) normal Quit leaves no owned process; outsider untouched.
Only token presence and process facts are recorded; the submission is proven from the provider transcript.
Usage: scripts/perf/claude_real.py [--run-dir DIR] [--app 'Loom Dev.app'] [--probe-root DIR]
Output: <run-dir>/claude-real/{evidence/,data/,result.json}; the directory must not exist yet."""
import argparse, importlib.util, json, os, pathlib, subprocess, sys, time, uuid
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import perf_paths
from perf_paths import REPO as ROOT, load_module as module
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
perf_paths.add_common_arguments(parser, 'claude-real')
parser.add_argument('--probe-root', type=pathlib.Path, default=perf_paths.PROBE,
                    help='holds claude-config/ (isolated profile) and workspace/ (default: Loom-Dev/probe)')
args = parser.parse_args()
app, run_dir = perf_paths.resolve_common(args, 'claude-real')
PROBE = perf_paths.refuse_documents('Probe root', args.probe_root)
measure = module('measure', ROOT / 'scripts/cp5-d-measure.py')
own = module('own', ROOT / 'scripts/cp5-own-native.py')
real = module('real', ROOT / 'scripts/cp5-own-real.py')
ic = module('ic', pathlib.Path(__file__).resolve().parent / 'indicator_cost_lib.py')
base = run_dir / 'claude-real'
evidence, data = base / 'evidence', base / 'data'
evidence.mkdir(parents=True); data.mkdir()
TOKENS = ['LOOM_FINAL_OK', 'LOOM_FINAL_BG', 'Try', 'esc to interrupt', 'thinking', 'Do you want', 'sleep 779']
report = {'checks': {}, 'modelTurns': 0, 'details': {}}
def check(name, ok, detail=None):
    report['checks'][name] = bool(ok)
    if detail is not None: report['details'][name] = detail
def snap(label):
    p = evidence / f'state-{label}.json'; p.unlink(missing_ok=True)
    measure.send('snapshot:' + label, evidence); return measure.wait_json(p, 15)
def until(label, pred, timeout):
    end = time.monotonic() + timeout; s = None
    while time.monotonic() < end:
        s = snap(label)
        if pred(s): return s
        time.sleep(.5)
    report['lastState'] = {'indicator': s['catalog'].get('selectedIndicator') if s else None,
                           'tokens': [sorted(k for k, v in t.get('tokenPresence', {}).items() if v) for t in (s or {}).get('conversationTerminals', [])]}
    raise RuntimeError('timeout:' + label)
def term(s, owner): return next((t for t in s.get('conversationTerminals', []) if t.get('owner') == owner), None)
def token(owner, name): return lambda s: (term(s, owner) or {}).get('tokenPresence', {}).get(name) is True
def transcript_has(owner, text, role='user'):
    for f in (PROBE / 'claude-config/projects').glob(f'*/{owner}.jsonl'):
        for line in f.read_text(errors='replace').splitlines():
            try: r = json.loads(line)
            except ValueError: continue
            c = r.get('message', {}).get('content') if r.get('type') == role else None
            if isinstance(c, list): c = ' '.join(x.get('text', '') for x in c if isinstance(x, dict))
            if isinstance(c, str) and text in c: return True
    return False
def prompt(owner, text):
    """Type, press Return, then poll fast; a short turn can finish in ~1 s, so
    submission is proven by the provider transcript and every indicator seen
    in between is recorded."""
    seen = []
    measure.send(f'type:{owner}:{text}', evidence); time.sleep(1.5)
    for attempt in range(3):
        measure.send(f'type:{owner}:', evidence)
        end = time.monotonic() + 8
        while time.monotonic() < end:
            ind = snap(f'submit-{attempt}')['catalog'].get('selectedIndicator')
            if not seen or seen[-1] != ind: seen.append(ind)
            if transcript_has(owner, text): return seen
            time.sleep(.2)
    raise RuntimeError('prompt-not-submitted')
outsider = subprocess.Popen(['/bin/sleep', '1200']); oid = measure.identity(outsider.pid)
app_pid = None
try:
    if subprocess.run(['pgrep', '-f', str(app / 'Contents/MacOS/Loom Dev')], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('already running')
    subprocess.run(['open', '-n', '-a', str(app), '--args', '--evidence', str(evidence), '--data-root', str(data),
                    '--claude-config', str(PROBE / 'claude-config'), '--codex-home', str(pathlib.Path.home() / '.loom-dev/codex-home'),
                    '--evidence-tokens', ','.join(TOKENS)], check=True)
    app_pid = measure.wait_json(evidence / 'launched.json', 30)['pid']
    until('ready', lambda s: s['catalog']['ready'] and s['catalog']['actionsAvailable'], 30)
    measure.send('view-mode:projects', evidence)
    measure.send('add-project:' + str(PROBE / 'workspace'), evidence)
    project = until('project', lambda s: len(s['catalog']['projects']) == 1, 30)['catalog']['projects'][0]['id']
    before = {t['owner'] for t in snap('before').get('conversationTerminals', [])}
    measure.send(f'start:claude:{project}', evidence)
    s = until('bound', lambda s: any(t['owner'] not in before for t in s.get('conversationTerminals', [])), 120)
    owner = next(t['owner'] for t in s['conversationTerminals'] if t['owner'] not in before)
    measure.send(f'select:{owner}', evidence)
    until('tui-ready', token(owner, 'Try'), 90); time.sleep(2)
    seen = prompt(owner, 'Reply with exactly the single word LOOM_FINAL_OK and nothing else'); report['modelTurns'] += 1
    until('replied', token(owner, 'LOOM_FINAL_OK'), 120)
    done = until('finished', lambda s: s['catalog'].get('selectedIndicator') in ('Finished', 'Ready'), 60)
    seen = seen + [done['catalog'].get('selectedIndicator')]
    check('assistantReplied', transcript_has(owner, 'LOOM_FINAL_OK', 'assistant'))
    check('workingIndicatorShown', 'Working' in seen, seen)
    check('turnCompletedIndicator', True, done['catalog'].get('selectedIndicator'))
    # Claude process env: COLORTERM key only.
    leader = [p for p in own.pids() if p > 0 and own.path(p).endswith('/claude')] or [p for p in own.pids() if p > 0 and 'claude' in own.path(p).rsplit('/', 1)[-1]]
    envs = [subprocess.run(['ps', 'eww', '-o', 'command=', '-p', str(p)], capture_output=True, text=True).stdout for p in leader]
    check('colortermTruecolor', any(' COLORTERM=truecolor' in e for e in envs), {'claudeProcesses': len(leader)})
    time.sleep(10)
    report['details']['idleObserver'] = ic.measure(app_pid, 'one-idle-claude-visible-active', 60)
    prompt(owner, 'Use the Bash tool with run_in_background set to true to run exactly: sleep 779 '
                  '- do not wait for it, then reply with the single word LOOM_FINAL_BG'); report['modelTurns'] += 1
    try:
        until('approval', lambda s: s['catalog'].get('selectedIndicator') == 'Needs approval', 90)
        check('approvalReachedCard', True); measure.send(f'type:{owner}:', evidence)
    except RuntimeError:
        check('approvalReachedCard', False)
    until('bg-replied', token(owner, 'LOOM_FINAL_BG'), 120)
    check('assistantRepliedBackground', own.wait_until(lambda: transcript_has(owner, 'LOOM_FINAL_BG', 'assistant'), 60))
    jobs = own.wait_until(lambda: real.pids_with('sleep 779'), 20) or []
    cid = own.coalition(jobs[0]) if jobs else None
    check('backgroundJobInScope', bool(jobs) and cid and cid != own.coalition(app_pid), {'jobs': len(jobs)})
    measure.send(f'stop:{owner}', evidence)
    until('stopped', lambda s: term(s, owner) is None, 60)
    gone = own.wait_until(lambda: all(measure.identity(p) is None for p in jobs) and (not cid or own.members(cid) == []), 20)
    check('stopEmptiedScope', gone)
    st = snap('after-stop'); issue = (next((r for r in st['catalog']['activityRowDetails'] if r['id'] == owner), {}) or {}).get('issue') or ''
    check('stopNoFailure', 'could not be verified' not in issue, issue[:200] or None)
finally:
    if app_pid:
        measure.send('quit', evidence)
        check('appQuit', own.wait_until(lambda: measure.identity(app_pid) is None, 60))
    check('outsiderUntouched', measure.identity(outsider.pid) == oid)
    outsider.terminate()
    report['leftoverClaude'] = [p for p in own.pids() if p > 0 and 'loom-run-host' in own.path(p)]
    (base / 'result.json').write_text(json.dumps(report, indent=1, default=str))
    print(json.dumps(report['checks']))
