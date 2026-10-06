#!/usr/bin/env python3
"""Evidence-only resource-coalition GPU time, with device-total IOReport alongside it.

No per-PID or GPU utilization claim. LaunchServices app coalition may include
independently verified, explicitly known Apple XPC services; all are counted.
WindowServer's complete coalition membership is shown.
Run-host coalitions include their fixture work. Unsupported reads, identity or
membership changes and counter resets fail closed. No elevation or preferences.
"""
import argparse
import ctypes
import errno
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import resource
import subprocess
import sys
import time

SPEC = importlib.util.spec_from_file_location('cp5d', Path(__file__).with_name('cp5-d-measure.py'))
D = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(D)
SOURCES = {
    'layoutAndNanoseconds': 'https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/coalition.h',
    'prototype': 'https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/coalition.h',
    'prefixCopy': 'https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/sys_coalition.c',
    'membershipAndXPC': 'https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/coalition.c',
}
APP_XPC_SERVICES = {
    '/System/Library/PrivateFrameworks/CascadeSets.framework/Versions/A/XPCServices/SetStoreUpdateService.xpc/Contents/MacOS/SetStoreUpdateService': 'com.apple.SetStoreUpdateService',
    '/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/ThemeWidgetControlViewService.xpc/Contents/MacOS/ThemeWidgetControlViewService': 'com.apple.appkit.xpc.ThemeWidgetControlViewService',
    '/System/Volumes/Preboot/Cryptexes/OS/System/Library/PrivateFrameworks/SafariPlatformSupport.framework/Versions/A/XPCServices/com.apple.SafariPlatformSupport.Helper.xpc/Contents/MacOS/com.apple.SafariPlatformSupport.Helper': 'com.apple.SafariPlatformSupport.Helper',
}
SAFARI_HELPER_CODE_ONLY = '/System/Volumes/Preboot/Cryptexes/OS/System/Library/PrivateFrameworks/SafariPlatformSupport.framework/Versions/A/XPCServices/com.apple.SafariPlatformSupport.Helper.xpc/Contents/MacOS/com.apple.SafariPlatformSupport.Helper'


class GPUUsagePrefix(ctypes.Structure):
    # Apple copies MIN(requested_size, sizeof(coalition_resource_usage)).
    # These first nine uint64 fields are enough; do not guess its evolving tail.
    _fields_ = [(name, ctypes.c_uint64) for name in (
        'tasks_started', 'tasks_exited', 'time_nonempty', 'cpu_time',
        'interrupt_wakeups', 'platform_idle_wakeups', 'bytesread', 'byteswritten', 'gpu_time')]


class ProcessPrefix(ctypes.Structure):
    # SDK sys/sysctl.h kinfo_proc starts with sys/proc.h extern_proc.
    # The initial pointer union is timeval-sized on this 64-bit Darwin ABI.
    _fields_ = [('seconds', ctypes.c_int64), ('microseconds', ctypes.c_int32),
                ('padding', ctypes.c_int32), ('vmspace', ctypes.c_void_p),
                ('sigacts', ctypes.c_void_p), ('flags', ctypes.c_int32),
                ('status', ctypes.c_char), ('pid', ctypes.c_int32)]


