#!/usr/bin/env python3
"""Test guard: the rules a test file keeps (DEVELOPMENT §3.1), counted per file against a ratchet.

The rules (comments and strings blanked unless a rule reads comments):
  pool-block        a blocking call (usleep, Thread.sleep, sleep, waitUntilExit, readDataToEndOfFile, a semaphore,
                    condition or group wait) outside an `onOwnThread { }` closure: it holds one of the cooperative pool's
                    eight threads
  detached-block    a `Task.detached { }` that makes a blocking call: the same, with the hop hiding it
  sleep             `Task.sleep` with no `// sleep: <reason>` on its line or the line above: wait for a condition instead
  wait-helper       a wait helper defined in a test file (`func waitUntil…`, `waitFor…`, `until`, `eventually`, `wait`):
                    the shared bounded wait lives in Tests/LoomTestSupport/
  silent-wait       `#expect`/`#require` of an awaited wait with no message: a failure names nothing it saw
  key-window        a window made key or ordered in outside the window tests (LoomWindowTests), or
                    LoomTestSupport's `host(…, key: true)` there
  global-state      a write to process-wide state that parallel suites share (ChatPresentation's verifier, HoverForce,
                    DragActivity, ChatUserText.watchedID, SessionDragProbe), or a render probe watched or reset in a file
                    without the `.renderProbe` trait
  real-input        a test reads the Mac's real input state (mouse buttons, pointer location, modifier keys) or drives a
                    product object whose default reader does (`DragActivity.shared`): a press anywhere on the Mac changes
                    the result. The owner injects a reader (0f48daf)
  superseded        a line cites a superseded decision (DECISIONS §2.1) and no other decision
  milestone-name    a test file named by a round, slice or release (FixRound, B3, ReleaseC, V12, Polish, Review)
  disabled          a `.disabled(` trait
  serialized        a `.serialized` suite with no `// serialized: <reason>` on its `@Suite` line or the three above
  quarantine        (strict, not ratcheted) `withKnownIssue(isIntermittent: true` needs `// flake: <id> <YYYY-MM-DD> <cause>`
                    on its line or the line above, and fails 14 days after that date
  targets           (strict) the tiers' boundaries in Package.swift and the test libraries: only test targets (and the
                    rigs, on LoomTestSupport) depend on a rig (`Loom<Area>TestRigs`) or LoomTestSupport, and no product
                    lists one; both live under Tests/; scripts/release/Package.release.swift names none; they declare no
                    `@Test` or `@Suite`; LoomTestSupport imports no product and nothing `@testable` (rigs reach product
                    internals, the support never does); Sources/ has no `@testable import`; `WindowEventTests` is only in
                    LoomWindowTests

The ratchet: scripts/check-tests.allow holds `rule<TAB>path<TAB>count` for what the tree had when a rule arrived. A count
that rises, or a path the file does not list, fails. A count that falls is reported; `--update` writes the lower counts and
re-keys moved files, and refuses a rule whose total rises unless `--accept-rise "<reason>"` (the reason belongs in the commit).

Usage: scripts/check-tests.py [--root <repo>]            check the tree against the allow file (exit 0, or 1 listing rises)
       scripts/check-tests.py --summary                   totals per rule and the files carrying the most
       scripts/check-tests.py --list <rule>               every finding of one rule, file:line
       scripts/check-tests.py --quarantines               the known intermittent issues and their age
       scripts/check-tests.py --decision D-xx             the test lines that cite a decision
       scripts/check-tests.py --update [--accept-rise "<reason>"]
       scripts/check-tests.py --self-test
"""
import datetime
import os
import re
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swift_source as swift  # noqa: E402

DEFAULT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALLOW = 'scripts/check-tests.allow'
SUPPORT = 'Tests/LoomTestSupport/'
WINDOW_TARGET = 'Tests/LoomWindowTests/'
QUARANTINE_DAYS = 14

BLOCKING = re.compile(r'(?<![\w.])(usleep|sleep)\s*\(|Thread\.sleep\s*\(|\.waitUntilExit\s*\(|\.readDataToEndOfFile\s*\('
                      r'|\b\w*([Ss]emaphore|[Cc]ondition|[Gg]roup|[Ss]ignal|[Gg]ate|[Ll]ock)\w*\.wait\s*\(')
