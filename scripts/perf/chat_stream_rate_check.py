#!/usr/bin/env python3
"""Checks the fake provider's `/scenario stream <seconds> <chars/s>` rate without the app: runs the provider alone in chat
mode (a temp profile and folder), reads its NDJSON, and compares the characters of text deltas with the rate over the whole
run and over every 10 s window. Exit 0 when the total and each full window are within --tolerance (default 5 %).
Usage: scripts/perf/chat_stream_rate_check.py --fixtures <dir with loom-fake-provider> [--seconds 60] [--rate 600]
Light (one small process), but run it like the other perf scripts: in the build slot, thermal state nominal.
Output: one JSON object on stdout (no content, only counts)."""
import argparse, json, os, pathlib, subprocess, sys, tempfile, threading, time, uuid

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--fixtures', type=pathlib.Path, required=True)
parser.add_argument('--seconds', type=float, default=60)
parser.add_argument('--rate', type=int, default=600)
parser.add_argument('--window', type=float, default=10)
parser.add_argument('--tolerance', type=float, default=0.05)
args = parser.parse_args()

provider = args.fixtures.expanduser().resolve() / 'loom-fake-provider'
work = pathlib.Path(tempfile.mkdtemp(prefix='loom-stream-rate-'))
(work / 'config').mkdir()
child = subprocess.Popen(
    [str(provider), '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose',
     '--include-partial-messages', '--replay-user-messages', '--permission-prompt-tool', 'stdio', '--session-id', str(uuid.uuid4())],
    cwd=work, env={'PATH': '/usr/bin:/bin', 'CLAUDE_CONFIG_DIR': str(work / 'config')},
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
deltas, tools, result = [], [], []   # (monotonic time, characters), tool_use times, the result record
def read():
    for line in child.stdout:
        now = time.monotonic()
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get('type') == 'stream_event':
            event = record.get('event', {})
            if event.get('type') == 'content_block_delta' and event.get('delta', {}).get('type') == 'text_delta':
                deltas.append((now, len(event['delta']['text'])))
            if event.get('type') == 'content_block_start' and event.get('content_block', {}).get('type') == 'tool_use':
                tools.append(now)
        elif record.get('type') == 'result':
            result.append((now, record))
reader = threading.Thread(target=read, daemon=True)
reader.start()
try:
    sent = time.monotonic()
    message = {'type': 'user', 'message': {'role': 'user', 'content': f'/scenario stream {args.seconds} {args.rate}'},
               'parent_tool_use_id': None, 'uuid': str(uuid.uuid4()), 'origin': {'kind': 'human'}}
    child.stdin.write((json.dumps(message) + '\n').encode()); child.stdin.flush()
    deadline = time.monotonic() + args.seconds + 30
    while not result and time.monotonic() < deadline:
        time.sleep(0.1)
finally:
    child.stdin.close()
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        child.kill()
    reader.join(timeout=5)

problems = []
if not result:
    sys.exit(json.dumps({'valid': False, 'invalidReasons': ['no result record']}))
first = deltas[0][0]
chars = sum(n for _, n in deltas)
elapsed = result[0][0] - first
buckets = []
for index in range(int(args.seconds // args.window)):
    low = first + index * args.window
    count = sum(n for t, n in deltas if low <= t < low + args.window)
    ratio = count / (args.rate * args.window)
    buckets.append({'fromSeconds': index * args.window, 'characters': count, 'ratioToRate': round(ratio, 4)})
    if abs(ratio - 1) > args.tolerance:
        problems.append(f'window {index}: {ratio:.3f} of the rate')
total_ratio = chars / (args.rate * args.seconds)
if abs(total_ratio - 1) > args.tolerance:
    problems.append(f'total: {total_ratio:.3f} of the rate')
record = result[0][1]
if record.get('subtype') != 'success' or record.get('is_error') or record.get('terminal_reason') != 'completed':
    problems.append('the turn did not end with a normal result')
print(json.dumps({'valid': not problems, 'invalidReasons': problems, 'requestedSeconds': args.seconds, 'requestedRate': args.rate,
                  'characters': chars, 'ratioToRequested': round(total_ratio, 4), 'firstDeltaToResultSeconds': round(elapsed, 3),
                  'effectiveCharactersPerSecond': round(chars / max(1e-9, deltas[-1][0] - first), 1), 'deltas': len(deltas),
                  'toolCalls': len(tools), 'windows': buckets}, indent=1))
subprocess.run(['rm', '-rf', str(work)], check=False)
sys.exit(1 if problems else 0)