class Collector:
    def __init__(self, app=D.DEFAULT_APP):
        self.app = Path(app).expanduser().resolve()
        self.app_metadata = None
        self.app_coalition = None
        if ctypes.sizeof(GPUUsagePrefix) != 72:
            raise RuntimeError('Coalition GPU prefix ABI mismatch')
        self.proc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        self.lib = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        self.proc.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.proc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.coalition_info_resource_usage.argtypes = [ctypes.c_uint64, ctypes.c_void_p, ctypes.c_size_t]
        self.lib.coalition_info_resource_usage.restype = ctypes.c_int
        self.lib.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint32, ctypes.c_void_p,
                                   ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        if ctypes.sizeof(ctypes.c_void_p) != 8 or ProcessPrefix.pid.offset != 40:
            raise RuntimeError('Darwin process birth prefix ABI mismatch')

    def identity(self, pid):
        # Unlike proc_pidinfo(TBSDINFO), this read-only ProcessTable oracle
        # permits protected WindowServer identities under a normal UID.
        mib = (ctypes.c_int * 4)(1, 14, 1, pid)  # CTL_KERN/KERN_PROC/KERN_PROC_PID.
        size = ctypes.c_size_t()
        ctypes.set_errno(0)
        status = self.lib.sysctl(mib, 4, None, ctypes.byref(size), None, 0)
        if status != 0:
            if ctypes.get_errno() == errno.ESRCH:
                return None
            raise RuntimeError(f'PID {pid} birth query unavailable: errno={ctypes.get_errno()}')
        if size.value == 0:
            return None
        expected = size.value
        if expected < ctypes.sizeof(ProcessPrefix):
            raise RuntimeError('Kernel process identity record is shorter than SDK prefix')
        buffer = ctypes.create_string_buffer(expected)
        ctypes.set_errno(0)
        status = self.lib.sysctl(mib, 4, buffer, ctypes.byref(size), None, 0)
        # The sizing query reserves headroom (six records on this kernel),
        # while KERN_PROC_PID copies just the one requested process record.
        if status != 0 or size.value > expected:
            raise RuntimeError(f'PID {pid} birth record unavailable: errno={ctypes.get_errno()}')
        if size.value == 0:
            return None
        if size.value < ctypes.sizeof(ProcessPrefix):
            raise RuntimeError('Returned process identity record is truncated')
        record = ProcessPrefix.from_buffer_copy(buffer)
        if record.pid != pid or record.seconds <= 0 or not 0 <= record.microseconds < 1_000_000:
            raise RuntimeError('Kernel process identity does not match SDK prefix')
        return {'pid': pid, 'startSeconds': record.seconds, 'startMicroseconds': record.microseconds}

    def coalition(self, pid):
        info = (ctypes.c_uint64 * 5)()
        ctypes.set_errno(0)
        size = self.proc.proc_pidinfo(pid, 20, 0, info, ctypes.sizeof(info))
        error = ctypes.get_errno()
        if size != 40 or error or not info[0] or any(info[2:]):
            raise RuntimeError(f'PID {pid} coalition identity unavailable: size={size}, errno={error}')
        return int(info[0])

    def usage(self, coalition):
        usage = GPUUsagePrefix()
        # Sentinel detects an unwritten/truncated prefix instead of accepting zero.
        ctypes.memset(ctypes.byref(usage), 0xff, ctypes.sizeof(usage))
        ctypes.set_errno(0)
        status = self.lib.coalition_info_resource_usage(coalition, ctypes.byref(usage), ctypes.sizeof(usage))
        error = ctypes.get_errno()
        if status != 0 or error or usage.gpu_time == 2**64 - 1:
            raise RuntimeError(f'Coalition {coalition} GPU unavailable: status={status}, errno={error}')
        return {'gpuNanoseconds': usage.gpu_time, 'tasksStarted': usage.tasks_started,
                'tasksExited': usage.tasks_exited}

    def census(self, coalition_ids):
        listing = subprocess.run(['ps', '-axo', 'pid=,stat='], capture_output=True, text=True,
                                 check=True, timeout=10).stdout
        members = {}
        for line in listing.splitlines():
            raw_pid, status = line.split()
            pid = int(raw_pid)
            if pid <= 0 or status.startswith('Z'):
                continue
            try:
                coalition = self.coalition(pid)
            except RuntimeError:
                # Only independently verified exit may be excluded from census.
                if self.identity(pid) is None:
                    continue
                raise
            if coalition not in coalition_ids:
                continue
            birth = self.identity(pid)
            if birth is None:
                continue
            if self.identity(pid) != birth:
                raise RuntimeError('Process identity changed during coalition census')
            if self.coalition(pid) != coalition:
                raise RuntimeError('Process coalition changed during census')
            members.setdefault(coalition, []).append(birth)
        return {key: sorted(value, key=lambda row: row['pid']) for key, value in members.items()}

    def classify_app(self, app_birth, members):
        """One startup metadata pass, before the measured baseline is recorded."""
        metadata = []
        for birth in members:
            buffer = ctypes.create_string_buffer(4096)
            if self.proc.proc_pidpath(birth['pid'], buffer, len(buffer)) <= 0:
                raise RuntimeError('App coalition member executable unavailable')
            path = str(Path(buffer.value.decode()).resolve())
            if birth == app_birth:
                if path != str(self.app / 'Contents/MacOS/Loom Dev'):
                    raise RuntimeError('App coalition leader executable differs from launched package')
                row = {'identity': birth, 'path': path, 'classification': 'loom-app'}
            else:
                identifier = APP_XPC_SERVICES.get(path)
                if not identifier:
                    raise RuntimeError(f'Unclassified app coalition member: {birth}, path={path}')
                if (birth['startSeconds'], birth['startMicroseconds']) < (app_birth['startSeconds'], app_birth['startMicroseconds']):
                    raise RuntimeError('App XPC member predates the fresh application')
                requirement = f'anchor apple and identifier "{identifier}"'
                code_only = path == SAFARI_HELPER_CODE_ONLY
                flags = ['--ignore-resources'] if code_only else []
                checked = subprocess.run(['codesign', '--verify', '--strict'] + flags + ['-R', '=' + requirement, path],
                                         capture_output=True, text=True, timeout=10)
                if checked.returncode:
                    raise RuntimeError(f'Known app XPC Apple signature verification failed: {path}')
                row = {'identity': birth, 'path': path, 'classification': 'known-Apple-system-XPC',
                       'signatureRequirement': requirement, 'signatureVerified': True,
                       'resourceEnvelopeVerified': not code_only,
                       'signatureVerificationScope': 'code-and-sealed-Info-identity' if code_only else 'code-and-resources'}
                if code_only:
                    info = plistlib.loads((Path(path).parents[1] / 'Info.plist').read_bytes())
                    if (info.get('CFBundleIdentifier') != identifier
                            or info.get('XPCService', {}).get('ServiceType') != 'Application'):
                        raise RuntimeError('Known Safari helper identifier or per-application XPC type changed')
                    row.update(bundleIdentifier=identifier, XPCServiceType='Application',
                               resourceEnvelopeLimit='Apple custom omit rules; resource contents are not validated')
            if self.identity(birth['pid']) != birth:
                raise RuntimeError('App coalition member identity changed during startup classification')
            metadata.append(row)
        if app_birth not in members:
            raise RuntimeError('App leader missing from startup coalition census')
        return metadata

    def sample(self, ack):
        started = time.clock_gettime(8)  # SDK CLOCK_UPTIME_RAW; same base as app snapshots/IOReport.
        snapshot = ack['result']
        servers = snapshot.get('windowServers', [])
        if len(servers) != 1:
            raise RuntimeError('Exactly one WindowServer identity required')
        scoped = D.scope_members(snapshot)
        host_rows = [row for row in scoped.values() if row['kind'] == 'hosts'
                     and str(row.get('path', '')).endswith('/loom-run-host')]
        targets = [snapshot['appIdentity'], servers[0]['identity']] + [row['identity'] for row in host_rows]
        census = self.census({self.coalition(row['pid']) for row in targets})
        groups = []
        def group(label, birth):
            if self.identity(birth['pid']) != birth:
                raise RuntimeError(f'{label} process identity changed')
            coalition = self.coalition(birth['pid'])
            members = census.get(coalition, [])
            if birth not in members:
                raise RuntimeError(f'{label} coalition {coalition} missing its leader: {members}')
            usage = self.usage(coalition)
            if self.identity(birth['pid']) != birth or self.coalition(birth['pid']) != coalition:
                raise RuntimeError(f'{label} identity/coalition changed during query')
            groups.append({'role': label, 'identity': birth, 'coalitionID': coalition,
                           'liveMembers': members, 'usage': usage,
                           'queryUptime': time.clock_gettime(8)})
        group('loom-app-and-system-xpc', snapshot['appIdentity'])
        app_group = groups[-1]
        if self.app_coalition is not None and app_group['coalitionID'] != self.app_coalition:
            raise RuntimeError('Fresh app coalition changed')
        self.app_coalition = app_group['coalitionID']
        # Initial zero-fixture launch probes precede surface/AppKit XPC setup.
        # Classify once when the first actual workload snapshot establishes the
        # measured baseline; never invoke codesign in subsequent samples.
        if snapshot['runs'] and self.app_metadata is None:
            self.app_metadata = self.classify_app(snapshot['appIdentity'], app_group['liveMembers'])
        if self.app_metadata is not None:
            if app_group['liveMembers'] != [row['identity'] for row in self.app_metadata]:
                raise RuntimeError('Classified app coalition membership changed')
            app_group['startupMemberMetadata'] = self.app_metadata
        group('WindowServer', servers[0]['identity'])
        seen = {row['coalitionID'] for row in groups}
        for row in host_rows:
            coalition = self.coalition(row['identity']['pid'])
            if coalition in seen:
                raise RuntimeError('Run-host coalition is shared or counted twice')
            seen.add(coalition)
            group('run-host', row['identity'])
            expected = [item['identity'] for item in list(scoped.values()) + snapshot['runs']
                        if self.coalition(item['identity']['pid']) == coalition]
            if groups[-1]['liveMembers'] != sorted(expected, key=lambda item: item['pid']):
                raise RuntimeError('Run-host coalition differs from independent scope inventory')
        if len([row for row in groups if row['role'] == 'run-host']) != len(snapshot['runs']):
            raise RuntimeError('Synthetic fixture run-host coalition inventory incomplete')
        return {'scope': 'resource-coalition', 'unit': 'nanoseconds', 'groups': groups,
                'startUptime': started, 'endUptime': time.clock_gettime(8),
                'queryWallSeconds': time.clock_gettime(8) - started}