SYNC_APIS = re.compile(r'(?<!\w)(exchange|readTUIFrame|helper)\s*\(|\.waitUntilExit\s*\(|\.readDataToEndOfFile\s*\('
                       r'|(?<![\w.])usleep\s*\(|Thread\.sleep\s*\(|\.wait\s*\(')
WAIT_HELPER = re.compile(r'\bfunc\s+(waitUntil\w*|waitFor\w*|until|eventually|wait)\s*[(<]')
WAIT_CALL = re.compile(r'(?<![\w.])(waitUntil\w*|waitFor\w*|until|eventually|wait)\s*[({]')
KEY_WINDOW = re.compile(r'\.makeKeyAndOrderFront\s*\(|\.orderFrontRegardless\s*\(|\.orderFront\s*\(|\.makeKey\s*\(')
GLOBAL_WRITES = re.compile(r'ChatPresentation\.(verifiesRows|onMismatch)\s*=(?!=)|HoverForce\.shared\b|DragActivity\.shared\b'
                           r'|ChatUserText\.watchedID\s*=(?!=)|SessionDragProbe\.watch\s*\(')
PROBE_USE = re.compile(r'\b(Sidebar|Chat|Header|StatusBar)RenderProbe\.(watch|reset)\s*\(|ChatSelectionProbe\.reset\s*\(')
REAL_INPUT = re.compile(r'\bNSEvent\.(pressedMouseButtons|mouseLocation|modifierFlags)\b'
                        r'|\bCGEventSource\.(buttonState|flagsState|keyState)\b|\bDragActivity\.shared\b')
MILESTONE = re.compile(r'FixRound|^B\d|Release[A-Z]|^V\d\d|Polish|Review')
FLAKE = re.compile(r'//\s*flake:\s*(\S+)\s+(\d{4}-\d{2}-\d{2})\s+\S')
DECISION = re.compile(r'\bD-(\d{2,3})\b')

RATCHETED = ['pool-block', 'detached-block', 'sleep', 'wait-helper', 'silent-wait', 'key-window', 'global-state',
             'real-input', 'superseded', 'milestone-name', 'disabled', 'serialized']


def superseded_ids(root):
    """Whole decisions DECISIONS §2.1 marks superseded: rows whose ID cell names no clause and whose reason starts
    'Superseded by/in'. A clause row (`D-40 (vault discovery clause)`) leaves the rest of its decision standing."""
    path = os.path.join(root, 'DECISIONS.md')
    if not os.path.exists(path):
        return set()
    ids, inside = set(), False
    for line in open(path, encoding='utf-8'):
        if line.startswith('### 2.1'):
            inside = True
        elif line.startswith('#') and inside:
            break
        elif inside and line.startswith('| **D-'):
            cells = [c.strip() for c in line.strip().strip('|').split('|')]
            if len(cells) >= 3 and '(' not in cells[0] and re.match(r'\*\*Superseded (by|in)', cells[2]):
                ids |= {f'D-{n}' for n in DECISION.findall(cells[0])}
    return ids


def test_files(root):
    found = []
    for base, _, names in os.walk(os.path.join(root, 'Tests')):
        for name in names:
            if name.endswith('.swift'):
                found.append(os.path.relpath(os.path.join(base, name), root))
    return sorted(found)


def own_thread_spans(code):
    """The spans of `onOwnThread(…) { … }` closures and of `Thread { … }` bodies: they run on threads of their own, where
    blocking is their purpose."""
    spans = []
    for m in re.finditer(r'(?<![\w.])Thread\s*(\{|\(block:\s*\{)', code):
        brace = m.end() - 1
        spans.append((brace, swift.closing_brace(code, brace)))
    for start in swift.call_sites('onOwnThread', code):
        paren = code.index('(', start)
        after = swift.closing_paren(code, paren) + 1
        brace = code.find('{', after)
        if brace >= 0 and code[after:brace].strip() == '':
            spans.append((brace, swift.closing_brace(code, brace)))
        else:  # a trailing closure inside the parentheses
            spans.append((paren, swift.closing_paren(code, paren)))
    return spans


def inside(spans, offset):
    return any(a <= offset <= b for a, b in spans)


def is_window_file(path, text):
    return path.startswith(WINDOW_TARGET)


