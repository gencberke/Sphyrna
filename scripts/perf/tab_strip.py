#!/usr/bin/env python3
"""Conversation tab strip evidence and switch latency (U4), on a packaged dev app with fake providers.

  scripts/perf/tab_strip.py scenario --app <Loom Dev.app> --fixtures <dir with loom-fake-provider> --work <dir>
  scripts/perf/tab_strip.py latency  --app <Loom Dev.app> --fixtures <dir> --work <dir> --output <json>

`scenario` drives the evidence channel and checks the CP5 regression scenario (no stale row or stale
terminal after switching during a stream, after a window close and reopen, and after a relaunch), the menu
shortcuts through the real main menu, and writes screenshots of the strip at 1220 and 780 pt with 8, 5 and
2 tabs. `latency` measures tab select -> terminal view available (the `TabToTerminal` signpost) next to
sidebar select -> terminal view available (`SelectToTerminal`) with 1, 5 and 8 live fake terminals that all
stream heavy output; run it inside the build slot lock so no build heats the Mac.

Everything stays under ~/Library (never ~/Documents); data roots are fresh, providers are the fake
provider, no real Claude, no model turn. Output is value-free (ids and timings only).
"""
import argparse
import json
import math
import os
import shutil
import statistics
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from perf_paths import command_channel, refuse_documents  # noqa: E402

CHECKS = []


def check(name, ok, detail=''):
    CHECKS.append({'check': name, 'ok': bool(ok), 'detail': detail})
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{detail}]' if detail and not ok else ''), flush=True)
    return ok


class Instance:
    def __init__(self, app, fixtures, work, name, data=None, extra=()):
        self.app, self.work = Path(app), Path(work)
        self.dir = self.work / name
        self.dir.mkdir(parents=True, exist_ok=True)
        self.data = Path(data) if data else self.dir / 'data'
        self.fixtures = fixtures
        self.extra = list(extra)
        self.process = None
        self.since = None

    def launch(self):
        self.since = datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S')
        (self.dir / 'launched.json').unlink(missing_ok=True)
        log = (self.dir / 'app.log').open('ab')
        self.process = subprocess.Popen(
            [str(self.app / 'Contents/MacOS/Loom Dev'), '--evidence', str(self.dir), '--data-root', str(self.data),
             '--fake-providers', str(self.fixtures), *self.extra], stdout=log, stderr=subprocess.STDOUT)
        self.wait_file(self.dir / 'launched.json')
        for _ in range(150):
            state = self.snap('ready')
            if state['catalog']['ready'] and state['catalog']['actionsAvailable']:
                return state
            time.sleep(0.2)
        raise SystemExit('app never became ready')

    def send(self, command):
        channel = command_channel(self.dir)
        script = ("ObjC.import('Foundation'); $.NSDistributedNotificationCenter.defaultCenter."
                  f"postNotificationNameObjectUserInfoDeliverImmediately({json.dumps(channel)}, {json.dumps(command)}, $(), true)")
        subprocess.run(['osascript', '-l', 'JavaScript', '-e', script], check=True, capture_output=True, timeout=30)

    def cmd(self, command, wait=0.5):
        self.send(command)
        time.sleep(wait)

    @staticmethod
    def wait_file(path, seconds=40):
        end = time.time() + seconds
        while time.time() < end:
            if path.exists():
                return
            time.sleep(0.1)
        raise SystemExit(f'missing {path}')

    def snap(self, label):
        target = self.dir / f'state-{label}.json'
        target.unlink(missing_ok=True)
        self.send(f'snapshot:{label}')
        self.wait_file(target)
        time.sleep(0.15)
        return json.loads(target.read_text())

    def until(self, label, seconds, predicate):
        end = time.time() + seconds
        state = None
        while time.time() < end:
            state = self.snap(label)
            try:
                if predicate(state):
                    return state
            except (KeyError, TypeError):
                pass
            time.sleep(0.25)
        return state

    def quit(self):
        self.send('quit')
        try:
            self.process.wait(timeout=40)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process = None


def live_ids(state):
    return [row['id'] for row in state['tabs']['rows'] if row['live']]


