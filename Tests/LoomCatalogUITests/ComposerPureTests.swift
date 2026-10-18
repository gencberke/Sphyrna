import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// The Chat composer's pure parts (V17): the key rules, the history, the menu triggers and rankings, the bar's words, the
// file index, the paste and image rules. No window and no process.

// MARK: Keys

struct ComposerKeysTests {
    private func resolve(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                         _ adjust: (inout ComposerKeys.State) -> Void = { _ in }) -> ComposerKeys.Action {
        var state = ComposerKeys.State()
        adjust(&state)
        return ComposerKeys.resolve(keyCode: keyCode, modifiers: modifiers, state: state)
    }

    @Test func returnSendsAndCommandReturnSendsTheSecondWay() {
        #expect(resolve(ComposerKeys.returnKey) == .send)
        #expect(resolve(ComposerKeys.keypadEnter) == .send)
        #expect(resolve(ComposerKeys.returnKey, .command) == .sendSecondary)
        #expect(resolve(ComposerKeys.returnKey) { $0.working = true } == .send)
        #expect(resolve(ComposerKeys.returnKey, .command) { $0.working = true } == .sendSecondary)
        // The same keys in the draft are the draft's own: the state decides what they start.
        #expect(resolve(ComposerKeys.returnKey) { $0.mode = .draft } == .send)
    }

    @Test func shiftAndOptionReturnInsertANewLine() {
        #expect(resolve(ComposerKeys.returnKey, .shift) == .newline)
        #expect(resolve(ComposerKeys.returnKey, .option) == .newline)
        #expect(resolve(ComposerKeys.returnKey, [.shift, .command]) == .passThrough)
    }

    @Test func aHeldReturnSendsOnceAndAnInputMethodKeepsItsReturn() {
        #expect(resolve(ComposerKeys.returnKey) { $0.isRepeat = true } == .ignore)
        #expect(resolve(ComposerKeys.returnKey, .command) { $0.isRepeat = true } == .ignore)
        // Composing text (Japanese, Chinese, an accent held): Return commits the composition and sends nothing.
        #expect(resolve(ComposerKeys.returnKey) { $0.hasMarkedText = true } == .passThrough)
        #expect(resolve(ComposerKeys.returnKey, .command) { $0.hasMarkedText = true } == .passThrough)
        #expect(resolve(ComposerKeys.escape) { $0.hasMarkedText = true; $0.working = true } == .passThrough)
        #expect(resolve(ComposerKeys.upArrow) { $0.hasMarkedText = true } == .passThrough)
    }

    @Test func returnNeverApprovesAndEscapeNeverDenies() {
        // A request waiting is answered on its card only: neither key does more than the text field's own work.
        #expect(resolve(ComposerKeys.escape) { $0.working = true; $0.cardWaiting = true } == .ignore)
        #expect(resolve(ComposerKeys.escape) { $0.cardWaiting = true } == .ignore)
        // Nothing here names a card: the only actions Return can have are sending and inserting.
        let returnActions: Set<ComposerKeys.Action> = [.send, .sendSecondary, .newline, .menuInsert, .ignore, .passThrough]
        for state in [ComposerKeys.State(), { var s = ComposerKeys.State(); s.working = true; return s }(),
                      { var s = ComposerKeys.State(); s.cardWaiting = true; return s }()] {
            for modifiers: NSEvent.ModifierFlags in [[], .command, .shift, .option] {
                #expect(returnActions.contains(ComposerKeys.resolve(keyCode: ComposerKeys.returnKey, modifiers: modifiers, state: state)))
            }
        }
    }

    @Test func withACardShownReturnSendsNothingTabGoesToTheCardAndEscapeDoesNothing() {
        let shown: (inout ComposerKeys.State) -> Void = { $0.cardShown = true; $0.cardWaiting = true; $0.working = true }
        for modifiers: NSEvent.ModifierFlags in [[], .command] {
            #expect(resolve(ComposerKeys.returnKey, modifiers, shown) == .ignore)
            #expect(resolve(ComposerKeys.keypadEnter, modifiers, shown) == .ignore)
        }
        #expect(resolve(ComposerKeys.returnKey, .shift, shown) == .newline)
        #expect(resolve(ComposerKeys.tab, [], shown) == .focusCard)
        #expect(resolve(ComposerKeys.tab, .shift, shown) == .passThrough)
        #expect(resolve(ComposerKeys.escape, [], shown) == .ignore)
        // A menu still takes ↵, Tab and Esc first.
        #expect(resolve(ComposerKeys.returnKey) { shown(&$0); $0.menuOpen = true } == .menuInsert)
        #expect(resolve(ComposerKeys.tab) { shown(&$0); $0.menuOpen = true } == .menuInsert)
        #expect(resolve(ComposerKeys.escape) { shown(&$0); $0.menuOpen = true } == .closeMenu)
        // A card the typing guard holds is not shown: the composer sends and Tab is the field's own.
        let held: (inout ComposerKeys.State) -> Void = { $0.cardWaiting = true; $0.working = true }
        #expect(resolve(ComposerKeys.returnKey, [], held) == .send)
        #expect(resolve(ComposerKeys.tab, [], held) == .passThrough)
        #expect(resolve(ComposerKeys.escape, [], held) == .ignore)
        // The draft has no cards.
        #expect(resolve(ComposerKeys.tab) { $0.mode = .draft; $0.cardShown = true } == .passThrough)
    }

    @Test func escapeInterruptsOnlyAWorkingSession() {
        #expect(resolve(ComposerKeys.escape) == .ignore, "an idle composer does nothing on Esc, and opens no completion popup")
        #expect(resolve(ComposerKeys.escape) { $0.working = true } == .interrupt)
        #expect(resolve(ComposerKeys.escape, .command) { $0.working = true } == .passThrough)
        // The menu and a queue edit take Escape first.
        #expect(resolve(ComposerKeys.escape) { $0.working = true; $0.menuOpen = true } == .closeMenu)
        #expect(resolve(ComposerKeys.escape) { $0.working = true; $0.editingQueued = true } == .cancelEdit)
        // The draft has nothing to interrupt.
        #expect(resolve(ComposerKeys.escape) { $0.mode = .draft; $0.working = true } == .ignore)
    }