def package_targets(text):
    """{name: (kind, path or None, [dependency names])} and {product: [targets]} from a manifest's text."""
    def call_end(i):
        depth = 0
        for k in range(i, len(text)):
            if text[k] == '(':
                depth += 1
            elif text[k] == ')':
                depth -= 1
                if depth == 0:
                    return k
        return len(text)
    targets, products = {}, {}
    for m in re.finditer(r'\.(target|executableTarget|testTarget|library|executable)\s*\(\s*name:\s*"([^"]+)"', text):
        body = text[m.start():call_end(text.index('(', m.start()))]
        if m.group(1) in ('library', 'executable'):
            t = re.search(r'targets:\s*\[([^\]]*)\]', body)
            products[m.group(2)] = re.findall(r'"([^"]+)"', t.group(1)) if t else []
            continue
        d = re.search(r'dependencies:\s*\[', body)
        deps = []
        if d:
            depth, k = 0, d.end() - 1
            for k in range(d.end() - 1, len(body)):
                depth += {'[': 1, ']': -1}.get(body[k], 0)
                if depth == 0:
                    break
            deps = re.findall(r'(?<![\w:])"([^"]+)"', re.sub(r'\.product\([^)]*\)', '', body[d.end():k]))
        path = re.search(r'path:\s*"([^"]+)"', body)
        targets[m.group(2)] = (m.group(1), path.group(1) if path else None, deps)
    return targets, products


def target_problems(root):
    """The `targets` rule over the checked-out tree (strict)."""
    manifest = os.path.join(root, 'Package.swift')
    if not os.path.exists(manifest):
        return []
    targets, products = package_targets(open(manifest, encoding='utf-8').read())
    libraries = {n for n in targets if n == 'LoomTestSupport' or n.endswith('TestRigs')}
    out = []
    for name, (kind, path, deps) in sorted(targets.items()):
        used = sorted(set(deps) & libraries)
        if name in libraries:
            if kind != 'target' or not (path or '').startswith('Tests/'):
                out.append(f'targets: {name} is a plain target under Tests/')
            if name == 'LoomTestSupport' and used:
                out.append(f'targets: LoomTestSupport depends on {", ".join(used)}')
        elif kind != 'testTarget' and used:
            out.append(f'targets: {kind} {name} depends on {", ".join(used)}; only test targets do')
    for name, members in sorted(products.items()):
        if set(members) & libraries:
            out.append(f'targets: product {name} lists {", ".join(sorted(set(members) & libraries))}')
    release = os.path.join(root, 'scripts/release/Package.release.swift')
    if os.path.exists(release) and re.search(r'LoomTestSupport|TestRigs', open(release, encoding='utf-8').read()):
        out.append('targets: scripts/release/Package.release.swift names a test library')
    library_types = set()
    for path in test_files(root):
        if path.split('/')[1] in libraries:
            library_types |= set(re.findall(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|final)\s+)*(?:struct|enum|class|actor)\s+(\w+)',
                                            swift.code(open(os.path.join(root, path), encoding='utf-8').read()), re.M))
    for path in test_files(root):
        top = path.split('/')[1]
        code = swift.code(open(os.path.join(root, path), encoding='utf-8').read())
        if top in libraries and re.search(r'@(Test|Suite)\b', code):
            out.append(f'targets: {path} declares a test or suite; {top} is a library the tests link')
        if top == 'LoomTestSupport':
            for m in re.finditer(r'^\s*(@testable\s+import\s+\w+|import\s+(Loom\w+|CLoom\w+))', code, re.M):
                out.append(f'targets: {path}:{swift.line_of(code, m.start())}: LoomTestSupport stays product-free ({m.group(1)})')
        if top not in libraries:
            for m in re.finditer(r'^extension\s+(\w+)\b', code, re.M):
                body = code[m.end():swift.closing_brace(code, code.index('{', m.end()))] if '{' in code[m.end():] else ''
                if m.group(1) in library_types and re.search(r'@(Test|Suite)\b', body):
                    out.append(f'targets: {path}:{swift.line_of(code, m.start())}: tests nested in {m.group(1)}, a type of a '
                               'test library, carry its module in their ids (out of their tier\'s filter)')
        if not path.startswith(WINDOW_TARGET) and re.search(r'\bWindowEventTests\b', code):
            out.append(f'targets: {path} names WindowEventTests, which is only LoomWindowTests\'')
    for base, _, names in os.walk(os.path.join(root, 'Sources')):
        for name in names:
            if name.endswith('.swift') and re.search(r'^\s*@testable\s+import', open(os.path.join(base, name), encoding='utf-8').read(), re.M):
                out.append(f'targets: {os.path.relpath(os.path.join(base, name), root)} has an @testable import')
    return out


