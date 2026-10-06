#!/usr/bin/env python3
"""Judges a perf/run-final-matrix.py run against the package I baseline (plans/experiments/cp5-final-matrix-I-20261006.json).
Usage: scripts/perf/compare_baseline.py <run-dir> [--baseline <json>]
       scripts/perf/compare_baseline.py --self-test
Reads <run-dir>/cells/<name>/result.json (and progress.jsonl when present). Cells named ref-* are the reference package
(run-final-matrix.py --reference-app); the others are the candidate. Prints a table; exit 0 when every gate holds,
1 when any gate fails (a missing cell group or an invalid cell fails too), 2 on usage or unreadable input.
No measurement happens here: this only reads files."""
import argparse, json, pathlib, shutil, statistics, sys, tempfile

# Regression gates of the multi-agent run, not product budgets (the budgets in LOOM-PRODUCT-CONTRACT.md §10 are
# still open: DECISIONS O-01). CPU is percent of one core, latency milliseconds.
CPU40_TOTAL = 40.0                  # stream1 total Loom CPU must stay below this (contract CPU40)
STREAM1_APP_OVER_REFERENCE = 1.5    # candidate stream1 app median may exceed the reference median by this much ...
STREAM1_APP_OVER_BASELINE = 1.5     # ... or, without a reference, the baseline maximum
SPINNER1_OVER_BASELINE = 2.5        # spinner1 app median over the baseline maximum
HIDDEN_STREAM1_OVER_BASELINE = 1.0  # hidden stream1 app over the baseline
LATENCY_P95_MS = 25.0               # input-to-draw p95 median must stay at or below this

DEFAULT_BASELINE = pathlib.Path(__file__).resolve().parents[2] / 'plans/experiments/cp5-final-matrix-I-20261006.json'


def as_list(value):
    return [value] if isinstance(value, (int, float)) else list(value)


def load_baseline(path):
    data = json.loads(pathlib.Path(path).read_text())
    matrix = data['matrix']
    return {'stream1App': as_list(matrix['stream1Visible']['appCPU']),
            'stream1Total': as_list(matrix['stream1Visible']['totalCPU']),
            'spinner1App': as_list(matrix['spinner1Visible']['appCPU']),
            'hiddenApp': as_list(matrix['stream1Hidden']['appCPU']),
            'latencyP95': as_list(matrix['latency']['p95Ms'])}


def load_cells(run_dir):
    """Returns (cells, problems). A cell: name, reference, scenario, visibility, valid, app, total, p95."""
    cells, problems = [], []
    cell_root = run_dir / 'cells'
    if not cell_root.is_dir():
        return cells, [f'no cells directory in {run_dir}']
    for directory in sorted(cell_root.iterdir()):
        name = directory.name
        if not directory.is_dir() or '.invalid-' in name:   # moved-aside failed attempts; the retry has the cell's name
            continue
        scenario = next((s for s in ('stream1', 'spinner1', 'latency') if name.endswith(s) or f'-{s}' in name), None)
        visibility = 'hidden' if '-hidden-' in name else 'visible'
        cell = {'name': name, 'reference': name.startswith('ref-'), 'scenario': scenario, 'visibility': visibility,
                'valid': False, 'app': None, 'total': None, 'p95': None}
        try:
            result = json.loads((directory / 'result.json').read_text())
        except (OSError, ValueError) as error:
            problems.append(f'{name}: no readable result.json ({error})')
            cells.append(cell)
            continue
        metrics = result.get('metrics') or {}
        cell.update(valid=result.get('valid') is True, app=metrics.get('appCPUPercentOfOneCore'),
                    total=metrics.get('totalLoomCPUPercentOfOneCore'),
                    p95=(result.get('inputToDraw') or {}).get('p95Milliseconds'))
        cell['scenario'] = result.get('scenario') or scenario
        if not cell['valid']:
            problems.append(f"{name}: invalid ({'; '.join(result.get('invalidReasons') or ['valid is not true'])})")
        elif cell['scenario'] in ('stream1', 'spinner1') and cell['app'] is None:
            cell['valid'] = False
            problems.append(f'{name}: no appCPUPercentOfOneCore')
        elif cell['scenario'] == 'stream1' and cell['total'] is None:
            cell['valid'] = False
            problems.append(f'{name}: no totalLoomCPUPercentOfOneCore (unreadable scope member)')
        elif cell['scenario'] == 'latency' and cell['p95'] is None:
            cell['valid'] = False
            problems.append(f'{name}: no inputToDraw.p95Milliseconds')
        cells.append(cell)
    progress = run_dir / 'progress.jsonl'
    if progress.exists():
        stages = []
        for line in progress.read_text().splitlines():
            try:
                stages.append(json.loads(line).get('stage'))
            except ValueError:
                pass
        if 'complete' not in stages:
            problems.append('progress.jsonl has no "complete" event (run unfinished or aborted)')
    return cells, problems


