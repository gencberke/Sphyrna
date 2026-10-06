#!/usr/bin/env python3
"""Run-scope process probe for the acceptance scripts (no signals are sent).

Every run starts under a LaunchServices-launched run host in its own resource
coalition, so providers and fixtures are no longer children of the app. This
finds them by scope instead:

  cp5-scope-probe.py snapshot <app>            JSON of every host of this package and its coalition members
  cp5-scope-probe.py verify <app> <snapshot>   after Quit: recorded identities, recorded coalitions and any
                                               host of this package must all be gone (exit 0 only then)
  cp5-scope-probe.py hosts <app>               count of live hosts of this package
"""
import importlib.util, json, pathlib, sys, time

ROOT = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('own_native', ROOT / 'cp5-own-native.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
measure = native.measure


def host_path(app):
    return str(pathlib.Path(app).resolve() / 'Contents/Helpers/LoomRunHost.app/Contents/MacOS/loom-run-host')


def live_hosts(app):
    target = host_path(app)
    return [pid for pid in native.pids() if native.path(pid) == target]


def snapshot(app):
    result = {'hosts': []}
    for pid in live_hosts(app):
        cid = native.coalition(pid)
        members = []
        for member in (native.members(cid) if cid else []):
            members.append({'pid': member, 'path': native.path(member), 'identity': measure.identity(member)})
        result['hosts'].append({'pid': pid, 'coalition': cid, 'identity': measure.identity(pid), 'members': members})
    return result


def verify(app, recorded, timeout=10.0):
    deadline = time.monotonic() + timeout
    while True:
        left = {'identities': [], 'coalitionMembers': [], 'hosts': live_hosts(app)}
        for host in recorded['hosts']:
            for member in host['members']:
                if member['identity'] and measure.identity(member['pid']) == member['identity']:
                    left['identities'].append(member)
            if host['coalition'] and native.members(host['coalition']):
                left['coalitionMembers'] += native.members(host['coalition'])
        clean = not any(left.values())
        if clean or time.monotonic() >= deadline:
            return {'clean': clean, 'left': left, 'recordedHosts': len(recorded['hosts'])}
        time.sleep(.2)


if __name__ == '__main__':
    command, app = sys.argv[1], sys.argv[2]
    if command == 'snapshot':
        print(json.dumps(snapshot(app)))
    elif command == 'hosts':
        print(len(live_hosts(app)))
    elif command == 'verify':
        report = verify(app, json.loads(pathlib.Path(sys.argv[3]).read_text()))
        print(json.dumps(report))
        sys.exit(0 if report['clean'] else 1)
    else:
        raise SystemExit(__doc__)