def start_conversation(inst, project, label):
    # A started conversation is pinned and shown at once, so it appears among the tab rows (the lists lag behind).
    before = set(inst.snap(label + '-before')['tabs']['pinned'])
    inst.send(f'start:claude:{project}')
    state = inst.until(label, 30, lambda s: any(
        row['live'] and row['id'] not in before for row in s['tabs']['rows'])
        and s['catalog']['selectedHasTerminalView'])
    new = [row['id'] for row in state['tabs']['rows'] if row['id'] not in before]
    if len(new) != 1:
        raise SystemExit(f'{label}: expected one new conversation, got {new}')
    return new[0]


def add_project(inst, path):
    Path(path).mkdir(parents=True, exist_ok=True)
    inst.cmd(f'add-project:{path}', 0.8)
    return inst.snap('project')['catalog']['projects'][0]['id']


def ready_terminal(inst, session_id, label):
    return inst.until(label, 30, lambda s: any(t['owner'] == session_id and 'FAKE-CLAUDE READY' in (t['screenTail'] or '')
                                                for t in s['conversationTerminals']))


def row_indicators(state):
    return {row['id']: row['indicator'] for row in state['tabs']['rows']}


def list_indicators(state):
    return {row['id']: row['indicator'] for row in state['catalog']['activityRowDetails']}


def tab_checks(state, expected_selected, label, require_attached=True):
    tabs = state['tabs']
    check(f'{label}: selected', state['catalog']['selectedSessionID'] == expected_selected, tabs['selected'])
    rows = list_indicators(state)
    stale = [r['id'] for r in tabs['rows'] if r['id'] in rows and r['indicator'] != rows[r['id']]]
    check(f'{label}: tab rows equal sidebar rows', not stale, stale)
    live = next((r['live'] for r in tabs['rows'] if r['id'] == expected_selected), False)
    if require_attached and live:
        check(f'{label}: only the selected terminal is attached', tabs['attachedTerminals'] == [expected_selected],
              tabs['attachedTerminals'])
    elif not live:
        check(f'{label}: no terminal attached for a record', tabs['attachedTerminals'] == [], tabs['attachedTerminals'])


def screenshot(inst, label):
    inst.cmd(f'screenshot:{label}', 1.2)