def scan(path, text, superseded):
    """{rule: [line, …]} for one test file."""
    code = swift.code(text)
    lines = text.split('\n')
    found = {}

    def add(rule, offset_or_line, is_line=False):
        found.setdefault(rule, []).append(offset_or_line if is_line else swift.line_of(code, offset_or_line))

    support = path.startswith(SUPPORT)
    spans = own_thread_spans(code)
    # A wait on a name the file binds to a semaphore, group or condition, whatever the name.
    bound = set(re.findall(r'\b(?:let|var)\s+(\w+)\s*(?::[^=\n]*)?=\s*(?:Dispatch(?:Semaphore|Group)|NSCondition\w*)\s*\(', code))
    blocking = list(BLOCKING.finditer(code))
    if bound:
        named = re.compile(r'(?<![\w.])(' + '|'.join(sorted(bound)) + r')\.wait\s*\(')
        seen = {m.start() for m in blocking}
        blocking += [m for m in named.finditer(code) if m.start() not in seen]
    for m in blocking:
        before = code[:m.start()].rstrip()
        # `await gate.wait()` suspends; `func sleep(` is a fake's declaration.
        if not inside(spans, m.start()) and not before.endswith('await') and not re.search(r'\bfunc$', before):
            add('pool-block', m.start())
    for start in [m.start() for m in re.finditer(r'\bTask\.detached\b', code)]:
        brace = code.find('{', start)
        if brace < 0:
            continue
        body = code[brace:swift.closing_brace(code, brace) + 1]
        body_spans = [(a - brace, b - brace) for a, b in own_thread_spans(body)]
        for m in SYNC_APIS.finditer(body):
            if not inside(body_spans, m.start()) and 'await' not in body[max(0, m.start() - 40):m.start()].split('\n')[-1]:
                add('detached-block', brace + m.start())
    for m in re.finditer(r'\bTask\.sleep\s*\(', code):
        n = swift.line_of(code, m.start())
        near = lines[n - 1] + '\n' + (lines[n - 2] if n >= 2 else '')
        if not re.search(r'//\s*sleep:\s*\S', near):
            add('sleep', m.start())
    if not support:
        for m in WAIT_HELPER.finditer(code):
            add('wait-helper', m.start())
    for m in re.finditer(r'#(expect|require)\s*\(', code):
        paren = m.end() - 1
        args = swift.top_level_args(code, paren)
        if len(args) == 1:
            first = code[args[0][0]:args[0][1]]
            if 'await' in first and WAIT_CALL.search(first):
                add('silent-wait', m.start())
    # The support's window host is where a test's window is made; whether it is key is the caller's ask, counted below.
    if not is_window_file(path, text) and not support:
        for m in KEY_WINDOW.finditer(code):
            add('key-window', m.start())
        # LoomTestSupport's `host(_:size:key:)` asked for a key window.
        for start in swift.call_sites('host', code):
            if code[start - 1:start] != '.' and re.search(r'\bkey:\s*true\b', code[start:swift.closing_paren(code, code.index('(', start))]):
                add('key-window', start)
    for m in GLOBAL_WRITES.finditer(code):
        add('global-state', m.start())
    if not re.search(r'\.renderProbe\b', code) and not path.endswith('RenderProbeExclusive.swift'):
        for m in PROBE_USE.finditer(code):
            add('global-state', m.start())
    for m in REAL_INPUT.finditer(code):
        add('real-input', m.start())
    if superseded:
        for n, line in enumerate(lines, 1):
            cited = {f'D-{d}' for d in DECISION.findall(line)}
            if cited & superseded and not cited - superseded:
                add('superseded', n, is_line=True)
    if MILESTONE.search(os.path.basename(path)):
        add('milestone-name', 1, is_line=True)
    for m in re.finditer(r'\.disabled\s*\(', code):
        add('disabled', m.start())
    for m in re.finditer(r'@Suite\b', code):
        n = swift.line_of(code, m.start())
        head = code[m.start():code.find('\n', m.start()) if '{' not in code[m.start():m.start() + 400] else code.find('{', m.start())]
        if '.serialized' in head:
            near = '\n'.join(lines[max(0, n - 4):n])
            if not re.search(r'//\s*serialized:\s*\S', near):
                add('serialized', m.start())
    return found


