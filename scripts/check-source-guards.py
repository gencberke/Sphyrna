#!/usr/bin/env python3
"""Source guards: rules about what the Swift sources may contain, checked before the build (DEVELOPMENT §2).

Each rule was a Swift test that read `Sources/` at test time; as a script it fails before the build and spends no test-pool
time. The rules and where they came from:
  harness-asks     D-94: no file outside the descriptor and dispatch files compares a harness id (HarnessCapabilitiesTests)
  remora-reach     Remora's model calls are made from exactly the listed places, and nothing in Remora starts by itself
                   (1.6.0 acceptance item 5; RemoraReachTests)
  remora-home      Home's Remora code has no timer, sleep, observer or watcher; one reachability monitor; one automatic-brief
                   site (RemoraHomeGuardTests)
  loggers          loggers are made only through LoomLog, and no log message carries an error's description or a detail
                   (LoggingAndJournalTests)
  keys             no default, cancel, exit or submit key where a card, a banner, a sheet or the composer lives: Return never
                   approves and Esc never denies (EdgesPureTests, PinnedFixRoundTests, PinnedCardsModelTests, InkSettingsSheetTests)
  sheets           the main window's four questions are bodies of the sheet family, attached by its own layer (InkSettingsSheetTests)
  input-reads      the Mac's real input state (mouse buttons, pointer, modifier keys) is read only at the listed places,
                   each a default reader its owner can replace, so no test depends on a press anywhere on the Mac (0f48daf)
  banner-symbol    a banner's symbol takes the tone's text variant, not the hue (EdgesPureTests)
Usage: scripts/check-source-guards.py [--root <repo>] [--only <rule>…]   (exit 0 clean, 1 with violations listed)
       scripts/check-source-guards.py --self-test                       (planted violations must fail, clean text must pass)
"""
import os
import re
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swift_source as swift  # noqa: E402

DEFAULT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Sources:
    def __init__(self, root):
        self.root = root
        self._files = None
        self._texts, self._codes = {}, {}

    def text(self, path):
        if path not in self._texts:
            with open(os.path.join(self.root, path), encoding='utf-8') as f:
                self._texts[path] = f.read()
        return self._texts[path]

    def code(self, path):
        """The file with comments and strings blanked (swift_source.code), read once per run."""
        if path not in self._codes:
            self._codes[path] = swift.code(self.text(path))
        return self._codes[path]

    def exists(self, path):
        return os.path.isfile(os.path.join(self.root, path))

    def all(self):
        """Every `.swift` file under Sources/, by its path from the repository, sorted."""
        if self._files is None:
            found = []
            for base, _, names in os.walk(os.path.join(self.root, 'Sources')):
                for name in names:
                    if name.endswith('.swift'):
                        full = os.path.join(base, name)
                        found.append(os.path.relpath(full, self.root))
            self._files = sorted(found)
        return self._files

    def listdir(self, path):
        return sorted(os.listdir(os.path.join(self.root, path)))


def code_lines(text, skip_prefix='//'):
    """The lines that do not start (after indentation) with `skip_prefix`: the Swift tests' comment filter."""
    return [line for line in text.split('\n') if not line.strip().startswith(skip_prefix)]


# ---- harness-asks (D-94) ------------------------------------------------------------------------------------------------

HARNESS_DISPATCH = {
    # The explicit bridge from neutral choices to the frozen Claude launch profile.
    'Sources/LoomCore/HarnessLaunchChoices.swift',
    'Sources/LoomCore/ProviderResume.swift',
    # AGY's invocation builder validates its own neutral launch choices.
    'Sources/LoomCore/AgyLaunchProfile.swift',
    # The Claude pipe controller validates that its run belongs to its native adapter.
    'Sources/LoomChat/Driver/ManagedClaudeTaskController.swift',
    # Development-only fixture dispatches the provider-shaped fake by its command-line route.
    'Sources/loom-fake-provider/main.swift',
    'Sources/loom-app/Evidence/AppDelegate+Evidence.swift',
    'Sources/loom-app/Evidence/EvidenceCatalogCommands.swift',
}
HARNESS_DESCRIPTOR = {
    'Sources/LoomCore/HarnessID.swift',
    'Sources/LoomCore/HarnessDescriptor.swift',
    'Sources/LoomCore/HarnessCatalogue.swift',
}
_COMPARISON = re.compile(r'(==|!=)\s*\.(claude|codex|opencode|agy|pi)\b(?!\w)|\.(claude|codex|opencode|agy|pi)\s*(==|!=)')
_TERNARY = re.compile(r'\?\s*"(claude|codex|opencode|agy|pi)"\s*:\s*"')


