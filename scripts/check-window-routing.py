"""Exercise check.sh's real tier routing with a recording Swift stub; no Swift or window test runs.

A tier is its targets (DEVELOPMENT §2): T1 the area targets, T2 LoomIntegrationTests, T3 LoomWindowTests (always a
swift test of its own, last), TF LoomFrozenTests. --suite never reaches the window or frozen target.
"""
from pathlib import Path
import json, os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parent.parent
UNIT = ['LoomCoreTests', 'LoomTerminalTests', 'LoomChatTests', 'LoomRemoraTests', 'LoomLaunchOptionsTests', 'LoomCatalogUITests']
STUB = '''#!{python}
import json, os, sys
with open(os.environ["LOOM_ROUTING_CAPTURE"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1] == "test":
    print("Test run started.")
    print("Test run with 0 tests passed after 0.001 seconds.")
if sys.argv[1] == "build" and "--package-path" in sys.argv:
    # the staged release tree's build: leave the binary its check reads
    out = os.path.join(sys.argv[sys.argv.index("--scratch-path") + 1], "release")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "loom-app"), "w") as f:
        f.write("#!/bin/sh\\n")
    os.chmod(os.path.join(out, "loom-app"), 0o755)
'''


def probe(flags):
    with tempfile.TemporaryDirectory(prefix='loom-check-routing-', dir='/private/tmp') as tmp:
        fixture = Path(tmp)
        for name in ['check.sh', 'dev-paths.sh', 'with-build-slot.sh', 'check-theme-literals.sh', 'check-user-wording.sh',
                     'check-user-wording.allow', 'check-selectable-labels.sh', 'test-ledger.py', 'release/allowlist.sh',
                     'release/Package.release.swift']:
            dst = fixture / 'scripts' / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / 'scripts' / name, dst)
        # The guards read the real Sources/ and Tests/; the fixture has neither, and routing is what it checks.
        for name in ['check-source-guards.py', 'check-tests.py']:
            (fixture / 'scripts' / name).write_text('print("guard stub")\n')
        for name in ['LoomCatalogUI', 'loom-app', 'LoomCore', 'LoomChat', 'LoomLaunchOptions', 'LoomRemora']:
            (fixture / 'Sources' / name).mkdir(parents=True)
            (fixture / 'Sources' / name / 'Fixture.swift').write_text('// Isolated routing fixture.\n')
        (fixture / 'bin').mkdir()
        stub = fixture / 'bin/swift'
        stub.write_text(STUB.format(python=sys.executable))
        stub.chmod(0o755)
        subprocess.run(['git', 'init', '-q', tmp], check=True, capture_output=True)
        capture = fixture / 'swift-args.jsonl'
        env = dict(os.environ, PATH=str(fixture / 'bin') + os.pathsep + os.environ['PATH'], LOOM_ROUTING_CAPTURE=str(capture),
                   LOOM_BUILD_LOCK=str(fixture / 'slot.lock'), LOOM_CHECK_LOG_DIR=str(fixture / 'logs'))
        p = subprocess.run([str(fixture / 'scripts/check.sh'), '--scratch', str(fixture / 'build'), *flags], cwd=tmp, env=env,
                           capture_output=True, text=True)
        calls = [json.loads(x) for x in capture.read_text().splitlines()] if capture.exists() else []
        return p.returncode, calls, p.stdout + p.stderr


def filters(call):
    return [b for a, b in zip(call, call[1:]) if a == '--filter']


def skips(call):
    return [b for a, b in zip(call, call[1:]) if a == '--skip']


def tests(calls):
    return [c for c in calls if c and c[0] == 'test']


unit = [f'^{t}\\.' for t in UNIT]

code, calls, out = probe(['--suite', 'InspectorResizeWindowTests'])
assert code == 0, out
t = tests(calls)
assert len(t) == 1 and filters(t[0]) == ['InspectorResizeWindowTests'], t
assert skips(t[0]) == ['^LoomWindowTests\\.', '^LoomFrozenTests\\.'], t
print('PASS: --suite skips the window and frozen targets')

code, calls, out = probe(['--unit'])
assert code == 0 and len(tests(calls)) == 1 and filters(tests(calls)[0]) == unit, (code, calls, out)
print('PASS: --unit runs the area targets (T1) and nothing else')

code, calls, out = probe(['--tests'])
assert code == 0 and len(tests(calls)) == 1, (code, calls, out)
assert filters(tests(calls)[0]) == unit + ['^LoomIntegrationTests\\.'], calls
assert '-c' not in tests(calls)[0], calls
print('PASS: --tests runs T1 and T2 in debug in one swift test, no window or frozen target')

code, calls, out = probe(['--integration', '--frozen'])
t = tests(calls)
assert code == 0 and [filters(c) for c in t] == [['^LoomIntegrationTests\\.'], ['^LoomFrozenTests\\.']], (code, calls, out)
print('PASS: --integration and --frozen run their targets, frozen after')

code, calls, out = probe(['--frozen', '--suite', 'RealClaudeSmokeTests'])
t = tests(calls)
assert code == 0 and len(t) == 1 and filters(t[0]) == ['RealClaudeSmokeTests'] and skips(t[0]) == ['^LoomWindowTests\\.'], (code, calls, out)
print('PASS: --frozen --suite runs the named suites in the frozen target too, not the whole lane')

code, calls, out = probe(['--windows'])
assert code == 2 and not calls, (code, calls, out)
print('PASS: --windows without --idle is refused before Swift is called')

code, calls, out = probe(['--tests', '--windows', '--idle'])
t = tests(calls)
assert code == 0 and len(t) == 2 and filters(t[-1]) == ['^LoomWindowTests\\.'], (code, calls, out)
print('PASS: --windows runs LoomWindowTests in a swift test of its own, after the rest')

code, calls, out = probe(['--full', '--idle'])
t = tests(calls)
builds = [c for c in calls if c and c[0] == 'build']
assert code == 0, out
assert all('--package-path' in c for c in builds) and len(builds) == 1, f'--full builds only the staged release tree: {builds}'
assert len(t) == 2 and all(c[c.index('-c') + 1] == 'release' for c in t), t
assert filters(t[0]) == unit + ['^LoomIntegrationTests\\.'] and filters(t[1]) == ['^LoomWindowTests\\.'], t
assert not any('^LoomFrozenTests\\.' in filters(c) for c in t), t
print('PASS: --full is the release tree, then T1 and T2 in release, then T3 alone; no plain release build, no frozen')