    @Test func menuKeysMoveInsertAndClose() {
        #expect(resolve(ComposerKeys.upArrow) { $0.menuOpen = true } == .menuMove(-1))
        #expect(resolve(ComposerKeys.downArrow) { $0.menuOpen = true } == .menuMove(1))
        #expect(resolve(ComposerKeys.returnKey) { $0.menuOpen = true } == .menuInsert)
        #expect(resolve(ComposerKeys.tab) { $0.menuOpen = true } == .menuInsert)
        #expect(resolve(ComposerKeys.tab) == .passThrough)
        #expect(resolve(ComposerKeys.tab, .shift) { $0.menuOpen = true } == .passThrough)
    }

    @Test func historyRecallStartsOnlyFromAnEmptyOrUneditedComposer() {
        #expect(resolve(ComposerKeys.upArrow) { $0.hasHistory = true } == .recallOlder)
        #expect(resolve(ComposerKeys.upArrow) == .passThrough)
        // Typed text is never replaced.
        #expect(resolve(ComposerKeys.upArrow) { $0.hasHistory = true; $0.isEmpty = false } == .passThrough)
        // An unedited recall keeps walking; the caret must sit on the first line, with no selection.
        #expect(resolve(ComposerKeys.upArrow) { $0.hasHistory = true; $0.isEmpty = false; $0.holdsUneditedRecall = true } == .recallOlder)
        #expect(resolve(ComposerKeys.upArrow) { $0.hasHistory = true; $0.caretOnFirstLine = false } == .passThrough)
        #expect(resolve(ComposerKeys.upArrow) { $0.hasHistory = true; $0.hasSelection = true } == .passThrough)
        #expect(resolve(ComposerKeys.downArrow) { $0.recalling = true; $0.holdsUneditedRecall = true; $0.isEmpty = false } == .recallNewer)
        #expect(resolve(ComposerKeys.downArrow) { $0.isEmpty = false } == .passThrough)
        #expect(resolve(ComposerKeys.downArrow) { $0.recalling = true; $0.holdsUneditedRecall = false; $0.isEmpty = false } == .passThrough)
    }

    @Test func theShortcutsAreMatchedByKeyCodeAndOnlyInTheLiveComposer() {
        let chord: NSEvent.ModifierFlags = [.command, .shift]
        #expect(resolve(ComposerKeys.letterV, chord) == .pastePlain)
        #expect(resolve(ComposerKeys.letterA, chord) == .openMenu(.attach))
        #expect(resolve(ComposerKeys.letterM, chord) == .openMenu(.mention))
        #expect(resolve(ComposerKeys.letterK, chord) == .openMenu(.commands))
        #expect(resolve(ComposerKeys.letterA, chord) { $0.mode = .draft } == .passThrough)
        // Without both modifiers they are ordinary letters.
        #expect(resolve(ComposerKeys.letterM, .command) == .passThrough)
        #expect(resolve(ComposerKeys.letterM, .shift) == .passThrough)
        #expect(resolve(ComposerKeys.letterM, [.command, .shift, .option]) == .passThrough)
        // Caps lock and the function flags do not count.
        #expect(resolve(ComposerKeys.letterM, [.command, .shift, .capsLock]) == .openMenu(.mention))
    }
}

// MARK: Turkish Q

/// Every key equivalent is reachable on a Turkish Q keyboard. The key codes name keys by place, so the rules hold on any
/// layout; this reads the system's own Turkish layouts through Text Input Sources and checks the facts that matter: the
/// characters the menus need (`/` and `@`) can be typed on each, the shortcuts sit on the letters they say on the three
/// Q layouts (on the F layout the same places print other letters, and the chords still work by place), and none of them
/// needs the layout's third level (⌥).
@MainActor
struct ComposerTurkishLayoutTests {
    nonisolated static let qLayouts = ["com.apple.keylayout.Turkish-QWERTY", "com.apple.keylayout.Turkish-QWERTY-PC"]
    nonisolated static let fLayouts = ["com.apple.keylayout.Turkish", "com.apple.keylayout.Turkish-Standard"]