def intervals(samples):
    rows = [sample['gpuCoalitions'] for sample in samples]
    first = {row['coalitionID']: row for row in rows[0]['groups']}
    for sample in rows[1:]:
        current = {row['coalitionID']: row for row in sample['groups']}
        if set(current) != set(first):
            raise ValueError('GPU coalition set changed inside measurement')
        for key, before in first.items():
            after = current[key]
            if any(before[field] != after[field] for field in ('role', 'identity', 'liveMembers')):
                raise ValueError('GPU coalition membership/identity changed inside measurement')
    result = []
    for coalition, initial in first.items():
        previous = initial
        for sample in rows[1:]:
            current = next(row for row in sample['groups'] if row['coalitionID'] == coalition)
            if (current['usage']['gpuNanoseconds'] < previous['usage']['gpuNanoseconds']
                    or current['queryUptime'] <= previous['queryUptime']
                    or any(current['usage'][field] != previous['usage'][field] for field in ('tasksStarted', 'tasksExited'))):
                raise ValueError('GPU counter reset, task churn or nonpositive interval')
            previous = current
        delta = previous['usage']['gpuNanoseconds'] - initial['usage']['gpuNanoseconds']
        span = previous['queryUptime'] - initial['queryUptime']
        result.append({'role': initial['role'], 'coalitionID': coalition, 'liveMembers': initial['liveMembers'],
                       'gpuNanosecondsDelta': delta, 'sampleSeconds': span, 'gpuMillisecondsPerSecond': delta / 1e6 / span,
                       'zeroInterpretation': 'Readable cumulative counter with no observed delta; not proof of hardware support'})
    return result


