"""Shared helpers for the indicator-cost and real-Claude checks: proc_pid_rusage CPU/wakeup sampling and the
per-instance evidence command channel (same name as scripts/dev-paths.sh `loom_command_channel`)."""
import ctypes, json, os, pathlib, subprocess, time, hashlib

WINDOW = int(os.environ.get('WINDOW', '60'))

class RU(ctypes.Structure):
    # rusage_info_v2 (flavor 2): the last two diskio fields are required, a shorter struct overruns and segfaults Python.
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        'user', 'system', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins', 'wired', 'resident', 'footprint',
        'start', 'exit', 'child_user', 'child_system', 'child_pkg_idle', 'child_interrupt', 'child_pageins', 'child_elapsed', 'diskio_read', 'diskio_written')]
libc = ctypes.CDLL('/usr/lib/libSystem.dylib')
class TB(ctypes.Structure): _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
tb = TB(); libc.mach_timebase_info(ctypes.byref(tb))
def usage(pid):
    ru = RU()
    if libc.proc_pid_rusage(pid, 2, ctypes.byref(ru)) != 0: raise OSError('rusage failed')
    ns = lambda t: t * tb.numer / tb.denom
    return {'cpu': (ns(ru.user) + ns(ru.system)) / 1e9, 'idleWakeups': ru.pkg_idle_wkups, 'intWakeups': ru.interrupt_wkups,
            'footprint': ru.footprint, 't': time.monotonic()}
def channel(d):
    return 'local.loom.desktop.dev.command.' + hashlib.sha256(os.path.realpath(d).encode()).hexdigest()[:16]
def send(d, text):
    subprocess.run(['osascript', '-l', 'JavaScript', '-e', "ObjC.import('Foundation');$.NSDistributedNotificationCenter.defaultCenter."
                    "postNotificationNameObjectUserInfoDeliverImmediately(" + json.dumps(channel(d)) + ", " + json.dumps(text) + ", $(), true)"],
                   check=True, capture_output=True)
def snap(d, label, timeout=10):
    p = pathlib.Path(d) / f'state-{label}.json'
    if p.exists(): p.unlink()
    send(d, f'snapshot:{label}')
    end = time.time() + timeout
    while time.time() < end:
        if p.exists():
            time.sleep(0.15); return json.loads(p.read_text())
        time.sleep(0.1)
    raise TimeoutError(label)
def until(d, label, pred, timeout):
    end = time.time() + timeout
    while time.time() < end:
        s = snap(d, label)
        if pred(s): return s
        time.sleep(0.3)
    raise TimeoutError(label)
def measure(pid, label, window=None):
    a = usage(pid); time.sleep(window or WINDOW); b = usage(pid)
    dt = b['t'] - a['t']
    row = {'label': label, 'seconds': dt, 'appCPUPercent': 100 * (b['cpu'] - a['cpu']) / dt,
           'idleWakeupsPerSec': (b['idleWakeups'] - a['idleWakeups']) / dt,
           'interruptWakeupsPerSec': (b['intWakeups'] - a['intWakeups']) / dt, 'footprintMiB': b['footprint'] / 2**20}
    print(json.dumps(row), flush=True); return row
