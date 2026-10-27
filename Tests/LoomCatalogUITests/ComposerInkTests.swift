import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// The composer in Ink (I6m, DESIGN §11, D-75): the one model chip and its popover (the groups, the dimmed rows, the keys),
// what Send says, the keys line, the `@` menu's heads and the sizes the reference gives. No window and no process; the
// popover is hosted offscreen and never ordered front.

struct ComposerInkTests {
    private func state(_ adjust: (inout ChatComposerState) -> Void = { _ in }) -> ChatComposerState {
        var state = ChatComposerState.idle(sessionID: UUID())
        adjust(&state)
        return state
    }

    private func picker(chosen: String? = nil, levels: [String] = ["low", "medium", "high"],
                        rows: [String] = ["opus", "sonnet", "haiku"]) -> ComposerModelPicker {
        ComposerModelPicker(
            modelTitle: "Sonnet 5.5", effortTitle: "High",
            rows: rows.map { ComposerBarText.ModelRow(value: $0, title: $0.capitalized) },
            chosenModel: chosen, levels: levels, chosenLevel: "high", canResetEffort: false)
    }

    // MARK: The chip

    /// The effort word follows the model: a model with no effort setting shows none, however the session last reported one.
    @Test func theChipShowsTheEffortOnlyForAModelThatTakesOne() {
        let sonnet = ModelOption(value: "sonnet", resolvedModel: "claude-sonnet-5-5", displayName: "Sonnet",
                                 supportedEffortLevels: ["low", "medium", "high"])
        let haiku = ModelOption(value: "haiku", resolvedModel: "claude-haiku-5-5", displayName: "Haiku", supportedEffortLevels: [])
        let withEffort = ComposerBarText.modelPicker(state { $0.models = [sonnet, haiku]; $0.choices.model = "sonnet"; $0.reportedEffort = "high" },
                                                     effortBaseline: nil)
        #expect(withEffort.chipEffortWord == "High" && withEffort.modelTitle != "Default model")
        let without = ComposerBarText.modelPicker(state { $0.models = [sonnet, haiku]; $0.choices.model = "haiku"; $0.reportedEffort = "high" },
                                                  effortBaseline: nil)
        #expect(without.levels.isEmpty && without.chipEffortWord == nil, "no effort setting, no word")
        let unnamed = ComposerBarText.modelPicker(state(), effortBaseline: nil)
        #expect(unnamed.modelTitle == "Default model" && unnamed.chipEffortWord == nil, "no effort known, no word")
    }

    @Test func theChosenRowIsDefaultUntilAModelIsChosen() {
        #expect(picker().chosenID == "default" && picker(chosen: "default").chosenID == "default")
        #expect(picker(chosen: "sonnet").chosenID == "sonnet")
    }

    // MARK: The groups

    @Test func theSessionsHarnessComesFirstWithItsMarkNameAndNote() {
        let groups = picker(chosen: "sonnet").groups()
        #expect(groups.map(\.name) == ["Claude Code", "Codex"])
        #expect(groups.map(\.provider) == [.claude, .codex])
        #expect(groups.map(\.note) == ["this session", "in a new session"])
        #expect(groups.map(\.isLive) == [true, false])
    }

    @Test func claudeCodeListsDefaultThenTheModelsWithTheirNotesAndOneCheck() {
        let claude = picker(chosen: "sonnet").groups()[0]
        #expect(claude.rows.map(\.title) == ["Default", "Opus", "Sonnet", "Haiku"])
        #expect(claude.rows.map(\.id) == ["default", "opus", "sonnet", "haiku"])
        #expect(claude.rows.map(\.subtitle) == ["Recommended", "Long agentic coding", "Fast, everyday work", "Quick answers, no effort"])
        #expect(claude.rows.filter(\.checked).map(\.id) == ["sonnet"])
        #expect(claude.rows.allSatisfy { $0.isEnabled })
        #expect(picker().groups()[0].rows.filter(\.checked).map(\.id) == ["default"], "no choice is Default")
    }

    @Test func aModelTheTableDoesNotKnowHasNoNote() {
        #expect(ComposerModelNotes.note(forAlias: "opusplan") == nil)
        #expect(ComposerModelNotes.note(forAlias: "Opus") == "Long agentic coding", "the alias is read in lowercase")
        let rows = picker(rows: ["opus", "fable"]).groups()[0].rows
        #expect(rows.map(\.subtitle) == ["Recommended", "Long agentic coding", nil])
    }

