#!/usr/bin/env python3
"""CP5 OWN native acceptance (plans/cp5/OWN.md: OWN-A1 and OWN-A6 in the package).

The packaged app starts the synthetic `apple-escape` fixture. That fixture
leaves an unmarked /bin/sleep behind, detached with setsid + double fork and
reparented to launchd. Then the app either quits normally or is SIGKILLed.
The run scope's coalition must end up empty, with the escape gone; a control
process outside the scope must stay alive. No provider and no model turn.

Usage: scripts/cp5-own-native.py <path/to/Loom Dev.app> quit|kill
The app must live outside ~/Documents: its run host is a separate
TCC-responsible app, and executing bundle helpers from ~/Documents would
block on a Documents consent prompt.
Evidence: ~/Library/Application Support/Loom-Dev/probe/runs/cp5-own-<mode>-<uuid>/
"""
import ctypes, importlib.util, json, os, pathlib, signal, subprocess, sys, time, uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('measure', ROOT / 'scripts/cp5-d-measure.py')
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)

libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
libproc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
libproc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]


def coalition(pid):
    buffer = (ctypes.c_uint64 * 5)()
    return buffer[0] if libproc.proc_pidinfo(pid, 20, 0, buffer, 40) == 40 else None


def original_parent_version(pid):
    # struct proc_uniqidentifierinfo: uuid[16], uniqueid, puniqueid, idversion, orig_ppidversion, ...
    buffer = (ctypes.c_uint8 * 56)()
    if libproc.proc_pidinfo(pid, 17, 0, buffer, 56) != 56:
        return None
    return int.from_bytes(bytes(buffer[36:40]), 'little', signed=True)


def path(pid):
    buffer = ctypes.create_string_buffer(4096)
    return buffer.value.decode() if libproc.proc_pidpath(pid, buffer, 4096) > 0 else ''


def pids():
    count = libproc.proc_listallpids(None, 0)
    buffer = (ctypes.c_int * (count + 256))()
    count = libproc.proc_listallpids(buffer, ctypes.sizeof(buffer))
    return [buffer[i] for i in range(count)]


def members(cid):
    return [pid for pid in pids() if pid > 0 and coalition(pid) == cid and measure.identity(pid) is not None]


def wait_until(predicate, timeout, step=.1):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return predicate()


def main():
    app, mode = pathlib.Path(sys.argv[1]).resolve(), sys.argv[2]
    assert mode in ('quit', 'kill')
    if str(app).startswith(str(pathlib.Path.home() / 'Documents')):
        raise SystemExit('Package the app outside ~/Documents (TCC); see the docstring.')
    base = pathlib.Path.home() / 'Library/Application Support/Loom-Dev/probe/runs' / f'cp5-own-{mode}-{uuid.uuid4()}'
    base.mkdir(parents=True)
    data = base / 'data'
    data.mkdir()
    report = {'mode': mode, 'app': str(app), 'modelTurns': 0, 'checks': {}}
    host_path = str(app / 'Contents/Helpers/LoomRunHost.app/Contents/MacOS/loom-run-host')
    executable = str(app / 'Contents/MacOS/Loom Dev')
    launchd_version = original_parent_version(1)

    def check(name, ok, detail=None):
        report['checks'][name] = bool(ok)
        if detail is not None:
            report.setdefault('details', {})[name] = detail

    if subprocess.run(['pgrep', '-f', executable], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit('Loom Dev from this package is already running; quit it first.')
    outsider = subprocess.Popen(['/bin/sleep', '300'])
    outsider_identity = measure.identity(outsider.pid)
    app_identity = None
    try:
        evidence = base / 'run'
        evidence.mkdir()
        subprocess.run(['open', '-a', str(app), '--args', '--evidence', str(evidence),
                        '--data-root', str(data), '--fixture', 'apple-escape'], check=True)
        launched = measure.wait_json(evidence / 'launched.json', 25)
        app_identity = measure.identity(launched['pid'])
        check('appStarted', app_identity is not None)

        def scoped_escape():
            for pid in pids():
                if path(pid) != host_path:
                    continue
                cid = coalition(pid)
                inside = members(cid) if cid else []
                sleeps = [p for p in inside if path(p) == '/bin/sleep' and original_parent_version(p) != launchd_version]
                if sleeps:
                    return {'host': pid, 'coalition': cid, 'escape': sleeps[0], 'members': inside}
            return None
        found = wait_until(scoped_escape, 15)
        check('escapeInRunScope', found is not None, found)
        if not found:
            return report
        cid, escape = found['coalition'], measure.identity(found['escape'])
        check('scopeIsNotAppCoalition', cid != coalition(launched['pid']))
        check('escapeDetached', escape is not None)

        if mode == 'quit':
            measure.send('quit', evidence)
            quit_report = measure.wait_json(evidence / 'quit.json', 35)
            check('quitSucceeded', quit_report.get('succeeded') is True and quit_report.get('remaining') == 0, quit_report.get('errors'))
        else:
            os.kill(launched['pid'], signal.SIGKILL)
            check('noQuitWritten', not (evidence / 'quit.json').exists())
        check('appGone', wait_until(lambda: measure.identity(launched['pid']) != app_identity, 15))
        empty = wait_until(lambda: members(cid) == [], 15)
        check('scopeEmpty', empty, members(cid))
        check('escapeGone', measure.identity(escape['pid']) != escape)
        check('outsideAlive', measure.identity(outsider.pid) == outsider_identity)

        if mode == 'kill':
            reopened = base / 'reopened'
            reopened.mkdir()
            subprocess.run(['open', '-a', str(app), '--args', '--evidence', str(reopened), '--data-root', str(data)], check=True)
            second = measure.wait_json(reopened / 'launched.json', 25)
            app_identity = measure.identity(second['pid'])
            time.sleep(1)
            check('noRunHostAfterReopen', not any(path(pid) == host_path for pid in pids()))
            measure.send('quit', reopened)
            final = measure.wait_json(reopened / 'quit.json', 35)
            check('reopenedQuitSucceeded', final.get('succeeded') is True)
            check('reopenedAppGone', wait_until(lambda: measure.identity(second['pid']) != app_identity, 15))
        return report
    finally:
        # An independent check, by path, that no run host of this package survived.
        wait_until(lambda: not [pid for pid in pids() if path(pid) == host_path], 15)
        leftovers = [pid for pid in pids() if path(pid) == host_path]
        report['hostsLeft'] = leftovers
        report['checks']['noRunHostLeft'] = leftovers == []
        report['passed'] = bool(report['checks']) and all(report['checks'].values())
        outsider.terminate()
        outsider.wait(timeout=5)
        (base / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({'evidence': str(base), 'passed': report['passed'], 'checks': report['checks']}, indent=2))


if __name__ == '__main__':
    result = main()
    sys.exit(0 if result and result.get('passed') else 1)
