#!/usr/bin/env python3
"""CP5 real-provider acceptance in run scopes (plans/cp5/OWN.md, C4/D3 real gates).

Real Claude Code and Codex TUIs in the packaged app, with isolated profiles.
The run covers these steps:
  1. A Claude Bash approval answered in the TUI starts a detached job; Stop must
     end the job and empty the run scope.
  2. A Codex approval is answered on the Loom card, then a detached job is
     started; Stop must end the TUI, the per-conversation server and the job.
  3. Both providers run active commands while the window is hidden; normal Quit
     must leave no owned process and must not touch an outside control process.
Only token presence and process facts are recorded: no transcript, terminal
text, credential or environment value.

Usage: scripts/cp5-own-real.py <path/to/Loom Dev.app outside ~/Documents>
Evidence: ~/Library/Application Support/Loom-Dev/probe/runs/cp5-own-real-<uuid>/result.json
"""
import importlib.util, json, os, pathlib, signal, subprocess, sys, time, uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value
sys.path.insert(0, str(ROOT / 'scripts/perf'))
import perf_paths
measure = module('measure', ROOT / 'scripts/cp5-d-measure.py')
own = module('own', ROOT / 'scripts/cp5-own-native.py')

PROBE = pathlib.Path.home() / 'Library/Application Support/Loom-Dev/probe'
CLAUDE = PROBE / 'claude-config'
CODEX = pathlib.Path.home() / '.loom-dev/codex-home'
WORKSPACE = pathlib.Path('/private/tmp/loom-real/workspace')   # outside HOME (perf_paths.WORK_ROOT); created and trusted in main()
TOKENS = ['LOOM_OWN_C1', 'LOOM_OWN_X1', 'Try', 'OpenAI Codex', 'esc to interrupt', 'thinking',
          # Diagnostics only (presence, never text): what the TUI did instead.
          'Do you want', 'sleep 777', 'sleep 778', 'background', "can't", 'cannot', 'Bash(']
# Input sent before the TUI draws its prompt is lost; these mark readiness.
READY = {'claude': 'Try', 'codex': 'OpenAI Codex'}


