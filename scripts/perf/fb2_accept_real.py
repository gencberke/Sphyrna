#!/usr/bin/env python3
"""Feedback round 2 acceptance on a package with real Claude (plans/FEEDBACK-2.md).
REAL MODEL TURNS: about 4 short turns through the isolated probe profile (<probe-root>/claude-config): 3 in the
first session (switched to haiku with the local /model command) and 1 in the session it opens. The window is shown
(visual acceptance); run only when the user says the Mac is idle, inside the build slot.
1) a turn that runs an Explore subagent: the card shows the subagent tree (window captures);
2) a turn that runs `"$LOOM_CLI" open --title ... --ticket TEST-7 --message-file ...`: the request box and Needs
   approval show, `open-approve` starts a new session with the title, the first message reaches Claude, the CLI
   reports `started`; a second run of the same command reports `exists` without opening a copy;
3) project view: the new session is above the older one, no project label; activity view: the label shows;
4) Mark as Read: a finished or waiting card returns to Ready and stays Ready across later idle samples.
Window captures (`screencapture -l`) go to the run dir only, never to the repository; the prompts are synthetic.
Usage: scripts/perf/fb2_accept_real.py --app <package>/'Loom Dev.app' [--run-dir DIR] [--probe-root DIR]"""
import argparse, json, pathlib, subprocess, sys, tempfile, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import perf_paths
from perf_paths import REPO as ROOT, load_module as module
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
perf_paths.add_common_arguments(parser, 'fb2-accept-real')
parser.add_argument('--probe-root', type=pathlib.Path, default=perf_paths.PROBE,
                    help='holds claude-config/ (isolated profile) and workspace/ (default: Loom-Dev/probe)')
parser.add_argument('--only-subagents', action='store_true', help='run step 1 only (1 model turn)')
args = parser.parse_args()
app, run_dir = perf_paths.resolve_common(args, 'fb2-accept-real')
PROBE = perf_paths.refuse_documents('Probe root', args.probe_root)
measure = module('measure', ROOT / 'scripts/cp5-d-measure.py')
own = module('own', ROOT / 'scripts/cp5-own-native.py')
base = run_dir / 'fb2-accept-real'
evidence, data, shots = base / 'evidence', base / 'data', base / 'shots'
evidence.mkdir(parents=True); data.mkdir(); shots.mkdir()
workspace = PROBE / 'workspace' / f'fb2-{time.strftime("%Y%m%dT%H%M%S")}'
workspace.mkdir(parents=True)
for name in ('alpha.txt', 'beta.txt', 'gamma.txt'): (workspace / name).write_text(name + '\n')
subprocess.run(['git', 'init', '-q', '-b', 'main', str(workspace)], check=True)
(workspace / 'TEST-7-msg.txt').write_text('Reply with exactly LOOM_CHILD_OK and nothing else.\n')
perf_paths.trust_probe_workspace(PROBE / 'claude-config', workspace)
TOKENS = ['Try', 'shortcuts', 'trust this folder', 'external imports', 'ZQX17', 'LOOM_CHILD_OK', 'LOOM_OPEN_ONE', 'LOOM_OPEN_TWO', 'started', 'exists']
COMMAND = '"$LOOM_CLI" open --title "TEST-7 - fb2 probe" --ticket TEST-7 --message-file TEST-7-msg.txt'
report = {'checks': {}, 'modelTurns': 0, 'details': {}}
def check(name, ok, detail=None):
    report['checks'][name] = bool(ok)
    if detail is not None: report['details'][name] = detail
def snap(label):
    p = evidence / f'state-{label}.json'; p.unlink(missing_ok=True)
    measure.send('snapshot:' + label, evidence); return measure.wait_json(p, 15)
def until(label, pred, timeout, every=.5):
    end = time.monotonic() + timeout; s = None
    while time.monotonic() < end:
        s = snap(label)
        if pred(s): return s
        time.sleep(every)
    raise RuntimeError('timeout:' + label)
def term(s, owner): return next((t for t in s.get('conversationTerminals', []) if t.get('owner') == owner), None)
def token(owner, name): return lambda s: (term(s, owner) or {}).get('tokenPresence', {}).get(name) is True
def records(owner):
    for f in (PROBE / 'claude-config/projects').glob(f'*/{owner}.jsonl'):
        for line in f.read_text(errors='replace').splitlines():
            try: yield json.loads(line)
            except ValueError: continue
def text_of(r):
    c = r.get('message', {}).get('content')
    if isinstance(c, list): c = ' '.join(x.get('text', '') or str(x.get('content', '')) for x in c if isinstance(x, dict))
    return c if isinstance(c, str) else ''