    private static func layout(_ id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// The character a key makes with these Carbon modifiers (`shift` 2, `option` 8), dead keys off.
    private static func character(_ layout: Data, key: UInt16, modifiers: UInt32) -> String {
        layout.withUnsafeBytes { raw -> String in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var dead: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(base, key, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &characters)
            return status == noErr ? String(utf16CodeUnits: characters, count: length) : ""
        }
    }

    /// The chords that type `target` on a layout: (key code, Carbon modifiers).
    private static func chords(typing target: String, _ layout: Data) -> [(UInt16, UInt32)] {
        var found: [(UInt16, UInt32)] = []
        for key in UInt16(0)...UInt16(50) {
            for modifiers: UInt32 in [0, 2, 8, 10] where character(layout, key: key, modifiers: modifiers) == target {
                found.append((key, modifiers))
            }
        }
        return found
    }

    @Test(arguments: qLayouts)
    func onTurkishQTheShortcutKeysAreTheLettersTheyNameAndSlashAndAtCanBeTyped(_ id: String) throws {
        let layout = try #require(Self.layout(id), "\(id) is not available to Text Input Sources")
        // ⇧⌘A, ⇧⌘M, ⇧⌘K and ⇧⌘V are the keys that print a, m, k and v.
        for (key, letter) in [(ComposerKeys.letterA, "a"), (ComposerKeys.letterM, "m"), (ComposerKeys.letterK, "k"),
                              (ComposerKeys.letterV, "v")] {
            #expect(Self.character(layout, key: key, modifiers: 0) == letter)
        }
        let slash = Self.chords(typing: "/", layout)
        let at = Self.chords(typing: "@", layout)
        #expect(!slash.isEmpty)
        #expect(!at.isEmpty)
        // Which chord types them does not matter: the menus open from the inserted character.
        // None of the chords that type them is on a key the composer reads: Return, Tab, Escape and the arrows are
        // placed the same on every layout.
        let ours: Set<UInt16> = [ComposerKeys.returnKey, ComposerKeys.keypadEnter, ComposerKeys.tab, ComposerKeys.escape,
                                 ComposerKeys.upArrow, ComposerKeys.downArrow]
        #expect(ours.isDisjoint(with: Set((slash + at).map(\.0))))
    }

    @Test(arguments: fLayouts)
    func onTheTurkishFLayoutsTheSameChordsWorkByPlaceAndSlashAndAtCanBeTyped(_ id: String) throws {
        let layout = try #require(Self.layout(id), "\(id) is not available to Text Input Sources")
        // The letters differ (the A place prints u): the chords are by key code, so they stay on the same keys.
        #expect(Self.character(layout, key: ComposerKeys.letterA, modifiers: 0) != "a")
        #expect(!Self.chords(typing: "/", layout).isEmpty)
        #expect(!Self.chords(typing: "@", layout).isEmpty)
    }

    @Test func menusOpenFromTheCharactersAnyLayoutTypes() {
        #expect(ComposerTrigger.detect(before: "/", caret: 1) == .slash(query: "", range: NSRange(location: 0, length: 1)))
        #expect(ComposerTrigger.detect(before: "see @", caret: 5) == .mention(query: "", range: NSRange(location: 4, length: 1)))
    }
}

// MARK: History

struct ComposerHistoryTests {
    @Test func olderWalksBackAndNewerWalksForwardThenClears() {
        var history = ComposerHistory()
        history.load(["one", "two", "three"])
        #expect(history.older() == "three")
        #expect(history.older() == "two")
        #expect(history.older() == "one")
        #expect(history.older() == nil)
        #expect(history.newer() == .text("two"))
        #expect(history.newer() == .text("three"))
        #expect(history.newer() == .clear)
        #expect(!history.isRecalling)
        #expect(history.newer() == nil)
    }

    @Test func anEditEndsTheRecallAndASendBecomesTheNewest() {
        var history = ComposerHistory()
        history.load(["one", "two"])
        _ = history.older()
        #expect(history.isUneditedRecall("two"))
        history.noteEdit()
        #expect(!history.isRecalling)
        #expect(!history.isUneditedRecall("two"))
        history.append("three")
        #expect(history.older() == "three")
    }

    @Test func repeatsCountOnceBlanksNeverAndTheNewestTwoHundredStay() {
        var history = ComposerHistory()
        history.load(["a", "a", "  ", "b"])
        #expect(history.messages == ["a", "b"])
        history.load((0..<250).map { "m\($0)" })
        #expect(history.messages.count == ComposerHistory.capacity)
        #expect(history.messages.first == "m50")
        #expect(history.messages.last == "m249")
    }
}

// MARK: Menu triggers

struct ComposerTriggerTests {
    private func detect(_ text: String, caret: Int? = nil) -> ComposerTrigger? {
        let units = Array(text.utf16)
        let end = caret ?? units.count
        let from = max(0, end - ComposerTrigger.window - 1)
        return ComposerTrigger.detect(before: String(decoding: units[from..<end], as: UTF16.self), caret: end)
    }

    @Test func slashOpensCommandsOnlyAtTheStartOfTheMessage() {
        #expect(detect("/") == .slash(query: "", range: NSRange(location: 0, length: 1)))
        #expect(detect("/rev") == .slash(query: "rev", range: NSRange(location: 0, length: 4)))
        #expect(detect("hello /rev") == nil)
        #expect(detect("a/b") == nil)
        #expect(detect("/review the file") == nil)
        #expect(detect("line one\n/rev") == nil)
    }

    @Test func atOpensMentionsAtTheStartOfAWord() {
        #expect(detect("@") == .mention(query: "", range: NSRange(location: 0, length: 1)))
        #expect(detect("look at @Sou") == .mention(query: "Sou", range: NSRange(location: 8, length: 4)))
        #expect(detect("one\n@x") == .mention(query: "x", range: NSRange(location: 4, length: 2)))
        // An address is not a mention.
        #expect(detect("mail me@host") == nil)
        #expect(detect("look at @Sou rce") == nil)
    }

    @Test func aLongWordIsNotATriggerAndTheCaretMustBeInTheWord() {
        #expect(detect("@" + String(repeating: "a", count: 400)) == nil)
        #expect(detect("@abc def", caret: 4) == .mention(query: "abc", range: NSRange(location: 0, length: 4)))
        #expect(detect("@abc def", caret: 8) == nil)
    }

    @Test func menusOpenFromCharactersWhateverTheKeyboard() {
        // `/` typed with ⇧7 and `@` with ⌥Q arrive as the same characters as on any layout (see the Turkish layout test).
        #expect(detect("\u{002F}") != nil)
        #expect(detect("\u{0040}") != nil)
        // Full-width forms from an input method are not triggers.
        #expect(detect("\u{FF0F}") == nil)
    }
}

// MARK: Ranking and command items

struct ComposerRankingTests {
    private func item(_ title: String, kind: ComposerMenuItem.Kind = .command) -> ComposerMenuItem {
        ComposerMenuItem(id: title, kind: kind, title: title, detail: nil, trailing: nil, insertion: title)
    }