def scenario(args):
    work = Path(args.work)
    shutil.rmtree(work / 'scenario', ignore_errors=True)
    inst = Instance(args.app, args.fixtures, work, 'scenario')
    inst.launch()
    project = add_project(inst, work / 'project')
    ids = [start_conversation(inst, project, f'start-{n}') for n in range(3)]
    for n, sid in enumerate(ids):
        ready_terminal(inst, sid, f'ready-{n}')
    a, b, c = ids
    state = inst.snap('three')
    check('three started conversations are pinned tabs', state['tabs']['pinned'] == ids, state['tabs']['pinned'])
    check('strip is visible with three tabs', state['tabs']['stripVisible'])
    check('openTabs persisted', state['catalog']['preferences']['openTabs'] == ids,
          state['catalog']['preferences']['openTabs'])

    # Switching during a stream.
    for sid in ids:
        inst.send(f'type:{sid}:/stream 14')
        time.sleep(0.2)
    time.sleep(1.5)
    state = inst.snap('streaming')
    check('all three are working while streaming', [row_indicators(state)[s] for s in ids] == ['Working'] * 3,
          [row_indicators(state)[s] for s in ids])
    screenshot(inst, 'tabs-3-streaming')
    for step, target in enumerate([a, c, b, a, b, c]):
        inst.cmd(f'tab-select:{target}', 0.4)
        tab_checks(inst.snap('switch'), target, f'switch {step} to {target[:4]}')
    inst.cmd('tab-select:next', 0.4)
    state = inst.snap('next')
    check('tab-select:next wraps to the first tab', state['catalog']['selectedSessionID'] == a, state['tabs']['selected'])
    inst.cmd('tab-select:prev', 0.4)
    state = inst.snap('prev')
    check('tab-select:prev wraps to the last tab', state['catalog']['selectedSessionID'] == c, state['tabs']['selected'])

    # The streams end: no row keeps a stale status.
    state = inst.until('streams-done', 40, lambda s: all(row_indicators(s)[x] != 'Working' for x in ids))
    tab_checks(state, c, 'after the streams')
    check('no tab still reads Working', all(r['indicator'] != 'Working' for r in state['tabs']['rows']),
          [r['indicator'] for r in state['tabs']['rows']])
    inst.cmd(f'rename:{b}:Renamed conversation', 0.6)
    state = inst.snap('renamed')
    title = next(r['title'] for r in state['tabs']['rows'] if r['id'] == b)
    check('rename is reflected in the tab row', title == 'Renamed conversation', title)

    # Shortcuts through the real main menu.
    inst.cmd(f'tab-select:{a}', 0.4)
    for key, expect in [('next', b), ('ctrl-next', c), ('prev', b), ('ctrl-prev', a)]:
        inst.cmd(f'tab-key:{key}', 0.5)
        ack = json.loads((inst.dir / f'ack-tab-key-{key}.json').read_text())
        state = inst.snap('key')
        check(f'tab-key:{key} handled by the menu and enabled', ack['handled'] and ack['enabledBefore'], ack)
        check(f'tab-key:{key} selects the expected tab', state['catalog']['selectedSessionID'] == expect, state['tabs']['selected'])
    inst.cmd('tab-key:close', 0.6)
    ack = json.loads((inst.dir / 'ack-tab-key-close.json').read_text())
    state = inst.snap('closed')
    check('Opt+Cmd+W closes the selected tab through the menu', ack['handled'] and a not in state['tabs']['pinned'], ack)
    owners = [t['owner'] for t in state['conversationTerminals']]
    check('closing a tab never stops its run', a in owners, owners)
    check('the neighbor is shown after closing', state['catalog']['selectedSessionID'] == b, state['tabs']['selected'])
    inst.cmd(f'tab-pin:{a}', 0.5)
    state = inst.snap('repinned')
    check('tab-pin pins and shows the conversation', state['tabs']['pinned'] == [b, c, a] and state['tabs']['selected'] == a,
          state['tabs'])
    inst.cmd(f'tab-unpin:{a}', 0.5)
    state = inst.snap('unpinned')
    check('tab-unpin keeps it shown as the transient tab', state['tabs']['transient'] == a and a not in state['tabs']['pinned'],
          state['tabs'])
    screenshot(inst, 'tabs-transient')
    inst.cmd(f'tab-pin:{a}', 0.4)

    # Window close and reopen (Cmd+W then the Dock/LaunchServices reopen).
    before = inst.snap('before-close')
    inst.cmd('close-window', 1.0)
    check('window closed', inst.snap('closed-window')['windowVisible'] is False)
    subprocess.run(['open', '-a', str(args.app)], check=True)
    state = inst.until('reopened', 15, lambda s: s['windowVisible'])
    check('window is back after reopen', state['windowVisible'])
    check('tabs and selection unchanged after reopen', state['tabs']['ids'] == before['tabs']['ids']
          and state['tabs']['selected'] == before['tabs']['selected'], state['tabs'])
    tab_checks(state, before['tabs']['selected'], 'after reopen')
    inst.cmd(f'tab-select:{c}', 0.5)
    tab_checks(inst.snap('after-reopen-switch'), c, 'switch after reopen')

    # Relaunch: tabs come back as records; nothing starts by itself.
    expected = inst.snap('pre-quit')
    inst.quit()
    time.sleep(2)
    relaunch = Instance(args.app, args.fixtures, work, 'scenario', data=inst.data)
    relaunch.launch()
    state = relaunch.until('relaunched', 15, lambda s: len(s['tabs']['rows']) == 3)
    check('tabs persisted across a relaunch', state['tabs']['pinned'] == expected['tabs']['pinned'], state['tabs']['pinned'])
    check('selection persisted across a relaunch', state['tabs']['selected'] == expected['tabs']['selected'], state['tabs']['selected'])
    check('relaunch starts no conversation', live_ids(state) == [], live_ids(state))
    check('relaunched tabs show records, no terminal attached', state['tabs']['attachedTerminals'] == [], state['tabs']['attachedTerminals'])
    check('relaunched tab rows carry titles', all(r['title'] for r in state['tabs']['rows']), state['tabs']['rows'])
    screenshot(relaunch, 'tabs-relaunched-records')
    relaunch.quit()

    result_path = Path(args.work) / 'scenario-checks.json'
    result_path.write_text(json.dumps(CHECKS, indent=2))
    failed = [c for c in CHECKS if not c['ok']]
    print(f'{len(CHECKS) - len(failed)}/{len(CHECKS)} checks passed')
    return 1 if failed else 0


