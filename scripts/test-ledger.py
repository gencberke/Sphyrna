#!/usr/bin/env python3
"""The test ledger: every check.sh log's Swift Testing results as one JSON line per run, suite and test (DEVELOPMENT §2).

Usage: scripts/test-ledger.py ingest [<log>[=<sha>] …] [--force]   (no log: every check-*.log not yet in the ledger)
       scripts/test-ledger.py runs [--last N]
       scripts/test-ledger.py summary [<stamp>|--log <log>]      per target: tests, wall, issues; the five slowest tests
       scripts/test-ledger.py failures [<stamp> …]                 failing tests, issues per run
       scripts/test-ledger.py flakes [--any-source]                tests that failed and passed on the same source
       scripts/test-ledger.py diff <stamp> <stamp>                 new and fixed failures, count changes, slow movers
Ledger: $LOOM_TEST_LEDGER, else $LOOM_CHECK_LOG_DIR/ledger.jsonl (default ~/Library/Caches/loom-check-logs); never under
~/Documents. The source of a run is the log's `=== source: <sha>` line (check.sh writes it), or `<log>=<sha>` at ingest.
A test is named by its target and its function (`Target/name(args:)`); the log lines carry no suite, so the suite is filled in
from the tree when the function name is unique in its target.
"""
import json
import os
import re
import sys
from collections import Counter, defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG_DIR = os.environ.get('LOOM_CHECK_LOG_DIR') or os.path.expanduser('~/Library/Caches/loom-check-logs')
LEDGER = os.environ.get('LOOM_TEST_LEDGER') or os.path.join(LOG_DIR, 'ledger.jsonl')

RE_STEP = re.compile(r'^=== (.+?): (.*)$')
RE_SOURCE = re.compile(r'^=== source: ([0-9a-f]{7,40})(\+dirty)?')
RE_TEST = re.compile(r'^[✔✘] Test (\S+?)(?: with (\d+) test cases?)? (passed|failed) after ([\d.]+) seconds')
RE_SUITE = re.compile(r'^[✔✘] Suite (\S+) (passed|failed) after ([\d.]+) seconds')
RE_ISSUE = re.compile(r'^✘ Test (\S+) recorded an issue(?: with \d+ arguments?.*?)? at (\S+?): (.*)')
RE_KNOWN = re.compile(r'^━ Test (\S+) recorded a known issue at (\S+?): (.*)')
RE_SKIP = re.compile(r'^➜ (Test|Suite) (\S+) skipped')
RE_RUN = re.compile(r'Test run with (\d+) tests? in (\d+) suites? (passed|failed) after ([\d.]+) seconds')
RE_STAMP = re.compile(r'check-(\d{8}T\d{6}-\d+)\.log$')


def refuse_documents(path):
    if os.path.abspath(path).startswith(os.path.expanduser('~/Documents')):
        sys.exit(f'test-ledger: refusing a ledger under ~/Documents: {path}')


def tree_index():
    """Type names and test functions per test target, from the checked-out tree."""
    types, funcs = {}, defaultdict(lambda: defaultdict(set))
    tests = os.path.join(ROOT, 'Tests')
    re_type = re.compile(r'^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|internal|public|final)\s+)*(?:struct|class|actor|enum|extension)\s+([A-Za-z0-9_]+)')
    re_func = re.compile(r'@Test\b[^\n]*?\bfunc\s+([A-Za-z0-9_]+)|^\s*(?:@\w+\s+)*func\s+([A-Za-z0-9_]+)')
    if not os.path.isdir(tests):
        return types, funcs
    for target in sorted(os.listdir(tests)):
        folder = os.path.join(tests, target)
        if not os.path.isdir(folder):
            continue
        for base, _, names in os.walk(folder):
            for name in names:
                if not name.endswith('.swift'):
                    continue
                owner = None
                pending_test = False
                for line in open(os.path.join(base, name), encoding='utf-8', errors='replace'):
                    m = re_type.match(line)
                    if m:
                        types.setdefault(m.group(1), target)
                        owner = m.group(1)
                    if '@Test' in line:
                        pending_test = True
                    m = re_func.search(line)
                    if m and (m.group(1) or pending_test):
                        funcs[target][m.group(1) or m.group(2)].add(owner)
                        pending_test = False
    return types, funcs