    @Test func exactBeatsPrefixBeatsContainsAndShortBeatsLong() {
        let items = [item("/review-pull-request"), item("/preview"), item("/review"), item("/rev")]
        let titles = ComposerRanking.rank(items, query: "rev").map(\.title)
        #expect(titles.first == "/rev")
        #expect(titles.firstIndex(of: "/review")! < titles.firstIndex(of: "/review-pull-request")!)
        #expect(titles.firstIndex(of: "/review-pull-request")! < titles.firstIndex(of: "/preview")!)
    }

    @Test func anEmptyQueryKeepsTheListsOrderAndNoMatchDropsTheItem() {
        let items = [item("/b"), item("/a"), item("/c")]
        #expect(ComposerRanking.rank(items, query: "").map(\.title) == ["/b", "/a", "/c"])
        #expect(ComposerRanking.rank(items, query: "zzz").isEmpty)
        #expect(ComposerRanking.rank(items, query: "", limit: 2).count == 2)
    }

    @Test func commandItemsListSkillsTerminalOnlyAndDoNotRepeat() {
        var state = ChatComposerState.idle(sessionID: UUID())
        state.commands = [CommandInfo(name: "compact", description: "Compact", argumentHint: "[focus]"),
                          CommandInfo(name: "review", description: "", argumentHint: nil)]
        state.slashCommands = ["compact", "review", "init", "my-skill"]
        state.skills = ["my-skill"]
        state.terminalOnlyCommands = ["focus"]
        let items = ComposerCommandItems.items(from: state)
        #expect(items.map(\.title) == ["/compact", "/review", "/init", "/focus"])
        #expect(items.first?.trailing == "[focus]")
        #expect(items.first?.insertion == "/compact ")
        let focus = items.last
        #expect(focus?.kind == .terminalOnly)
        #expect(focus?.trailing == "Terminal only")
        #expect(focus?.insertion == "")
    }

    @Test func aSkillOnlyInTheInitListIsLeftOutWhileTheInitializeListIsKnown() {
        var state = ChatComposerState.idle(sessionID: UUID())
        state.commands = [CommandInfo(name: "compact", description: nil, argumentHint: nil)]
        state.slashCommands = ["compact", "hidden-skill"]
        state.skills = ["hidden-skill"]
        #expect(ComposerCommandItems.items(from: state).map(\.title) == ["/compact"])
        // Before `initialize` answered, the init list is all there is.
        state.commands = []
        #expect(ComposerCommandItems.items(from: state).map(\.title) == ["/compact", "/hidden-skill"])
    }
}

// MARK: The bar's words

struct ComposerBarTextTests {
    private func state(_ adjust: (inout ChatComposerState) -> Void = { _ in }) -> ChatComposerState {
        var state = ChatComposerState.idle(sessionID: UUID())
        adjust(&state)
        return state
    }

    @Test func theModelChipReadsTheResolvedNameElseDefaultModel() {
        #expect(ComposerBarText.modelTitle(state()) == "Default model")
        #expect(ComposerBarText.modelTitle(state { $0.choices.model = "default" }) == "Default model")
        #expect(ComposerBarText.modelTitle(state { $0.resolvedModel = "claude-opus-5-5" }) == "Opus 5.5")
        #expect(ComposerBarText.modelTitle(state { $0.resolvedModel = "claude-opus-5-5[1m]" }) == "Opus 5.5 1M")
        #expect(ComposerBarText.modelTitle(state { $0.choices.model = "sonnet" }) != "Default model")
        let option = ModelOption(value: "opus", resolvedModel: "claude-opus-5-5", displayName: "Opus", supportedEffortLevels: [])
        #expect(ComposerBarText.modelTitle(state { $0.resolvedModel = "claude-opus-5-5"; $0.models = [option] }) == "Opus")
    }

    @Test func prettyModelNamesShapedIdsAndLeavesOthersAlone() {
        #expect(ComposerBarText.prettyModel("claude-sonnet-4-6") == "Sonnet 4.6")
        #expect(ComposerBarText.prettyModel("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ComposerBarText.prettyModel("12345") == "12345")
    }

    @Test func theEffortComesAfterTheModelInALighterWordAndNothingWhenUnknown() {
        #expect(ComposerBarText.effortTitle(state()) == nil)
        #expect(ComposerBarText.effortTitle(state { $0.reportedEffort = "high" }) == "High")
        #expect(ComposerBarText.effortTitle(state { $0.reportedEffort = "high"; $0.choices.effort = "xhigh" }) == "Extra high")
        #expect(ComposerBarText.effortLevels(state()) == ["low", "medium", "high", "xhigh", "max"])
        let option = ModelOption(value: "default", resolvedModel: "claude-fake-5-1", displayName: nil,
                                 supportedEffortLevels: ["low", "high"])
        #expect(ComposerBarText.effortLevels(state { $0.models = [option]; $0.resolvedModel = "claude-fake-5-1" }) == ["low", "high"])
    }

    @Test func everyModeReadsAsPlainTextWithNoWarningWording() {
        for mode in ClaudePermissionMode.allCases {
            let title = ComposerBarText.modeTitle(permissionMode: mode.rawValue, choices: ClaudeLaunchChoices())
            #expect(title == mode.title)
            #expect(!title.localizedCaseInsensitiveContains("warning"))
            #expect(!title.contains("\u{26A0}"))
            #expect(!title.contains("!"))
        }
        #expect(ComposerBarText.modeTitle(permissionMode: nil, choices: ClaudeLaunchChoices()) == "Mode")
        #expect(ComposerBarText.modeTitle(permissionMode: nil, choices: ClaudeLaunchChoices(permissionMode: "plan")) == ClaudePermissionMode.plan.title)
    }

