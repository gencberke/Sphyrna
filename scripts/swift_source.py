"""Swift source scanning shared by scripts/check-tests.py and scripts/check-source-guards.py (imported, not run).

`code(text)` blanks comments and string literals to spaces and keeps newlines, so line numbers survive; interpolations inside
a string stay code, because they run. It is the port of the matcher the Remora reach tests used (RemoraReachTests.swift until
the source guards became scripts), and `check-source-guards.py --self-test` keeps its cases.
"""
import re

IDENT = 'A-Za-z0-9_'


def code(text):
    out = []
    i = _scan(text, 0, out, closing=False)
    assert i <= len(text)
    return ''.join(out)


def _blank(c):
    return '\n' if c == '\n' else ' '


def _scan(b, i, out, closing):
    depth = 0
    n = len(b)
    while i < n:
        c = b[i]
        nxt = b[i + 1] if i + 1 < n else None
        if c == '/' and nxt == '/':
            while i < n and b[i] != '\n':
                out.append(' ')
                i += 1
        elif c == '/' and nxt == '*':
            nesting = 0
            while True:
                if i + 1 < n and b[i] == '/' and b[i + 1] == '*':
                    nesting += 1
                    out.append('  ')
                    i += 2
                elif i + 1 < n and b[i] == '*' and b[i + 1] == '/':
                    nesting -= 1
                    out.append('  ')
                    i += 2
                else:
                    out.append(_blank(b[i]))
                    i += 1
                if not (nesting > 0 and i < n):
                    break
        elif c == '"' or (c == '#' and _raw_string_starts(b, i)):
            i = _string(b, i, out)
        elif closing and c == '(':
            depth += 1
            out.append(c)
            i += 1
        elif closing and c == ')':
            if depth == 0:
                return i
            depth -= 1
            out.append(c)
            i += 1
        else:
            out.append(c)
            i += 1
    return i


def _raw_string_starts(b, i):
    j = i
    while j < len(b) and b[j] == '#':
        j += 1
    return j < len(b) and b[j] == '"'


def _has_hashes(b, start, count):
    return start + count <= len(b) and all(b[start + k] == '#' for k in range(count))


def _closes(b, i, delimiter, hashes):
    return i + delimiter + hashes <= len(b) and all(b[i + k] == '"' for k in range(delimiter)) \
        and _has_hashes(b, i + delimiter, hashes)


def _string(b, i, out):
    n = len(b)
    hashes = 0
    while i < n and b[i] == '#':
        hashes += 1
        out.append(' ')
        i += 1
    multiline = i + 2 < n and b[i + 1] == '"' and b[i + 2] == '"'
    delimiter = 3 if multiline else 1
    out.append(' ' * delimiter)
    i += delimiter
    while i < n:
        c = b[i]
        if c == '\\' and _has_hashes(b, i + 1, hashes) and i + 1 + hashes < n:
            after = b[i + 1 + hashes]
            if after == '(':
                out.append(' ' * (1 + hashes))
                out.append('(')
                i += 2 + hashes
                i = _scan(b, i, out, closing=True)
                if i < n:
                    out.append(')')
                    i += 1
            else:
                out.append(' ' * (1 + hashes))
                out.append(_blank(after))
                i += 2 + hashes
        elif c == '"' and _closes(b, i, delimiter, hashes):
            out.append(' ' * (delimiter + hashes))
            return i + delimiter + hashes
        elif c == '\n' and not multiline:
            return i
        else:
            out.append(_blank(c))
            i += 1
    return i


def _is_declaration(code_text, start):
    before = code_text[:start].rstrip(' \t')
    if not before.endswith('func'):
        return False
    head = before[:-4]
    return not head or not (head[-1].isalnum() or head[-1] == '_')


def call_sites(name, code_text):
    """Offsets of call expressions of `name`: the whole identifier followed by `(`, not a `func` declaration."""
    pattern = re.compile(rf'(?<![{IDENT}]){re.escape(name)}\s*\(')
    return [m.start() for m in pattern.finditer(code_text) if not _is_declaration(code_text, m.start())]


def calls(name, code_text):
    return len(call_sites(name, code_text))


def words(name, code_text):
    """`name` as a whole word (not part of a longer identifier), calls or not."""
    return len(re.findall(rf'(?<![{IDENT}]){re.escape(name)}(?![{IDENT}])', code_text))


def line_of(text, offset):
    return text.count('\n', 0, offset) + 1


def closing_paren(code_text, open_index):
    """Index of the `)` matching the `(` at `open_index` in blanked code, or len when unbalanced."""
    depth = 0
    for i in range(open_index, len(code_text)):
        c = code_text[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i
    return len(code_text)


def closing_brace(code_text, open_index):
    depth = 0
    for i in range(open_index, len(code_text)):
        c = code_text[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
    return len(code_text)


def top_level_args(code_text, open_index):
    """The argument spans (start, end) of the call whose `(` is at `open_index`, split at depth-one commas."""
    end = closing_paren(code_text, open_index)
    spans, depth, start = [], 0, open_index + 1
    for i in range(open_index + 1, end):
        c = code_text[i]
        if c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ',' and depth == 0:
            spans.append((start, i))
            start = i + 1
    if code_text[start:end].strip():
        spans.append((start, end))
    return spans