def transcript_has(owner, text, role):
    return any(r.get('type') == role and text in text_of(r) for r in records(owner))
def row(s, sid):
    for key in ('activityRowDetails', 'rows'):
        for r in s.get('catalog', {}).get(key, []) or []:
            if r.get('id') == sid: return r
    return None
WINDOW_ID = '''import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
let best = mine.max { (($0[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) < (($1[kCGWindowBounds as String] as? [String: Double])?["Width"] ?? 0) }
print(best?[kCGWindowNumber as String] as? Int ?? 0)
'''
window_id = None
def shot(label):
    global window_id
    if window_id is None:
        with tempfile.NamedTemporaryFile('w', suffix='.swift', delete=False) as f: f.write(WINDOW_ID)
        out = subprocess.run(['swift', f.name, str(app_pid)], capture_output=True, text=True, timeout=120).stdout.strip()
        window_id = int(out or 0)
    if window_id:
        time.sleep(.6)
        subprocess.run(['screencapture', '-x', '-o', '-l', str(window_id), str(shots / f'{label}.png')], timeout=20)
def tui_ready(owner, label):
    end = time.monotonic() + 90
    while time.monotonic() < end:
        s = snap(label)
        if token(owner, 'Try')(s) or token(owner, 'shortcuts')(s): return s
        if token(owner, 'trust this folder')(s):
            raise RuntimeError('folder-trust question shown (its default quits Claude): ' + label)
        if token(owner, 'external imports')(s):
            # Default "No, disable external imports": keeps the user's own imported rules out of the probe.
            measure.send(f'type:{owner}:', evidence); time.sleep(2)
        time.sleep(.5)
    raise RuntimeError('timeout:' + label)
def prompt(owner, text, label):
    measure.send(f'type:{owner}:{text}', evidence); time.sleep(1.5)
    for attempt in range(3):
        measure.send(f'type:{owner}:', evidence)
        end = time.monotonic() + 8
        while time.monotonic() < end:
            if transcript_has(owner, text[:40], 'user'): return
            time.sleep(.3)
    raise RuntimeError('prompt-not-submitted:' + label)
