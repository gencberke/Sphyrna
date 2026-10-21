#!/usr/bin/env python3
"""Launch-to-first-list measurement from Loom's own signposts (F5).

Launches each package with an isolated evidence directory and a copy of a seeded
catalog (`loom-catalog-fixture seed <root> <rows>`), lets it settle, quits it through
the evidence command channel and reads the `local.loom.desktop` signpost intervals of
that process with `log show --signpost`. Packages alternate run by run (A/B/A/B) so
drift hits both. Nothing here touches the default data root, the installed app or
a real provider profile.

  scripts/perf/launch_paint.py --seed 0=<root> --seed 1000=<root> --seed 10000=<root> \\
      --app before=<Loom Dev.app> --app after=<Loom Dev.app> --runs 5 --output <json>

Run it inside the build slot (scripts/with-build-slot.sh) so no build heats the Mac.
Output is value-free: per package and row count, per interval the samples, median,
min and max in milliseconds.
"""
import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from perf_paths import seed_remora_off  # noqa: E402
INTERVALS = ['LaunchToFirstPage', 'CatalogOpen', 'WindowShown', 'RuntimeStart', 'FirstPage']
COLUMNS = INTERVALS + [name + '.endsAt' for name in INTERVALS]


def refuse_documents(path):
    resolved = Path(path).expanduser().resolve()
    documents = (Path.home() / 'Documents').resolve()
    if resolved == documents or documents in resolved.parents:
        sys.exit(f'{path} is under ~/Documents; refused')


def send(evidence, command):
    script = f'source "{ROOT}/scripts/dev-paths.sh"; loom_send_command "{evidence}" "{command}"'
    subprocess.run(['zsh', '-c', script], check=True, timeout=30)


def signposts(pid, since):
    out = subprocess.run(
        ['/usr/bin/log', 'show', '--start', since, '--signpost', '--style', 'ndjson',
         '--predicate', f'subsystem == "local.loom.desktop" AND processID == {pid}'],
        capture_output=True, text=True, timeout=120, check=True).stdout
    begins, ends, result = {}, {}, {}
    for line in out.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        kind, name = row.get('signpostType'), row.get('signpostName')
        if name not in INTERVALS or 'timestamp' not in row:
            continue
        stamp = datetime.strptime(row['timestamp'], '%Y-%m-%d %H:%M:%S.%f%z').timestamp()
        if kind == 'begin':
            begins[name] = stamp
        elif kind == 'end' and name in begins:
            result[name] = (stamp - begins[name]) * 1000
            ends[name] = stamp
    # Where each interval ended, in ms after the app delegate was created: shows what waited for what.
    origin = begins.get('LaunchToFirstPage')
    if origin is not None:
        for name, stamp in ends.items():
            result[name + '.endsAt'] = (stamp - origin) * 1000
    return result


def one_run(app, seed, settle):
    executable = app / 'Contents/MacOS/Loom Dev'
    work = Path(tempfile.mkdtemp(prefix='loom-f5-', dir=Path.home() / 'Library/Caches/loom-run1'))
    try:
        data = work / 'data'
        shutil.copytree(seed, data)
        seed_remora_off(data)
        evidence = work / 'evidence'
        evidence.mkdir()
        since = datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S')
        log = (work / 'app.log').open('wb')
        process = subprocess.Popen([str(executable), '--evidence', str(evidence), '--data-root', str(data)],
                                   stdout=log, stderr=subprocess.STDOUT)
        time.sleep(settle)
        try:
            send(evidence, 'quit')
            process.wait(timeout=30)
        except Exception:
            process.kill()
            process.wait()
            raise
        time.sleep(1.5)  # the unified log flushes asynchronously
        return signposts(process.pid, since)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def summarize(samples):
    return {'samples': [round(value, 2) for value in samples], 'median': round(statistics.median(samples), 2),
            'min': round(min(samples), 2), 'max': round(max(samples), 2)}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--app', action='append', required=True, metavar='LABEL=PATH')
    parser.add_argument('--seed', action='append', required=True, metavar='ROWS=PATH')
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--settle', type=float, default=5.0, help='seconds the app runs before it is quit')
    parser.add_argument('--cooldown', type=float, default=3.0)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    apps = {label: Path(path).expanduser() for label, path in (item.split('=', 1) for item in args.app)}
    seeds = {rows: Path(path).expanduser() for rows, path in (item.split('=', 1) for item in args.seed)}
    for path in [*apps.values(), *seeds.values(), args.output]:
        refuse_documents(path)
    results = {label: {rows: {name: [] for name in COLUMNS} for rows in seeds} for label in apps}
    for rows, seed in seeds.items():
        for index in range(args.runs):
            for label, app in apps.items():
                measured = one_run(app, seed, args.settle)
                print(f'{label} rows={rows} run={index + 1}: '
                      + ' '.join(f'{name}={measured.get(name, float("nan")):.1f}' for name in INTERVALS), flush=True)
                for name in COLUMNS:
                    if name in measured:
                        results[label][rows][name].append(measured[name])
                time.sleep(args.cooldown)
    summary = {label: {rows: {name: summarize(values) for name, values in intervals.items() if values}
                       for rows, intervals in per_rows.items()} for label, per_rows in results.items()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'unit': 'ms', 'runs': args.runs, 'settleSeconds': args.settle,
                                       'results': summary}, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