def parse_log(path, source=None):
    """Runs of one log: [{step, config, target?, summary, suites, tests}]."""
    stamp = RE_STAMP.search(path)
    stamp = stamp.group(1) if stamp else os.path.basename(path)
    runs, cur, step = [], None, None
    for raw in open(path, encoding='utf-8', errors='replace'):
        line = raw.rstrip('\n')
        m = RE_SOURCE.match(line)
        if m and not source:
            source = m.group(1) + (m.group(2) or '')
            continue
        m = RE_STEP.match(line)
        if m:
            step = m.group(1)
            continue
        if 'Test run started.' in line:
            cur = {'step': step, 'tests': [], 'suites': [], 'issues': defaultdict(list), 'known': defaultdict(list),
                   'skipped': [], 'summary': None}
            runs.append(cur)
            continue
        if cur is None:
            continue
        m = RE_TEST.match(line)
        if m:
            cur['tests'].append((m.group(1), int(m.group(2) or 1), m.group(3), float(m.group(4))))
            continue
        m = RE_SUITE.match(line)
        if m:
            cur['suites'].append((m.group(1), m.group(2), float(m.group(3))))
            continue
        m = RE_ISSUE.match(line)
        if m:
            cur['issues'][m.group(1)].append({'at': m.group(2), 'message': m.group(3)[:240]})
            continue
        m = RE_KNOWN.match(line)
        if m:
            cur['known'][m.group(1)].append({'at': m.group(2), 'message': m.group(3)[:240]})
            continue
        m = RE_SKIP.match(line)
        if m:
            cur['skipped'].append(m.group(2))
            continue
        m = RE_RUN.search(line)
        if m:
            cur['summary'] = {'tests': int(m.group(1)), 'suites': int(m.group(2)), 'status': m.group(3),
                              'seconds': float(m.group(4))}
    return stamp, source, runs


def records(path, source=None):
    stamp, source, runs = parse_log(path, source)
    types, funcs = tree_index()
    log = os.path.basename(path)
    out = []
    for index, run in enumerate(runs):
        votes = Counter(types.get(s[0]) for s in run['suites'] if types.get(s[0]))
        target = votes.most_common(1)[0][0] if votes else None
        step = run['step'] or ''
        config = 'release' if '-c release' in step else 'debug'
        base = {'stamp': stamp, 'source': source, 'run': index, 'target': target}
        summary = run['summary'] or {}
        out.append(dict(base, kind='run', log=log, step=step, config=config, tests=summary.get('tests'),
                        suites=summary.get('suites'), status=summary.get('status', 'incomplete'),
                        seconds=summary.get('seconds'), issues=sum(len(v) for v in run['issues'].values()),
                        skipped=len(run['skipped'])))
        for name, status, seconds in run['suites']:
            out.append(dict(base, kind='suite', suite=name, status=status, seconds=seconds))
        for name, cases, status, seconds in run['tests']:
            owners = funcs.get(target, {}).get(name.split('(')[0], set())
            row = dict(base, kind='test', test=name, status=status, seconds=seconds)
            if len(owners) == 1:
                row['suite'] = next(iter(owners))
            if cases > 1:
                row['cases'] = cases
            if run['issues'].get(name):
                row['issues'] = run['issues'][name]
            if run['known'].get(name):
                row['known'] = run['known'][name]
            out.append(row)
    return stamp, out


def load():
    if not os.path.exists(LEDGER):
        return []
    with open(LEDGER, encoding='utf-8') as f:
        return [json.loads(line) for line in f if line.strip()]


def by_stamp(rows):
    grouped = defaultdict(list)
    for r in rows:
        grouped[r['stamp']].append(r)
    return grouped


def test_runs(rows):
    """Stamps that hold at least one test run, oldest first."""
    return sorted({r['stamp'] for r in rows if r['kind'] == 'run'})