def answer_bash(owner, label, timeout=60):
    """Accept Claude's Bash permission request through the card's approval (the user's click)."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        s = snap(label)
        ind = (row(s, owner) or {}).get('indicator') or s['catalog'].get('selectedIndicator')
        if ind == 'Needs approval' and not s.get('openRequests'):
            measure.send(f'answer:{owner}:accept', evidence); return True
        if s.get('openRequests'): return False
        time.sleep(.4)
    return False
app_pid = None
try:
    if subprocess.run(['pgrep', '-f', str(app / 'Contents/MacOS/Loom Dev')], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('already running')
    subprocess.run(['open', '-n', '-a', str(app), '--args', '--evidence', str(evidence), '--data-root', str(data),
                    '--claude-config', str(PROBE / 'claude-config'), '--evidence-tokens', ','.join(TOKENS)], check=True)
    app_pid = measure.wait_json(evidence / 'launched.json', 30)['pid']
    until('ready', lambda s: s['catalog']['ready'] and s['catalog']['actionsAvailable'], 30)
    measure.send('resize:1180x760', evidence)
    measure.send('view-mode:activity', evidence)
    measure.send('add-project:' + str(workspace), evidence)
    project = until('project', lambda s: len(s['catalog']['projects']) == 1, 30)['catalog']['projects'][0]['id']
    measure.send(f'start:claude:{project}', evidence)
    s = until('bound', lambda s: bool(s.get('conversationTerminals')), 120)
    parent = s['conversationTerminals'][0]['owner']
    measure.send(f'select:{parent}', evidence)
    tui_ready(parent, 'tui-ready'); time.sleep(2)
    measure.send(f'type:{parent}:/model haiku', evidence); time.sleep(4)
    (evidence / 'first-snapshot-keys.json').write_text(json.dumps(sorted(snap('keys').keys())))

    # 1) Subagent tree.
    # The reply token is not in the prompt (the prompt itself is on screen).
    prompt(parent, 'Use the Agent tool with subagent_type general-purpose in the foreground (not in the background). '
                   'The agent must run the shell command `sleep 20` and then say it is done. After it returns, reply '
                   'with the letters ZQX immediately followed by the number 17, nothing else.', 'sub')
    report['modelTurns'] += 1
    end = time.monotonic() + 150; n = 0
    while time.monotonic() < end and not token(parent, 'ZQX17')(snap('sub-watch')):
        if n < 10: shot(f'1-subagent-running-{n}'); n += 1
        time.sleep(2.5)
    check('subagentTurnReplied', transcript_has(parent, 'ZQX17', 'assistant'))
    time.sleep(2); shot('1-subagent-finished')
    if args.only_subagents: raise SystemExit(0)

    # 2) Open a session through the command, approve in Loom.
    prompt(parent, f'Run this exact command with the Bash tool: {COMMAND} -- then reply with LOOM_OPEN_ONE followed by '
                   'the command output, nothing else.', 'open1')
    report['modelTurns'] += 1
    bash_answered = answer_bash(parent, 'open1-bash')
    report['details']['bashPermissionAsked'] = bash_answered
    s = until('open-request', lambda s: bool(s.get('openRequests')), 120)
    request = s['openRequests'][0]
    report['details']['openRequest'] = {k: request.get(k) for k in ('kind', 'phase', 'title', 'ticket')}
    check('requestBoxForTheRequester', request.get('kind') == 'open' and (request.get('requester') or request.get('requesterID')) == parent,
          request)
    check('requesterNeedsApproval', ((row(s, parent) or {}).get('indicator') or s['catalog'].get('selectedIndicator')) == 'Needs approval')
    shot('2-request-box')
    before = {t['owner'] for t in s.get('conversationTerminals', [])}
    measure.send(f'open-approve:{request["id"]}', evidence)
    s = until('child', lambda s: len({t['owner'] for t in s.get('conversationTerminals', [])} - before) == 1, 120)
    child = ({t['owner'] for t in s['conversationTerminals']} - before).pop()
    until('open1-done', token(parent, 'LOOM_OPEN_ONE'), 120)
    check('cliReportedStarted', transcript_has(parent, 'started', 'assistant') or transcript_has(parent, 'started', 'user'))
    shot('2-after-approve')
    # The child's first message is its first prompt (one model turn in the child).
    report['modelTurns'] += 1
    try:
        until('child-reply', lambda s: transcript_has(child, 'LOOM_CHILD_OK', 'assistant'), 150, every=1.5)
    except RuntimeError: pass
    check('childGotFirstMessage', transcript_has(child, 'Reply with exactly LOOM_CHILD_OK', 'user'))
    check('childReplied', transcript_has(child, 'LOOM_CHILD_OK', 'assistant'))
    s = snap('child-row')
    report['details']['childRow'] = row(s, child)

    # Same ticket again: exists, no copy.
    prompt(parent, f'Run the same command again with the Bash tool: {COMMAND} -- then reply with LOOM_OPEN_TWO followed by '
                   'the command output, nothing else.', 'open2')
    report['modelTurns'] += 1
    answer_bash(parent, 'open2-bash')
    s = until('exists', lambda s: any(r.get('kind') == 'exists' for r in s.get('openRequests', [])), 120)
    check('existsNotice', True, [r.get('kind') for r in s['openRequests']])
    shot('2-exists-notice')
    until('open2-done', token(parent, 'LOOM_OPEN_TWO'), 120)
    check('cliReportedExists', transcript_has(parent, 'exists', 'assistant') or transcript_has(parent, 'exists', 'user'))
    check('noCopyOpened', len(snap('after-exists').get('conversationTerminals', [])) == 2)
    for r in snap('dismiss').get('openRequests', []): measure.send(f'open-dismiss:{r["id"]}', evidence)

    # 3) Views: activity (label shown), project (newest on top, no label, origin line).
    shot('3-activity-view')
    measure.send('view-mode:projects', evidence); time.sleep(1); shot('3-project-view')
    measure.send('view-mode:activity', evidence); time.sleep(1); shot('3-activity-view-again')

    # 4) Mark as Read on the requester while the child is selected (so the requester is not being viewed).
    measure.send(f'select:{child}', evidence)
    s = until('parent-attention', lambda s: ((row(s, parent) or {}).get('indicator')) in ('Finished', 'Waiting for you'), 150, every=2)
    report['details']['parentBeforeMarkRead'] = (row(s, parent) or {}).get('indicator')
    shot('4-before-mark-read')
    measure.send(f'mark-read:{parent}', evidence); time.sleep(1.5)
    check('markReadToReady', (row(snap('mark-read'), parent) or {}).get('indicator') == 'Ready')
    seen = set(); end = time.monotonic() + 75
    while time.monotonic() < end:
        seen.add((row(snap('mark-read-hold'), parent) or {}).get('indicator')); time.sleep(3)
    check('markReadHoldsThroughIdle', seen == {'Ready'}, sorted(map(str, seen)))
    shot('4-after-mark-read')
finally:
    if app_pid:
        measure.send('quit', evidence)
        check('appQuit', own.wait_until(lambda: measure.identity(app_pid) is None, 60))
    (base / 'result.json').write_text(json.dumps(report, indent=1, default=str))
    print(json.dumps(report, indent=1, default=str))