def quarantines(path, text, today):
    """[(line, id, date, problem or None)] for each intermittent known issue."""
    out = []
    lines = text.split('\n')
    code = swift.code(text)
    for m in re.finditer(r'withKnownIssue\s*\([^)]*isIntermittent:\s*true', code):
        n = swift.line_of(code, m.start())
        mark = None
        for k in range(max(0, n - 2), n):
            mark = FLAKE.search(lines[k]) or mark
        if not mark:
            out.append((n, None, None, 'no `// flake: <id> <YYYY-MM-DD> <cause>` on its line or the line above'))
            continue
        try:
            date = datetime.date.fromisoformat(mark.group(2))
        except ValueError:
            out.append((n, mark.group(1), mark.group(2), 'the date is not a date'))
            continue
        age = (today - date).days
        problem = f'quarantined {age} days, more than {QUARANTINE_DAYS}: fix the cause or remove the test' \
            if age > QUARANTINE_DAYS else None
        out.append((n, mark.group(1), date.isoformat(), problem))
    return out


def collect(root):
    superseded = superseded_ids(root)
    findings = {}
    for path in test_files(root):
        text = open(os.path.join(root, path), encoding='utf-8').read()
        for rule, where in scan(path, text, superseded).items():
            findings.setdefault(rule, {})[path] = sorted(where)
    return findings


def counts(findings):
    return {(rule, path): len(lines) for rule, paths in findings.items() for path, lines in paths.items()}


def read_allow(root):
    allowed = {}
    path = os.path.join(root, ALLOW)
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            if line.strip() and not line.startswith('#'):
                rule, file, n = line.rstrip('\n').split('\t')
                allowed[(rule, file)] = int(n)
    return allowed


def write_allow(root, current):
    with open(os.path.join(root, ALLOW), 'w', encoding='utf-8') as f:
        f.write('# What the tests carried when each rule of scripts/check-tests.py arrived: rule, file, count.\n'
                '# Counts only fall. Written by `scripts/check-tests.py --update`; do not raise a line by hand.\n')
        for rule, path in sorted(current, key=lambda k: (RATCHETED.index(k[0]), k[1])):
            f.write(f'{rule}\t{path}\t{current[(rule, path)]}\n')


def totals(c):
    out = {}
    for (rule, _), n in c.items():
        out[rule] = out.get(rule, 0) + n
    return out


def check(root, today):
    findings = collect(root)
    current, allowed = counts(findings), read_allow(root)
    rises, falls = [], []
    for key, n in sorted(current.items()):
        rule, path = key
        if n > allowed.get(key, 0):
            lines = ', '.join(str(x) for x in findings[rule][path])
            rises.append(f'{rule}: {path} has {n}, the allow file {allowed.get(key, 0)} (lines {lines})')
    for key, n in sorted(allowed.items()):
        if current.get(key, 0) < n:
            falls.append(f'{key[0]}: {key[1]} {n} -> {current.get(key, 0)}')
    bad_quarantine = []
    for path in test_files(root):
        text = open(os.path.join(root, path), encoding='utf-8').read()
        for n, _, _, problem in quarantines(path, text, today):
            if problem:
                bad_quarantine.append(f'quarantine: {path}:{n}: {problem}')
    bad_quarantine += target_problems(root)
    t = totals(current)
    print('test guard: ' + ', '.join(f'{r} {t.get(r, 0)}' for r in RATCHETED))
    if falls:
        print(f'test guard: {len(falls)} counts fell; `scripts/check-tests.py --update` records them')
    if rises or bad_quarantine:
        print('Test guard (scripts/check-tests.py; the rules are in DEVELOPMENT §3.1):', file=sys.stderr)
        for line in rises + bad_quarantine:
            print(f'  {line}', file=sys.stderr)
        return 1
    return 0


def update(root, accept_rise):
    current, allowed = counts(collect(root)), read_allow(root)
    now, before = totals(current), totals(allowed)
    risen = [r for r in RATCHETED if now.get(r, 0) > before.get(r, 0)]
    if risen and allowed and not accept_rise:
        print('check-tests --update: these totals rise: ' + ', '.join(f'{r} {before.get(r, 0)} -> {now[r]}' for r in risen)
              + '. Fix the tests, or pass --accept-rise "<reason>" and put the reason in the commit.', file=sys.stderr)
        return 1
    write_allow(root, current)
    print(f'check-tests --update: {ALLOW} holds ' + ', '.join(f'{r} {now.get(r, 0)}' for r in RATCHETED))
    return 0