    /// The other harness's rows are listed and dimmed: none can be picked, none is checked, and they cannot be reached by the
    /// arrow keys.
    @MainActor @Test func codexIsStaticAndItsRowsCannotBePicked() {
        let codex = picker(chosen: "sonnet").groups()[1]
        #expect(codex.rows.count == ModelCatalog.codexFallback.count && !codex.rows.isEmpty)
        #expect(codex.rows.allSatisfy { !$0.isEnabled && !$0.checked && $0.id.hasPrefix("codex:") })
        #expect(codex.help == ComposerModelNotes.keepsItsHarness)
        var later = picker()
        later.codexNote = CatalogModel.codexLaterReason
        #expect(later.groups()[1].note == "Codex comes in a later version", "a build that cannot start Codex says so")
        #expect(later.groups()[0].note == "this session")
    }

    // MARK: The keys

    @Test func upAndDownMoveBetweenTheModelsAndWrap() {
        #expect(ComposerPopoverKeys.cursor(from: 0, delta: 1, count: 4) == 1)
        #expect(ComposerPopoverKeys.cursor(from: 3, delta: 1, count: 4) == 0, "down from the last row wraps to the first")
        #expect(ComposerPopoverKeys.cursor(from: 0, delta: -1, count: 4) == 3, "up from the first row wraps to the last")
        #expect(ComposerPopoverKeys.cursor(from: nil, delta: 1, count: 4) == 0 && ComposerPopoverKeys.cursor(from: nil, delta: -1, count: 4) == 3)
        #expect(ComposerPopoverKeys.cursor(from: 0, delta: 1, count: 0) == nil)
    }

    @Test func leftAndRightStepTheEffortAndStopAtTheEnds() {
        #expect(EffortSliderMath.step(from: 1, delta: 1, count: 5) == 2 && EffortSliderMath.step(from: 1, delta: -1, count: 5) == 0)
        #expect(EffortSliderMath.step(from: 4, delta: 1, count: 5) == nil, "→ at max changes nothing")
        #expect(EffortSliderMath.step(from: 0, delta: -1, count: 5) == nil, "← at the lowest changes nothing")
        #expect(EffortSliderMath.step(from: nil, delta: 1, count: 5) == 0 && EffortSliderMath.step(from: nil, delta: -1, count: 5) == 4)
        #expect(EffortSliderMath.step(from: nil, delta: 1, count: 0) == nil, "a model with no effort has no stops")
    }

    @Test func returnPicksTheHighlightedModelAndOnlyClosesWhenItIsAlreadyChosen() {
        #expect(ComposerPopoverKeys.pickOnDone(cursor: "opus", chosen: "sonnet") == "opus")
        #expect(ComposerPopoverKeys.pickOnDone(cursor: "sonnet", chosen: "sonnet") == nil)
        #expect(ComposerPopoverKeys.pickOnDone(cursor: nil, chosen: "sonnet") == nil)
    }

    @Test func theKeysLineNamesTheThreeKeys() {
        #expect(ComposerModelPopover.keys.map(\.key) == ["\u{2191}\u{2193}", "\u{2190}\u{2192}", "\u{21B5}"])
        #expect(ComposerModelPopover.keys.map(\.words) == ["model", "effort", "done"])
    }

    // MARK: Send

    @Test func sendSaysWhatReturnDoes() {
        // A plain send is the accent disc, an off one the faint disc, Interrupt a primary disc with a square.
        #expect(ComposerSendLook.send.disc == .accent && ComposerSendLook.send.word == nil)
        #expect(ComposerSendLook.disabled.disc == .faint && !ComposerSendLook.disabled.isEnabled)
        #expect(ComposerSendLook.stop.disc == .primary && ComposerSendLook.stop.symbol == nil, "Interrupt draws a square, not a glyph")
        // The rest are accent capsules with their word and icon.
        let words = ComposerSendLook.allCases.compactMap(\.word)
        #expect(words == ["Send Now", "After This Turn", "Update", "Resume"])
        for look in ComposerSendLook.allCases where look.word != nil {
            #expect(look.disc == nil && look.symbol != nil && look.isEnabled, "\(look) is a capsule")
        }
        #expect(ComposerSendLook.allCases.filter { $0.disc != nil }.count == 3)
    }

    @Test func eachSendKindDrawsItsLookAndNamesItself() {
        let table: [(ComposerSendKind, ComposerSendLook, String)] = [
            (.sendDisabled, .disabled, "Send"), (.send, .send, "Send"), (.sendNow, .sendNow, "Send Now"),
            (.afterTurn, .afterTurn, "After This Turn"), (.interrupt, .stop, "Interrupt"), (.update, .update, "Update"),
            (.resume, .resume, "Resume"),
        ]
        for (kind, look, label) in table {
            #expect(kind.look == look, "\(kind)")
            #expect(kind.label == label, "\(kind)")
        }
    }

    // MARK: The keys line and the menus

