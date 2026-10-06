#!/usr/bin/env python3
"""Verify one evidence run's normal Quit and recorded app, fixture, run-host and scope-member birth identities.

Usage: cp5-d-check-quit.py <evidence-directory> [app]. With the app path, no run host of that package may remain
(checked by path, independent of the recorded identities).
"""
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('cp5d', Path(__file__).with_name('cp5-d-measure.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
directory = Path(sys.argv[1])
quit_result = module.wait_json(directory / 'quit.json', 30)
errors = []
if not quit_result.get('succeeded') or quit_result.get('remaining') != 0:
    errors.append('Quit did not verify empty ownership')
identities = []
for label in ('start', 'end'):
    path = directory / f'resource-{label}.json'
    if not path.exists():
        errors.append(f"Recorded {label} resource snapshot missing")
        continue
    if path.exists():
        data = json.loads(path.read_text())['result']
        identities += [data['appIdentity']] + [row['identity'] for row in data['supervisorRuns']]
        scope = data.get('scope')
        if not isinstance(scope, dict) or scope.get('valid') is not True:
            errors.append(f"Recorded {label} scope accounting missing or invalid")
        else:
            identities += [row['identity'] for kind in ('hosts', 'others') for row in scope[kind]]
registry = {}
for expected in identities:
    if not isinstance(expected, dict) or any(key not in expected for key in ('pid', 'startSeconds', 'startMicroseconds')):
        errors.append('Recorded birth identity missing or malformed')
        continue
    registry[tuple(expected[key] for key in ('pid', 'startSeconds', 'startMicroseconds'))] = expected
if not registry:
    errors.append('Recorded birth identities missing')
for expected in registry.values():
    try:
        current = module.identity(expected['pid'])
    except module.ProcessIdentityQueryError as error:
        errors.append(f'Process identity query failed: {error}')
        continue
    if current == expected:
        errors.append(f'Registered identity remains: {expected}')
if len(sys.argv) > 2:
    deadline = module.time.monotonic() + 15
    hosts = module.host_pids(sys.argv[2])
    while hosts and module.time.monotonic() < deadline:
        module.time.sleep(.1)
        hosts = module.host_pids(sys.argv[2])
    if hosts:
        errors.append(f'Run hosts remain after Quit: {hosts}')
report = {'succeeded': not errors, 'errors': errors, 'registeredIdentities': len(registry)}
(directory / 'cleanup-verified.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
sys.exit(0 if report['succeeded'] else 1)