def asks_which_harness(line):
    """A comparison with a harness id, or a `? "codex" : "claude"` name ternary; not a comment or a case label."""
    text = line.strip()
    if text.startswith('//') or ('=' not in text and '?' not in text):
        return False
    return bool(_COMPARISON.search(text) or _TERNARY.search(text))


def rule_harness_asks(src):
    problems, scanned = [], 0
    for path in src.all():
        scanned += 1
        if path in HARNESS_DISPATCH or path in HARNESS_DESCRIPTOR or path.startswith('Sources/loom-probe/'):
            continue
        for number, line in enumerate(src.text(path).split('\n'), 1):
            if asks_which_harness(line):
                problems.append(f'{path}:{number}: asks which harness it has; ask HarnessCatalogue or the descriptor (D-94)')
    if scanned <= 100:
        problems.append(f'harness-asks: the walk found only {scanned} files under Sources/')
    return problems


# ---- remora-reach ---------------------------------------------------------------------------------------------------------

REMORA_HOST = 'Sources/LoomRemora/RemoraHost.swift'
REMORA_MODEL = 'Sources/LoomCatalogUI/CatalogModel+Remora.swift'
REMORA_HOME_CALLS = 'Sources/LoomCatalogUI/HomeRemoraCalls.swift'
REMORA_EVIDENCE_CALLS = 'Sources/loom-app/Evidence/EvidenceRemoraCommands.swift'
REMORA_PALETTE_CALLS = 'Sources/LoomCatalogUI/PaletteRemora.swift'
REMORA_DRAFT_ROW = 'Sources/LoomCatalogUI/DraftRemoraViews.swift'
# The allow-lists: a new path to a model call is a reviewed change to these lists, made in the commit that adds it.
# `RemoraHost(` constructions: the app makes the one host, in `installRemora`.
REMORA_HOST_CONSTRUCTIONS = {REMORA_MODEL: 1}
# `RemoraCall(` constructions: the host's `makeCall` is the one place a call process is made.
REMORA_CALL_CONSTRUCTIONS = {REMORA_HOST: 1}
# Files that name the type `RemoraHost` as a whole word: the host and the model API that forwards to it.
REMORA_HOST_NAMERS = {REMORA_HOST, REMORA_MODEL}
# Calls of the unasked entry `briefIfDue(`: the model's `briefRemoraIfDue`.
REMORA_UNASKED_CALLS = {REMORA_MODEL: 1}
# Calls of the model API's entries (`askRemora(`, `briefRemora(`, `briefRemoraIfDue(`, summed per file). Home's calls are all
# in one file (L3b): the automatic brief when Home shows, Catch Me Up / Catch Me Up Anyway / Try Again of a brief, and the
# field's question. The evidence commands `remora-brief` and `remora-ask`; ⌘K's Ask Remora (L3c) is one call.
REMORA_MODEL_API_CALLS = {REMORA_HOME_CALLS: 3, REMORA_EVIDENCE_CALLS: 2, REMORA_PALETTE_CALLS: 1}
# Calls of Draft Brief's entry `draftRemoraBrief(` (L3c, D-80): the new-session page's row and the evidence command.
REMORA_DRAFT_API_CALLS = {REMORA_DRAFT_ROW: 1, REMORA_EVIDENCE_CALLS: 1}
# Names that would make something run by itself, in Remora's files.
REMORA_SELF_STARTING = ['Timer', 'DispatchSource', 'NWPathMonitor', 'FSEventStream', 'NotificationCenter', 'asyncAfter',
                        'Task.sleep']


def count_map(files, name, calls=True):
    result = {}
    for path, blanked in files:
        n = swift.calls(name, blanked) if calls else swift.words(name, blanked)
        if n:
            result[path] = n
    return result