    /// D-63: five modes, Loom's names, Ask first, no Plan, and no "Claude's default" anywhere.
    @Test func theModeListHasTheFiveModesUnderLoomsNames() {
        let titles = ClaudePermissionMode.menuModes.map(\.title)
        #expect(titles == ["Ask", "Ask before edits", "Accept edits", "Auto", "Full access"])
        #expect(!ClaudePermissionMode.menuModes.contains(.plan), "Plan is a card's choice, not a mode of the list")
        #expect(ClaudePermissionMode.plan.title == "Plan", "a plan session still reads as Plan")
        for mode in ClaudePermissionMode.allCases {
            #expect(!ComposerBarText.modeDetail(mode).isEmpty)
            #expect(!mode.title.contains("Claude"), "no \"Claude's default\" mode any more")
            #expect(!ComposerBarText.modeDetail(mode).localizedCaseInsensitiveContains("conversation"))
        }
        // Ask is Loom's own: the CLI is told `dontAsk`, every other mode keeps its word.
        #expect(ClaudePermissionMode.ask.cliValue == "dontAsk")
        #expect(ClaudePermissionMode.askBeforeEdits.cliValue == "default" && ClaudePermissionMode.fullAccess.cliValue == "bypassPermissions")
        #expect(ClaudePermissionMode.isOffered("ask") && ClaudePermissionMode.isOffered("default") && !ClaudePermissionMode.isOffered("plan"))
    }

    /// An older session, or one the CLI put in a mode of its own, reads under Loom's name or as the CLI wrote it.
    @Test func aModeLoomDoesNotKnowReadsAsTheCliWroteIt() {
        let none = ClaudeLaunchChoices()
        #expect(ComposerBarText.modeTitle(permissionMode: "default", choices: none) == "Ask before edits")
        #expect(ComposerBarText.modeTitle(permissionMode: "bypassPermissions", choices: none) == "Full access")
        #expect(ComposerBarText.modeTitle(permissionMode: "dontAsk", choices: none) == "Ask", "dontAsk is Ask's word to the CLI")
        #expect(ComposerBarText.modeTitle(permissionMode: "somethingNewer", choices: none) == "somethingNewer")
        // A session in Ask reports the CLI's `dontAsk` (or nothing yet, or nothing at all once it stopped): the bar says Ask.
        let ask = ClaudeLaunchChoices(permissionMode: "ask")
        #expect(ComposerBarText.modeTitle(permissionMode: nil, choices: ask) == "Ask")
        #expect(ComposerBarText.modeTitle(permissionMode: "dontAsk", choices: ask) == "Ask")
        // A stopped session shows the mode chosen, not the one the CLI reported last (`permissionMode` is nil then).
        #expect(ComposerBarText.modeTitle(permissionMode: nil, choices: ClaudeLaunchChoices(permissionMode: "acceptEdits")) == "Accept edits")
        // Once the CLI reports another mode (the mode was changed, a plan was approved), the bar follows it.
        #expect(ComposerBarText.modeTitle(permissionMode: "plan", choices: ask) == "Plan")
        #expect(ComposerBarText.modeTitle(permissionMode: "acceptEdits", choices: ask) == "Accept edits")
    }

    @Test func eachModeHasItsOwnIconAndToneAndTheToneIsReadableOnAPopoverAndACard() {
        var symbols = Set<String>()
        var tones: [LoomTheme.RGB] = []
        for mode in ClaudePermissionMode.menuModes {
            symbols.insert(ComposerModeLook.symbol(forRaw: mode.rawValue))
            let tone = LoomTheme.Composer.ModeTone.rgb(forRaw: mode.rawValue)
            tones.append(tone)
            for surface in [LoomTheme.Surface.popoverRGB, LoomTheme.Surface.cardRGB] {
                #expect(tone.contrast(with: surface) >= 4.5, "\(mode.title) on \(surface)")
            }
        }
        #expect(symbols.count == ClaudePermissionMode.menuModes.count, "one icon per mode")
        #expect(Set(tones.map { "\($0.red),\($0.green),\($0.blue)" }).count == tones.count, "one colour per mode")
        #expect(ComposerModeLook.symbol(forRaw: "dontAsk") == "shield" && LoomTheme.Composer.ModeTone.rgb(forRaw: "dontAsk") == LoomTheme.Composer.ModeTone.neutralRGB)
    }

    /// What each model offers for effort: its own list from the CLI, none for a model without effort, else the five.
    @Test func theEffortLevelsFollowTheModelTheCliListed() {
        func state(_ models: [ModelOption], chosen: String? = nil, resolved: String? = nil) -> ChatComposerState {
            var state = ChatComposerState.idle(sessionID: UUID())
            state.models = models
            state.choices.model = chosen
            state.resolvedModel = resolved
            return state
        }
        let five = ["low", "medium", "high", "xhigh", "max"]
        let opus = ModelOption(value: "opus", resolvedModel: "claude-opus-5-5", displayName: "Opus", supportedEffortLevels: five)
        let sonnet = ModelOption(value: "sonnet", resolvedModel: "claude-sonnet-5-5", displayName: "Sonnet",
                                 supportedEffortLevels: ["low", "medium", "high"])
        let haiku = ModelOption(value: "haiku", resolvedModel: "claude-haiku-4-5", displayName: "Haiku", supportedEffortLevels: [])
        let models = [opus, sonnet, haiku]
        #expect(ComposerBarText.effortLevels(state(models, chosen: "opus")) == five)
        #expect(ComposerBarText.effortLevels(state(models, chosen: "sonnet")) == ["low", "medium", "high"])
        #expect(ComposerBarText.effortLevels(state(models, chosen: "haiku")).isEmpty, "a model without effort offers no slider")
        #expect(ComposerBarText.effortLevels(state(models, resolved: "claude-sonnet-5-5")) == ["low", "medium", "high"])
        // A CLI that listed no effort for any model has not said anything about this one: the five the CLI takes.
        let silent = ModelOption(value: "opus", resolvedModel: "claude-opus-5-5", displayName: nil, supportedEffortLevels: [])
        #expect(ComposerBarText.effortLevels(state([silent], chosen: "opus")) == five)
        #expect(ComposerBarText.effortLevels(state([])) == five)
        #expect(NewSessionModels.effortLevels == five)
    }

