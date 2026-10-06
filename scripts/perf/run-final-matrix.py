#!/usr/bin/env python3
"""Short CP5 on-screen CPU matrix (cp5-d-measure.py cells, coregraphics): 3x stream1 and spinner1 visible,
1x stream1 hidden, 2x latency (200 samples). Heavy cells are preceded by a 90 s cooldown; every cell is retried once.
HEAVY: run only when the user says the Mac is idle and the Loom window may stay on screen.
Usage: scripts/perf/run-final-matrix.py [--run-dir DIR] [--app 'Loom Dev.app'] [--reference-app 'Loom Dev.app']
With --reference-app, one reference stream1 cell is interleaved before each package stream1 cell (alternation).
Output: <run-dir>/{freeze.json,progress.jsonl,logs/,cells/<name>/result.json}."""
import argparse, json, hashlib, os, pathlib, subprocess, sys, time, shutil
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import perf_paths

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
perf_paths.add_common_arguments(parser, 'matrix')
parser.add_argument('--reference-app', type=pathlib.Path, default=None, help='older package to alternate against (optional)')
args = parser.parse_args()
app, root = perf_paths.resolve_common(args, 'matrix')
reference = str(perf_paths.refuse_documents('Reference app path', args.reference_app)) if args.reference_app else None
(root / 'cells').mkdir(parents=True, exist_ok=True)
H = str(app)
script = str(perf_paths.REPO / 'scripts/cp5-d-measure.py')
COOL = 90
def cmd(app_path, scen, vis, name, extra=()):
    return {'name': name, 'heavy': scen in ('stream1', 'spinner1'), 'command': ['python3', script, '--app', app_path, '--scenario', scen,
            '--visibility', vis, '--renderer', 'coregraphics', '--warmup', '10', '--duration', '60', '--sample-every', '5',
            '--output', str(root / 'cells' / name), *extra]}
rows = []
for r in range(1, 4):
    if reference:
        rows.append(cmd(reference, 'stream1', 'visible', f'ref-cg-visible-r{r}-stream1'))
    rows.append(cmd(H, 'stream1', 'visible', f'I-cg-visible-r{r}-stream1'))
    rows.append(cmd(H, 'spinner1', 'visible', f'I-cg-visible-r{r}-spinner1'))
rows.append(cmd(H, 'stream1', 'hidden', 'I-cg-hidden-r1-stream1'))
for r in range(1, 3):
    rows.append(cmd(H, 'latency', 'visible', f'I-latency-coregraphics-r{r}', ('--latency-samples', '200')))
inputs = [script, H + '/Contents/MacOS/Loom Dev', H + '/Contents/MacOS/loom-test-child']
hashes = {p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in inputs}
(root / 'freeze.json').write_text(json.dumps({'commands': rows, 'hashes': hashes, 'cooldownSeconds': COOL}, indent=1))
progress = root / 'progress.jsonl'; logs = root / 'logs'; logs.mkdir(exist_ok=True)
caffeine = subprocess.Popen(['/usr/bin/caffeinate', '-dimsu', '-w', str(os.getpid())])
def event(row):
    row['time'] = time.time()
    with progress.open('a') as f: f.write(json.dumps(row) + '\n')
try:
    for index, row in enumerate(rows):
        for p, h in hashes.items():
            if hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() != h:
                raise RuntimeError('Frozen input changed: ' + p)
        for attempt in (1, 2):
            if row['heavy']:
                event({'stage': 'cooldown', 'name': row['name'], 'seconds': COOL}); time.sleep(COOL)
            out = pathlib.Path(row['command'][row['command'].index('--output') + 1])
            if out.exists(): shutil.move(str(out), str(out) + f'.invalid-{int(time.time())}')
            event({'stage': 'start', 'index': index + 1, 'total': len(rows), 'name': row['name'], 'attempt': attempt})
            started = time.monotonic()
            with (logs / f"{row['name']}-a{attempt}.log").open('wb') as log:
                try:
                    child = subprocess.run(row['command'], stdout=log, stderr=subprocess.STDOUT, timeout=1600); code = child.returncode
                except subprocess.TimeoutExpired:
                    code = 'timeout'
            try: report = json.loads((out / 'result.json').read_text())
            except Exception as e: report = {'valid': False, 'invalidReasons': ['no result.json: ' + str(e)]}
            m = report.get('metrics', {})
            event({'stage': 'done', 'index': index + 1, 'name': row['name'], 'attempt': attempt, 'exit': code, 'valid': report.get('valid'),
                   'invalidReasons': report.get('invalidReasons'), 'seconds': time.monotonic() - started,
                   'CPU': {k: m.get(k) for k in ['appCPUPercentOfOneCore', 'totalLoomCPUPercentOfOneCore']}})
            if code == 0 and report.get('valid') is True: break
    event({'stage': 'complete', 'count': len(rows)})
finally:
    if caffeine.poll() is None: caffeine.terminate()