    @Test func aHintIsItsKeyThenItsWords() {
        #expect(ComposerHints.split("\u{21B5} send now") == ("\u{21B5}", "send now"))
        #expect(ComposerHints.split("esc interrupt") == ("esc", "interrupt"))
        #expect(ComposerHints.split("@ files and sessions") == ("@", "files and sessions"))
        #expect(ComposerHints.split("tab") == ("tab", ""))
    }

    private func item(_ id: String, _ kind: ComposerMenuItem.Kind) -> ComposerMenuItem {
        ComposerMenuItem(id: id, kind: kind, title: id, detail: nil, trailing: nil, insertion: id)
    }

    @MainActor @Test func theAtMenuHasFilesAndSessionsHeadsAndTheSlashMenuOne() {
        let mixed = [item("a", .file), item("b", .folder), item("c", .session), item("d", .session)]
        #expect((0..<4).map { ComposerMenuPanel.head(for: $0, in: mixed, kind: .mention) } == ["Files", nil, "Sessions", nil])
        let sessionsOnly = [item("c", .session)]
        #expect(ComposerMenuPanel.head(for: 0, in: sessionsOnly, kind: .mention) == "Sessions")
        let commands = [item("/review", .command), item("deploy", .skill)]
        #expect((0..<2).map { ComposerMenuPanel.head(for: $0, in: commands, kind: .commands) } == ["Commands and skills", nil])
        #expect(ComposerMenuPanel.symbol(for: .command) != ComposerMenuPanel.symbol(for: .skill))
        #expect(Set([ComposerMenuItem.Kind.file, .folder, .session, .skill].map(ComposerMenuPanel.symbol(for:))).count == 4)
    }

    // MARK: Sizes

    @Test func theBarAndItsPopoversHaveTheReferencesSizes() {
        #expect(LoomTheme.Composer.barHeight == 38 && LoomTheme.Composer.controlSide == 28 && LoomTheme.Composer.sendSide == 30)
        #expect(LoomTheme.Composer.modelPopoverWidth == 332 && LoomTheme.Composer.pickWidth == 312)
        #expect(LoomTheme.Composer.ringPopoverWidth == 268 && LoomTheme.Composer.plusPopoverWidth == 300)
        #expect(LoomTheme.Composer.modelRowHeight == 30 && LoomTheme.Composer.groupHeadHeight == 28)
        #expect(LoomTheme.Composer.radius == 18 && LoomTheme.Composer.chipRadius == 6)
        // The track, the thumb and the dots.
        #expect(LoomTheme.Composer.effortTrackThickness == 6 && LoomTheme.Composer.effortThumb == 14 && LoomTheme.Composer.effortDot == 4)
        // The thumb fits in the track's hit height, so a click on it never misses.
        #expect(LoomTheme.Composer.effortTrackHeight >= LoomTheme.Composer.effortThumb)
        #expect(LoomTheme.Layout.minimumHitTarget.height <= LoomTheme.Composer.effortTrackHeight)
    }

    /// Ink v4 (DESIGN §0.3): the composer is elevation 2, a hairline and a small drop; no ring, no inner highlight.
    @Test func theCardIsLiftedWithALevelTwoDropOnly() {
        #expect(LoomTheme.Composer.depth == LoomTheme.Elevation.lift)
        let dark = LoomTheme.Composer.depth[.dark]
        #expect(dark.ring == nil && dark.drops.first?.blur == 2 && dark.drops.first?.y == 1)
    }

    @Test func theQueueStripIsTuckedBehindTheCardsTopEdge() {
        #expect(LoomTheme.Composer.queueInsetH == 14 && LoomTheme.Composer.queueOverlap == 12)
        #expect(LoomTheme.Composer.queuePaddingBottom >= LoomTheme.Composer.queueOverlap, "the last row clears the card")
        #expect(LoomTheme.Composer.queueRadius == 12)
    }

    /// The popover is 332 wide whatever the picker holds, and holds both groups, the effort and the keys line. Hosted
    /// offscreen: no window is ordered front.
    @MainActor @Test func theModelPopoverIs332WideAndHoldsTheGroupsTheEffortAndTheKeys() {
        func size(_ picker: ComposerModelPicker) -> CGSize {
            let host = NSHostingView(rootView: ComposerModelPopover(picker: picker, identifier: "composer-model", onPickModel: { _ in },
                                                                    onPickEffort: { _ in }, onResetEffort: {}, onDone: {}))
            host.frame = NSRect(x: 0, y: 0, width: 332, height: 900)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let withEffort = size(picker(chosen: "sonnet"))
        let without = size(picker(chosen: "sonnet", levels: []))
        #expect(withEffort.width == 332 && without.width == 332)
        // Seven rows of 30 and two heads of 28 are the least the list takes.
        #expect(withEffort.height > 7 * 30 + 2 * 28)
        #expect(without.height < withEffort.height, "no track and no level names without an effort setting")
    }
}
