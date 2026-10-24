import Foundation
import Testing
import LoomCore
@testable import LoomChat
@testable import LoomRemora
@testable import LoomCatalogUI

/// Home's Put in Draft (D-95, DESIGN §20 Tiles): the line goes below whatever the session's composer holds and the session opens with
/// its composer asked for the keyboard; where no composer can be filled the button reads Copy to Clipboard, copies, and then reads
/// Copied until Home's next read. Also Home's Remora read key, which changes once when a call ends (FB5-11). No view; the rig's host is
/// never called.
@MainActor
struct RemoraHomeDraftTests {
    /// What a target did, in order.
    private final class Log {
        var text: String
        var steps: [String] = []
        var copied: [String] = []
        init(text: String) { self.text = text }
    }

    private func composerTarget(_ log: Log, copyReason: RemoraCopyReason? = nil) -> RemoraHomeDraftTarget {
        RemoraHomeDraftTarget(
            sessionID: UUID(), copyReason: copyReason, composerText: { log.text },
            setComposerText: { log.text = $0; log.steps.append("set") }, focusComposer: { log.steps.append("focus") }, drafts: nil,
            open: { log.steps.append("open") })
    }

    private func store() -> (ChatDraftStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-remora-drafts-\(UUID())", isDirectory: true)
        return (ChatDraftStore(directory: directory), directory)
    }

    // MARK: Placing

    @Test func anEmptyComposerGetsTheLineThenTheSessionOpensAndItsComposerIsAskedForFocus() {
        let log = Log(text: "")
        let target = composerTarget(log)
        #expect(RemoraHomeDraft.plan(target) == .place)
        #expect(RemoraHomeDraft.perform(target, line: "Run the checks.", copy: { log.copied.append($0) }) == .placed)
        #expect(log.text == "Run the checks." && log.copied.isEmpty, "placed, not copied")
        #expect(log.steps == ["set", "open", "focus"], "the line lands, then the session opens with its composer focused")
    }

    @Test func aComposerWithTextKeepsItAndTheLineLandsBelowAfterABlankLine() {
        let log = Log(text: "half a thought")
        #expect(RemoraHomeDraft.perform(composerTarget(log), line: "Run the checks.", copy: { log.copied.append($0) }) == .placed)
        #expect(log.text == "half a thought\n\nRun the checks." && log.copied.isEmpty)
        #expect(log.steps == ["set", "open", "focus"])
        // A text that already ends in a line break, or a blank line, gets only what makes one blank line.
        #expect(RemoraHomeDraft.appending("Next.", to: "one\n") == "one\n\nNext.")
        #expect(RemoraHomeDraft.appending("Next.", to: "one\n\n") == "one\n\nNext.")
        #expect(RemoraHomeDraft.appending("Next.", to: " \n") == "Next.", "a blank composer is an empty one")
    }

    @Test func aSessionThatIsNotRunningGetsTheLineInItsSavedDraftAndOpens() throws {
        let (drafts, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        var steps: [String] = []
        var copied: [String] = []
        let target = RemoraHomeDraftTarget(sessionID: id, copyReason: nil, composerText: nil, setComposerText: nil, focusComposer: nil,
                                           drafts: drafts, open: { steps.append("open") })
        #expect(RemoraHomeDraft.perform(target, line: "First line.", copy: { copied.append($0) }) == .placed)
        #expect(try drafts.load(sessionID: id)?.text == "First line." && steps == ["open"] && copied.isEmpty)
        // A saved draft with text and an attachment keeps both; the line goes below the text.
        let image = ChatDraft.Attachment(id: "a1", kind: .image, mediaType: "image/png")
        try drafts.save(ChatDraft(text: "my own words", attachments: [image]), sessionID: id)
        #expect(RemoraHomeDraft.perform(target, line: "Second line.", copy: { copied.append($0) }) == .placed)
        let saved = try #require(try drafts.load(sessionID: id))
        #expect(saved.text == "my own words\n\nSecond line." && saved.attachments == [image] && copied.isEmpty)
    }

    @Test func aSavedDraftThatCannotBeReadIsLeftAloneTheLineIsCopiedAndNothingOpens() throws {
        let (drafts, directory) = store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: drafts.url(for: id))
        var opened = 0
        var copied: [String] = []
        let target = RemoraHomeDraftTarget(sessionID: id, copyReason: nil, composerText: nil, setComposerText: nil, focusComposer: nil,
                                           drafts: drafts, open: { opened += 1 })
        let result = RemoraHomeDraft.perform(target, line: "Line.", copy: { copied.append($0) })
        #expect(result == .copiedNotSaved && copied == ["Line."] && opened == 0)
        #expect(HomeRemoraText.draftButton(plan: .place, result: result).title == "Copied")
    }

    // MARK: Copying

