#!/usr/bin/env python3
"""Isolated model-free resource driver. No provider CLI and no unregistered PID signals.

Examples (after packaging the evidence harness):
  cp5-d-measure.py --app '~/Library/Application Support/Loom-Dev/app/Loom Dev.app' --scenario smoke --visibility hidden
  cp5-d-measure.py --app '~/Library/Application Support/Loom-Dev/app/Loom Dev.app' --scenario stream10
  cp5-d-measure.py --app '~/Library/Application Support/Loom-Dev/app/Loom Dev.app' --scenario cycles --cycles 100
Run hosts and other scope members (every run lives in a LoomRunHost scope) are
counted in each sample; a scope member whose usage cannot be read invalidates it.
The app must live outside ~/Documents (run hosts are separate TCC-responsible apps).
Long defaults: buffer fill, 10 s warm-up, 600 s continuously alive load, samples every 5 s.
Only one surface is shown; the other real surface/PTY pairs remain detached.
"""
import argparse
import ctypes
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import subprocess
import statistics
import sys
import time
import uuid

# interactive keeps the PTY default ONLCR; the explicit CR is followed by CRLF.
BANNER = b'Loom synthetic terminal. Type a line; Ctrl-D exits.\r\r\n> '
FOOTER = re.compile(rb'\r\nEND bytes=(\d+) seconds=(\d+\.\d{3})\r\n\Z')