def summary(root):
    findings = collect(root)
    for rule in RATCHETED:
        paths = findings.get(rule, {})
        total = sum(len(v) for v in paths.values())
        top = sorted(paths.items(), key=lambda kv: -len(kv[1]))[:3]
        print(f'{rule:15} {total:5} in {len(paths):3} files   ' + ', '.join(f'{os.path.basename(p)} {len(v)}' for p, v in top))


def list_rule(root, rule):
    for path, lines in sorted(collect(root).get(rule, {}).items()):
        for n in lines:
            print(f'{path}:{n}')


def list_quarantines(root, today):
    for path in test_files(root):
        text = open(os.path.join(root, path), encoding='utf-8').read()
        for n, flake, date, problem in quarantines(path, text, today):
            print(f'{path}:{n}\t{flake or "-"}\t{date or "-"}\t{problem or "ok"}')


def list_decision(root, decision):
    pattern = re.compile(rf'\b{re.escape(decision)}\b')
    for path in test_files(root):
        for n, line in enumerate(open(os.path.join(root, path), encoding='utf-8'), 1):
            if pattern.search(line):
                print(f'{path}:{n}: {line.strip()[:140]}')


# ---- self-test ------------------------------------------------------------------------------------------------------------

PLANTED = {
    'pool-block': ('func f() async { usleep(10); let s = DispatchSemaphore(value: 0); s.wait() }\n'
                   'func g() async throws { try await onOwnThread("x") { usleep(5); p.waitUntilExit() } }\n'
                   'func h() async { await gate.wait() }\nfunc sleep(until date: Date) async throws {}\n'
                   'func i() { while lock.withLock({ n }) < 1 { usleep(10_000) }; _ = pipe.readDataToEndOfFile() }\n'
                   'let t = Thread { _ = done.wait(timeout: .now() + 5); Thread.sleep(forTimeInterval: 1) }\n', 4),
    'detached-block': ('func f() async { Task.detached { _ = try client.exchange(request) } }\n'
                       'func g() async { Task.detached { await model.wait() } }\n', 1),
    'sleep': ('func f() async throws {\n    try await Task.sleep(for: .milliseconds(5))\n'
              '    // sleep: the negative window, nothing may arrive in 200 ms\n    try await Task.sleep(for: .milliseconds(200))\n'
              '    try await Task.sleep(for: .seconds(1)) // sleep: lets the clock pass a second\n}\n', 1),
    'wait-helper': ('private func waitUntil(_ c: () -> Bool) async {}\nfunc until(_ c: () -> Bool) {}\nfunc waiting() {}\n'
                    'func waitForReader() {}\n', 3),
    'silent-wait': ('#expect(await waitUntil { x })\n#expect(await waitUntil { x }, "saw \\(x)")\n'
                    '#expect(await eventually { a == nil }, "the drag ends")\n'
                    '#expect(await model.count == 1)\nlet ok = try #require(await until(timeout: 1) { y })\n', 2),
    'key-window': ('window.makeKeyAndOrderFront(nil)\nwindow.orderFrontRegardless()\n'
                   'let (w, _) = host(view, size: s, key: true)\nlet (v, _) = host(view, size: s)\n', 3),
    'global-state': ('ChatPresentation.verifiesRows = true\nif ChatPresentation.verifiesRows == true {}\n'
                     'SidebarRenderProbe.watch([])\n', 2),
    'real-input': ('let down = NSEvent.pressedMouseButtons != 0\nlet a = DragActivity.shared\n'
                   'let b = DragActivity(buttonsDown: mouse.buttonsDown)\nlet f = event.modifierFlags\n', 2),
    'superseded': ('// D-28: Codex frozen\n// D-28, now D-94\n// D-94\n', 1),
    'disabled': ('@Test(.disabled("later")) func f() {}\n', 1),
    'serialized': ('@Suite(.serialized) struct A {}\n// serialized: one shared port\n@MainActor\n@Suite(.serialized) struct B {}\n'
                   '@Suite struct C {}\n', 1),
}


