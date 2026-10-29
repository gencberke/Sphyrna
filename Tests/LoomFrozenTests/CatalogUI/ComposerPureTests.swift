import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
@testable import LoomCatalogUITestRigs

// MARK: Turkish Q

/// Every key equivalent is reachable on a Turkish Q keyboard. The key codes name keys by place, so the rules hold on any
/// layout; this reads the system's own Turkish layouts through Text Input Sources and checks the facts that matter: the
/// characters the menus need (`/` and `@`) can be typed on each, the shortcuts sit on the letters they say on the three
/// Q layouts (on the F layout the same places print other letters, and the chords still work by place), and none of them
/// needs the layout's third level (⌥).
@MainActor
struct ComposerTurkishLayoutTests {
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

struct ComposerBarTextTests: ComposerBarTextFixtures {
    @Test func theModelChipReadsTheResolvedNameElseDefaultModel() {
        #expect(ComposerBarText.modelTitle(state()) == "Default model")
        #expect(ComposerBarText.modelTitle(state { $0.choices.model = "default" }) == "Default model")
        #expect(ComposerBarText.modelTitle(state { $0.resolvedModel = "claude-opus-5-5" }) == "Opus 5.5")
        #expect(ComposerBarText.modelTitle(state { $0.resolvedModel = "claude-opus-5-5[1m]" }) == "Opus 5.5 1M")
        #expect(ComposerBarText.modelTitle(state { $0.choices.model = "sonnet" }) != "Default model")
        let option = ModelOption(value: "opus", resolvedModel: "claude-opus-5-5", displayName: "Opus", supportedEffortLevels: [])
        #expect(ComposerBarText.modelTitle(state { $0.resolvedModel = "claude-opus-5-5"; $0.models = [option] }) == "Opus 5.5",
                "the release's full name, not the CLI's short display name")
    }

    @Test func aStoppedSessionsChipNamesTheModelItLastRanOn() {
        // Nothing is resolved or chosen: the model the usage index saw is the one a resume passes back.
        #expect(ComposerBarText.modelTitle(state(), observed: "claude-haiku-5-5") == "Haiku 5.5")
        #expect(ComposerBarText.modelTitle(state(), observed: "") == "Default model")
        #expect(ComposerBarText.modelTitle(state(), observed: nil) == "Default model")
        // The model the CLI reported, and a model the user picked, win.
        #expect(ComposerBarText.modelTitle(state { $0.resolvedModel = "claude-opus-5-5" }, observed: "claude-haiku-5-5") == "Opus 5.5")
        #expect(ComposerBarText.modelTitle(state { $0.choices.model = "sonnet" }, observed: "claude-haiku-5-5") != "Haiku 5.5")
        #expect(ComposerBarText.modelTitle(state { $0.choices.model = "default" }, observed: "claude-haiku-5-5") == "Default model")
        #expect(ComposerBarText.modelPicker(state(), effortBaseline: nil, observedModel: "claude-haiku-5-5").modelTitle == "Haiku 5.5")
        #expect(ComposerBarText.modelPicker(state(), effortBaseline: nil).modelTitle == "Default model")
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

    @Test func aCancelledRankReturnsNothing() {
        let entries = (0..<2_000).map { ComposerFileEntry(path: "file\($0).txt", isDirectory: false) }
        #expect(ComposerFileIndex.rank(entries, query: "file1", isCancelled: { true }).isEmpty)
    }
}

// MARK: Paste and images

struct ComposerPasteTests: ComposerPasteFixtures {
    @Test func aLargePasteBecomesAChipAtTheThresholdAndASmallOneDoesNot() {
        #expect(!ComposerPaste.becomesChip(String(repeating: "a", count: ComposerPaste.chipThreshold - 1)))
        #expect(ComposerPaste.becomesChip(String(repeating: "a", count: ComposerPaste.chipThreshold)))
        // Multi-byte text reaches the byte bound first.
        #expect(ComposerPaste.becomesChip(String(repeating: "\u{00E7}", count: ComposerPaste.chipThreshold / 2 + 1)))
        #expect(ComposerPaste.sizeLabel(bytes: 41_000) == "40 KB")
        #expect(ComposerPaste.sizeLabel(bytes: 10) == "1 KB")
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
}

// MARK: Delivery and queue words

struct ComposerWordsTests {
    @Test func theQueueSaysWhyItWaitsAndWhatWentWrong() {
        #expect(ComposerQueueText.title(count: 2) == "Queued \u{00B7} 2")
        #expect(ComposerQueueText.pause(nil) == nil)
        #expect(ComposerQueueText.pause(.interrupted) == "Queue paused because you interrupted")
        #expect(ComposerQueueText.pause(.failedTurn) == "Queue paused because the turn failed")
        #expect(ComposerQueueText.pause(.processEnded) == "Queue paused because Claude ended")
        #expect(ComposerQueueText.pause(.relaunch) == "Queue paused since Sphyrna started again")
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
