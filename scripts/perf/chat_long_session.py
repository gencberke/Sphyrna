#!/usr/bin/env python3
"""A long fake Claude transcript for the Chat long-session cell (Release B evaluation, step 4).

Writes about 10,000 transcript records (user prompts, assistant text with fenced code blocks, tool calls and their
results) to `<config>/projects/<folder>/<session id>.jsonl` in the shape Claude Code writes, from a fixed seed: the same
arguments give the same bytes. Fake content only. The session must be one the app knows (a Chat session started with
`chat-start`, then stopped), whose isolated profile is `<data root>/claude-config` (the fake-providers profile) and whose
working directory is the project's real path.

How the app loads it (TranscriptLens, Sources/LoomChat/Lens): a cold open reads backward from the end of the file until it
holds the last 10 human prompts (and what follows them) or 1.5 MiB, whichever comes first; older turns come 20 prompts at
a time when the view scrolls up. A resumed session then joins the live run to that history (LiveHistoryJoin). So the file
holds about 10,000 records but opening it parses only its tail: the cell measures that cost, and what a stream costs on
top of a long history.

Usage as a module: write_long_transcript(config, cwd, session_id, records=10000) -> stats dict.
Usage as a script: chat_long_session.py --config <dir> --cwd <project dir> --session <uuid> [--records 10000] [--seed N]
Nothing here touches the real ~/.claude: it refuses a config directory that is the user's own."""
import argparse, datetime, json, pathlib, random, sys, uuid

HOME = pathlib.Path.home()
VERSION = '2.1.300'
MODEL = 'claude-haiku-5-5'
BASE_TIME = datetime.datetime(2026, 9, 1, 9, 0, 0, tzinfo=datetime.timezone.utc)  # fixed, long before any run

WORDS = ('the session stream coordinator buffer request should keep every update before after layout row cache state token '
         'message queue cancel retry window render frame model driver path file result check small stable shared pending '
         'visible hidden across within because while then once never always reads writes wraps holds drops moves emits '
         'applies returns needs keeps avoids limits tracks').split()
NAMES = ['SyncCoordinator', 'retryCount', 'ChatRowStore', 'flushPending()', 'Package.swift', 'makeSnapshot()', 'maxBatch',
         'LiveFeed', 'applyDelta(_:)', 'README.md', 'tick()']
CODE = ['let value = compute(index, limit: 64)', 'guard let next = queue.first else { return }',
        'for item in pending where item.isReady {', '    results.append(item.run())', '}',
        'if retries > limit { throw SyncError.exhausted }', 'state.flush(into: &buffer)', 'return buffer.count - offset',
        'await coordinator.apply(delta)', 'defer { lock.unlock() }', 'let total = rows.reduce(0) { $0 + $1.height }',
        'cache[key] = rendered', '// keep the newest page only']
FILES = ['Sources/Sync/SyncCoordinator.swift', 'Sources/Sync/Retry.swift', 'Tests/SyncTests/SyncCoordinatorTests.swift',
         'Sources/Chat/RowStore.swift', 'Package.swift', 'README.md']


def folder_name(cwd):
    """ClaudeTranscriptFile.folderName: every non-alphanumeric character of the working directory becomes `-`."""
    return ''.join(c if c.isalnum() else '-' for c in str(cwd))


def sentence(rng):
    words = [rng.choice(WORDS) for _ in range(rng.randint(7, 16))]
    for i in range(len(words)):
        if rng.random() < 0.07:
            words[i] = '`' + rng.choice(NAMES) + '`'
        elif rng.random() < 0.05:
            words[i] = '**' + words[i] + '**'
    words[0] = words[0][0].upper() + words[0][1:]
    return ' '.join(words) + '.'


def code_block(rng):
    return '```swift\n' + '\n'.join(rng.choice(CODE) for _ in range(rng.randint(5, 12))) + '\n```'


def paragraph(rng):
    return ' '.join(sentence(rng) for _ in range(rng.randint(2, 4)))