def shots(args):
    """Strip screenshots at 1220 and 780 pt with 8, 5 and 2 tabs (8 live fake conversations)."""
    work = Path(args.work)
    shutil.rmtree(work / 'shots', ignore_errors=True)
    inst = Instance(args.app, args.fixtures, work, 'shots')
    inst.launch()
    project = add_project(inst, work / 'project')
    ids = [start_conversation(inst, project, f'start-{n}') for n in range(8)]
    for n, sid in enumerate(ids):
        ready_terminal(inst, sid, f'ready-{n}')
    names = ['Fix flaky sync test', 'Refactor catalog actor', 'Summarize release notes', 'Why does CPU spike on resize',
             'Add usage index', 'Review PR 214 with a rather long title that must truncate', 'Migrate schema v3', 'Draft settings copy']
    for sid, name in zip(ids, names):
        inst.cmd(f'rename:{sid}:{name}', 0.3)
    inst.send(f'type:{ids[0]}:/stream 600')
    inst.send(f'type:{ids[3]}:/approve')
    inst.send(f'type:{ids[5]}:/fail')
    time.sleep(1.5)
    inst.cmd(f'tab-select:{ids[2]}', 0.5)

    def take(label):
        for width, height in [(1220, 780), (780, 500)]:
            inst.cmd(f'resize:{width}x{height}', 1.0)
            inst.cmd(f'sidebar-width:300', 0.8)
            screenshot(inst, f'{label}-{width}')
        return inst.snap(label)

    state = take('tabs-8')
    check('8 tabs visible', len(state['tabs']['ids']) == 8)
    for sid in ids[5:]:
        inst.cmd(f'tab-close:{sid}', 0.3)
    state = take('tabs-5')
    check('5 tabs visible', len(state['tabs']['ids']) == 5, state['tabs']['ids'])
    for sid in ids[2:5]:
        inst.cmd(f'tab-close:{sid}', 0.3)
    state = take('tabs-2')
    check('2 tabs visible', len(state['tabs']['ids']) == 2, state['tabs']['ids'])
    inst.cmd(f'tab-close:{ids[1]}', 0.5)
    state = inst.snap('one')
    check('strip hidden with one tab', state['tabs']['stripVisible'] is False)
    screenshot(inst, 'tabs-1-hidden')
    inst.quit()
    (Path(args.work) / 'shots-checks.json').write_text(json.dumps(CHECKS, indent=2))
    return 0


def interval_durations(pid, since):
    out = subprocess.run(
        ['/usr/bin/log', 'show', '--start', since, '--signpost', '--style', 'ndjson',
         '--predicate', f'subsystem == "local.loom.desktop" AND processID == {pid}'],
        capture_output=True, text=True, timeout=300, check=True).stdout
    begins, result = {}, {'TabToTerminal': [], 'SelectToTerminal': []}
    for line in out.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        name = row.get('signpostName')
        if name not in result or 'timestamp' not in row:
            continue
        stamp = datetime.strptime(row['timestamp'], '%Y-%m-%d %H:%M:%S.%f%z').timestamp()
        if row.get('signpostType') == 'begin':
            begins[name] = stamp
        elif row.get('signpostType') == 'end' and name in begins:
            result[name].append((stamp - begins.pop(name)) * 1000)
    return result


def summarize(values):
    if not values:
        return {'n': 0}
    ordered = sorted(values)
    p95 = ordered[min(len(ordered) - 1, math.ceil(0.95 * len(ordered)) - 1)]
    return {'n': len(values), 'median': round(statistics.median(values), 2), 'p95': round(p95, 2),
            'min': round(ordered[0], 2), 'max': round(ordered[-1], 2),
            'samples': [round(v, 2) for v in values]}


