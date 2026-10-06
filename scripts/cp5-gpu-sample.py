#!/usr/bin/env python3
"""Bounded normal-UID, device-total GPU IOReport sampler; never PID attribution.

Run alongside the frozen matrix runner, using a fresh output directory:
  cp5-gpu-sample.py --duration 600 --interval 5 --output /path/to/gpu-run
Counters include every GPU user on this device. They cannot attribute Loom or
WindowServer consumption. Energy is Apple's modeled counter, not a calibrated
physical measurement. No root, installations, or preferences are involved.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--duration', type=float, default=3)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--output', type=Path, required=True, help='Fresh directory for manifest, JSONL samples and result')
    parser.add_argument('--test-missing-channel', action='store_true', help='Capability-negative smoke: select no channels, fail honestly')
    args = parser.parse_args()
    if not all(math.isfinite(value) for value in (args.duration, args.interval)) or not 0 < args.duration <= 3600 or not .1 <= args.interval <= min(60, args.duration):
        parser.error('Expected finite duration >0, <=3600 and interval >=0.1, <=60, <=duration')
    if args.output.exists():
        parser.error('Output directory must be fresh; existing evidence is never overwritten')
    args.output.mkdir(parents=True)
    source = Path(__file__).with_suffix('.c').resolve()
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    limits = ['Device aggregate; Loom/WindowServer/process attribution unavailable.',
              'Energy model counter; not calibrated physical power measurement.',
              'Undocumented IOReport channels/units must match exactly; capability drift fails.',
              'IORegistry utilization is not sampled; no unverified private key assumptions.',
              'CPU/frame counters are not used as GPU evidence.',
              'Opaque subscription teardown is owned by standalone process exit.',
              'Interval >=0.1s and duration <=3600s; cadence tolerance max(10%,50ms).']
    manifest = {'scope': 'device-total', 'attribution': 'unavailable', 'euid': os.geteuid(),
                'source': str(source), 'sourceSHA256': digest, 'wrapperSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'requestedDurationSeconds': args.duration, 'requestedIntervalSeconds': args.interval,
                'timebase': 'CLOCK_UPTIME_RAW (SDK8) seconds, mach_absolute_time base; aligns Loom ProcessInfo.systemUptime; sampled after IOReport sample creation',
                'wrapperTimebase': 'Python time.monotonic is process-relative/duration-only on this host; never use wrapper timestamps for global alignment',
                'units': {'energy': 'nJ', 'modeledAveragePower': 'mW', 'residency': '24Mticks', 'active': 'percent'},
                'capabilitySource': 'plans/experiments/cp5-gpu-capability-research.json', 'limits': limits}
    result = {'available': False, 'scope': 'device-total', 'attribution': 'unavailable', 'errors': []}
    child = None
    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix='loom-cp5-gpu-') as temporary:
            binary = Path(temporary) / 'sampler'
            command = ['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', str(source),
                       '-framework', 'CoreFoundation', '-lIOReport', '-o', str(binary)]
            manifest['compileCommand'] = command
            compiled = subprocess.run(command, capture_output=True, text=True, timeout=30)
            (args.output / 'compile.txt').write_text(compiled.stdout + compiled.stderr)
            if compiled.returncode:
                raise RuntimeError('clang failed; see compile.txt')
            manifest['binarySHA256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
            run = [str(binary), format(args.duration, '.17g'), format(args.interval, '.17g'), str(args.output.resolve() / 'samples.jsonl')]
            if args.test_missing_channel:
                run.append('--test-missing-channel')
            manifest['sampleCommand'] = run
            manifest['watchdogSeconds'] = args.duration + 5
            (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
            sample_started = time.monotonic()
            manifest['wrapperLaunchLocalMonotonicSeconds'] = sample_started
            child = subprocess.Popen(run, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            result['samplerPID'] = child.pid
            try:
                stdout, stderr = child.communicate(timeout=args.duration + 5)
            except subprocess.TimeoutExpired:
                # This is our direct unreaped child; no PID scan or unrelated signals.
                child.kill()
                stdout, stderr = child.communicate(timeout=5)
                raise TimeoutError('Sampler exceeded duration+5s watchdog; partial counters are unavailable for acceptance')
            result['samplerWallSeconds'] = time.monotonic() - sample_started
            result['samplerExitCode'] = child.returncode
            (args.output / 'sampler-log.txt').write_text(stdout + stderr)
            records = [json.loads(line) for line in (args.output / 'samples.jsonl').read_text().splitlines()]
            samples = [row for row in records if row.get('type') == 'sample']
            errors = [row.get('error', 'Unknown counter error') for row in records if row.get('type') == 'error']
            if child.returncode or errors:
                result['errors'] += errors
                raise RuntimeError(f'GPU capability/sample failed (exit {child.returncode}); no unavailable values replaced with zero')
            if not samples or any(row.get('available') is not True or row.get('scope') != 'device-total' or row.get('attribution') != 'unavailable' for row in samples):
                raise RuntimeError('Missing valid device-total sample records')
            measured = samples[-1]['endUptimeSeconds'] - samples[0]['startUptimeSeconds']
            if measured < args.duration - .001:
                raise RuntimeError('Sampler ended before requested counter duration')
            if any(row['elapsedSeconds'] > args.interval + max(.05, args.interval * .1) for row in samples):
                raise RuntimeError('Sampling cadence missed requested interval beyond declared 10%/50ms tolerance')
            if any(row['elapsedSeconds'] <= 0 for row in samples):
                raise RuntimeError('Nonpositive monotonic counter interval')
            for old, new in zip(samples, samples[1:]):
                if new['index'] != old['index'] + 1 or abs(new['startUptimeSeconds'] - old['endUptimeSeconds']) > .000001:
                    raise RuntimeError('Counter interval sequence is incomplete')
            energy = sum(channel['delta'] for row in samples for channel in row['channels'] if channel['unit'] == 'nJ')
            result.update(available=True, sampleCount=len(samples), measuredCounterSeconds=measured,
                          energyDeltaNanojoules=energy, modeledAverageMilliwatts=energy / measured / 1e6,
                          limits=limits)
    except Exception as error:
        result['errors'].append(str(error))
    finally:
        # Compilation is also bounded and is recorded separately from sampling.
        result['wrapperEndLocalMonotonicSeconds'] = time.monotonic()
        result['totalToolWallSeconds'] = result['wrapperEndLocalMonotonicSeconds'] - started
        (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
        (args.output / 'result.json').write_text(json.dumps(result, indent=2))
        print(args.output)
    return 0 if result['available'] else 1


if __name__ == '__main__':
    sys.exit(main())