    @Test func theModelPickerOffersDefaultThenTheCliModelsAndResetsEffortOnlyWhenItMoved() {
        var state = ChatComposerState.idle(sessionID: UUID())
        let plain = ComposerBarText.modelPicker(state, effortBaseline: nil)
        #expect(plain.rows.map(\.title) == ["Opus", "Sonnet", "Haiku"] && ComposerBarText.isDefaultModelChosen(plain.chosenModel))
        #expect(!plain.canResetEffort)
        state.reportedEffort = "medium"
        #expect(!ComposerBarText.modelPicker(state, effortBaseline: "medium").canResetEffort)
        state.choices.effort = "high"
        let moved = ComposerBarText.modelPicker(state, effortBaseline: "medium")
        #expect(moved.canResetEffort && moved.chosenLevel == "high" && moved.effortTitle == "High")
        #expect(!ComposerBarText.isDefaultModelChosen("opus") && ComposerBarText.isDefaultModelChosen("default"))
    }

    /// M2: the reset goes to the effort the session opened with, as the model now chosen takes it; with none, to Default.
    @Test func theEffortResetGoesToTheBaselineAsTheModelTakesItOrToDefault() {
        var state = ChatComposerState.idle(sessionID: UUID())
        let sonnet = ModelOption(value: "sonnet", resolvedModel: "claude-sonnet-5-5", displayName: "Sonnet",
                                 supportedEffortLevels: ["low", "medium", "high"])
        state.models = [sonnet]
        state.choices.model = "sonnet"
        state.choices.effort = "low"
        #expect(ComposerBarText.resetTarget(state, effortBaseline: "xhigh") == "high", "the baseline the model lacks is clamped")
        #expect(ComposerBarText.resetTarget(state, effortBaseline: "medium") == "medium")
        #expect(ComposerBarText.resetTarget(state, effortBaseline: nil) == nil, "no baseline: Default")
        #expect(ComposerBarText.modelPicker(state, effortBaseline: nil).canResetEffort, "an effort chosen over none can go back to Default")
        state.choices.effort = nil
        #expect(!ComposerBarText.modelPicker(state, effortBaseline: nil).canResetEffort)
    }

    /// The notices of a mode change that did not happen say what is true now.
    @Test func aRefusedModeChangeSaysWhatIsTrueNow() {
        #expect(ChatComposerModel.modeFailure(ChatDriverError.requestWaiting) == "Answer the waiting request first.")
        #expect(ChatComposerModel.modeFailure(ChatDriverError.modeNotChanged(staysInAsk: true))
            == "The mode was not changed; the session stays in Ask.")
        #expect(ChatComposerModel.modeFailure(ChatDriverError.askUnavailable).hasSuffix("The mode was not changed."))
        #expect(ChatComposerModel.modeFailure(ChatDriverError.inputFull) == "The mode was not changed.")
    }

    /// B1: where the session starts in the terminal, Ask is in the mode list but cannot be chosen, and says why.
    @MainActor @Test func askIsListedButDisabledWhereTheSessionStartsInTheTerminal() throws {
        let chat = ComposerModeChip.rows(selected: "default")
        let ask = try #require(chat.first { $0.id == "ask" })
        #expect(ask.isEnabled && ask.subtitle == ComposerBarText.modeDetail(.ask))
        let terminal = ComposerModeChip.rows(selected: "default", askAllowed: false)
        let blocked = try #require(terminal.first { $0.id == "ask" })
        #expect(!blocked.isEnabled && blocked.subtitle == "Chat only" && !blocked.checked)
        #expect(terminal.filter { $0.id != "ask" }.allSatisfy { $0.isEnabled })
        #expect(terminal.map { $0.id } == chat.map { $0.id })
    }

    @Test func theEffortSliderPicksTheNearestStopAndSpansTheTrack() {
        let positions = EffortSliderMath.positions(count: 5, width: 200, thumb: 20, inset: 4)
        #expect(positions.count == 5 && abs(positions[0] - 14) < 0.001 && abs(positions[4] - 186) < 0.001)
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $1 > $0 })
        #expect(EffortSliderMath.nearest(to: -50, in: positions) == 0 && EffortSliderMath.nearest(to: 500, in: positions) == 4)
        #expect(EffortSliderMath.nearest(to: positions[2] + 3, in: positions) == 2)
        #expect(EffortSliderMath.positions(count: 0, width: 200, thumb: 20, inset: 4).isEmpty)
        #expect(EffortSliderMath.positions(count: 1, width: 200, thumb: 20, inset: 4) == [100])
        #expect(EffortSliderMath.nearest(to: 10, in: []) == nil)
    }

    @Test func theContextReadsFromTheDriverElseTheUsageIndex() {
        #expect(ComposerBarText.contextUsage(state(), fallback: nil) == nil)
        let fallback = ContextUsage(tokens: 5_000, window: 200_000, model: "m")
        #expect(ComposerBarText.contextUsage(state(), fallback: fallback) == fallback)
        let live = ComposerBarText.contextUsage(state { $0.contextTokens = 120_000; $0.contextWindow = 1_000_000 }, fallback: fallback)
        #expect(live?.tokens == 120_000)
        #expect(live.map(ComposerBarText.contextLine) == "Context \u{00B7} 120K of 1M (12%)")
        let unknownWindow = ComposerBarText.contextUsage(state { $0.contextTokens = 84_000 }, fallback: nil)
        #expect(unknownWindow.map(ComposerBarText.contextLine) == "Context \u{00B7} 84K")
    }
}

// MARK: Files