class Writer:
    def __init__(self, session_id, cwd, rng):
        self.session, self.cwd, self.rng = session_id, str(cwd), rng
        self.parent = None
        self.time = BASE_TIME
        self.lines = []

    def new_uuid(self):
        return str(uuid.UUID(int=self.rng.getrandbits(128), version=4))

    def stamp(self):
        self.time += datetime.timedelta(seconds=2, milliseconds=self.rng.randint(0, 900))
        return self.time.strftime('%Y-%m-%dT%H:%M:%S.') + f'{self.time.microsecond // 1000:03d}Z'

    def record(self, kind, **fields):
        uid = self.new_uuid()
        record = {'parentUuid': self.parent, 'isSidechain': False, 'sessionId': self.session, 'cwd': self.cwd,
                  'version': VERSION, 'gitBranch': 'main', 'uuid': uid, 'timestamp': self.stamp(), 'userType': 'external',
                  'entrypoint': 'cli', 'type': kind}
        record.update(fields)
        self.lines.append(json.dumps(record, separators=(',', ':')))
        self.parent = uid

    def user(self, text):
        self.record('user', message={'role': 'user', 'content': text}, promptId=self.new_uuid())

    def assistant(self, blocks, stop='end_turn', tokens=300, message_id=None):
        uid = self.new_uuid()
        self.record('assistant', requestId='req_' + uid[:8], message={
            'id': message_id or 'msg_' + uid[:12], 'type': 'message', 'role': 'assistant', 'model': MODEL, 'content': blocks,
            'stop_reason': stop, 'usage': {'input_tokens': 20000 + len(self.lines), 'output_tokens': tokens,
                                           'cache_read_input_tokens': 18000, 'cache_creation_input_tokens': 1000}})

    def result(self, tool_id, text):
        self.record('user', message={'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool_id, 'content': text}]},
                    toolUseResult={'stdout': text, 'stderr': '', 'interrupted': False})


def turn(w, number):
    """One turn, five records: a prompt, an answer with a code block, a tool call, its result, a closing answer."""
    rng = w.rng
    w.user(f'Step {number}: ' + sentence(rng))
    # One API message of two blocks (Claude Code writes one record per block, sharing the message id).
    message = f'msg_{number:08d}a'
    w.assistant([{'type': 'text', 'text': paragraph(rng) + '\n\n' + code_block(rng) + '\n\n' + sentence(rng)}], stop=None, message_id=message)
    tool_id = f'toolu_{number:06d}'
    path = rng.choice(FILES)
    if rng.random() < 0.5:
        w.assistant([{'type': 'tool_use', 'id': tool_id, 'name': 'Read', 'input': {'file_path': '/tmp/orbit/' + path}}], stop='tool_use', tokens=80, message_id=message)
        w.result(tool_id, '\n'.join(f'{i:6d}\t{rng.choice(CODE)}' for i in range(1, rng.randint(6, 20))))
    else:
        w.assistant([{'type': 'tool_use', 'id': tool_id, 'name': 'Bash', 'input': {'command': f'grep -n {rng.choice(NAMES)} {path}', 'description': 'Search'}}],
                    stop='tool_use', tokens=80, message_id=message)
        w.result(tool_id, '\n'.join(f'{path}:{rng.randint(1, 400)}:{rng.choice(CODE)}' for _ in range(rng.randint(1, 6))))
    w.assistant([{'type': 'text', 'text': paragraph(rng)}])


def write_long_transcript(config, cwd, session_id, records=10000, seed=20261018, folder=None):
    """`folder`: the name of the folder under projects/ when the app's own (a file already there) is known."""
    config = pathlib.Path(config).expanduser().resolve()
    if config in (HOME / '.claude', HOME / '.codex') or HOME / '.claude' in config.parents:
        raise SystemExit(f'{config} is the user\'s real profile; use an isolated profile.')
    session_id = str(uuid.UUID(str(session_id))).lower()
    writer = Writer(session_id, cwd, random.Random(seed))
    number = 0
    while len(writer.lines) < records:
        number += 1
        turn(writer, number)
    folder = config / 'projects' / (folder or folder_name(cwd))
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f'{session_id}.jsonl'
    path.write_text('\n'.join(writer.lines) + '\n')
    kinds = {'user': 0, 'assistant': 0, 'toolUse': 0, 'toolResult': 0, 'codeBlocks': 0}
    for line in writer.lines:
        record = json.loads(line)
        kinds[record['type']] += 1
        content = record['message']['content']
        if isinstance(content, list):
            for block in content:
                kinds['toolUse'] += block['type'] == 'tool_use'
                kinds['toolResult'] += block['type'] == 'tool_result'
                kinds['codeBlocks'] += block['type'] == 'text' and '```' in block['text']
    prompts = number
    return {'path': str(path), 'records': len(writer.lines), 'bytes': path.stat().st_size, 'humanPrompts': prompts,
            'seed': seed, **kinds}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--config', type=pathlib.Path, required=True)
    parser.add_argument('--cwd', type=pathlib.Path, required=True)
    parser.add_argument('--session', required=True)
    parser.add_argument('--records', type=int, default=10000)
    parser.add_argument('--seed', type=int, default=20261018)
    args = parser.parse_args()
    print(json.dumps(write_long_transcript(args.config, args.cwd.resolve(), args.session, args.records, args.seed), indent=1))


if __name__ == '__main__':
    sys.exit(main())