def differences(rule, found, allowed):
    out = []
    for path in sorted(set(found) | set(allowed)):
        if found.get(path, 0) != allowed.get(path, 0):
            out.append(f'remora-reach {rule}: {path} has {found.get(path, 0)}, the list allows {allowed.get(path, 0)}. '
                       'A new path to a model call is a reviewed change to the allow-list in scripts/check-source-guards.py; '
                       'a removed one must leave it too.')
    return out


def remora_reach(files):
    """`files`: [(path, blanked code)]. The reach rules over them; separate from the walk so the self-test can plant files."""
    problems = []
    problems += differences('RemoraHost(', count_map(files, 'RemoraHost'), REMORA_HOST_CONSTRUCTIONS)
    problems += differences('RemoraCall(', count_map(files, 'RemoraCall'), REMORA_CALL_CONSTRUCTIONS)
    namers = set(count_map(files, 'RemoraHost', calls=False))
    if namers != REMORA_HOST_NAMERS:
        problems.append(f'remora-reach: files naming RemoraHost: {sorted(namers)}; the list allows {sorted(REMORA_HOST_NAMERS)}')
    problems += differences('briefIfDue(', count_map(files, 'briefIfDue'), REMORA_UNASKED_CALLS)
    api = {}
    for name in ('askRemora', 'briefRemora', 'briefRemoraIfDue'):
        for path, n in count_map(files, name).items():
            api[path] = api.get(path, 0) + n
    problems += differences('askRemora( / briefRemora( / briefRemoraIfDue(', api, REMORA_MODEL_API_CALLS)
    problems += differences('draftRemoraBrief(', count_map(files, 'draftRemoraBrief'), REMORA_DRAFT_API_CALLS)
    own = [(p, c) for p, c in files if p.startswith('Sources/LoomRemora/') or p == REMORA_MODEL]
    starting = {}
    for name in REMORA_SELF_STARTING:
        for path, n in count_map(own, name, calls=False).items():
            starting[f'{path} ({name})'] = n
    for key in sorted(starting):
        problems.append(f'remora-reach: {key} x{starting[key]}: Remora runs only when the app calls it, '
                        'no timer, watcher or delayed hop')
    return problems


def rule_remora_reach(src):
    files = [(p, src.code(p)) for p in src.all()]
    problems = []
    paths = {p for p, _ in files}
    if len(files) < 300:
        problems.append(f'remora-reach: the scan saw only {len(files)} files under Sources/')
    for must in (REMORA_HOST, REMORA_MODEL, 'Sources/LoomRemora/RemoraCall.swift', 'Sources/LoomRemora/RemoraMemory.swift'):
        if must not in paths:
            problems.append(f'remora-reach: the scan missed {must}')
    host = dict(files).get(REMORA_HOST, '')
    if swift.words('RemoraHost', host) == 0 or swift.calls('RemoraCall', host) != 1:
        problems.append('remora-reach: the host file does not carry what the lists say (a scan that blanked everything?)')
    return problems + remora_reach(files)


# ---- remora-home ----------------------------------------------------------------------------------------------------------

HOME_DIR = 'Sources/LoomCatalogUI'
HOME_NAMES = {'NetworkReach.swift', 'CatalogModel+RemoraDraft.swift', 'HomeView.swift', 'HomeBand.swift'}
HOME_BANNED = ['Timer', 'Task.sleep', 'NotificationCenter', 'DispatchSource', 'asyncAfter', 'FSEventStream',
               'SCNetworkReachabilitySetCallback', 'SCNetworkReachabilityScheduleWithRunLoop', 'addObserver', 'onReceive']
HOME_TASK = '.task(id: HomeRemoraShowKey(windowAttached: windowAttached, hasHost: model.hasRemora))'


def home_sources(src):
    """Home's Remora code, the reachability read, Put in Draft and the Home views, each line cut at its `//`."""
    names = [n for n in src.listdir(HOME_DIR) if n.startswith('HomeRemora') or n in HOME_NAMES]
    out = []
    for name in names:
        lines = [line.split('//', 1)[0] for line in src.text(f'{HOME_DIR}/{name}').split('\n')]
        out.append((name, '\n'.join(lines)))
    return out