def median(values):
    return statistics.median(values) if values else None


def evaluate(cells, problems, baseline):
    """Returns table rows (gate, observed, limit, verdict); verdict 'PASS' or 'FAIL'."""
    rows = []

    def gate(name, observed, limit, failed):
        rows.append((name, 'n/a' if observed is None else f'{observed:.2f}', limit, 'FAIL' if failed else 'PASS'))

    def group(scenario, visibility, reference=False):
        return [c for c in cells if c['scenario'] == scenario and c['visibility'] == visibility
                and c['reference'] == reference and c['valid']]

    for problem in problems:
        rows.append(('cell', problem, '', 'FAIL'))
    stream_cells, ref_cells = group('stream1', 'visible'), group('stream1', 'visible', reference=True)
    spinner_cells, hidden_cells = group('spinner1', 'visible'), group('stream1', 'hidden')
    latency_cells = group('latency', 'visible')

    stream_total_max = max((c['total'] for c in stream_cells + hidden_cells), default=None)
    gate('stream1 total CPU max (CPU40)', stream_total_max, f'< {CPU40_TOTAL}', stream_total_max is None or stream_total_max >= CPU40_TOTAL)

    stream_app = median([c['app'] for c in stream_cells])
    if ref_cells:
        ref_app = median([c['app'] for c in ref_cells])
        limit = ref_app + STREAM1_APP_OVER_REFERENCE
        gate(f'stream1 app median vs reference ({ref_app:.2f})', stream_app, f'<= {limit:.2f}', stream_app is None or stream_app > limit)
    else:
        limit = max(baseline['stream1App']) + STREAM1_APP_OVER_BASELINE
        gate('stream1 app median vs baseline max', stream_app, f'<= {limit:.2f}', stream_app is None or stream_app > limit)

    spinner = median([c['app'] for c in spinner_cells])
    limit = max(baseline['spinner1App']) + SPINNER1_OVER_BASELINE
    gate('spinner1 app median vs baseline max', spinner, f'<= {limit:.2f}', spinner is None or spinner > limit)

    hidden = median([c['app'] for c in hidden_cells])
    limit = max(baseline['hiddenApp']) + HIDDEN_STREAM1_OVER_BASELINE
    gate('stream1 hidden app vs baseline', hidden, f'<= {limit:.2f}', hidden is None or hidden > limit)

    p95 = median([c['p95'] for c in latency_cells])
    gate('latency p95 median (ms)', p95, f'<= {LATENCY_P95_MS:.2f}', p95 is None or p95 > LATENCY_P95_MS)
    return rows


def print_table(cells, rows):
    print('cells (CPU % of one core; latency p95 ms):')
    for c in cells:
        value = c['p95'] if c['scenario'] == 'latency' else c['app']
        total = f"  total {c['total']:.2f}" if c['total'] is not None else ''
        shown = 'n/a' if value is None else f'{value:.2f}'
        print(f"  {c['name']:<34} {'valid' if c['valid'] else 'INVALID':<8} {shown}{total}")
    print('gates:')
    for name, observed, limit, verdict in rows:
        print(f'  {verdict:<5} {name:<48} {observed:<10} {limit}')


def judge(run_dir, baseline_path):
    baseline = load_baseline(baseline_path)
    cells, problems = load_cells(run_dir)
    rows = evaluate(cells, problems, baseline)
    return cells, rows, all(row[3] == 'PASS' for row in rows)


