#!/usr/bin/env python3
"""Real-Claude stop -> resume check on a package (the gap behind the 0.2.1 'State unknown after resume' report).
REAL MODEL TURNS: 2 short turns on the user's Claude account through the isolated probe profile
(<probe-root>/claude-config); launches the app (window may appear briefly); run inside the build slot.
1) start in a fresh probe project, set /effort max (a local command, no model turn; Claude keeps max for
   one process only, which is how the user lost it on resume), one short turn;
2) Stop, then Resume the same card;
3) after resume: the card leaves 'State unknown' once Claude is up, a turn shows Working then Finished/Ready;
4) the resumed Claude remembers turn 1 (it repeats a secret word it was only told in turn 1) and both turns are
   in the same provider transcript (same conversation, not a new one);
5) the resumed turn runs at max again: Loom passes the recorded level back with --effort.
Only token presence, indicator labels, transcript facts (role, marker present, effort value) are recorded.
Usage: scripts/perf/claude_resume_real.py --app <package>/'Loom Dev.app' [--run-dir DIR] [--probe-root DIR]"""
import argparse, json, pathlib, subprocess, sys, time, uuid
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import perf_paths
from perf_paths import REPO as ROOT, load_module as module
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
perf_paths.add_common_arguments(parser, 'claude-resume-real')
parser.add_argument('--probe-root', type=pathlib.Path, default=perf_paths.PROBE,
                    help='holds claude-config/ (isolated profile) and workspace/ (default: Loom-Dev/probe)')
args = parser.parse_args()
app, run_dir = perf_paths.resolve_common(args, 'claude-resume-real')
PROBE = perf_paths.refuse_documents('Probe root', args.probe_root)
measure = module('measure', ROOT / 'scripts/cp5-d-measure.py')
own = module('own', ROOT / 'scripts/cp5-own-native.py')
base = run_dir / 'claude-resume-real'
evidence, data = base / 'evidence', base / 'data'
evidence.mkdir(parents=True); data.mkdir()
workspace = PROBE / 'workspace' / f'resume-{time.strftime("%Y%m%dT%H%M%S")}'
workspace.mkdir(parents=True)
SECRET = 'LOOMWORD' + uuid.uuid4().hex[:6].upper()
TOKENS = ['Try', 'trust', 'LOOM_RESUME_ONE', 'LOOM_RESUME_TWO', SECRET, 'this session only']
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
    report['details']['timeout:' + label] = {'indicator': s['catalog'].get('selectedIndicator') if s else None}
    raise RuntimeError('timeout:' + label)
def term(s, owner): return next((t for t in s.get('conversationTerminals', []) if t.get('owner') == owner), None)
def token(owner, name): return lambda s: (term(s, owner) or {}).get('tokenPresence', {}).get(name) is True
def transcripts(owner): return list((PROBE / 'claude-config/projects').glob(f'*/{owner}.jsonl'))
def records(owner):
    for f in transcripts(owner):
        for line in f.read_text(errors='replace').splitlines():
            try: yield json.loads(line)
            except ValueError: continue
def text_of(r):
    c = r.get('message', {}).get('content')
    if isinstance(c, list): c = ' '.join(x.get('text', '') for x in c if isinstance(x, dict))
    return c if isinstance(c, str) else ''
def transcript_has(owner, text, role='user'):
    return any(r.get('type') == role and text in text_of(r) for r in records(owner))
def efforts(owner): return [r.get('effort') for r in records(owner) if r.get('type') == 'assistant']
def prompt(owner, text, label):
    """Type, Return, then poll fast; every indicator seen until the provider transcript has the prompt."""
    seen = []
    measure.send(f'type:{owner}:{text}', evidence); time.sleep(1.5)
    for attempt in range(3):
        measure.send(f'type:{owner}:', evidence)
        end = time.monotonic() + 8
        while time.monotonic() < end:
            ind = snap(f'{label}-submit-{attempt}')['catalog'].get('selectedIndicator')
            if not seen or seen[-1] != ind: seen.append(ind)
            if transcript_has(owner, text): return seen
            time.sleep(.2)
    raise RuntimeError('prompt-not-submitted:' + label)
def watch(owner, label, until_token, timeout):
    """Indicators seen while a turn runs, until the reply token shows and the card settles."""
    seen = []; end = time.monotonic() + timeout; replied = False
    while time.monotonic() < end:
        s = snap(f'{label}-watch'); ind = s['catalog'].get('selectedIndicator')
        if not seen or seen[-1] != ind: seen.append(ind)
        replied = replied or token(owner, until_token)(s)
        if replied and ind in ('Finished', 'Ready'): break
        time.sleep(.3)
    return seen, replied