def workload_sample(original_sample, collector, preparations, timeout=None):
    """Classification is preparation; recorded CPU/GPU baselines follow it."""
    pending = collector.app_metadata is None
    started = time.clock_gettime(8) if pending else None
    before = resource.getrusage(resource.RUSAGE_SELF) if pending else None
    children_before = resource.getrusage(resource.RUSAGE_CHILDREN) if pending else None
    ack = original_sample(timeout=timeout)
    ack['gpuCoalitions'] = collector.sample(ack)
    if pending and collector.app_metadata is not None:
        completed = time.clock_gettime(8)
        after = resource.getrusage(resource.RUSAGE_SELF)
        children_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        preparations.append({'definition': 'Unmeasured startup snapshot and classification; fresh baseline follows',
            'startUptime': started, 'completedUptime': completed, 'wallSeconds': completed - started,
            'observerCPUSeconds': after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime,
            'observerHelperCPUSeconds': children_after.ru_utime + children_after.ru_stime
                - children_before.ru_utime - children_before.ru_stime,
            'snapshot': ack})
        # Fetch both the resource snapshot and coalition counters again. Reusing
        # either preparation value would include codesign in the measured span.
        fresh = original_sample(timeout=timeout)
        if fresh is ack or fresh['result']['uptime'] < completed:
            raise ValueError('Fresh resource baseline predates signature preparation completion')
        fresh['gpuCoalitions'] = collector.sample(fresh)
        if fresh['gpuCoalitions']['startUptime'] < completed:
            raise ValueError('Fresh GPU baseline predates signature preparation completion')
        return fresh
    return ack