def self_test():
    """Builds matrix runs in the shape run-final-matrix.py writes, from the baseline JSON, and checks the verdicts."""
    baseline_path = DEFAULT_BASELINE
    baseline = load_baseline(baseline_path)

    def write_cell(root, name, scenario, app=None, total=None, p95=None, valid=True):
        directory = root / 'cells' / name
        directory.mkdir(parents=True)
        result = {'valid': valid, 'invalidReasons': [] if valid else ['synthetic'], 'scenario': scenario,
                  'metrics': {'appCPUPercentOfOneCore': app, 'totalLoomCPUPercentOfOneCore': total}}
        if p95 is not None:
            result['inputToDraw'] = {'p95Milliseconds': p95}
        (directory / 'result.json').write_text(json.dumps(result))

    def build(reference=None, stream_add=0.0, spinner_add=0.0, hidden_add=0.0, p95_add=0.0, total_add=0.0, complete=True,
              broken=None):
        root = pathlib.Path(tempfile.mkdtemp(prefix='compare-baseline-selftest-'))
        for r in range(3):
            if reference:
                write_cell(root, f'ref-cg-visible-r{r + 1}-stream1', 'stream1', reference[r], reference[r] + 1.6)
            write_cell(root, f'I-cg-visible-r{r + 1}-stream1', 'stream1', baseline['stream1App'][r] + stream_add,
                       baseline['stream1Total'][r] + total_add)
            write_cell(root, f'I-cg-visible-r{r + 1}-spinner1', 'spinner1', baseline['spinner1App'][r] + spinner_add, 14.0)
        write_cell(root, 'I-cg-hidden-r1-stream1', 'stream1', baseline['hiddenApp'][0] + hidden_add, 5.16)
        for r in range(2):
            write_cell(root, f'I-latency-coregraphics-r{r + 1}', 'latency', None, None, baseline['latencyP95'][r] + p95_add)
        if broken == 'invalid':
            shutil.rmtree(root / 'cells/I-latency-coregraphics-r2')
            write_cell(root, 'I-latency-coregraphics-r2', 'latency', valid=False)
        if broken == 'missing-result':
            (root / 'cells/I-cg-hidden-r1-stream1/result.json').unlink()
        if broken == 'aborted-retry-ignored':   # an earlier failed attempt moved aside by the runner must not fail the run
            write_cell(root, 'I-cg-hidden-r1-stream1.invalid-1', 'stream1', valid=False)
        if complete:
            (root / 'progress.jsonl').write_text(json.dumps({'stage': 'complete', 'count': 9}) + '\n')
        else:
            (root / 'progress.jsonl').write_text(json.dumps({'stage': 'start'}) + '\n')
        return root

    def failing(root):
        """Names of the failed gate rows ('' joined); empty when the run passes."""
        return ' | '.join(f'{row[0]} {row[1]}' for row in judge(root, baseline_path)[1] if row[3] == 'FAIL')

    stable_ref = baseline['stream1App']
    cases = [
        ('baseline values pass without a reference', build(), True),
        ('baseline values pass with a matching reference', build(reference=stable_ref), True),
        ('retry leftovers are ignored', build(broken='aborted-retry-ignored'), True),
        ('stream1 +1.4 over baseline max passes', build(stream_add=1.4 - (max(baseline['stream1App']) - baseline['stream1App'][1])), True),
        ('stream1 total at 40 fails (CPU40)', build(total_add=40 - baseline['stream1Total'][0]), 'CPU40'),
        ('stream1 app +3 over baseline fails', build(stream_add=3.0), 'vs baseline max'),
        ('stream1 app over reference + 1.5 fails', build(reference=[v - 2.0 for v in stable_ref]), 'vs reference'),
        ('spinner1 +3 over baseline max fails', build(spinner_add=3.0 + max(baseline['spinner1App']) - min(baseline['spinner1App'])), 'spinner1'),
        ('hidden stream1 +1.2 fails', build(hidden_add=1.2), 'hidden'),
        ('latency p95 over 25 ms fails', build(p95_add=6.0), 'latency'),
        ('an invalid cell fails', build(broken='invalid'), 'invalid'),
        ('a cell without result.json fails', build(broken='missing-result'), 'no readable result.json'),
        ('an unfinished run fails', build(complete=False), 'complete'),
    ]
    failures = 0
    for label, root, expected in cases:
        actual = failing(root)
        ok = (not actual) if expected is True else (expected in actual)
        failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {label} (failed: {actual or 'nothing'})")
        shutil.rmtree(root, ignore_errors=True)
    empty = pathlib.Path(tempfile.mkdtemp(prefix='compare-baseline-selftest-'))
    ok = bool(failing(empty))
    shutil.rmtree(empty, ignore_errors=True)
    failures += not ok
    print(f"  {'ok  ' if ok else 'FAIL'} an empty run directory fails")
    print('self-test ' + ('FAIL' if failures else 'PASS'))
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('run_dir', nargs='?', type=pathlib.Path)
    parser.add_argument('--baseline', type=pathlib.Path, default=DEFAULT_BASELINE, help=f'baseline JSON (default: {DEFAULT_BASELINE.name})')
    parser.add_argument('--self-test', action='store_true', help='check the gates on synthetic runs built from the baseline JSON')
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.run_dir is None:
        parser.error('run_dir is required (or --self-test)')
    try:
        cells, rows, passed = judge(args.run_dir, args.baseline)
    except (OSError, ValueError, KeyError) as error:
        print(f'compare_baseline: cannot read input: {error}', file=sys.stderr)
        return 2
    print_table(cells, rows)
    print('verdict: ' + ('PASS' if passed else 'FAIL'))
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