def tui_ready(owner, label):
    """Claude's prompt is up; a folder-trust question for the fresh probe folder is answered with its default."""
    end = time.monotonic() + 90
    while time.monotonic() < end:
        s = snap(label)
        if token(owner, 'Try')(s): return s
        if token(owner, 'trust')(s):
            report['details'].setdefault('trustPromptsAnswered', 0)
            report['details']['trustPromptsAnswered'] += 1
            measure.send(f'type:{owner}:', evidence); time.sleep(2)
        time.sleep(.5)
    raise RuntimeError('timeout:' + label)
app_pid = None
try:
    if subprocess.run(['pgrep', '-f', str(app / 'Contents/MacOS/Loom Dev')], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('already running')
    subprocess.run(['open', '-n', '-g', '-a', str(app), '--args', '--evidence', str(evidence), '--data-root', str(data),
                    '--claude-config', str(PROBE / 'claude-config'), '--evidence-tokens', ','.join(TOKENS)], check=True)
    app_pid = measure.wait_json(evidence / 'launched.json', 30)['pid']
    until('ready', lambda s: s['catalog']['ready'] and s['catalog']['actionsAvailable'], 30)
    measure.send('view-mode:projects', evidence)
    measure.send('add-project:' + str(workspace), evidence)
    project = until('project', lambda s: len(s['catalog']['projects']) == 1, 30)['catalog']['projects'][0]['id']
    measure.send(f'start:claude:{project}', evidence)
    s = until('bound', lambda s: bool(s.get('conversationTerminals')), 120)
    owner = s['conversationTerminals'][0]['owner']
    measure.send(f'select:{owner}', evidence)
    tui_ready(owner, 'tui-ready'); time.sleep(2)
    # /effort is a local command: no model turn. Claude Code prints whether it is kept.
    measure.send(f'type:{owner}:/effort max', evidence); time.sleep(3)
    report['details']['effortCommandSaysSessionOnly'] = token(owner, 'this session only')(snap('effort'))
    seen1 = prompt(owner, f'Remember the secret word {SECRET}. Reply with exactly LOOM_RESUME_ONE and nothing else.', 'one')
    report['modelTurns'] += 1
    w1, r1 = watch(owner, 'one', 'LOOM_RESUME_ONE', 120)
    check('firstTurnReplied', r1 and transcript_has(owner, 'LOOM_RESUME_ONE', 'assistant'))
    check('firstTurnIndicatorsKnown', 'State unknown' not in (seen1 + w1)[1:] and (w1[-1:] or [None])[0] in ('Finished', 'Ready'),
          seen1 + w1)
    report['details']['effortBeforeResume'] = efforts(owner)
    measure.send(f'stop:{owner}', evidence)
    until('stopped', lambda s: term(s, owner) is None, 60)
    measure.send(f'resume:{owner}', evidence)
    until('resumed', lambda s: term(s, owner) is not None, 120)
    measure.send(f'select:{owner}', evidence)
    # A resumed Claude replays the history instead of showing the 'Try' hint: wait for turn 1 on screen.
    until('resumed-tui', token(owner, 'LOOM_RESUME_ONE'), 90); time.sleep(5)
    after_resume = snap('after-resume')['catalog'].get('selectedIndicator')
    report['details']['indicatorAfterResumeIdle'] = after_resume
    seen2 = prompt(owner, 'What was the secret word? Reply with the secret word, then LOOM_RESUME_TWO, nothing else.', 'two')
    report['modelTurns'] += 1
    w2, r2 = watch(owner, 'two', 'LOOM_RESUME_TWO', 120)
    check('secondTurnReplied', r2 and transcript_has(owner, 'LOOM_RESUME_TWO', 'assistant'))
    check('resumedTurnIndicatorsKnown', 'Working' in (seen2 + w2) and (w2[-1:] or [None])[0] in ('Finished', 'Ready'), seen2 + w2)
    check('notStateUnknownAfterResume', after_resume != 'State unknown' and 'State unknown' not in w2, after_resume)
    check('resumedClaudeRemembers', transcript_has(owner, SECRET, 'assistant'))
    check('sameTranscript', len(transcripts(owner)) == 1 and transcript_has(owner, 'LOOM_RESUME_ONE', 'assistant'),
          {'files': len(transcripts(owner))})
    after = efforts(owner)[len(report['details']['effortBeforeResume']):]
    report['details']['effortAfterResume'] = after
    check('effortKeptAfterResume', bool(after) and all(e == 'max' for e in after), after)
finally:
    if app_pid:
        measure.send('quit', evidence)
        check('appQuit', own.wait_until(lambda: measure.identity(app_pid) is None, 60))
    (base / 'result.json').write_text(json.dumps(report, indent=1, default=str))
    print(json.dumps(report, default=str))