def cmd_ingest(args):
    refuse_documents(LEDGER)
    force = '--force' in args
    args = [a for a in args if a != '--force']
    rows = load()
    have = {r['stamp'] for r in rows}
    if args:
        targets = []
        for a in args:
            path, _, sha = a.partition('=')
            targets.append((path, sha or None))
    else:
        targets = [(os.path.join(LOG_DIR, n), None) for n in sorted(os.listdir(LOG_DIR)) if RE_STAMP.search(n)]
    added = 0
    for path, sha in targets:
        stamp = RE_STAMP.search(path)
        stamp = stamp.group(1) if stamp else os.path.basename(path)
        if stamp in have and not force:
            continue
        stamp, new = records(path, sha)
        if not any(r['kind'] == 'run' for r in new):
            continue
        rows = [r for r in rows if r['stamp'] != stamp] + new
        have.add(stamp)
        added += 1
        tests = sum(1 for r in new if r['kind'] == 'test')
        print(f'ingested {os.path.basename(path)}: {sum(1 for r in new if r["kind"] == "run")} runs, {tests} tests'
              + (f', source {new[0]["source"]}' if new[0]['source'] else ''))
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    tmp = LEDGER + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False, separators=(',', ':')) + '\n')
    os.replace(tmp, LEDGER)
    print(f'{added} log(s) added; ledger {LEDGER}: {len(test_runs(rows))} logs with test runs')


def cmd_runs(args):
    rows = load()
    last = int(args[args.index('--last') + 1]) if '--last' in args else None
    grouped = by_stamp(rows)
    stamps = test_runs(rows)
    for stamp in stamps[-last:] if last else stamps:
        runs = [r for r in grouped[stamp] if r['kind'] == 'run']
        tests = sum(r['tests'] or 0 for r in runs)
        wall = sum(r['seconds'] or 0 for r in runs)
        issues = sum(r['issues'] for r in runs)
        failed = sum(1 for r in runs if r['status'] != 'passed')
        print(f'{stamp}  source {runs[0]["source"] or "?":<10} runs {len(runs)}  tests {tests:>5}  wall {wall:7.1f} s  '
              f'issues {issues:>3}  {"FAIL" if failed else "pass"}')


def resolve(rows, arg):
    if arg is None:
        stamps = test_runs(rows)
        if not stamps:
            sys.exit('test-ledger: the ledger has no test runs')
        return stamps[-1]
    matches = [s for s in test_runs(rows) if arg in s]
    if len(matches) != 1:
        sys.exit(f'test-ledger: {arg!r} matches {len(matches)} logs')
    return matches[0]


def heavy_suites():
    """Suites that carry `.processHeavy` in the tree (their sum is the serial chain)."""
    found = set()
    tests = os.path.join(ROOT, 'Tests')
    re_suite = re.compile(r'@Suite\(([^)]*processHeavy[^)]*)\)[\s\S]{0,200}?(?:struct|class|actor|enum)\s+([A-Za-z0-9_]+)')
    for base, _, names in os.walk(tests):
        for name in names:
            if name.endswith('.swift'):
                text = open(os.path.join(base, name), encoding='utf-8', errors='replace').read()
                found.update(m.group(2) for m in re_suite.finditer(text))
    return found


def cmd_summary(args):
    if '--log' in args:
        stamp, rows = records(args[args.index('--log') + 1])
    else:
        rows = load()
        stamp = resolve(rows, args[0] if args else None)
        rows = by_stamp(rows)[stamp]
    heavy = heavy_suites()
    print(f'{stamp} (source {rows[0]["source"] or "?"})')
    print(f'  {"target":<24} {"config":<8} {"tests":>6} {"wall s":>8} {"heavy chain s":>14} {"issues":>7}  step')
    total = 0.0
    for r in [r for r in rows if r['kind'] == 'run']:
        chain = sum(s['seconds'] for s in rows if s['kind'] == 'suite' and s['run'] == r['run'] and s['suite'] in heavy)
        total += r['seconds'] or 0
        print(f'  {r["target"] or "?":<24} {r["config"]:<8} {r["tests"] or 0:>6} {r["seconds"] or 0:>8.1f} {chain:>14.1f} '
              f'{r["issues"]:>7}  {r["step"][:60]}')
    print(f'  total test wall {total:.1f} s')
    tests = sorted((r for r in rows if r['kind'] == 'test'), key=lambda r: -r['seconds'])[:5]
    print('  slowest tests:')
    for r in tests:
        print(f'    {r["seconds"]:7.1f} s  {r["target"]}/{r["test"]}' + (f' x{r["cases"]}' if r.get('cases', 1) > 1 else ''))
    failing = [r for r in rows if r['kind'] == 'test' and r.get('issues')]
    if failing:
        print(f'  failing tests: {len(failing)}')
        for r in failing:
            print(f'    {r["target"]}/{r["test"]}: {len(r["issues"])} issue(s) at {r["issues"][0]["at"]}')