def rule_remora_home(src):
    sources = home_sources(src)
    problems = []
    if len(sources) < 8:
        problems.append(f'remora-home: the scan saw only {[n for n, _ in sources]}')
    for name, text in sources:
        for banned in HOME_BANNED:
            if banned in text:
                problems.append(f'remora-home: {HOME_DIR}/{name} uses {banned}: Remora\'s Home starts nothing by itself')
    reach = dict(sources).get('NetworkReach.swift')
    if reach is None:
        problems.append('remora-home: NetworkReach.swift is missing')
    else:
        if reach.count('NWPathMonitor') != 1:
            problems.append('remora-home: NetworkReach.swift must make one NWPathMonitor, inside the read')
        if 'monitor.cancel()' not in reach:
            problems.append('remora-home: NetworkReach.swift must cancel its monitor when the read is over')
        if 'static var monitor' in reach or 'static let monitor' in reach:
            problems.append('remora-home: NetworkReach.swift keeps a monitor')
        if 'SCNetworkReachability' in reach:
            problems.append('remora-home: NetworkReach.swift uses the deprecated reachability read')
    sites = [n for n, t in sources if 'briefRemoraIfDue(' in t]
    if sites != ['HomeRemoraCalls.swift']:
        problems.append(f'remora-home: the automatic brief is called from {sites}, not only HomeRemoraCalls.swift')
    view = dict(sources).get('HomeView.swift', '')
    if HOME_TASK not in view or 'HomeRemoraCalls.homeShown(' not in view:
        problems.append("remora-home: HomeView.swift's .task no longer asks HomeRemoraCalls.homeShown for the automatic brief")
    return problems


# ---- loggers --------------------------------------------------------------------------------------------------------------

LOGGER_FILES = {'Sources/LoomCore/LoomLog.swift', 'Sources/LoomCore/LoomSignposts.swift'}
LOG_CALL = re.compile(r'(LoomLog\.(notice|error|debug)|(?<![A-Za-z])(log|hookLog|logger)\.(info|notice|error|debug|fault|warning|trace|critical))\(')
LOG_FORBIDDEN = [re.compile(p) for p in (r'String\(describing:', r'\\\((error|failure|refusal)\s*[\),]', r'\.detail\b',
                                         r'localizedDescription')]


def log_calls(text):
    """Each LoomLog or logger call, from its name to its closing parenthesis, following strings and interpolations."""
    calls = []
    for m in LOG_CALL.finditer(text):
        i = start = m.end()
        stack = [[False, 1]]
        while i < len(text) and stack:
            c = text[i]
            if stack[-1][0]:
                if c == '\\' and i + 1 < len(text):
                    if text[i + 1] == '(':
                        stack.append([False, 1])
                        i += 2
                        continue
                    i += 2
                    continue
                if c == '"':
                    stack.pop()
            else:
                if c == '"':
                    stack.append([True, 0])
                elif c == '(':
                    stack[-1][1] += 1
                elif c == ')':
                    stack[-1][1] -= 1
                    if stack[-1][1] == 0:
                        stack.pop()
            i += 1
        calls.append(text[start:min(i, len(text))])
    return calls


def rule_loggers(src):
    problems = []
    for path in src.all():
        text = src.text(path)
        if path not in LOGGER_FILES and 'Logger(subsystem:' in text:
            problems.append(f'loggers: {path} makes a Logger; make loggers through LoomLog')
        for call in log_calls(text):
            if any(p.search(call) for p in LOG_FORBIDDEN):
                problems.append(f'loggers: {path}: a log message names an error only by LoomLog.category(of:): {call[:160]}')
    return problems


# ---- keys and sheets ------------------------------------------------------------------------------------------------------

UI = 'Sources/LoomCatalogUI'
KEYS_BANNED = ['.defaultAction', 'defaultAction', 'cancelAction', 'onExitCommand', 'onSubmit', '.keyboardShortcut(.return',
               '.keyboardShortcut(.defaultAction', '.keyboardShortcut(.cancelAction', '.keyboardShortcut(.escape']
SHEET_FAMILY = ['SheetFamily.swift', 'SettingsSheets.swift', 'LoomTheme+Sheets.swift', 'MainSheets.swift']
EDGE_FILES = ['BannerStack.swift', 'BannerBox.swift', 'EndedLine.swift', 'ConversationRecord.swift', 'LoomTheme+Edges.swift',
              'CatalogModel+EvidenceBanners.swift', 'SessionIssueNotice.swift', 'Chat/ChatBanner.swift']