struct ComposerFileIndexTests {
    private func folder(_ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-index-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func touch(_ root: URL, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    @Test func theScanListsShallowFirstAndSkipsHiddenAndBuildFolders() throws {
        let root = try folder { root in
            for path in ["README.md", "Sources/App/Main.swift", ".git/config", "node_modules/x/index.js", ".hidden", "build/out.o", "docs/a.md"] {
                try touch(root, path)
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ComposerFileIndex.scan(root: root).map(\.path)
        #expect(paths.contains("README.md"))
        #expect(paths.contains("Sources/App/Main.swift"))
        #expect(paths.contains("docs/a.md"))
        #expect(!paths.contains { $0.hasPrefix(".git") || $0.hasPrefix(".hidden") })
        // A skipped folder is listed itself but not entered.
        #expect(paths.contains("node_modules"))
        #expect(!paths.contains { $0.hasPrefix("node_modules/") })
        #expect(paths.firstIndex(of: "README.md")! < paths.firstIndex(of: "Sources/App/Main.swift")!)
    }

    @Test func theScanStopsAtTheDepthAndTheEntryCaps() throws {
        let root = try folder { root in
            try touch(root, (1...12).map { "d\($0)" }.joined(separator: "/") + "/deep.txt")
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let deepest = ComposerFileIndex.scan(root: root).map { $0.path.split(separator: "/").count }.max() ?? 0
        #expect(deepest <= ComposerFileIndex.maximumDepth)
        #expect(deepest >= ComposerFileIndex.maximumDepth - 1)
        let wide = try folder { root in
            for index in 0..<(ComposerFileIndex.maximumPerFolder + 300) { try touch(root, "f\(index).txt") }
        }
        defer { try? FileManager.default.removeItem(at: wide) }
        #expect(ComposerFileIndex.scan(root: wide).count == ComposerFileIndex.maximumPerFolder)
    }

    @Test func aCancelledScanStopsAtOnce() throws {
        let root = try folder { root in
            for index in 0..<30 { try touch(root, "dir\(index)/file.txt") }
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ComposerFileIndex.scan(root: root, isCancelled: { true }).isEmpty)
        var calls = 0
        let partial = ComposerFileIndex.scan(root: root, isCancelled: { calls += 1; return calls > 2 })
        #expect(partial.count < 60)
    }

    @Test func theHomeFolderAndTheRootAreNotScanned() {
        #expect(ComposerFileIndex.isTooBroad(URL(fileURLWithPath: NSHomeDirectory())))
        #expect(ComposerFileIndex.isTooBroad(URL(fileURLWithPath: "/")))
        #expect(!ComposerFileIndex.isTooBroad(FileManager.default.temporaryDirectory))
        #expect(ComposerFileIndex.scan(root: URL(fileURLWithPath: NSHomeDirectory())).isEmpty)
    }

    @Test func rankingPrefersNamesShortPathsAndInsertsMentions() {
        let entries = ["docs/readme-draft.md", "README.md", "Sources/App/Reader.swift", "Sources"].map {
            ComposerFileEntry(path: $0, isDirectory: $0 == "Sources")
        }
        let ranked = ComposerFileIndex.rank(entries, query: "readme")
        #expect(ranked.first?.title == "README.md")
        #expect(ranked.map(\.title).contains("docs/readme-draft.md"))
        #expect(!ranked.map(\.title).contains("Sources/"))
        #expect(ComposerFileIndex.rank(entries, query: "").first?.title == "docs/readme-draft.md")
        #expect(ComposerFileIndex.insertion(for: "README.md", isDirectory: false) == "@README.md ")
        #expect(ComposerFileIndex.insertion(for: "Sources", isDirectory: true) == "@Sources/")
        #expect(ComposerFileIndex.insertion(for: "My Notes/a b.md", isDirectory: false) == "@\"My Notes/a b.md\" ")
    }

    @Test func aCancelledRankReturnsNothing() {
        let entries = (0..<2_000).map { ComposerFileEntry(path: "file\($0).txt", isDirectory: false) }
        #expect(ComposerFileIndex.rank(entries, query: "file1", isCancelled: { true }).isEmpty)
    }
}

// MARK: Paste and images

struct ComposerPasteTests {
    @Test func aLargePasteBecomesAChipAtTheThresholdAndASmallOneDoesNot() {
        #expect(!ComposerPaste.becomesChip(String(repeating: "a", count: ComposerPaste.chipThreshold - 1)))
        #expect(ComposerPaste.becomesChip(String(repeating: "a", count: ComposerPaste.chipThreshold)))
        // Multi-byte text reaches the byte bound first.
        #expect(ComposerPaste.becomesChip(String(repeating: "\u{00E7}", count: ComposerPaste.chipThreshold / 2 + 1)))
        #expect(ComposerPaste.sizeLabel(bytes: 41_000) == "40 KB")
        #expect(ComposerPaste.sizeLabel(bytes: 10) == "1 KB")
    }

    private func png(width: Int, height: Int, alpha: Bool = false) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                   samplesPerPixel: alpha ? 4 : 3, hasAlpha: alpha, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func aSmallImageGoesOutAsItIsAndABigOneIsScaledToTwoThousandPixels() throws {
        let small = try png(width: 300, height: 200)
        let kept = try ComposerImages.prepare(small)
        #expect(kept.data == small)
        #expect(kept.mediaType == "image/png")
        #expect(kept.pixelSize == CGSize(width: 300, height: 200))
        #expect(kept.thumbnail != nil)
        let big = try png(width: 3000, height: 1500)
        let scaled = try ComposerImages.prepare(big)
        #expect(scaled.pixelSize.width == 2000)
        #expect(scaled.pixelSize.height == 1000)
        #expect(scaled.mediaType == "image/png")
        #expect(scaled.data.count < big.count * 2)
    }

    @Test func notAnImageAndAHugeFileAreRefused() throws {
        #expect(throws: ComposerImages.Failure.unreadable) { try ComposerImages.prepare(Data("not an image".utf8)) }
        #expect(throws: ComposerImages.Failure.tooLarge) { try ComposerImages.prepare(Data(count: ComposerImages.refuseAbove + 1)) }
    }

    @Test func aMentionIsRelativeInsideTheFolderAbsoluteOutsideAndQuotedWithSpaces() {
        let inside = URL(fileURLWithPath: "/work/app/Sources/Main.swift")
        #expect(ComposerPasteboard.mention(for: inside, relativeTo: "/work/app") == "@Sources/Main.swift")
        #expect(ComposerPasteboard.mention(for: inside, relativeTo: "/other") == "@/work/app/Sources/Main.swift")
        let spaced = URL(fileURLWithPath: "/work/app/My Notes/a.md")
        #expect(ComposerPasteboard.mention(for: spaced, relativeTo: "/work/app") == "@\"My Notes/a.md\"")
    }

    @Test func thePasteboardPastesFilesBeforeTextAndTextBeforeAnImage() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("loom-test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("some text", forType: .string)
        board.setData(try png(width: 10, height: 10), forType: .png)
        #expect(ComposerPasteboard.items(from: board) == [.text("some text")])
        board.clearContents()
        board.setData(try png(width: 10, height: 10), forType: .png)
        guard case .imageData? = ComposerPasteboard.items(from: board).first else {
            Issue.record("an image on the pasteboard is not offered as an image")
            return
        }
    }
}

// MARK: Delivery and queue words

struct ComposerWordsTests {
    @Test func theQueueSaysWhyItWaitsAndWhatWentWrong() {
        #expect(ComposerQueueText.title(count: 2) == "Queued \u{00B7} 2")
        #expect(ComposerQueueText.pause(nil) == nil)
        #expect(ComposerQueueText.pause(.interrupted) == "Queue paused because you interrupted")
        #expect(ComposerQueueText.pause(.failedTurn) == "Queue paused because the turn failed")
        #expect(ComposerQueueText.pause(.processEnded) == "Queue paused because Claude ended")
        #expect(ComposerQueueText.pause(.relaunch) == "Queue paused since Loom started again")
        #expect(ComposerQueueText.issue(nil) == nil)
        #expect(ComposerQueueText.issue(.notSaved("disk"))?.contains("could not be saved") == true)
        #expect(ComposerQueueText.issue(.unreadable(keptAs: "queue.1.json"))?.contains("queue.1.json") == true)
        #expect(ComposerQueueText.issue(.notSent("io"))?.contains("back at the front") == true)
    }

    @Test func aMultiLineQueuedMessageShowsItsFirstLine() {
        #expect(ComposerQueueStrip.oneLine("first\nsecond") == "first")
        #expect(ComposerQueueStrip.oneLine("   ") == "")
    }

    @Test func theHintsNameTheKeysThatApplyNow() {
        var state = ChatComposerState.idle(sessionID: UUID())
        let idle = ComposerBarText.hints(state, editing: false)
        #expect(idle.first == "\u{21B5} send")
        #expect(idle.contains { $0.contains("new line") })
        state.turnRunning = true
        let working = ComposerBarText.hints(state, editing: false)
        #expect(working.first == "\u{21B5} send now")
        #expect(working.contains { $0.contains("after this turn") })
        #expect(working.contains { $0.contains("esc interrupt") })
        #expect(ComposerBarText.hints(state, editing: true).contains { $0.contains("esc") && $0.contains("cancel") })
    }
}

// MARK: Fix round (V17)

@MainActor
struct ComposerFixRoundPureTests {
    /// Fix 5: the folders no scan may enter, and the per-folder cap.
    @Test func theBroadFoldersAreNotScannedNorTheirAncestors() {
        let home = "/Users/someone"
        for broad in ["/", "/Users", home, "/Volumes", "/Volumes/Backup"] {
            #expect(ComposerFileIndex.isTooBroad(URL(fileURLWithPath: broad), home: home), "\(broad)")
        }
        for fine in ["/Users/someone/code/app", "/Volumes/Backup/code", "/tmp/project"] {
            #expect(!ComposerFileIndex.isTooBroad(URL(fileURLWithPath: fine), home: home), "\(fine)")
        }
    }

    /// Fix 16: only the strip's own drag moves a row.
    @Test func onlyTheQueueStripsOwnDragIsAccepted() {
        #expect(ComposerQueueStrip.draggedID(from: ComposerQueueStrip.dragPrefix + "item-1") == "item-1")
        #expect(ComposerQueueStrip.draggedID(from: "item-1") == nil, "a string from anywhere else")
        #expect(ComposerQueueStrip.draggedID(from: "https://example.com") == nil)
        #expect(ComposerQueueStrip.draggedID(from: ComposerQueueStrip.dragPrefix) == nil, "no id")
    }

    /// Fix 10: an image of more pixels than the limit is refused from its header, before it is decoded.
    @Test func anImageOfTooManyPixelsIsRefusedBeforeDecoding() throws {
        // 12000 x 12000 = 144 M pixels, a few hundred KB of PNG.
        let width = 12_000, height = 12_000
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(data.length < ComposerImages.refuseAbove)
        #expect(throws: ComposerImages.Failure.tooLarge) { try ComposerImages.prepare(data as Data) }
    }

    /// Fix 9: the model setting the text never lands in the middle of an input method's composition, and clears undo.
    @Test func textTheModelSetsUnmarksTheCompositionAndClearsStaleUndo() throws {
        let view = ComposerTextEditor.ComposerTextView()
        view.string = "ab"
        view.setMarkedText("\u{00F6}", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: 2, length: 0))
        #expect(view.hasMarkedText())
        view.replaceAll(with: "recalled message")
        #expect(!view.hasMarkedText())
        #expect(view.string == "recalled message")
        #expect(view.undoManager?.canUndo != true, "earlier undo steps point into text that is gone")
    }
}