    @Test(arguments: [RemoraCopyReason.terminal, .codex])
    func aSessionWhoseComposerCannotBeFilledReadsCopyToClipboardCopiesThenReadsCopied(reason: RemoraCopyReason) {
        let log = Log(text: "")
        let target = composerTarget(log, copyReason: reason)
        let plan = RemoraHomeDraft.plan(target)
        #expect(plan == .copy(reason))
        let before = HomeRemoraText.draftButton(plan: plan, result: nil)
        #expect(before.title == "Copy to Clipboard" && before.hint == before.help)
        #expect(before.help == (reason == .terminal ? "This session runs in the terminal, so the line is copied"
            : "Sphyrna cannot open Codex sessions yet, so the line is copied"))
        let result = RemoraHomeDraft.perform(target, line: "Run the checks.", copy: { log.copied.append($0) })
        #expect(result == .copied(reason) && log.copied == ["Run the checks."])
        #expect(log.text.isEmpty && log.steps.isEmpty, "nothing placed, nothing opened")
        #expect(HomeRemoraText.draftButton(plan: plan, result: result).title == "Copied")
    }

    @Test func putInDraftIsTheLabelOnlyWhereTheLineWillBePlaced() {
        let place = HomeRemoraText.draftButton(plan: .place, result: nil)
        #expect(place.title == "Put in Draft" && place.help == nil, "the hover popover says where it goes")
        #expect(place.hint.contains("opens the session"))
        #expect(HomeRemoraText.draftButton(plan: .copy(.terminal), result: nil).title != "Put in Draft")
    }

    /// The model's side: a session with no Chat face is copied, a Codex session says so, and opening a session selects it as its
    /// sidebar row does.
    @Test func theModelCopiesForATerminalOrCodexSessionAndOpensBySelecting() async throws {
        let rig = try await RemoraHomeRig.make(
            seeds: [.init(title: "Billing webhook", project: 0, ago: 600),
                    .init(title: "Codex port", project: 0, ago: 900, provider: .codex)],
            withHost: false)
        defer { Task { await rig.finish() } }
        let terminal = try #require(try await rig.catalog.listedSession(id: rig.sessions[0]))
        let codex = try #require(try await rig.catalog.listedSession(id: rig.sessions[1]))
        #expect(rig.model.remoraHomeDraftPlan(for: terminal) == .copy(.terminal))
        #expect(rig.model.remoraHomeDraftPlan(for: codex) == .copy(.codex))
        var copied: [String] = []
        #expect(rig.model.putRemoraLineInDraft("Line.", record: terminal, copy: { copied.append($0) }) == .copied(.terminal))
        #expect(copied == ["Line."] && rig.model.selectedSessionID == nil, "a copy opens nothing")
        rig.model.remoraHomeDraftTarget(for: terminal).open()
        #expect(rig.model.selectedSessionID == rig.sessions[0])
    }

    // MARK: The result clears

    @Test func theResultClearsOnHomesNextReadOrWhenTheLineChanges() async throws {
        let rig = try await RemoraHomeRig.make(seeds: [.init(title: "Billing webhook", project: 0, ago: 600)])
        defer { Task { await rig.finish() } }
        let reads = HomeRemoraReads(baselineUndo: nil)
        await reads.read(model: rig.model)
        let ui = HomeRemoraUI()
        let id = rig.sessions[0]
        ui.placed[id] = HomeRemoraUI.Placed(result: .copied(.terminal), line: "Run the checks.", read: reads.generation)
        #expect(ui.placedResult(id, line: "Run the checks.", read: reads.generation) == .copied(.terminal))
        #expect(ui.placedResult(id, line: "Another step.", read: reads.generation) == nil, "a new line brings the button back")
        await reads.read(model: rig.model)
        #expect(ui.placedResult(id, line: "Run the checks.", read: reads.generation) == nil, "the next read brings the button back")
        #expect(!rig.ranAProcess)
    }

    // MARK: FB5-11

    /// A call's end sets the answer, the kept brief and the idle phase one after another; Home's read key takes them in one change.
    @Test func homesReadKeyChangesOnceWhenACallEnds() async throws {
        let rig = try await RemoraHomeRig.make(seeds: [.init(title: "Billing webhook", project: 0, ago: 600)], withHost: false)
        defer { Task { await rig.finish() } }
        let model = rig.model
        let state = model.remora
        state.phase = .briefing
        var key = model.homeRemoraReadKey
        var changes = 0
        func note() {
            let next = model.homeRemoraReadKey
            if next != key { changes += 1; key = next }
        }
        let answer = RemoraHostAnswer(
            kind: .brief, question: nil,
            answer: RemoraAnswer(text: "Two projects moved.", cited: [], chips: [], drafts: [], proposedFacts: [], block: .valid, model: nil,
                                 usage: RemoraTokenUsage(input: 2, cacheCreation: 0, cacheRead: 0, output: 64), costUSD: nil,
                                 duration: .milliseconds(900)),
            proposedFacts: [], readSessionIDs: [rig.sessions[0]], footer: "read 1 session", journaled: true)
        state.finish(.answered(answer))
        note()
        state.keptBrief = RemoraKeptBrief(startedAt: rig.base, text: "Two projects moved.", readSessionIDs: [rig.sessions[0]])
        note()
        state.phase = .idle
        note()
        #expect(changes == 1, "the key changed \(changes) times for one call's end")
        #expect(key.settled?.answer == answer && key.settled?.kept != nil)
    }
}