def self_test():
    failures = []

    def expect(cond, what):
        if not cond:
            failures.append(what)

    superseded = {'D-28', 'D-08'}
    for rule, (text, n) in PLANTED.items():
        got = len(scan('Tests/LoomCoreTests/PlantedTests.swift', text, superseded).get(rule, []))
        expect(got == n, f'{rule}: {n} expected, {got} found')
    expect(not scan('Tests/LoomTestSupport/Waits.swift', PLANTED['wait-helper'][0], set()).get('wait-helper'),
           'wait-helper: the support target may define waits')
    expect(not scan('Tests/LoomWindowTests/W.swift', PLANTED['key-window'][0], set()).get('key-window'),
           'key-window: the window tests may make windows key')
    expect(scan('Tests/LoomCoreTests/W.swift', 'extension WindowEventTests {}\n' + PLANTED['key-window'][0], set())
           .get('key-window'), 'key-window: the namespace alone no longer exempts a file outside LoomWindowTests')
    expect(not scan('Tests/LoomCoreTests/P.swift', '@Suite(.renderProbe) struct S {}\nSidebarRenderProbe.watch([])\n', set())
           .get('global-state'), 'global-state: a file with .renderProbe may watch the probe')
    expect(scan('Tests/LoomCoreTests/B2FixRoundTests.swift', '', set()).get('milestone-name') == [1], 'milestone-name')
    expect(scan('Tests/LoomCoreTests/CTests.swift', '// usleep(1) in a comment\nlet s = "usleep(1)"\n', set()) == {},
           'comments and strings are not code')

    today = datetime.date(2026, 10, 29)
    q = quarantines('x', '// flake: F1 2026-10-20 a port race in the fixture\nwithKnownIssue(isIntermittent: true) {}\n'
                         'withKnownIssue(isIntermittent: true) {}\n'
                         '// flake: F2 2026-10-01 old\nwithKnownIssue("x", isIntermittent: true) {}\n', today)
    expect([p is None for _, _, _, p in q] == [True, False, False], f'quarantine: fresh passes, unmarked and old fail: {q}')

    tmp = tempfile.mkdtemp(prefix='check-tests-')
    try:
        clean = '''let package = Package(name: "P",
    products: [.library(name: "LoomCore", targets: ["LoomCore"])],
    targets: [
        .target(name: "LoomCore", dependencies: ["CLoomPOSIX", .product(name: "X", package: "x")]),
        .target(name: "LoomTestSupport", path: "Tests/LoomTestSupport"),
        .target(name: "LoomCoreTestRigs", dependencies: ["LoomCore", "LoomTestSupport"], path: "Tests/LoomCoreTestRigs"),
        .testTarget(name: "LoomCoreTests", dependencies: ["LoomCore", "LoomTestSupport", "LoomCoreTestRigs"]),
    ])'''
        for d in ('Tests/LoomTestSupport', 'Tests/LoomCoreTestRigs', 'Tests/LoomCoreTests', 'Tests/LoomWindowTests', 'Sources/LoomCore',
                  'scripts/release'):
            os.makedirs(os.path.join(tmp, d))
        open(os.path.join(tmp, 'Package.swift'), 'w').write(clean)
        open(os.path.join(tmp, 'scripts/release/Package.release.swift'), 'w').write('// no test libraries\n')
        open(os.path.join(tmp, 'Tests/LoomTestSupport/Waits.swift'), 'w').write('import Testing\npublic func waitFor() {}\n')
        open(os.path.join(tmp, 'Tests/LoomCoreTestRigs/Rig.swift'), 'w').write('@testable import LoomCore\nstruct Rig {}\n')
        open(os.path.join(tmp, 'Tests/LoomWindowTests/W.swift'), 'w').write('enum WindowEventTests {}\n')
        open(os.path.join(tmp, 'Tests/LoomCoreTests/Own.swift'), 'w').write('enum Own {}\nextension Own { @Suite struct S {} }\n')
        expect(target_problems(tmp) == [], f'targets: the clean layout passes: {target_problems(tmp)}')
        for what, path, text in [
                ('a product target on a rig', 'Package.swift', clean.replace('"CLoomPOSIX",', '"CLoomPOSIX", "LoomCoreTestRigs",')),
                ('a product listing the support', 'Package.swift', clean.replace('targets: ["LoomCore"]', 'targets: ["LoomCore", "LoomTestSupport"]')),
                ('a rig outside Tests/', 'Package.swift', clean.replace('path: "Tests/LoomCoreTestRigs"', 'path: "Sources/Rigs"')),
                ('the release manifest naming the support', 'scripts/release/Package.release.swift', '.target(name: "LoomTestSupport")\n'),
                ('a test in a rig', 'Tests/LoomCoreTestRigs/Rig.swift', '@Suite struct S { @Test func t() {} }\n'),
                ('the support importing a product', 'Tests/LoomTestSupport/Waits.swift', 'import LoomCore\n'),
                ('the support importing @testable', 'Tests/LoomTestSupport/Waits.swift', '@testable import Foundation\n'),
                ('@testable in a product', 'Sources/LoomCore/A.swift', '@testable import LoomChat\n'),
                ('the window namespace outside LoomWindowTests', 'Tests/LoomCoreTestRigs/Rig.swift', 'extension WindowEventTests {}\n'),
                ('a suite nested in a rig type', 'Tests/LoomCoreTests/Nested.swift',
                 'extension Rig { @Suite struct S { @Test func t() {} } }\n')]:
            full = os.path.join(tmp, path)
            before = open(full).read() if os.path.exists(full) else None
            open(full, 'w').write(text)
            expect(len(target_problems(tmp)) == 1, f'targets: {what} fails once: {target_problems(tmp)}')
            if before is None:
                os.remove(full)
            else:
                open(full, 'w').write(before)
        expect(target_problems(tmp) == [], 'targets: each plant is undone')
        shutil.rmtree(tmp)
        tmp = tempfile.mkdtemp(prefix='check-tests-')
        os.makedirs(os.path.join(tmp, 'Tests/LoomCoreTests'))
        os.makedirs(os.path.join(tmp, 'scripts'))
        plant = os.path.join(tmp, 'Tests/LoomCoreTests/ATests.swift')
        open(plant, 'w').write('func f() async { usleep(1) }\n')
        expect(update(tmp, None) == 0, 'ratchet: a first --update writes the file')
        expect(check(tmp, today) == 0, 'ratchet: the tree that wrote the file passes')
        open(plant, 'w').write('func f() async { usleep(1); usleep(2) }\n')
        expect(check(tmp, today) == 1, 'ratchet: a rising count fails')
        expect(update(tmp, None) == 1, 'ratchet: --update refuses a rising total')
        expect(update(tmp, 'measured') == 0, 'ratchet: --accept-rise records it')
        open(plant, 'w').write('func f() async { }\n')
        open(os.path.join(tmp, 'Tests/LoomCoreTests/BTests.swift'), 'w').write('func g() async { usleep(1) }\n')
        expect(check(tmp, today) == 1, 'ratchet: a new file with a finding fails though the total fell')
        os.remove(os.path.join(tmp, 'Tests/LoomCoreTests/BTests.swift'))
        expect(check(tmp, today) == 0, 'ratchet: a falling count passes')
        expect(update(tmp, None) == 0 and read_allow(tmp) == {}, 'ratchet: --update lowers to nothing')
        os.makedirs(os.path.join(tmp, 'Tests/LoomIntegrationTests'))
        open(plant, 'w').write('func f() async { usleep(1) }\n')
        update(tmp, 'seed')
        os.rename(plant, os.path.join(tmp, 'Tests/LoomIntegrationTests/ATests.swift'))
        expect(check(tmp, today) == 1, 'ratchet: a moved file fails until --update re-keys it')
        expect(update(tmp, None) == 0 and check(tmp, today) == 0, 'ratchet: --update re-keys a move with no rise')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print('test guard self-test FAILED:', file=sys.stderr)
        for f in failures:
            print(f'  {f}', file=sys.stderr)
        return 1
    print(f'test guard self-test: {len(PLANTED)} planted rules, the targets rule, quarantine dates and the ratchet behave')
    return 0


def main(argv):
    if '-h' in argv or '--help' in argv:
        print(__doc__)
        return 0
    if '--self-test' in argv:
        return self_test()
    root = argv[argv.index('--root') + 1] if '--root' in argv else DEFAULT_ROOT
    today = datetime.date.today()
    if '--summary' in argv:
        summary(root)
        return 0
    if '--list' in argv:
        list_rule(root, argv[argv.index('--list') + 1])
        return 0
    if '--quarantines' in argv:
        list_quarantines(root, today)
        return 0
    if '--decision' in argv:
        list_decision(root, argv[argv.index('--decision') + 1])
        return 0
    if '--update' in argv:
        reason = argv[argv.index('--accept-rise') + 1] if '--accept-rise' in argv else None
        return update(root, reason)
    return check(root, today)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