def cmd_failures(args):
    rows = load()
    stamps = [resolve(rows, a) for a in args] if args else test_runs(rows)
    grouped = by_stamp(rows)
    table = defaultdict(dict)
    where = {}
    for stamp in stamps:
        for r in grouped[stamp]:
            if r['kind'] == 'test' and r.get('issues'):
                key = f'{r["target"]}/{r["test"]}'
                table[key][stamp] = len(r['issues'])
                where.setdefault(key, r['issues'][0]['at'])
    print(f'{len(table)} failing tests across {len(stamps)} logs; issues per log: '
          + ', '.join(f'{s} {sum(v.get(s, 0) for v in table.values())}' for s in stamps))
    for key in sorted(table):
        print(f'  {key:<100} ' + ' '.join(f'{table[key].get(s, "-"):>3}' for s in stamps) + f'  {where[key]}')


def cmd_flakes(args):
    any_source = '--any-source' in args
    rows = [r for r in load() if r['kind'] == 'test']
    outcomes = defaultdict(lambda: defaultdict(set))
    for r in rows:
        if r['source'] is None and not any_source:
            continue
        key = f'{r["target"]}/{r["test"]}'
        group = 'any' if any_source else r['source']
        outcomes[key][group].add((r['stamp'], 'failed' if r.get('issues') else 'passed'))
    found = []
    for key, groups in outcomes.items():
        for source, seen in groups.items():
            kinds = {k for _, k in seen}
            if kinds == {'failed', 'passed'}:
                fails = sorted(s for s, k in seen if k == 'failed')
                passes = sorted(s for s, k in seen if k == 'passed')
                found.append((key, source, fails, passes))
    label = 'across sources (candidates only)' if any_source else 'on the same source'
    print(f'{len(found)} test(s) failed and passed {label}')
    for key, source, fails, passes in sorted(found):
        print(f'  {key}  source {source}: failed in {", ".join(fails)}; passed in {len(passes)} log(s)')


def cmd_diff(args):
    if len(args) != 2:
        sys.exit('usage: test-ledger.py diff <stamp> <stamp>')
    rows = load()
    a, b = (resolve(rows, x) for x in args)
    grouped = by_stamp(rows)

    def tests(stamp):
        return {f'{r["target"]}/{r["test"]}': r for r in grouped[stamp] if r['kind'] == 'test'}
    ta, tb = tests(a), tests(b)
    fa = {k for k, r in ta.items() if r.get('issues')}
    fb = {k for k, r in tb.items() if r.get('issues')}
    print(f'{a} → {b}: tests {len(ta)} → {len(tb)}; failing {len(fa)} → {len(fb)}')
    for title, keys in (('newly failing', fb - fa), ('fixed', fa & set(tb) - fb), ('gone', set(ta) - set(tb)),
                        ('new', set(tb) - set(ta))):
        if keys:
            print(f'  {title} ({len(keys)}):')
            for k in sorted(keys)[:40]:
                print(f'    {k}')
    slower = sorted(((tb[k]['seconds'] - ta[k]['seconds'], k) for k in set(ta) & set(tb)
                     if tb[k]['seconds'] > 2 * ta[k]['seconds'] and tb[k]['seconds'] - ta[k]['seconds'] > 1), reverse=True)
    if slower:
        print('  slower by more than 2x and 1 s:')
        for delta, k in slower[:10]:
            print(f'    +{delta:6.1f} s  {k}  ({ta[k]["seconds"]:.2f} → {tb[k]["seconds"]:.2f})')
    ra = {r['target']: r for r in grouped[a] if r['kind'] == 'run'}
    rb = {r['target']: r for r in grouped[b] if r['kind'] == 'run'}
    for t in sorted(set(ra) | set(rb), key=str):
        wa = ra.get(t, {}).get('seconds') or 0
        wb = rb.get(t, {}).get('seconds') or 0
        print(f'  wall {str(t):<24} {wa:8.1f} → {wb:8.1f} s')


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    commands = {'ingest': cmd_ingest, 'runs': cmd_runs, 'summary': cmd_summary, 'failures': cmd_failures,
                'flakes': cmd_flakes, 'diff': cmd_diff}
    if argv[0] not in commands:
        print(__doc__, file=sys.stderr)
        return 2
    commands[argv[0]](argv[1:])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
