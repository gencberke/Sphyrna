import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
@testable import LoomCatalogUITestRigs

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
    @Test(arguments: ComposerPureShared.qLayouts)
    func onTurkishQTheShortcutKeysAreTheLettersTheyNameAndSlashAndAtCanBeTyped(_ id: String) throws {
        let layout = try #require(ComposerPureShared.layout(id), "\(id) is not available to Text Input Sources")
        // ⇧⌘A, ⇧⌘M, ⇧⌘K and ⇧⌘V are the keys that print a, m, k and v.
        for (key, letter) in [(ComposerKeys.letterA, "a"), (ComposerKeys.letterM, "m"), (ComposerKeys.letterK, "k"),
                              (ComposerKeys.letterV, "v")] {
            #expect(ComposerPureShared.character(layout, key: key, modifiers: 0) == letter)
        }
        let slash = ComposerPureShared.chords(typing: "/", layout)
        let at = ComposerPureShared.chords(typing: "@", layout)
        #expect(!slash.isEmpty)
        #expect(!at.isEmpty)
        // Which chord types them does not matter: the menus open from the inserted character.
        // None of the chords that type them is on a key the composer reads: Return, Tab, Escape and the arrows are
        // placed the same on every layout.
        let ours: Set<UInt16> = [ComposerKeys.returnKey, ComposerKeys.keypadEnter, ComposerKeys.tab, ComposerKeys.escape,
                                 ComposerKeys.upArrow, ComposerKeys.downArrow]
        #expect(ours.isDisjoint(with: Set((slash + at).map(\.0))))
    }

    @Test(arguments: ComposerPureShared.fLayouts)
    func onTheTurkishFLayoutsTheSameChordsWorkByPlaceAndSlashAndAtCanBeTyped(_ id: String) throws {
        let layout = try #require(ComposerPureShared.layout(id), "\(id) is not available to Text Input Sources")
        // The letters differ (the A place prints u): the chords are by key code, so they stay on the same keys.
        #expect(ComposerPureShared.character(layout, key: ComposerKeys.letterA, modifiers: 0) != "a")
        #expect(!ComposerPureShared.chords(typing: "/", layout).isEmpty)
        #expect(!ComposerPureShared.chords(typing: "@", layout).isEmpty)
    }
}

// MARK: The bar's words

struct ComposerBarTextTests: ComposerBarTextFixtures {
    @Test func prettyModelNamesShapedIdsAndLeavesOthersAlone() {
        #expect(ComposerBarText.prettyModel("claude-sonnet-4-6") == "Sonnet 4.6")
        #expect(ComposerBarText.prettyModel("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ComposerBarText.prettyModel("12345") == "12345")
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

    @Test func eachModeHasItsOwnIconAndToneAndTheToneIsReadableOnAPopoverAndTheComposer() {
        var symbols = Set<String>()
        var tones: [LoomTheme.RGB] = []
        for mode in ClaudePermissionMode.menuModes {
            symbols.insert(ComposerModeLook.symbol(forRaw: mode.rawValue))
            let tone = LoomTheme.Composer.ModeTone.rgb(forRaw: mode.rawValue)
            tones.append(tone)
            for surface in [LoomTheme.Surface.greys(.dark, tone: .neutral).popover, LoomTheme.Surface.greys(.dark, tone: .neutral).raised2] {
                #expect(tone.contrast(with: surface) >= 4.5, "\(mode.title) on \(surface)")
            }
        }
        #expect(symbols.count == ClaudePermissionMode.menuModes.count, "one icon per mode")
        #expect(Set(tones.map { "\($0.red),\($0.green),\($0.blue)" }).count == tones.count, "one colour per mode")
        #expect(ComposerModeLook.symbol(forRaw: "dontAsk") == "shield" && LoomTheme.Composer.ModeTone.rgb(forRaw: "dontAsk") == LoomTheme.Composer.ModeTone.neutralRGB)
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
}

// MARK: Paste and images

struct ComposerPasteTests: ComposerPasteFixtures {
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