def latency(args):
    work = Path(args.work)
    results = {}
    for live in args.live:
        name = f'latency-{live}'
        shutil.rmtree(work / name, ignore_errors=True)
        inst = Instance(args.app, args.fixtures, work, name)
        inst.launch()
        project = add_project(inst, work / 'project')
        streaming = [start_conversation(inst, project, f'start-{n}') for n in range(live)]
        for n, sid in enumerate(streaming):
            ready_terminal(inst, sid, f'ready-{n}')
        # One more conversation that is stopped: a record tab, so one live terminal still has a tab to switch from.
        record = start_conversation(inst, project, 'start-record')
        ready_terminal(inst, record, 'ready-record')
        inst.cmd(f'stop:{record}', 1.0)
        inst.until('stopped', 20, lambda s: record not in live_ids(s))
        # Heavy output in every live terminal, long enough for the whole sampling loop.
        seconds = args.visits * 2 * (args.pause + 0.6) + 40
        for sid in streaming:
            inst.send(f'type:{sid}:/stream {int(seconds)}')
            time.sleep(0.15)
        time.sleep(3)
        before = inst.snap('stream-check')
        growing = {t['owner']: t['outputBytes'] for t in before['conversationTerminals']}
        time.sleep(1.5)
        after = inst.snap('stream-check-2')
        grew = [t['outputBytes'] - growing.get(t['owner'], 0) for t in after['conversationTerminals'] if t['owner'] in streaming]
        check(f'{live} live: every terminal streams', len(grew) == live and all(g > 100_000 for g in grew), grew)
        working = [row_indicators(after)[s] for s in streaming]
        check(f'{live} live: all are working', working == ['Working'] * live, working)
        marker = datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S')
        order = streaming + [record]
        index = 0
        visits = 0
        method = 0
        while visits < args.visits * 2:
            target = order[index % len(order)]
            index += 1
            if target == record:
                inst.cmd(f'tab-select:{record}', args.pause)
                continue
            inst.cmd(('tab-select:' if method % 2 == 0 else 'select:') + target, args.pause)
            method += 1
            visits += 1
        pid = inst.process.pid
        final = inst.snap('final')
        check(f'{live} live: the selected terminal is attached', final['catalog']['selectedHasTerminalView'])
        time.sleep(1)
        inst.send('quit')
        inst.process.wait(timeout=60)
        time.sleep(2.5)
        durations = interval_durations(pid, marker)
        results[str(live)] = {'tab': summarize(durations['TabToTerminal']), 'sidebar': summarize(durations['SelectToTerminal'])}
        print(live, 'live: tab', {k: v for k, v in results[str(live)]['tab'].items() if k != 'samples'},
              'sidebar', {k: v for k, v in results[str(live)]['sidebar'].items() if k != 'samples'}, flush=True)
        time.sleep(args.cooldown)
    output = {
        'slice': 'U4', 'date': datetime.now().strftime('%Y-%m-%d'), 'unit': 'ms',
        'what': 'selection -> terminal view available to the detail pane, tab strip path (TabToTerminal) next to the sidebar path (SelectToTerminal)',
        'method': {
            'signposts': 'LoomSignposts (subsystem local.loom.desktop), read with /usr/bin/log show --signpost --style ndjson, process-filtered',
            'load': 'N live fake-provider conversations, each streaming about 1 MiB/s (/stream), plus one stopped record tab',
            'visits': args.visits, 'pause': args.pause, 'cooldownSeconds': args.cooldown,
            'order': 'tab and sidebar visits alternate in one run (A/B/A/B) over the same terminals',
            'launch': 'direct exec of the packaged executable with --evidence <work> --data-root <fresh> --fake-providers <dir>',
            'script': 'scripts/perf/tab_strip.py latency',
        },
        'results': results, 'checks': CHECKS,
    }
    Path(args.output).parent.mkdir(parents=True, exist_ok=True)
    Path(args.output).write_text(json.dumps(output, indent=2, sort_keys=True))
    return 1 if any(not c['ok'] for c in CHECKS) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('mode', choices=['scenario', 'shots', 'latency'])
    parser.add_argument('--app', required=True)
    parser.add_argument('--fixtures', required=True)
    parser.add_argument('--work', required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--live', type=int, nargs='+', default=[1, 5, 8])
    parser.add_argument('--visits', type=int, default=20, help='visits per method and configuration')
    parser.add_argument('--pause', type=float, default=0.5, help='seconds between switches')
    parser.add_argument('--cooldown', type=float, default=90.0)
    args = parser.parse_args()
    for label, path in [('app', args.app), ('fixtures', args.fixtures), ('work', args.work)]:
        refuse_documents(label, path)
    if args.mode == 'latency' and not args.output:
        parser.error('latency needs --output')
    sys.exit({'scenario': scenario, 'shots': shots, 'latency': latency}[args.mode](args))


if __name__ == '__main__':
    main()