# The popover and menu host (I4) takes Esc in its own key handling while one of its popovers is open.
INK_HOST_FILES = ['InkHost.swift', 'InkHostPlacement.swift', 'InkOpenState.swift', 'ProjectMenuView.swift', 'LoomTheme+Hosts.swift']
QUESTION_FILES = ['DetailView.swift', 'DeletionViews.swift', 'Chat/RewindSheetView.swift', 'SideTab.swift']
QUESTION_BANNED = ['.defaultAction', '.cancelAction', 'onExitCommand', 'onSubmit', '.keyboardShortcut(']
CARD_BANNED = ['.keyboardShortcut', 'defaultAction', 'cancelAction', 'onExitCommand', 'onSubmit']


def banned_in(src, path, banned, why):
    if not src.exists(path):
        return [f'keys: {path} is scanned and must exist']
    lines = code_lines(src.text(path))
    return [f'keys: {path} uses {b}: {why}' for b in banned if any(b in line for line in lines)]


def chat_key_files(src):
    names = [n for n in src.listdir(f'{UI}/Chat') if n.endswith('.swift') and (
        n.startswith('Pinned') or n.startswith('Composer') or n.startswith('ChatComposer') or n == 'LiveChatView.swift')]
    return [f'{UI}/Chat/{n}' for n in names] + [f'{UI}/SessionChatView.swift'] + [f'{UI}/{n}' for n in INK_HOST_FILES]


def rule_keys(src):
    problems = []
    for name in SHEET_FAMILY:
        problems += banned_in(src, f'{UI}/{name}', KEYS_BANNED, 'the sheet family takes its keys through its own key handling')
    if src.exists(f'{UI}/SheetFamily.swift') and not any('onKeyPress' in l for l in code_lines(src.text(f'{UI}/SheetFamily.swift'))):
        problems.append('keys: SheetFamily.swift no longer reads its keys itself (onKeyPress)')
    for name in EDGE_FILES:
        problems += banned_in(src, f'{UI}/{name}', KEYS_BANNED, 'Return belongs to the screen below the banners')
    files = chat_key_files(src)
    if len(files) < 12 + len(INK_HOST_FILES):
        problems.append(f'keys: the chat scan saw only {[os.path.basename(f) for f in files]}')
    for path in files:
        problems += banned_in(src, path, KEYS_BANNED, 'no default or cancel key may answer a card')
    cards = [f'{UI}/Chat/{n}' for n in src.listdir(f'{UI}/Chat') if n.startswith('Pinned') and n.endswith('.swift')]
    if len(cards) < 5:
        problems.append(f'keys: the card scan saw only {cards}')
    for path in cards:
        problems += banned_in(src, path, CARD_BANNED, 'Return never approves and Esc never denies')
    for name in ['MainSheets.swift', 'DeletionViews.swift', 'Chat/RewindSheetView.swift', 'SideTab.swift']:
        problems += banned_in(src, f'{UI}/{name}', QUESTION_BANNED, "a question's body takes its keys through the family")
    return problems


def rule_sheets(src):
    problems = []
    for name in QUESTION_FILES:
        path = f'{UI}/{name}'
        if not src.exists(path):
            problems.append(f'sheets: {path} is scanned and must exist')
            continue
        if src.text(path).count('InkSheet(') != 1:
            problems.append(f'sheets: {path} must draw its question as one sheet of the family (InkSheet)')
    for name in ('DetailView.swift', 'SideTab.swift'):
        if src.exists(f'{UI}/{name}') and '.sheet(' in src.text(f'{UI}/{name}'):
            problems.append(f'sheets: {UI}/{name} attaches a sheet; the window\'s own layer does (MainSheets.swift)')
    sheets = src.text(f'{UI}/MainSheets.swift') if src.exists(f'{UI}/MainSheets.swift') else ''
    if 'sheetLayer(' not in sheets or 'makeMainSheetOverlayView' not in sheets:
        problems.append('sheets: MainSheets.swift no longer holds the window\'s sheet layer')
    return problems


# ---- input-reads ----------------------------------------------------------------------------------------------------------