def self_test():
    from unittest.mock import patch
    app_birth = {'pid': 42, 'startSeconds': 100, 'startMicroseconds': 1}
    service_birth = {'pid': 43, 'startSeconds': 100, 'startMicroseconds': 2}
    service_path = next(iter(APP_XPC_SERVICES))
    paths = {42: str(D.DEFAULT_APP / 'Contents/MacOS/Loom Dev'), 43: service_path}
    collector = Collector.__new__(Collector)
    collector.app = D.DEFAULT_APP.resolve()
    collector.identity = lambda pid: app_birth if pid == 42 else service_birth
    class Proc:
        def proc_pidpath(self, pid, buffer, size):
            buffer.value = paths[pid].encode()
            return len(buffer.value)
    collector.proc = Proc()
    with patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess(['codesign'], 0)) as checked:
        metadata = collector.classify_app(app_birth, [app_birth, service_birth])
        assert len(metadata) == 2 and metadata[1]['signatureVerified'] is True
        assert 'anchor apple and identifier' in checked.call_args.args[0][-2]
        assert '--ignore-resources' not in checked.call_args.args[0]
        assert metadata[1]['resourceEnvelopeVerified'] is True
        paths[43] = SAFARI_HELPER_CODE_ONLY
        safari = collector.classify_app(app_birth, [app_birth, service_birth])
        assert '--ignore-resources' in checked.call_args.args[0]
        assert safari[1]['resourceEnvelopeVerified'] is False
        assert safari[1]['XPCServiceType'] == 'Application'
        paths[43] = service_path
        paths[43] = '/usr/bin/true'
        try:
            collector.classify_app(app_birth, [app_birth, service_birth])
        except RuntimeError as error:
            assert 'Unclassified' in str(error)
        else:
            raise AssertionError('Unknown coalition member accepted')
        service_birth['startSeconds'] = 99
        for candidate in (service_path, SAFARI_HELPER_CODE_ONLY):
            paths[43] = candidate
            try:
                collector.classify_app(app_birth, [app_birth, service_birth])
            except RuntimeError as error:
                assert 'predates' in str(error)
            else:
                raise AssertionError('Preexisting shared XPC accepted')
        service_birth['startSeconds'] = 100
        paths[43] = SAFARI_HELPER_CODE_ONLY
        with patch.object(plistlib, 'loads', return_value={'CFBundleIdentifier': APP_XPC_SERVICES[SAFARI_HELPER_CODE_ONLY],
                                                         'XPCService': {'ServiceType': 'System'}}):
            try:
                collector.classify_app(app_birth, [app_birth, service_birth])
            except RuntimeError as error:
                assert 'per-application' in str(error)
            else:
                raise AssertionError('Non-application Safari helper service accepted')
    with patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess(['codesign'], 1)):
        for candidate in (service_path, SAFARI_HELPER_CODE_ONLY):
            paths[43] = candidate
            try:
                collector.classify_app(app_birth, [app_birth, service_birth])
            except RuntimeError as error:
                assert 'signature' in str(error)
            else:
                raise AssertionError('Unverified Apple signature accepted')
    paths[43] = service_path
    import copy
    def sample(uptime, ns):
        return {'gpuCoalitions': {'groups': [{'role': 'loom-app-and-system-xpc', 'coalitionID': 7,
            'identity': app_birth, 'liveMembers': [app_birth, service_birth], 'queryUptime': uptime,
            'usage': {'gpuNanoseconds': ns, 'tasksStarted': 2, 'tasksExited': 0}}]}}
    valid = [sample(1, 100), sample(2, 1000100)]
    assert intervals(valid)[0]['gpuMillisecondsPerSecond'] == 1
    for change in ('reset', 'membership', 'coalition', 'identity', 'task-churn', 'clock'):
        broken = copy.deepcopy(valid)
        row = broken[-1]['gpuCoalitions']['groups'][0]
        if change == 'reset': row['usage']['gpuNanoseconds'] = 0
        elif change == 'membership': row['liveMembers'] = [app_birth]
        elif change == 'coalition': row['coalitionID'] = 8
        elif change == 'identity': row['identity'] = {'pid': 44}
        elif change == 'task-churn': row['usage']['tasksStarted'] = 3
        else: row['queryUptime'] = 1
        try:
            intervals(broken)
        except ValueError:
            pass
        else:
            raise AssertionError(f'GPU interval accepted {change}')
    # A signature check advances time and counters. Only the second complete
    # snapshot may become the first recorded baseline; later reads stay single.
    def preparation_case(stale_resource=False, stale_gpu=False):
        clock = [1.0]
        reads = []
        class FakeCollector:
            app_metadata = None
            signatures = 0
            queries = 0
            def sample(self, ack):
                self.queries += 1
                if self.app_metadata is None:
                    self.signatures += 1
                    self.app_metadata = ['verified']
                    clock[0] = 4.0
                    return {'startUptime': 2.0, 'counter': 10}
                return {'startUptime': 2.0 if stale_gpu else clock[0], 'counter': self.queries * 100}
        fake = FakeCollector()
        def original_sample(timeout=None):
            reads.append(timeout)
            clock[0] = 2.0 if len(reads) == 1 else 5.0 + len(reads)
            return {'result': {'uptime': 2.0 if stale_resource else clock[0], 'cpuCounter': len(reads) * 100}}
        preparations = []
        with patch.object(time, 'clock_gettime', side_effect=lambda _: clock[0]):
            first = workload_sample(original_sample, fake, preparations)
            assert first['result']['cpuCounter'] == 200 and first['gpuCoalitions']['counter'] == 200
            assert preparations[0]['snapshot']['result']['cpuCounter'] == 100
            assert preparations[0]['snapshot']['gpuCoalitions']['counter'] == 10
            assert preparations[0]['completedUptime'] == 4.0
            assert preparations[0]['wallSeconds'] == 3.0
            second = workload_sample(original_sample, fake, preparations)
            assert second['result']['cpuCounter'] == 300 and fake.signatures == 1
            assert fake.queries == len(reads) == 3 and len(preparations) == 1
    preparation_case()
    for stale_resource, stale_gpu in [(True, False), (False, True)]:
        try:
            preparation_case(stale_resource, stale_gpu)
        except ValueError as error:
            assert 'predates signature preparation' in str(error)
        else:
            raise AssertionError('Stale preparation baseline accepted')
    print('Known Apple XPC inclusion; unknown/older/unsigned member and interval identity/churn/reset/clock guards PASS')
    print('Signature preparation excluded; fresh CPU/GPU baselines, separate cost and single subsequent reads PASS')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=D.DEFAULT_APP)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--visibility', choices=['visible', 'occluded'], default='visible')
    parser.add_argument('--material', choices=['glass', 'opaque'], default='glass')
    parser.add_argument('--scenario', choices=['idle1', 'stream1'], default='idle1')
    parser.add_argument('--renderer', choices=['coregraphics', 'metal'], default='coregraphics')
    parser.add_argument('--duration', type=float, default=60)
    parser.add_argument('--device-only', action='store_true',
                        help='Explicitly leave coalition attribution unavailable; preserve the device-total GPU matrix')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.output is None:
        parser.error('--output is required for measurement')
    if not D.math.isfinite(args.duration) or not 10 <= args.duration <= 600:
        parser.error('Duration must be finite and 10...600 seconds')
    args.output.mkdir(parents=True, exist_ok=False)
    resource_directory = args.output / 'resource'
    resource_directory.mkdir()
    settings = argparse.Namespace(app=args.app, output=resource_directory, scenario=args.scenario,
        renderer=args.renderer, visibility=args.visibility, material=args.material, warmup=10,
        duration=args.duration, sample_every=5, ack_timeout=30, drain_timeout=30, cycles=100,
        latency_samples=200, launch_services=True)
    driver = D.Driver(settings, resource_directory)
    original_sample = driver.sample
    preparations = []
    def sample(timeout=None):
        if args.device_only:
            return original_sample(timeout=timeout)
        return workload_sample(original_sample, collector, preparations, timeout=timeout)
    driver.sample = sample
    gpu_directory = args.output / 'device-gpu'
    # Compilation precedes app launch. Retain only full buckets in the common uptime window.
    sampler = None
    collector = None
    report = {'valid': False, 'invalidReasons': [],
              'scope': 'device-total' if args.device_only else 'resource-coalition',
              'coalitionAttributionAvailable': False,
              'classificationPreparation': preparations,
              'unit': None if args.device_only else 'nanoseconds',
              'primarySources': SOURCES, 'collectorSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'limits': ['Coalition GPU time is not per-PID utilization or device-total busy percentage.',
                         'WindowServer coalition includes all reported members and all window clients.',
                         'Loom coalition includes all classified Apple XPC members; their GPU work is not subtracted.',
                         'Exact Safari platform helper uses code/sealed-Info identity verification; its resource envelope is not validated.',
                         'Zero delta alone cannot distinguish unsupported accounting from no submitted GPU work.',
                         'Numeric budgets remain unknown; device IOReport energy is modeled.']}
    try:
        collector = None if args.device_only else Collector(args.app)
        sampler = subprocess.Popen(['python3', str(Path(__file__).with_name('cp5-gpu-sample.py')),
            '--duration', str(args.duration + 90), '--interval', '5', '--output', str(gpu_directory)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        D.wait_json(gpu_directory / 'manifest.json', 30)
        report['resource'] = driver.run()
        samples = json.loads((resource_directory / 'samples.json').read_text())
        if not args.device_only:
            if collector.app_metadata is None:
                raise ValueError('App coalition startup classification never completed')
            report['coalitionGPU'] = intervals(samples)
            report['appCoalitionStartupMetadata'] = collector.app_metadata
            report['coalitionAttributionAvailable'] = True
        if sampler.wait(timeout=args.duration + 100) != 0:
            raise ValueError('Device-total GPU collector failed')
        device = json.loads((gpu_directory / 'result.json').read_text())
        if device.get('available') is not True:
            raise ValueError('Device GPU counters unavailable')
        start = samples[0]['result']['uptime']
        end = samples[-1]['result']['uptime']
        if not args.device_only:
            start = max(start, samples[0]['gpuCoalitions']['endUptime'])
            end = min(end, samples[-1]['gpuCoalitions']['startUptime'])
        records = [json.loads(line) for line in (gpu_directory / 'samples.jsonl').read_text().splitlines()]
        kept = [row for row in records if row.get('type') == 'sample' and row['startUptimeSeconds'] >= start and row['endUptimeSeconds'] <= end]
        seconds = sum(row['elapsedSeconds'] for row in kept)
        if seconds < args.duration - 10.1:
            raise ValueError('Insufficient complete device GPU buckets in common uptime window')
        report.update(valid=True, deviceGPUMatchedSeconds=seconds, deviceGPUSamples=kept,
                      coalitionSamples=[row['gpuCoalitions'] for row in samples] if not args.device_only else [])
    except Exception as error:
        report['invalidReasons'].append(str(error))
    finally:
        report['appCoalitionID'] = collector.app_coalition if collector is not None else None
        try:
            report['cleanup'] = driver.cleanup()
            if collector is not None and collector.app_coalition is not None:
                deadline = time.monotonic() + 30
                remaining = collector.census({collector.app_coalition}).get(collector.app_coalition, [])
                while remaining and time.monotonic() < deadline:
                    time.sleep(.1)
                    remaining = collector.census({collector.app_coalition}).get(collector.app_coalition, [])
                report['cleanup']['appCoalitionMembersLeft'] = remaining
                if remaining:
                    raise ValueError('App coalition/XPC members remained after Quit')
        except Exception as error:
            report['invalidReasons'].append('Cleanup: ' + str(error))
        if sampler is not None and sampler.poll() is None:
            sampler.terminate()  # Only our own direct unreaped measurement tool child.
            sampler.wait(timeout=5)
        report['valid'] = report['valid'] and not report['invalidReasons']
        (args.output / 'report.json').write_text(json.dumps(report, indent=2))
        print(args.output)
    return 0 if report['valid'] else 1


if __name__ == '__main__':
    sys.exit(main())