def pids_with(argument):
    # Only the job itself: the /bin/sleep binary with exactly these arguments.
    # A command-line match would also hit any process whose argv carries the
    # prompt text (for example an osascript sending it).
    out = subprocess.run(['ps', '-axo', 'pid=,args='], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        pid, _, args = line.strip().partition(' ')
        if args.strip() == argument and own.path(int(pid)) == '/bin/sleep' and measure.identity(int(pid)) is not None:
            found.append(int(pid))
    return found


def pids_with_path(fragment):
    return [p for p in own.pids() if p > 0 and fragment in own.path(p).rsplit('/', 1)[-1]]


def describe(pids):
    return [{'pid': p, 'path': own.path(p), 'coalition': own.coalition(p)} for p in pids]


def main():
    app = pathlib.Path(sys.argv[1]).resolve()
    if str(app).startswith(str(pathlib.Path.home() / 'Documents')):
        raise SystemExit('Package the app outside ~/Documents (run-host TCC).')
    perf_paths.real_work_dir(CLAUDE, 'workspace')
    base = PROBE / 'runs' / f'cp5-own-real-{uuid.uuid4()}'
    evidence, data = base / 'evidence', base / 'data'
    evidence.mkdir(parents=True)
    data.mkdir()
    report = {'app': str(app), 'checks': {}, 'modelTurns': {'claude': 0, 'codex': 0}}
    host_path = str(app / 'Contents/Helpers/LoomRunHost.app/Contents/MacOS/loom-run-host')
    approval_file = WORKSPACE / f'loom-own-approval-{base.name[-8:]}.txt'

    def check(name, ok, detail=None):
        report['checks'][name] = bool(ok)
        if detail is not None:
            report.setdefault('details', {})[name] = detail
        return ok

    def snap(label):
        path = evidence / f'state-{label}.json'
        path.unlink(missing_ok=True)
        measure.send('snapshot:' + label, evidence)
        return measure.wait_json(path, 15)

    def until(label, predicate, timeout):
        end = time.monotonic() + timeout
        state = None
        while time.monotonic() < end:
            state = snap(label)
            if predicate(state):
                return state
            time.sleep(.5)
        if state:
            report['lastState'] = {'indicator': state['catalog'].get('selectedIndicator'),
                                   'issue': state['catalog'].get('selectedIssue'),
                                   'tokens': [sorted(k for k, v in t.get('tokenPresence', {}).items() if v)
                                              for t in state.get('conversationTerminals', [])]}
        raise RuntimeError('timeout:' + label)

    def terminal(state, owner):
        return next((t for t in state.get('conversationTerminals', []) if t.get('owner') == owner), None)

    def token(owner, name):
        return lambda s: (terminal(s, owner) or {}).get('tokenPresence', {}).get(name) is True

    def selected(owner, indicator):
        return lambda s: s['catalog'].get('selectedSessionID') == owner and s['catalog'].get('selectedIndicator') == indicator

    def start(provider, project):
        before = {t['owner'] for t in snap(f'before-{provider}').get('conversationTerminals', [])}
        measure.send(f'start:{provider}:{project}', evidence)
        state = until(f'{provider}-bound', lambda s: any(t['owner'] not in before for t in s.get('conversationTerminals', []))
                      and all(r.get('conversationID') for r in s['catalog']['activityRowDetails']
                              if r['id'] in {t['owner'] for t in s['conversationTerminals']}), 120)
        owner = next(t['owner'] for t in state['conversationTerminals'] if t['owner'] not in before)
        measure.send(f'select:{owner}', evidence)
        until(f'{provider}-ready', token(owner, READY[provider]), 90)
        time.sleep(2)
        return owner

    def prompt(owner, text):
        # Real TUIs take text plus an immediate Return as a paste (newline, no
        # submit). Send the text, then Return on its own until work visibly
        # starts; stop before any approval dialog can appear.
        measure.send(f'type:{owner}:{text}', evidence)
        for attempt in range(4):
            time.sleep(1.5)
            measure.send(f'type:{owner}:', evidence)
            time.sleep(1.5)
            presence = (terminal(snap(f'submit-{attempt}'), owner) or {}).get('tokenPresence', {})
            if presence.get('esc to interrupt') or presence.get('thinking'):
                report.setdefault('submitReturns', []).append(attempt + 1)
                return
        raise RuntimeError('prompt-not-submitted')

    def scope_of(pid):
        cid = own.coalition(pid)
        return cid, [p for p in own.members(cid)] if cid else []

    def stopped_cleanly(name, owner, job_pids, cid):
        measure.send(f'stop:{owner}', evidence)
        until(f'{name}-stopped', lambda s: terminal(s, owner) is None, 60)
        gone = own.wait_until(lambda: all(measure.identity(p) is None for p in job_pids) and own.members(cid) == [], 20)
        check(f'{name}StopEmptiedScope', gone, {'left': own.members(cid)})
        state = snap(f'{name}-after-stop')
        issue = (next((r for r in state['catalog']['activityRowDetails'] if r['id'] == owner), {}) or {}).get('issue') or ''
        check(f'{name}StopReportedNoFailure', 'could not be verified' not in issue, issue[:200] or None)

    if subprocess.run(['pgrep', '-f', str(app / 'Contents/MacOS/Loom Dev')], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('This package is already running; quit it first.')
    outsider = subprocess.Popen(['/bin/sleep', '900'])
    outsider_identity = measure.identity(outsider.pid)
    app_pid = None
    try:
        subprocess.run(['open', '-a', str(app), '--args', '--evidence', str(evidence), '--data-root', str(data),
                        '--claude-config', str(CLAUDE), '--codex-home', str(CODEX),
                        '--evidence-tokens', ','.join(TOKENS)], check=True)
        app_pid = measure.wait_json(evidence / 'launched.json', 30)['pid']
        app_identity = measure.identity(app_pid)
        until('ready', lambda s: s['catalog']['ready'] and s['catalog']['actionsAvailable'], 30)
        measure.send('view-mode:activity', evidence)
        measure.send('add-project:' + str(WORKSPACE), evidence)
        project = until('project', lambda s: len(s['catalog']['projects']) == 1, 30)['catalog']['projects'][0]['id']

        # 1) Claude: approval answered in the TUI starts a detached job; Stop ends it.
        claude = start('claude', project)
        prompt(claude, 'Use the Bash tool with run_in_background set to true to run exactly: sleep 777 '
               '— do not wait for it, then reply with the two words LOOM_OWN and C1 joined by an underscore')
        report['modelTurns']['claude'] += 1
        until('claude-approval', selected(claude, 'Needs approval'), 120)
        check('claudeApprovalReachedCard', True)
        measure.send(f'type:{claude}:', evidence)   # Enter on the TUI's own default "Yes"
        until('claude-replied', token(claude, 'LOOM_OWN_C1'), 120)
        jobs = own.wait_until(lambda: pids_with('sleep 777'), 20) or []
        cid, inside = scope_of(jobs[0]) if jobs else (None, [])
        check('claudeJobInRunScope', bool(jobs) and cid and cid != own.coalition(app_pid)
              and any(own.path(p) == host_path for p in inside), {'jobs': describe(jobs), 'members': describe(inside)})
        if cid:
            stopped_cleanly('claude', claude, jobs, cid)

        # 2) Codex: answer the first approval on the card; then a detached job; Stop.
        codex = start('codex', project)
        prompt(codex, f'Run exactly this shell command and nothing else: touch {approval_file.name}')
        report['modelTurns']['codex'] += 1
        state = until('codex-request', lambda s: s['catalog'].get('selectedSessionID') == codex
                      and len(s['catalog'].get('selectedRequests', [])) == 1, 180)
        check('codexApprovalReachedCard', state['catalog'].get('selectedIndicator') == 'Needs approval')
        measure.send(f'answer:{codex}:accept', evidence)
        check('codexApprovedFileCreated', own.wait_until(approval_file.exists, 90))
        until('codex-turn-done', lambda s: s['catalog'].get('selectedSessionID') == codex
              and s['catalog'].get('selectedRequests') == [] and s['catalog'].get('selectedIndicator') in ('Ready', 'Finished'), 120)
        prompt(codex, 'Run exactly this shell command and nothing else, without waiting for the job: '
               'nohup sleep 778 >/dev/null 2>&1 & — then reply with the two words LOOM_OWN and X1 joined by an underscore')
        report['modelTurns']['codex'] += 1
        end = time.monotonic() + 180
        while time.monotonic() < end and not pids_with('sleep 778'):
            s = snap('codex-job')
            if s['catalog'].get('selectedSessionID') == codex and s['catalog'].get('selectedRequests'):
                measure.send(f'answer:{codex}:accept', evidence)
            time.sleep(1)
        jobs = pids_with('sleep 778')
        cid, inside = scope_of(jobs[0]) if jobs else (None, [])
        tui_and_server = [p for p in inside if 'codex' in own.path(p)]
        # Codex reaps a command's own background children when the command
        # ends, so this job may never outlive its command; record, don't gate.
        report.setdefault('observations', {})['codexDetachedJob'] = {'jobs': describe(jobs), 'members': describe(inside)}
        codex_coalition = own.coalition(next(p for p in pids_with_path('codex')) ) if pids_with_path('codex') else None
        check('codexServerAndTuiShareRunScope', codex_coalition is not None
              and len([p for p in own.members(codex_coalition) if 'codex' in own.path(p)]) >= 2)
        stopped_cleanly('codex', codex, jobs, codex_coalition) if codex_coalition else None

        # 3) Active work in both providers with a hidden window, then normal Quit.
        claude2 = start('claude', project)
        prompt(claude2, 'Use the Bash tool with run_in_background set to true to run exactly: sleep 41 '
               '— do not wait for it')
        report['modelTurns']['claude'] += 1
        # The approval gate was proven in step 1; here only the active command
        # matters, whether or not Claude asks again.
        state = until('claude2-started', lambda s: selected(claude2, 'Needs approval')(s) or bool(pids_with('sleep 41')), 120)
        if not pids_with('sleep 41'):
            measure.send(f'type:{claude2}:', evidence)
        check('claudeActiveCommand', own.wait_until(lambda: pids_with('sleep 41'), 60))
        codex2 = start('codex', project)
        prompt(codex2, 'Run exactly this shell command and wait for it to finish: sleep 42')
        report['modelTurns']['codex'] += 1
        end = time.monotonic() + 120
        while time.monotonic() < end and not pids_with('sleep 42'):
            s = snap('codex2-job')
            if s['catalog'].get('selectedSessionID') == codex2 and s['catalog'].get('selectedRequests'):
                measure.send(f'answer:{codex2}:accept', evidence)
            time.sleep(1)
        check('codexActiveCommand', bool(pids_with('sleep 42')))
        hosts = [p for p in own.pids() if own.path(p) == host_path]
        scopes = {own.coalition(p) for p in hosts}
        measure.send('close-window', evidence)
        time.sleep(1)
        measure.send('quit', evidence)
        quit_report = measure.wait_json(evidence / 'quit.json', 60)
        check('activeHiddenQuitSucceeded', quit_report.get('succeeded') is True and quit_report.get('remaining') == 0,
              quit_report.get('errors'))
        check('appGone', own.wait_until(lambda: measure.identity(app_pid) != app_identity, 20))
        check('allScopesEmpty', own.wait_until(lambda: all(own.members(c) == [] for c in scopes if c), 20),
              {'scopes': len(scopes)})
        check('noActiveCommandsLeft', not pids_with('sleep 41') and not pids_with('sleep 42')
              and not pids_with('sleep 777') and not pids_with('sleep 778'))
        check('noRunHostLeft', not [p for p in own.pids() if own.path(p) == host_path])
        check('outsideAlive', measure.identity(outsider.pid) == outsider_identity)
        return report
    except Exception as error:
        report['failure'] = str(error)
        return report
    finally:
        if app_pid and measure.identity(app_pid) is not None:
            try:
                measure.send('quit', evidence)
                measure.wait_json(evidence / 'quit.json', 60)
            except Exception as error:
                report['cleanupError'] = str(error)
        approval_file.unlink(missing_ok=True)
        for leftover in ('loom-own-c1.out', 'loom-own-x1.out'):
            (WORKSPACE / leftover).unlink(missing_ok=True)
        outsider.terminate()
        outsider.wait(timeout=5)
        report['passed'] = 'failure' not in report and bool(report['checks']) and all(report['checks'].values())
        (base / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({'evidence': str(base), 'passed': report['passed'], 'checks': report['checks'],
                          'failure': report.get('failure'), 'modelTurns': report['modelTurns']}, indent=2))


if __name__ == '__main__':
    sys.exit(0 if main().get('passed') else 1)