INPUT_READS = ['NSEvent.pressedMouseButtons', 'NSEvent.mouseLocation', 'NSEvent.modifierFlags', 'CGEventSource.buttonState',
               'CGEventSource.flagsState', 'CGEventSource.keyState']
# The reads allowed, per file: a new read is a reviewed change to this list, made with the reader it is injected through.
INPUT_READ_SITES = {
    # DragActivity's default button reader; its tests inject their own (0f48daf).
    'Sources/LoomCatalogUI/DragActivity.swift': 1,
    # Command-click on the composer's send control, in the Chat face frozen by D-100; its tests are TF's.
    'Sources/LoomCatalogUI/Chat/ComposerBar.swift': 1,
}


def input_reads(files):
    found = {}
    for path, blanked in files:
        n = sum(swift.words(name, blanked) for name in INPUT_READS)
        if n:
            found[path] = n
    out = []
    for path in sorted(set(found) | set(INPUT_READ_SITES)):
        if found.get(path, 0) != INPUT_READ_SITES.get(path, 0):
            out.append(f'input-reads: {path} reads real input {found.get(path, 0)} times, the list allows '
                       f'{INPUT_READ_SITES.get(path, 0)}: read it through a reader the owner injects, and list the default')
    return out


def rule_input_reads(src):
    return input_reads([(p, src.code(p)) for p in src.all()])


# ---- banner-symbol --------------------------------------------------------------------------------------------------------

def rule_banner_symbol(src):
    path = f'{UI}/Chat/ChatBanner.swift'
    if not src.exists(path):
        return [f'banner-symbol: {path} is missing']
    text = src.text(path)
    start = text.find('var symbolStyle: AnyShapeStyle {')
    if start < 0:
        return [f'banner-symbol: {path} has no symbolStyle']
    block = text[start:start + 400]
    problems = []
    for need in ('case .failure: AnyShapeStyle(LoomTheme.Status.failureLight)',
                 'case .attention: AnyShapeStyle(LoomTheme.Status.attentionLight)'):
        if need not in block:
            problems.append(f'banner-symbol: {path}: the symbol must take the text variant: {need}')
    if 'Status.failure)' in block or 'Status.attention)' in block:
        problems.append(f'banner-symbol: {path}: the symbol takes the hue, not the text variant')
    return problems


RULES = {
    'harness-asks': rule_harness_asks,
    'remora-reach': rule_remora_reach,
    'remora-home': rule_remora_home,
    'loggers': rule_loggers,
    'keys': rule_keys,
    'sheets': rule_sheets,
    'banner-symbol': rule_banner_symbol,
    'input-reads': rule_input_reads,
}


def run(root, only=None):
    src = Sources(root)
    problems = []
    for name, rule in RULES.items():
        if only and name not in only:
            continue
        problems += rule(src)
    return problems


# ---- self-test ------------------------------------------------------------------------------------------------------------