def payload_chunks(total, block=1024 * 1024):
    """Independent payload oracle: fixed 64-byte records; never retain full output."""
    chunk = bytearray()
    for index in range((total + 63) // 64):
        line = b'L' + f'{index:09d}'.encode('ascii') + b' ' + b'x' * 51 + b'\r\n'
        keep = min(64, total - index * 64)
        chunk.extend(line[:keep])
        if len(chunk) >= block:
            yield bytes(chunk)
            chunk.clear()
    if chunk:
        yield bytes(chunk)


SPINNER_FPS = 30
SPINNER_GLYPHS = ['·', '✢', '✳', '✶', '✻', '✽']


def spinner_chunks(fps, frames):
    """Independent oracle for `loom-test-child spinner`: setup, then one chunk per frame.

    200 static lines, hide cursor, six LFs to the seventh row, up two rows onto row 5.
    Rows 6-7 stay blank so the END footer (CRLF, text, CRLF) also never reaches a bottom-row LF.
    Each frame returns to row 1 of the five-row region, erases and rewrites rows 1-5,
    leaving the cursor on row 5, so no LF ever happens on the bottom row after setup."""
    yield b''.join(f'Static scrollback line {i:03d}: the quick brown fox jumps over the lazy dog\r\n'.encode()
                   for i in range(200)) + b'\x1b[?25l' + b'\r\n' * 6 + b'\x1b[2A'
    for frame in range(frames):
        tokens = frame * 13
        rows = [
            f'\x1b[2K\x1b[38;5;208m{SPINNER_GLYPHS[(frame // 2) % 6]}\x1b[0m Thinking… ({frame // fps}s · ↓ {tokens // 1000}.{tokens % 1000 // 100}k tokens · esc to interrupt)',
            f'\x1b[2K\x1b[2m  ⎿  Tip: frame {frame}\x1b[0m',
            '\x1b[2K╭' + '─' * 56 + '╮',
            '\x1b[2K│ > Try "refactor the session catalog"                      │',
            '\x1b[2K╰' + '─' * 56 + '╯',
        ]
        yield ('\r\x1b[4A' + '\r\n'.join(rows)).encode()


def spinner_payload(fps, frames):
    return b''.join(spinner_chunks(fps, frames))


def spinner_screen_check(fps, frames, footer=b'\r\nEND bytes=0 seconds=0.000\r\n', rows=24):
    """Minimal terminal model: cursor row after setup/frames/footer, scroll events after setup.

    Returns (scrolls_after_setup, max_row). Handles only the sequences the fixture emits."""
    row, scrolls, in_setup = 0, 0, True
    stream = spinner_payload(fps, frames) + footer
    setup_len = len(next(iter(spinner_chunks(fps, 0))))
    # Rows are counted from the first row after the 200 static lines scrolled the screen:
    # the bottom row is `rows - 1`; start with the cursor on it after the 200th CRLF.
    row = rows - 1
    index = 0
    while index < len(stream):
        if index == setup_len:
            in_setup = False
        byte = stream[index]
        if byte == 0x1b and stream[index + 1:index + 2] == b'[':
            match = re.compile(rb'\x1b\[([0-9;?]*)([A-Za-z])').match(stream, index)
            params, final = match[1], match[2]
            if final == b'A':
                row = max(0, row - int(params or 1))
            index = match.end()
            continue
        if byte == 0x0a:
            if row == rows - 1:
                if not in_setup:
                    scrolls += 1
            else:
                row += 1
        index += 1
    return scrolls, row


def validate_run(row, cache):
    audit = row['audit']
    if row.get('secondScrollback'):
        raise ValueError('A second terminal scrollback exists')
    if audit.get('footerOverflow'):
        raise ValueError('Audit footer exceeded bounded capacity')
    if row['terminal']['outputBytes'] != audit['wireBytes'] or row['terminal']['engineBytesFed'] != audit['wireBytes']:
        raise ValueError('Forwarded audit/engine byte totals differ')
    if row['rate'] == -1:
        expected = hashlib.sha256(BANNER).hexdigest()
        if audit['wireBytes'] != len(BANNER) or audit['wireSHA256'] != expected:
            raise ValueError('Idle banner byte count/digest differs from independent oracle')
        return {'wireBytes': len(BANNER), 'wireSHA256': expected, 'payloadVerified': True}
    total = row['totalPayloadBytes']
    spinner = row.get('spinnerFrames')
    footer = audit['footer'].encode('utf-8')
    match = FOOTER.fullmatch(footer)
    if not match or int(match[1]) != total:
        raise ValueError('Missing or malformed END footer')
    key = (total, spinner, row['rate'] if spinner else None)
    if key not in cache:
        h = hashlib.sha256()
        for chunk in (spinner_chunks(row['rate'], spinner) if spinner else payload_chunks(total)):
            h.update(chunk)
        cache[key] = h
    expected_payload = cache[key].hexdigest()
    wire = cache[key].copy()
    wire.update(footer)
    if audit['payloadBytes'] != total or audit['payloadSHA256'] != expected_payload:
        raise ValueError('Payload count/digest differs from independent oracle')
    if audit['wireBytes'] != total + len(footer) or audit['wireSHA256'] != wire.hexdigest():
        raise ValueError('Payload plus END footer wire count/digest differs')
    seconds = float(match[2])
    actual_rate = total / seconds if seconds else None
    if spinner:
        # Pacing is frames per second, not bytes per second.
        frame_rate = spinner / seconds if seconds else None
        if frame_rate is None or not .95 * row['rate'] <= frame_rate <= 1.1 * row['rate']:
            raise ValueError(f'Spinner frame rate {frame_rate} differs from requested {row["rate"]}')
    elif row['rate'] > 0 and (actual_rate is None or not .95 * row['rate'] <= actual_rate <= 1.1 * row['rate']):
        raise ValueError(f'Fixture throughput {actual_rate} differs from requested {row["rate"]}')
    return {'payloadVerified': True, 'wireBytes': audit['wireBytes'], 'wireSHA256': wire.hexdigest(),
            'fixtureSeconds': seconds, 'fixtureBytesPerSecond': actual_rate}


def is_buffer_full(terminal):
    lines, capacity = terminal.get('mainBufferLines'), terminal.get('mainBufferCapacity')
    return lines is not None and capacity is not None and capacity > 0 and lines >= capacity


class BSDInfo(ctypes.Structure):
    # macOS sys/proc_info.h proc_bsdinfo, PROC_PIDTBSDINFO=3.
    _fields_ = [(name, ctypes.c_uint32) for name in
                ('flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'jobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('seconds', ctypes.c_uint64), ('microseconds', ctypes.c_uint64)]


class ProcessIdentityQueryError(RuntimeError):
    def __init__(self, pid, returned_size, error):
        self.pid, self.returned_size, self.errno = pid, returned_size, error
        name = errno.errorcode.get(error, 'UNSPECIFIED' if error == 0 else 'UNKNOWN')
        super().__init__(f'proc_pidinfo PID {pid} returned {returned_size} bytes, errno {error} ({name}); identity unknown')


def identity(pid):
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    info = BSDInfo()
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    ctypes.set_errno(0)
    size = lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
    error = ctypes.get_errno()
    if size <= 0 and error == errno.ESRCH:
        return None
    if error != 0 or size != ctypes.sizeof(info):
        raise ProcessIdentityQueryError(pid, size, error)
    if info.pid != pid:
        raise ProcessIdentityQueryError(pid, size, error)
    return {'pid': info.pid, 'startSeconds': info.seconds, 'startMicroseconds': info.microseconds}


DEFAULT_APP = Path.home() / 'Library/Application Support/Loom-Dev/app/Loom Dev.app'


class LaunchServicesProcess:
    """Birth-pinned app handle; LaunchServices owns reaping, so no exit code is inferred."""
    def __init__(self, pid):
        self.pid = pid
        self.birth = identity(pid)
        if self.birth is None:
            raise ValueError('LaunchServices app identity unavailable')

    def poll(self):
        return None if identity(self.pid) == self.birth else 0

    def wait(self, timeout):
        deadline = time.monotonic() + timeout
        while self.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError('LaunchServices app remained alive after Quit')
            time.sleep(.05)
        return 0


def refuse_documents(path):
    resolved = Path(path).expanduser().resolve()
    documents = (Path.home() / 'Documents').resolve()
    if resolved == documents or documents in resolved.parents:
        raise SystemExit(f"App path '{path}' is under ~/Documents. Run hosts are separate TCC-responsible apps and "
                         "block on a Documents consent prompt there; package the app under ~/Library "
                         f"(default: {DEFAULT_APP}).")


def host_pids(app):
    """Independent, path-based list of live run hosts of this package (ps comm is the executable path)."""
    target = str(Path(app).resolve() / 'Contents/Helpers/LoomRunHost.app/Contents/MacOS/loom-run-host')
    listing = subprocess.run(['ps', '-axo', 'pid=,comm='], capture_output=True, text=True,
                             check=True, timeout=10).stdout
    found = []
    for line in listing.splitlines():
        pid, _, comm = line.strip().partition(' ')
        if comm.strip() == target:
            found.append(int(pid))
    return found


def scope_members(result):
    """Run hosts and non-leader scope members of one snapshot, keyed by PID."""
    scope = result.get('scope')
    if not isinstance(scope, dict):
        raise ValueError('Scope accounting missing from snapshot')
    if scope.get('valid') is not True:
        raise ValueError(f'Scope member accounting invalid: {scope.get("invalid")}')
    rows = {}
    for kind in ('hosts', 'others'):
        if not isinstance(scope.get(kind), list):
            raise ValueError(f'Scope {kind} inventory missing')
        for row in scope[kind]:
            if not row.get('usage'):
                raise ValueError('Scope member usage missing')
            pid = row['identity']['pid']
            if pid in rows:
                raise ValueError('Scope member counted more than once')
            rows[pid] = row | {'kind': kind}
    return rows


def wait_json(path, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            try:
                return json.loads(path.read_text())
            except (OSError, ValueError):
                pass
        time.sleep(.025)
    raise TimeoutError(f'Missing valid acknowledgement/snapshot: {path.name}')


def command_channel(directory):
    # Mirrors LaunchOptions.commandChannel (Sources/LoomLaunchOptions).
    real = os.path.realpath(directory)
    return 'local.loom.desktop.dev.command.' + hashlib.sha256(real.encode()).hexdigest()[:16]


def send(text, directory):
    # JSON is inserted as a JavaScript literal, never into shell command text.
    expression = ("ObjC.import('Foundation'); $.NSDistributedNotificationCenter.defaultCenter."
                  "postNotificationNameObjectUserInfoDeliverImmediately("
                  + json.dumps(command_channel(directory)) + ", " + json.dumps(text) + ", $(), true)")
    subprocess.run(['osascript', '-l', 'JavaScript', '-e', expression], check=True, capture_output=True, timeout=10)


class Driver:
    def __init__(self, args, directory):
        self.args, self.directory = args, directory
        self.identities = {}
        self.scope_identities = {}
        self.cache = {}
        self.process = None
        self.app_identity = None
        self.expected_runs = None
        self.observer_seconds = 0.0
        self.effective_material = None

    def operation(self, name, *fields, timeout=None):
        operation_id = str(uuid.uuid4())
        started = time.monotonic()
        target_pid = self.process.pid if self.process else json.loads((self.directory / 'launched.json').read_text())['pid']
        send(':'.join(['resource', str(target_pid), operation_id, name] + [str(value) for value in fields]), self.directory)
        ack = wait_json(self.directory / f'ack-{operation_id}.json', timeout or self.args.ack_timeout)
        self.observer_seconds += time.monotonic() - started
        for row in ack.get('result', {}).get('runs', []):
            self.identities[row['runID']] = row['identity']
        if ack.get('operationID') != operation_id or ack.get('succeeded') is not True:
            raise ValueError(f'{name} failed: {ack.get("error", ack)}')
        return ack

    def sample(self, timeout=None):
        ack = self.operation('snapshot', timeout=timeout)
        snapshot, state = ack['result'], ack['app']
        if state.get('attachedSheet') is not None:
            raise ValueError('Attached sheet interrupted resource measurement')
        if snapshot['runs']:
            selected = snapshot.get('selectedIndex')
            if not isinstance(selected, int) or not 0 <= selected < len(snapshot['runs']):
                raise ValueError('Pool has runs without one selected surface')
            if snapshot['runs'][selected].get('renderer') != self.args.renderer:
                raise ValueError('Selected surface actual renderer differs from requested renderer')
        material = state.get('sidebarMaterial')
        if material not in ('glass', 'opaque'):
            raise ValueError('Effective sidebar material snapshot missing')
        if self.args.material != 'system' and material != self.args.material:
            raise ValueError('Effective sidebar material does not match requested scenario')
        if self.effective_material is None:
            self.effective_material = material
        elif material != self.effective_material:
            raise ValueError('Effective sidebar material changed during measurement')
        if not snapshot.get('appUsage'):
            raise ValueError('App CPU/physical footprint snapshot missing')
        if snapshot['appIdentity'] != self.app_identity:
            raise ValueError('App process identity changed')
        visible = self.args.visibility != 'hidden'
        unoccluded = self.args.visibility == 'visible'
        if state.get('windowVisible') != visible or state.get('windowOcclusionVisible') != unoccluded:
            raise ValueError('Window visibility/occlusion does not match scenario')
        if self.expected_runs is not None and {row['runID'] for row in snapshot['runs']} != self.expected_runs:
            raise ValueError('Registered pool run set changed during measurement')
        for member in scope_members(snapshot).values():
            self.scope_identities[member['identity']['pid']] = member['identity']
        for row in snapshot['runs']:
            if not row.get('usage'):
                raise ValueError('Registered fixture CPU snapshot missing')
            if not row.get('alive') or not row.get('identityMatches'):
                raise ValueError('Registered fixture exited early or its PID was reused')
        return ack

    def launch(self):
        refuse_documents(self.args.app)
        app = self.args.app.expanduser().resolve()
        executable = app / 'Contents/MacOS/Loom Dev'
        if not executable.is_file():
            raise ValueError(f'Packaged executable not found: {executable}')
        manifest = {'scenario': self.args.scenario, 'parameters': vars(self.args) | {'app': str(app)},
                    'binarySHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
                    'fixtureSHA256': hashlib.sha256((executable.parent / 'loom-test-child').read_bytes()).hexdigest(),
                    'runHostSHA256': hashlib.sha256((app / 'Contents/Helpers/LoomRunHost.app/Contents/MacOS/loom-run-host').read_bytes()).hexdigest(),
                    'definition': 'N real surfaces/PTys; one selected panel, remaining detached; model/provider runs=0',
                    'driverPID': os.getpid(), 'driverIdentity': identity(os.getpid()),
                    'measurementStartedMonotonic': time.monotonic(),
                    'GPU': 'unmeasured; CPU/frame counts are not GPU attribution'}
        # Path values converted above; no user profile/data root is used.
        manifest['parameters']['output'] = str(self.args.output) if self.args.output else None
        (self.directory / 'manifest.json').write_text(json.dumps(manifest, indent=2))
        command = [str(executable), '--evidence', str(self.directory), '--data-root', str(self.directory / 'data')]
        if self.args.material != 'system':
            command += ['--evidence-transparency', self.args.material]
        if self.args.renderer == 'metal':
            command.append('--metal')
        self.log = (self.directory / 'app.log').open('wb')
        if getattr(self.args, 'launch_services', False):
            subprocess.run(['open', '-n', '-a', str(app), '--args'] + command[1:],
                           check=True, timeout=self.args.ack_timeout, stdout=self.log, stderr=subprocess.STDOUT)
            launched = wait_json(self.directory / 'launched.json', self.args.ack_timeout)
            self.process = LaunchServicesProcess(launched['pid'])
        else:
            self.process = subprocess.Popen(command, stdout=self.log, stderr=subprocess.STDOUT)
            launched = wait_json(self.directory / 'launched.json', self.args.ack_timeout)
        if launched.get('pid') != self.process.pid:
            raise ValueError('Launched snapshot does not belong to registered app PID')
        self.app_identity = identity(self.process.pid)
        if self.app_identity is None:
            raise ValueError('App birth identity could not be read')
        deadline = time.monotonic() + self.args.ack_timeout
        while True:
            try:
                self.operation('snapshot')
                break
            except ValueError as error:
                if 'not ready' not in str(error) or time.monotonic() >= deadline:
                    raise
                time.sleep(.1)
        if self.args.visibility == 'hidden':
            self.operation('hide')
        self.await_initial_visibility()

    def await_initial_visibility(self):
        # resource-ready does not imply that AppKit has made the requested
        # visibility observable. Only startup can wait; measured samples remain
        # strict, and this never activates or covers the native window.
        deadline = time.monotonic() + self.args.ack_timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ValueError('Initial window visibility/occlusion readiness timed out')
            try:
                self.sample(timeout=remaining)
                return
            except ValueError as error:
                if str(error) != 'Window visibility/occlusion does not match scenario':
                    raise
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError('Initial window visibility/occlusion readiness timed out') from error
                time.sleep(min(.1, remaining))

    def run(self):
        self.launch()
        scenario = self.args.scenario
        if scenario == 'cycles':
            before = self.sample()['result']
            result = self.operation('cycles', self.args.cycles, timeout=max(self.args.ack_timeout, self.args.cycles * 12 + 10))
            verified = []
            completed = result['result']['cycles']
            if len(completed) != self.args.cycles or not result['result'].get('releaseVerified') or any(result['result']['weakAlive'].values()):
                raise ValueError('Cycle count or final weak release differs from requested run')
            for expected_index, cycle in enumerate(completed):
                if cycle['cycle'] != expected_index or len(cycle['result']['stopped']) != 1 or not cycle['result'].get('releaseVerified'):
                    raise ValueError('Missing or duplicated launch/stop/release cycle')
                for row in cycle['result']['stopped']:
                    if row['runID'] in self.identities:
                        raise ValueError('Cycle reused a registered run ID')
                    self.identities[row['runID']] = row['identity']
                    verified.append(validate_run(row, self.cache))
            return {'cycles': self.args.cycles, 'verifiedRuns': verified, 'weakAlive': result['result']['weakAlive'],
                    'resourceBefore': before, 'resourceAfter': self.sample()['result']}
        count, rate = {'idle0': (0, -1), 'idle1': (1, -1), 'idle10': (10, -1), 'idle50': (50, -1),
                       'stream1': (1, 1048576), 'spinner1': (1, SPINNER_FPS), 'stream10': (10, 102400), 'burst': (1, 0), 'smoke': (2, 10240),
                       'instrument': (0, -1), 'latency': (1, -1)}[scenario]
        warmup, duration = self.args.warmup, self.args.duration
        if scenario == 'smoke':
            warmup, duration = 0, .3
        if scenario == 'burst':
            warmup, duration = 0, 0
        total = 0 if rate == -1 else 20971520 if rate == 0 else int(rate * (warmup + duration + (1.7 if scenario == 'smoke' else 15)))
        if scenario == 'spinner1':
            # The finite spinner lasts warm-up + duration + 15 s at 30 frames/s; payload bytes come from the oracle.
            frames = int(rate * (warmup + duration + 15))
            total = len(spinner_payload(rate, frames))
            opened = self.operation('openspinner', count, rate, frames, total)
        else:
            opened = self.operation('open', count, rate, total)
        self.expected_runs = {row['runID'] for row in opened['result']['runs']}
        if len(self.expected_runs) != count:
            raise ValueError('Pool did not create the requested number of runs')
        if count:
            self.operation('select', 0)
        if scenario == 'latency':
            time.sleep(warmup)
            before = self.sample()
            validate_run(before['result']['runs'][0], self.cache)
            measured = self.operation('latency', self.args.latency_samples,
                                      timeout=max(self.args.ack_timeout, self.args.latency_samples * 1.1 + 10))
            latency = measured['result']['latency']
            if (latency.get('valid') is not True or latency.get('samples') != self.args.latency_samples
                    or latency.get('measured') != self.args.latency_samples or latency.get('timeouts') != 0
                    or latency.get('renderer') != self.args.renderer
                    or latency.get('runID') not in self.expected_runs):
                raise ValueError(f'Input-to-draw latency invalid: {latency}')
            after = self.sample()
            stopped = self.operation('stop')['result']
            if (len(stopped['stopped']) != 1 or stopped['stopped'][0]['runID'] not in self.expected_runs
                    or stopped['stopped'][0]['identity'] != self.identities[stopped['stopped'][0]['runID']]
                    or any(stopped['weakAlive'].values()) or not stopped.get('releaseVerified')):
                raise ValueError('Latency run Stop/release inventory invalid')
            row = stopped['stopped'][0]
            if row['terminal']['outputBytes'] != row['audit']['wireBytes'] or row['terminal']['engineBytesFed'] != row['audit']['wireBytes']:
                raise ValueError('Latency output audit/engine byte totals differ')
            (self.directory / 'samples.json').write_text(json.dumps([before, after], indent=2))
            return {'scenario': scenario, 'inputToDraw': latency, 'weakAlive': stopped['weakAlive'],
                    'metrics': interval_metrics([before, after]), 'effectiveSidebarMaterial': self.effective_material,
                    'definition': 'Initial banner independently verified; typed echo checked for audit/engine byte equality, not fixed payload digest'}
        if rate > 0 and duration >= 600:
            # Ten-minute acceptance starts after measured buffer fullness.
            # Unknown counters never silently satisfy that condition.
            deadline = time.monotonic() + 10
            while True:
                snap = self.sample()['result']
                rows = snap['runs']
                if rows and all(is_buffer_full(row['terminal']) for row in rows):
                    break
                if time.monotonic() >= deadline:
                    raise ValueError('Cannot establish full buffers before long-load acceptance')
                time.sleep(.1)
        time.sleep(warmup)
        start = self.sample()
        start_usage = resource.getrusage(resource.RUSAGE_SELF)
        start_child_usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        start_clock = time.monotonic()
        samples = [start]
        while time.monotonic() - start_clock < duration:
            time.sleep(min(self.args.sample_every, max(0, duration - (time.monotonic() - start_clock))))
            current = self.sample()
            previous = samples[-1]
            samples.append(current)
            if rate > 0 and scenario != 'spinner1':
                elapsed = current['result']['uptime'] - previous['result']['uptime']
                for old, new in zip(previous['result']['runs'], current['result']['runs']):
                    received = new['audit']['payloadBytes'] - old['audit']['payloadBytes']
                    # The fixture emits whole 64-byte records in ~10ms ticks;
                    # adjacent short samples may straddle one tick. Full-run
                    # footer throughput still requires 95% without this margin.
                    tick_bytes = ((max(64, rate // 100) + 63) // 64) * 64
                    if elapsed > 0 and received + tick_bytes < .95 * rate * elapsed:
                        raise ValueError('Continuous fixture load fell below 95% of requested rate plus one tick margin')
            if rate > 0 and any(row['audit']['footer'] for row in current['result']['runs']):
                raise ValueError('Finite load ended before continuous measurement completed')
        end_usage = resource.getrusage(resource.RUSAGE_SELF)
        end_child_usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        end = samples[-1]
        changes = [event for event in end['app'].get('visibilityEvents', [])
                   if start['result']['uptime'] <= event['uptime'] <= end['result']['uptime']]
        if changes:
            raise ValueError('Visibility changed inside measurement interval')
        (self.directory / 'samples.json').write_text(json.dumps(samples, indent=2))
        if rate >= 0:
            deadline = time.monotonic() + self.args.drain_timeout
            while True:
                current = self.sample()['result']
                if all(FOOTER.fullmatch(row['audit']['footer'].encode()) for row in current['runs']):
                    break
                if time.monotonic() >= deadline:
                    raise TimeoutError('Payload/END drain did not finish')
                time.sleep(.1)
        stopped = self.operation('stop')['result']
        stopped_rows = stopped['stopped']
        if len(stopped_rows) != count or {row['runID'] for row in stopped_rows} != self.expected_runs:
            raise ValueError('Stop result does not match every registered pool run')
        if any(row['identity'] != self.identities[row['runID']] for row in stopped_rows):
            raise ValueError('Stopped fixture identity differs from registered identity')
        verified = [validate_run(row, self.cache) for row in stopped['stopped']]
        if any(stopped['weakAlive'].values()) or not stopped.get('releaseVerified'):
            raise ValueError('Weak inventory did not return to zero after release')
        return {'scenario': scenario, 'sampleSeconds': end['result']['uptime'] - start['result']['uptime'],
                'warmupSeconds': warmup, 'sampleCount': len(samples), 'verifiedRuns': verified,
                'weakAlive': stopped['weakAlive'], 'metrics': interval_metrics(samples),
                'observerCPUSeconds': (end_usage.ru_utime + end_usage.ru_stime) - (start_usage.ru_utime + start_usage.ru_stime),
                'observerHelperCPUSeconds': (end_child_usage.ru_utime + end_child_usage.ru_stime) - (start_child_usage.ru_utime + start_child_usage.ru_stime),
                'observerCommandWallSecondsWholeRun': self.observer_seconds,
                'effectiveSidebarMaterial': self.effective_material,
                'unavailableMetrics': end['result'].get('unavailableMetrics', [])}

    def cleanup(self):
        if self.process is None:
            return {'notLaunched': True}
        if self.process.poll() is None:
            self.operation('quit', timeout=self.args.ack_timeout)
        quit_result = wait_json(self.directory / 'quit.json', self.args.ack_timeout)
        if not quit_result.get('succeeded') or quit_result.get('remaining') != 0:
            raise ValueError('Normal Quit did not verify empty ownership')
        self.process.wait(timeout=self.args.ack_timeout)
        if identity(self.process.pid) == self.app_identity:
            raise ValueError('Registered app process remains after Quit')
        recorded = list(self.identities.values()) + list(self.scope_identities.values())
        remaining = [item for item in recorded if identity(item['pid']) == item]
        if remaining:
            raise ValueError(f'Registered fixture or scope identities remain: {remaining}')
        # Independent of the recorded identities: no host of this package may be left.
        deadline = time.monotonic() + self.args.ack_timeout
        hosts = host_pids(self.args.app)
        while hosts and time.monotonic() < deadline:
            time.sleep(.1)
            hosts = host_pids(self.args.app)
        if hosts:
            raise ValueError(f'Run hosts remain after Quit: {hosts}')
        return {'quitSucceeded': True, 'remainingRegisteredIdentities': 0,
                'recordedScopeMembers': len(self.scope_identities), 'runHostsLeft': 0}


def interval_metrics(samples):
    first, last = samples[0]['result'], samples[-1]['result']
    span = last['uptime'] - first['uptime']
    def cpu(a, b):
        if not a or not b or span <= 0:
            return None
        return ((b['userTimeNanoseconds'] + b['systemTimeNanoseconds']) -
                (a['userTimeNanoseconds'] + a['systemTimeNanoseconds'])) / 1e9 / span * 100
    footprint_minutes = {}
    for sample in samples:
        row = sample['result']
        minute = int((row['uptime'] - first['uptime']) // 60)
        footprint_minutes.setdefault(minute, []).append((row.get('appUsage') or {}).get('physicalFootprintBytes'))
    result = {'appCPUPercentOfOneCore': cpu(first.get('appUsage'), last.get('appUsage')),
              'footprintSamplesByMinute': footprint_minutes, 'snapshotCostMilliseconds':
              [row['result'].get('snapshotCostMilliseconds') for row in samples], 'fixtureCPUPercentOfOneCore': []}
    eligible = {key: statistics.median([value for value in values if value is not None])
                for key, values in footprint_minutes.items() if len([v for v in values if v is not None]) >= 3}
    result['minuteMedianFootprintBytes'] = eligible
    if len(eligible) >= 2:
        result['firstLastMinuteMedianDeltaBytes'] = eligible[max(eligible)] - eligible[min(eligible)]
    last_five = [eligible[key] for key in sorted(eligible)[-5:]]
    result['continuousGrowthLastFiveMinuteMedians'] = all(b > a for a, b in zip(last_five, last_five[1:])) if len(last_five) == 5 else None
    result['terminalIntervals'] = []
    for a, b in zip(first['runs'], last['runs']):
        if a['runID'] != b['runID'] or a['identity'] != b['identity']:
            raise ValueError('Run identity changed inside sample')
        result['fixtureCPUPercentOfOneCore'].append({'runID': a['runID'], 'cpu': cpu(a.get('usage'), b.get('usage'))})
        old, new = a['terminal'], b['terminal']
        histogram = [y - x for x, y in zip(old['feedHistogramMicroseconds'], new['feedHistogramMicroseconds'])]
        if any(value < 0 for value in histogram):
            raise ValueError('Feed histogram moved backwards')
        batches = sum(histogram)
        upper = None
        accumulated = 0
        for index, amount in enumerate(histogram):
            accumulated += amount
            if batches and accumulated >= batches * .95:
                if index == len(histogram) - 1:
                    raise ValueError('Feed p95 falls in unbounded overflow bucket')
                upper = 2 ** index / 1000
                break
        result['terminalIntervals'].append({'runID': a['runID'], 'outputBytes': new['outputBytes'] - old['outputBytes'],
            'frames': new['frames'] - old['frames'], 'renders': new['renders'] - old['renders'],
            'feedBatches': batches, 'feedP95UpperBoundMilliseconds': upper,
            'runMaxFeedMilliseconds': new['maxFeedMilliseconds'], 'pendingInputBytesAtEnd': new['pendingInputBytes']})
    window_a, window_b = first.get('windowServers', []), last.get('windowServers', [])
    hosts_a, hosts_b = scope_members(first), scope_members(last)
    for sample in samples[1:]:
        members = scope_members(sample['result'])
        if set(hosts_a) != set(members) or any(hosts_a[p]['identity'] != members[p]['identity'] for p in hosts_a):
            raise ValueError('Scope member set changed inside sample')
    scope_cpu = {str(p): cpu(hosts_a[p]['usage'], hosts_b[p]['usage']) for p in hosts_a}
    result['scopeMemberCPUPercentOfOneCore'] = scope_cpu
    result['scopeHostCount'] = sum(1 for row in hosts_b.values() if row['kind'] == 'hosts')
    result['scopeMemberFootprintBytesAtEnd'] = sum(
        row['usage']['physicalFootprintBytes'] for row in hosts_b.values())
    result['totalLoomFootprintBytesBySample'] = [
        {'uptime': sample['result']['uptime'], 'bytes': sample['result']['appUsage']['physicalFootprintBytes']
         + sum(row['usage']['physicalFootprintBytes'] for row in sample['result']['runs'])
         + sum(row['usage']['physicalFootprintBytes'] for row in scope_members(sample['result']).values())}
        for sample in samples]
    result['totalLoomCPUPercentOfOneCore'] = None if result['appCPUPercentOfOneCore'] is None or None in scope_cpu.values() else (
        result['appCPUPercentOfOneCore'] + sum(scope_cpu.values())
        + sum(item['cpu'] or 0 for item in result['fixtureCPUPercentOfOneCore']))
    result['windowServerCPUPercentOfOneCore'] = cpu(window_a[0].get('usage'), window_b[0].get('usage')) \
        if len(window_a) == len(window_b) == 1 and window_a[0]['identity'] == window_b[0]['identity'] else None
    return result


def self_test():
    literal = b'L000000000 ' + b'x' * 51 + b'\r\n'
    assert b''.join(payload_chunks(64)) == literal
    assert b''.join(payload_chunks(65)) == literal + b'L'
    footer = b'\r\nEND bytes=64 seconds=0.001\r\n'
    wire = literal + footer
    payload = spinner_payload(30, 90)
    assert payload.startswith(b'Static scrollback line 000:') and payload.count(b'\x1b[4A') == 90
    assert b'Thinking\xe2\x80\xa6 (1s \xc2\xb7 \xe2\x86\x93 0.4k tokens' in payload  # frame 30..: 390 tokens
    assert spinner_screen_check(30, 90) == (0, 23), spinner_screen_check(30, 90)
    # A frame that ended with a LF on the bottom row must be detected as scrolling.
    assert spinner_screen_check(30, 3, footer=b'\r\n' * 2)[0] == 0 and spinner_screen_check(30, 3, footer=b'\r\n' * 3)[0] > 0
    sfooter = b'\r\nEND bytes=%d seconds=3.000\r\n' % len(payload)
    swire = payload + sfooter
    srow = {'rate': 30, 'spinnerFrames': 90, 'totalPayloadBytes': len(payload), 'secondScrollback': False,
            'terminal': {'outputBytes': len(swire), 'engineBytesFed': len(swire)},
            'audit': {'wireBytes': len(swire), 'payloadBytes': len(payload), 'wireSHA256': hashlib.sha256(swire).hexdigest(),
                      'payloadSHA256': hashlib.sha256(payload).hexdigest(), 'footer': sfooter.decode(), 'footerOverflow': False}}
    validate_run(srow, {})
    for field, value in [('payloadSHA256', '0'), ('wireBytes', 1)]:
        broken = json.loads(json.dumps(srow)); broken['audit'][field] = value
        try:
            validate_run(broken, {})
        except ValueError:
            pass
        else:
            raise AssertionError(f'Corrupted spinner {field} was accepted')
    slow = json.loads(json.dumps(srow)); slow['audit']['footer'] = sfooter.decode().replace('3.000', '6.000')
    try:
        validate_run(slow, {})
    except ValueError:
        pass
    else:
        raise AssertionError('Wrong spinner pacing was accepted')
    row = {'rate': 0, 'totalPayloadBytes': 64, 'secondScrollback': False,
           'terminal': {'outputBytes': len(wire), 'engineBytesFed': len(wire)},
           'audit': {'wireBytes': len(wire), 'payloadBytes': 64, 'wireSHA256': hashlib.sha256(wire).hexdigest(),
                     'payloadSHA256': hashlib.sha256(literal).hexdigest(), 'footer': footer.decode(), 'footerOverflow': False}}
    validate_run(row, {})
    for field in ['wireBytes', 'payloadBytes', 'wireSHA256', 'payloadSHA256', 'footer', 'footerOverflow']:
        broken = json.loads(json.dumps(row))
        broken['audit'][field] = True if field == 'footerOverflow' else 0
        try:
            validate_run(broken, {})
        except (ValueError, AttributeError):
            pass
        else:
            raise AssertionError(f'Corrupted {field} was accepted')
    metadata = {'app': {'sidebarMaterial': 'opaque', 'windowVisible': True, 'windowOcclusionVisible': True, 'attachedSheet': None},
                'result': {'scope': {'valid': True, 'invalid': [], 'hosts': [], 'others': []},
                           'appIdentity': {'pid': 1}, 'appUsage': {'physicalFootprintBytes': 1}, 'selectedIndex': 0,
                           'runs': [{'runID': 'test-run', 'renderer': 'coregraphics', 'usage': {'cpu': 1},
                                     'alive': True, 'identityMatches': True}]}}
    def check_snapshot(candidate, visibility='visible'):
        driver = Driver(argparse.Namespace(renderer='coregraphics', material='opaque', visibility=visibility), Path('.'))
        driver.app_identity = {'pid': 1}
        driver.expected_runs = {'test-run'}
        driver.operation = lambda name, **kwargs: candidate
        return driver.sample()
    check_snapshot(metadata)
    for visibility, visible in [('hidden', False), ('occluded', True)]:
        candidate = json.loads(json.dumps(metadata))
        candidate['app'].update(windowVisible=visible, windowOcclusionVisible=False)
        check_snapshot(candidate, visibility)
    for target, field, invalid in [('app', 'attachedSheet', 'NSAlert'), ('app', 'sidebarMaterial', None),
                                   ('app', 'windowVisible', False), ('app', 'windowOcclusionVisible', False), ('result', 'appUsage', None),
                                   ('result', 'selectedIndex', None), ('run', 'renderer', 'metal'),
                                   ('scope', 'valid', False), ('scope', 'missing', None),
                                   ('run', 'alive', False), ('run', 'identityMatches', False), ('run', 'usage', None)]:
        broken = json.loads(json.dumps(metadata))
        owner = broken['result']['runs'][0] if target == 'run' else (
            broken['result']['scope'] if target == 'scope' else broken[target])
        if target == 'scope' and field == 'missing':
            del broken['result']['scope']
        else:
            owner[field] = invalid
        try:
            check_snapshot(broken)
        except ValueError:
            pass
        else:
            raise AssertionError(f'Invalid snapshot {target}.{field} was accepted')
    # Run hosts are summed into the total; a changed member set is rejected.
    def usage(ns):
        return {'userTimeNanoseconds': ns, 'systemTimeNanoseconds': 0, 'physicalFootprintBytes': 1000}
    def sampled(uptime, app_ns, host_ns, host_pid=7):
        host = {'identity': {'pid': host_pid, 'startSeconds': 1, 'startMicroseconds': 1}, 'usage': usage(host_ns)}
        return {'result': {'uptime': uptime, 'appUsage': usage(app_ns), 'runs': [], 'windowServers': [],
                           'scope': {'valid': True, 'invalid': [], 'hosts': [host], 'others': []}}}
    counted = interval_metrics([sampled(0, 0, 0), sampled(10, 10 * 10**9 // 10, 10 * 10**9 // 5)])
    assert counted['scopeHostCount'] == 1 and abs(counted['scopeMemberCPUPercentOfOneCore']['7'] - 20) < 1e-6
    assert abs(counted['totalLoomCPUPercentOfOneCore'] - 30) < 1e-6, counted
    try:
        interval_metrics([sampled(0, 0, 0), sampled(10, 1, 1, host_pid=8)])
    except ValueError:
        pass
    else:
        raise AssertionError('Changed scope member set was accepted')
    assert counted['totalLoomFootprintBytesBySample'][-1]['bytes'] == 2000
    try:
        interval_metrics([sampled(0, 0, 0), sampled(5, 1, 1, host_pid=8), sampled(10, 2, 2)])
    except ValueError:
        pass
    else:
        raise AssertionError('Transient scope member change was accepted')
    for field in ('hosts', 'others'):
        broken = sampled(0, 0, 0)['result']
        del broken['scope'][field]
        try:
            scope_members(broken)
        except ValueError:
            pass
        else:
            raise AssertionError('Missing scope inventory was accepted')
    # Independent host process scan must fail closed when ps cannot enumerate.
    from unittest.mock import patch
    def failed_ps(*args, **kwargs):
        if kwargs.get('check'):
            raise subprocess.CalledProcessError(1, ['ps'])
        return subprocess.CompletedProcess(['ps'], 1, stdout='')
    with patch.object(subprocess, 'run', side_effect=failed_ps):
        try:
            host_pids('/tmp/Loom Dev.app')
        except subprocess.CalledProcessError:
            pass
        else:
            raise AssertionError('Failed host process scan was accepted as empty')
    # Pure startup oracle: a transient mismatch can settle only before
    # measurement; permanent mismatch times out and unrelated errors propagate.
    def initial_visibility_check(outcomes):
        driver = Driver(argparse.Namespace(ack_timeout=.3), Path('.'))
        clock = [0.0]
        observed_timeouts = []
        iterator = iter(outcomes)
        def sample(timeout=None):
            observed_timeouts.append(timeout)
            outcome = next(iterator)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome
        driver.sample = sample
        with patch.object(time, 'monotonic', side_effect=lambda: clock[0]), \
             patch.object(time, 'sleep', side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            driver.await_initial_visibility()
        assert all(0 < value <= .3 for value in observed_timeouts)
        return len(observed_timeouts)
    mismatch = ValueError('Window visibility/occlusion does not match scenario')
    assert initial_visibility_check([mismatch, metadata]) == 2
    try:
        initial_visibility_check([mismatch] * 10)
    except ValueError as error:
        assert 'readiness timed out' in str(error)
    else:
        raise AssertionError('Never-ready initial visibility was accepted')
    try:
        initial_visibility_check([ValueError('App process identity changed')])
    except ValueError as error:
        assert str(error) == 'App process identity changed'
    else:
        raise AssertionError('Unrelated startup failure was retried')
    import tempfile
    with tempfile.TemporaryDirectory(prefix='loom-d-ack-oracle-') as directory:
        try:
            wait_json(Path(directory) / 'missing-ack.json', .05)
        except TimeoutError:
            pass
        else:
            raise AssertionError('Missing acknowledgement was accepted')
    print('Independent payload/footer oracle, strict snapshot guards, bounded startup visibility and missing-ack rejection PASS.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=DEFAULT_APP)
    parser.add_argument('--launch-services', action='store_true',
                        help='Launch a fresh app instance through LaunchServices; its coalition must be independently checked for attribution')
    parser.add_argument('--scenario', choices=['smoke', 'idle0', 'idle1', 'idle10', 'idle50', 'stream1', 'spinner1', 'stream10', 'burst', 'cycles', 'instrument', 'latency'], default='smoke')
    parser.add_argument('--latency-samples', type=int, default=200)
    parser.add_argument('--warmup', type=float, default=10)
    parser.add_argument('--duration', type=float, default=600)
    parser.add_argument('--sample-every', type=float, default=5)
    parser.add_argument('--visibility', choices=['visible', 'hidden', 'occluded'], default='visible',
                        help='occluded requires an external covering window within --ack-timeout; no global window preferences change')
    parser.add_argument('--material', choices=['glass', 'opaque', 'system'], default='system')
    parser.add_argument('--renderer', choices=['coregraphics', 'metal'], default='coregraphics')
    parser.add_argument('--cycles', type=int, default=100)
    parser.add_argument('--ack-timeout', type=float, default=30)
    parser.add_argument('--drain-timeout', type=float, default=30)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--snapshot-directory', type=Path)
    parser.add_argument('--quit-directory', type=Path)
    parser.add_argument('--operation-directory', type=Path)
    parser.add_argument('--operation', choices=['snapshot', 'quit', 'hide', 'latency'])
    parser.add_argument('--operation-argument', type=int)
    args = parser.parse_args()
    if args.snapshot_directory or args.quit_directory or args.operation_directory:
        directory = args.snapshot_directory or args.quit_directory or args.operation_directory
        name = 'snapshot' if args.snapshot_directory else 'quit' if args.quit_directory else args.operation
        if name is None:
            parser.error('--operation-directory requires --operation')
        fields = [] if args.operation_argument is None else [args.operation_argument]
        ack = Driver(args, directory).operation(name, *fields)
        print(json.dumps(ack))
        return 0
    if args.self_test:
        self_test()
        return 0
    if not all(math.isfinite(value) for value in (args.warmup, args.duration, args.sample_every, args.ack_timeout, args.drain_timeout)):
        parser.error("Durations and timeouts must be finite")
    if not 1 <= args.cycles <= 100:
        parser.error("Cycles must be 1...100")
    if not 1 <= args.latency_samples <= 500:
        parser.error('Latency samples must be 1...500')
    if args.scenario == 'latency' and args.visibility != 'visible':
        parser.error('Latency requires visible/unoccluded window')
    if min(args.warmup, args.duration) < 0 or min(args.sample_every, args.ack_timeout, args.drain_timeout) <= 0:
        parser.error('Durations must be nonnegative and timeouts/sample interval positive')
    directory = args.output or Path.home() / 'Library/Application Support/Loom-Dev/probe/runs' / f'cp5-d-measure-{uuid.uuid4()}'
    directory.mkdir(parents=True, exist_ok=False)
    driver = Driver(args, directory)
    report = {'valid': False, 'invalidReasons': []}
    try:
        report.update(driver.run())
        report['valid'] = True
    except Exception as error:
        report['invalidReasons'].append(str(error))
    finally:
        try:
            report['cleanup'] = driver.cleanup()
        except Exception as error:
            report['invalidReasons'].append('Cleanup: ' + str(error))
        report['valid'] = report['valid'] and not report['invalidReasons']
        (directory / 'result.json').write_text(json.dumps(report, indent=2))
        print(directory)
    return 0 if report['valid'] else 1


if __name__ == '__main__':
    sys.exit(main())