def self_test():
    failures = []

    def check(cond, what):
        if not cond:
            failures.append(what)

    # The harness matcher (the Swift test's cases).
    for line in ('guard record.session.provider == .claude else { return }', 'if summary.harness != .opencode {',
                 'filter { $0.harness == .agy }', 'let isPi = harnessID == .pi',
                 'let name = provider == .codex ? "codex" : "claude"', 'let command = isAgy ? "agy" : "pi"'):
        check(asks_which_harness(line), f'harness matcher misses: {line}')
    for line in ('/// The UI asks these, never `provider == .claude`', 'case .claude: self = .claude',
                 'var pick = modePick == .claudeDefault ? .inherit : modePick', 'let mark = "harness-codex"',
                 'canStart(.newSessionDefault, projectID: nil)'):
        check(not asks_which_harness(line), f'harness matcher flags: {line}')

    # The Swift blanker and counters (the Remora reach tests' cases).
    planted = '\n'.join([
        '// briefIfDue( in a line comment',
        '/// RemoraHost( in a doc comment',
        '/* RemoraCall( in a block comment /* and a nested one */ still a comment briefIfDue( */',
        'let plain = "briefIfDue( in a string"',
        'let escaped = "a \\" quote, then briefIfDue("',
        'let raw = #"RemoraHost( "quoted" in a raw string"#',
        'let many = """',
        '    briefIfDue(',
        '    RemoraCall(',
        '    """',
        'func briefIfDue(homeShown: Bool) {}',
        'func   briefIfDue(again: Bool) {}',
        'let ok = host.briefIfDue(homeShown: true)',
        'let other = host.briefIfDueLater(1) + XbriefIfDue(2)',
        'let inside = "\\(host.briefIfDue(inInterpolation: true))"',
        'let created = RemoraHost(dataRoot: root)',
        'let mentioned = RemoraHostAnswer(x: 1) as RemoraHost',
        'let delay = Task.sleep(for: .seconds(1)) // and Timer in a comment',
    ])
    blanked = swift.code(planted)
    check(swift.calls('briefIfDue', blanked) == 2, 'blanker: the call in code and the one in an interpolation, nothing else')
    check(swift.calls('RemoraHost', blanked) == 1, 'blanker: one RemoraHost( call')
    check(swift.calls('RemoraCall', blanked) == 0, 'blanker: RemoraCall( only in comments and strings')
    check(swift.words('RemoraHost', blanked) == 2, 'blanker: RemoraHostAnswer is another name')
    check(swift.words('Task.sleep', blanked) == 1 and swift.words('Timer', blanked) == 0, 'blanker: Task.sleep in code, Timer in a comment')
    check(swift.calls('briefIfDue', planted) > 2, 'blanker: a naive scan counts more')
    check(blanked.count('\n') == planted.count('\n'), 'blanker: line numbers survive')

    # The log call scanner.
    calls = log_calls('LoomLog.error(.chat, "A (b) failed (\\(LoomLog.category(of: error))) (\\(x))") ; other(error)\n'
                      'LoomLog.notice(.session, "Start (no card") ; String(describing: error)')
    check(len(calls) == 2, f'log scanner: two calls, got {len(calls)}')
    check(calls and calls[0].endswith('(\\(x))")'), 'log scanner: follows parentheses inside the message')
    check(calls and 'describing' not in calls[-1], 'log scanner: stops at the call\'s own parenthesis')
    check(len(log_calls('Self.hookLog.error("x \\(String(describing: error))"); catalog.error("y")')) == 1,
          'log scanner: catalog.error is not a log call')

    # The reach rules over planted files: a second unasked call fails, the listed ones pass.
    base = [(REMORA_HOST, swift.code('final class RemoraHost { func makeCall() { _ = RemoraCall(x) } }')),
            (REMORA_MODEL, swift.code('func install() { host = RemoraHost(root) }\nfunc briefRemoraIfDue() { host.briefIfDue(a) }')),
            (REMORA_HOME_CALLS, swift.code('m.briefRemoraIfDue()\nm.briefRemora()\nm.askRemora(q)')),
            (REMORA_EVIDENCE_CALLS, swift.code('m.briefRemora()\nm.askRemora(q)\nm.draftRemoraBrief(p)')),
            (REMORA_PALETTE_CALLS, swift.code('m.askRemora(q)')),
            (REMORA_DRAFT_ROW, swift.code('m.draftRemoraBrief(p)'))]
    check(remora_reach(base) == [], f'reach: the listed calls pass: {remora_reach(base)}')
    second = [(p, c + ('\nfunc extra() async { _ = await briefIfDue(homeShown: true) }' if p == REMORA_HOST else ''))
              for p, c in base]
    found = remora_reach([(p, swift.code(c)) for p, c in second])
    check(len(found) == 1 and REMORA_HOST in found[0] and 'has 1, the list allows 0' in found[0], f'reach: a second call fails: {found}')
    extra = base + [('Sources/LoomCatalogUI/DraftPresets.swift', swift.code('func e() { _ = model.draftRemoraBrief(project: p) }'))]
    found = remora_reach(extra)
    check(len(found) == 1 and 'DraftPresets.swift' in found[0], f'reach: an extra draft caller fails: {found}')
    timer = base + [('Sources/LoomRemora/RemoraClock.swift', swift.code('let t = Timer.scheduledTimer(withTimeInterval: 1)'))]
    check(any('Timer' in p for p in remora_reach(timer)), 'reach: a Timer in Remora\'s files fails')

    # Whole rules on a planted tree: a copy of the real tree must pass, then each planted violation must fail its rule.
    root = DEFAULT_ROOT
    tmp = tempfile.mkdtemp(prefix='source-guards-')
    try:
        shutil.copytree(os.path.join(root, 'Sources'), os.path.join(tmp, 'Sources'))
        clean = run(tmp)
        check(clean == [], f'the copied tree is clean: {clean[:5]}')

        def plant(path, append='', replace=None):
            full = os.path.join(tmp, path)
            original = open(full, encoding='utf-8').read() if os.path.exists(full) else ''
            text = original
            if replace:
                assert replace[0] in text, f'self-test: {replace[0]!r} not in {path}'
                text = text.replace(replace[0], replace[1], 1)
            with open(full, 'w', encoding='utf-8') as f:
                f.write(text + append)
            return original

        plants = [
            ('harness-asks', 'Sources/LoomCatalogUI/HomeView.swift', '\nlet planted = session.provider == .codex\n', None),
            ('remora-reach', 'Sources/LoomCatalogUI/DraftPresets.swift', '\nfunc planted(_ m: CatalogModel) { m.askRemora("q") }\n', None),
            ('remora-home', 'Sources/LoomCatalogUI/HomeBand.swift', '\nlet planted = Timer.publish(every: 1, on: .main, in: .common)\n', None),
            ('loggers', 'Sources/LoomCore/SessionCatalog.swift', '\nfunc planted() { LoomLog.error(.chat, "failed \\(error)") }\n', None),
            ('loggers', 'Sources/LoomChat/Planted.swift', 'let planted = Logger(subsystem: "x", category: "y")\n', None),
            ('keys', 'Sources/LoomCatalogUI/BannerBox.swift', '\nlet planted = Button("x") {}.keyboardShortcut(.defaultAction)\n', None),
            ('keys', 'Sources/LoomCatalogUI/Chat/PinnedPlanted.swift', 'let planted = Button("x") {}.keyboardShortcut("a")\n', None),
            ('sheets', 'Sources/LoomCatalogUI/SideTab.swift', '\nlet planted = EmptyView().sheet(isPresented: .constant(false)) {}\n', None),
            ('input-reads', 'Sources/LoomCatalogUI/SidebarDrag.swift', 'let planted = NSEvent.mouseLocation\n', None),
            ('banner-symbol', 'Sources/LoomCatalogUI/Chat/ChatBanner.swift', '',
             ('AnyShapeStyle(LoomTheme.Status.failureLight)', 'AnyShapeStyle(LoomTheme.Status.failure)')),
        ]
        for rule, path, append, replace in plants:
            before = plant(path, append, replace)
            found = run(tmp, only=[rule])
            check(found != [], f'{rule}: the planted violation in {path} passes')
            others = run(tmp, only=[r for r in RULES if r != rule])
            check(others == [], f'{rule}: the plant trips other rules: {others[:3]}')
            if before:
                with open(os.path.join(tmp, path), 'w', encoding='utf-8') as f:
                    f.write(before)
            else:
                os.remove(os.path.join(tmp, path))
            check(run(tmp, only=[rule]) == [], f'{rule}: the tree is clean again after removing the plant')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print('source guards self-test FAILED:', file=sys.stderr)
        for f in failures:
            print(f'  {f}', file=sys.stderr)
        return 1
    print(f'source guards self-test: matchers and {len(RULES)} rules pass on a clean copy and fail on planted violations')
    return 0


def main(argv):
    if '--self-test' in argv:
        return self_test()
    if '-h' in argv or '--help' in argv:
        print(__doc__)
        return 0
    root = argv[argv.index('--root') + 1] if '--root' in argv else DEFAULT_ROOT
    only = None
    if '--only' in argv:
        only = [a for a in argv[argv.index('--only') + 1:] if not a.startswith('--')]
        unknown = [o for o in only if o not in RULES]
        if unknown:
            print(f'check-source-guards: unknown rule {unknown}; rules: {", ".join(RULES)}', file=sys.stderr)
            return 2
    problems = run(root, only)
    if problems:
        print('Source guards (scripts/check-source-guards.py):', file=sys.stderr)
        for p in problems:
            print(f'  {p}', file=sys.stderr)
        return 1
    print(f'source guards: {len(only or RULES)} rules hold ({", ".join(only or RULES)})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
