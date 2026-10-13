import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

/// The subagent panel (FB4-5, P1): the model that holds a transcript's entries and runs its feed only while
/// the panel can be seen, and the catalog model's rules for opening and leaving it. Files are made in
/// temporary folders; the real `~/.claude` is never read.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SubagentPanelTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Panel model

    private struct Tree {
        let root: URL
        var projects: URL { root.appendingPathComponent("projects", isDirectory: true) }
        let transcript: URL

        init(text: String = "") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-panel-\(UUID())", isDirectory: true)
            let folder = root.appendingPathComponent("projects/-tmp-ws/s1/subagents", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            transcript = folder.appendingPathComponent("agent-a1.jsonl")
            try text.write(to: transcript, atomically: true, encoding: .utf8)
        }

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: transcript)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        func locate() -> @MainActor (String) async -> SubagentTranscriptFile? {
            let projects = projects
            return { path in SubagentTranscriptLocation.resolve(path: path, agentID: "a1", projectsDirectory: projects) }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func textLine(_ text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private let briefLine = #"{"type":"user","message":{"role":"user","content":"Map the module"}}"#

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return condition()
    }

    private func panel(_ tree: Tree, path: String? = nil, windowVisible: Bool = true, running: Bool = true) -> SubagentTranscriptModel {
        SubagentTranscriptModel(
            agentID: "a1", transcriptPath: path ?? tree.transcript.path, isRunning: running, windowVisible: windowVisible,
            coalescing: 0.03, locate: tree.locate())
    }

    @Test func theRingKeepsTheLastFourHundredEntriesAndTheBriefStaysApart() throws {
        let tree = try Tree()
        defer { tree.remove() }
        let model = panel(tree)
        func batch(_ range: Range<Int>, replaces: Bool = false) -> SubagentTranscriptBatch {
            SubagentTranscriptBatch(entries: range.map { .text("entry \($0)") }, replacesEarlier: replaces, omitsEarlier: false)
        }
        model.apply(SubagentTranscriptBatch(entries: [.brief("Map the module")] + batch(0..<300).entries,
                                            replacesEarlier: true, omitsEarlier: false))
        #expect(model.brief == "Map the module" && model.items.count == 300 && !model.omitsEarlier && model.phase == .live)
        model.apply(batch(300..<700))
        #expect(model.items.count == SubagentTranscriptModel.ringLimit)
        #expect(model.items.first?.entry == .text("entry 300") && model.items.last?.entry == .text("entry 699"))
        #expect(model.omitsEarlier && model.brief == "Map the module")
        #expect(model.items.map(\.id) == Array(model.items.first!.id..<(model.items.first!.id + 400)), "ids run on, one per entry")
        // The file started over: the ring starts over; a later brief in the batch replaces the old one.
        model.apply(SubagentTranscriptBatch(entries: [.brief("Second brief"), .text("fresh")], replacesEarlier: true, omitsEarlier: false))
        #expect(model.items.map(\.entry) == [.text("fresh")] && model.brief == "Second brief" && !model.omitsEarlier)
        // A restart that carries no brief keeps the one already known.
        model.apply(SubagentTranscriptBatch(entries: [.text("again")], replacesEarlier: true, omitsEarlier: true))
        #expect(model.brief == "Second brief" && model.omitsEarlier)
    }

    @Test func theFeedRunsOnlyWhileThePanelIsOnScreenAndTheWindowIsVisible() async throws {
        let tree = try Tree(text: briefLine + "\n" + textLine("first") + "\n")
        defer { tree.remove() }
        let model = panel(tree)
        #expect(!model.isFeeding, "a panel that was never shown reads nothing")
        model.setOnScreen(true)
        #expect(await waitUntil { model.isFeeding && model.items.count == 1 })
        #expect(model.brief == "Map the module" && model.items.first?.entry == .text("first"))

        try tree.append(textLine("second") + "\n")
        #expect(await waitUntil { model.items.count == 2 })

        // The window is hidden: the feed stops, and what is on the file meanwhile waits for the next show.
        model.setWindowVisible(false)
        #expect(!model.isFeeding)
        try tree.append(textLine("third") + "\n")
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.items.count == 2)
        model.setWindowVisible(true)
        #expect(await waitUntil { model.isFeeding && model.items.count == 3 })

        model.setOnScreen(false)
        #expect(!model.isFeeding)
        model.setOnScreen(true)
        #expect(await waitUntil { model.isFeeding })
        model.close()
        #expect(!model.isFeeding)
        model.setOnScreen(true)
        model.setWindowVisible(true)
        #expect(!model.isFeeding, "a closed panel does not start again")
    }

    @Test func aBatchThatArrivesAfterTheCloseChangesNothing() async throws {
        let tree = try Tree(text: briefLine + "\n" + textLine("first") + "\n")
        defer { tree.remove() }
        let model = panel(tree)
        model.setOnScreen(true)
        #expect(await waitUntil { model.items.count == 1 })
        // The write is read by the feed's queue about 30 ms later; the close comes first and does not wait for it.
        try tree.append(textLine("second") + "\n")
        model.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.items.count == 1 && !model.isFeeding)
        #expect(model.items.first?.entry == .text("first"))
    }

    @Test func aPanelThatIsHiddenBeforeItsFileIsLocatedNeverStartsAFeed() async throws {
        let tree = try Tree(text: textLine("x") + "\n")
        defer { tree.remove() }
        let inner = tree.locate()
        let model = SubagentTranscriptModel(
            agentID: "a1", transcriptPath: tree.transcript.path, isRunning: true, windowVisible: true, coalescing: 0.03,
            locate: { path in
                try? await Task.sleep(for: .milliseconds(150))
                return await inner(path)
            })
        model.setOnScreen(true)
        model.setOnScreen(false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!model.isFeeding && model.items.isEmpty)
    }

    @Test func aTranscriptThatCannotBeLocatedShowsAsUnavailableAndAPathThatArrivesLaterStartsIt() async throws {
        let tree = try Tree(text: textLine("x") + "\n")
        defer { tree.remove() }
        // The meta file was not found yet: no path.
        let model = SubagentTranscriptModel(
            agentID: "a1", transcriptPath: nil, isRunning: true, windowVisible: true, coalescing: 0.03, locate: tree.locate())
        model.setOnScreen(true)
        #expect(model.phase == .unavailable && !model.isFeeding)
        model.setTranscriptPath(tree.transcript.path)
        #expect(await waitUntil { model.isFeeding && model.phase == .live && model.items.count == 1 })
        // A path the location rules refuse is unavailable, too.
        let outside = try Tree()
        defer { outside.remove() }
        let refused = SubagentTranscriptModel(
            agentID: "a1", transcriptPath: outside.transcript.path, isRunning: true, windowVisible: true, coalescing: 0.03,
            locate: tree.locate())
        refused.setOnScreen(true)
        #expect(await waitUntil { refused.phase == .unavailable })
        #expect(!refused.isFeeding)
    }

    @Test func entriesReadAsClaudeWritesThem() {
        #expect(TranscriptEntryRow.thoughtText(milliseconds: 6_400) == "Thought for 6s")
        #expect(TranscriptEntryRow.thoughtText(milliseconds: 200) == "Thought for 1s")
        #expect(TranscriptEntryRow.thoughtText(milliseconds: nil) == "Thought")
        #expect(TranscriptEntryRow.resultText(firstLine: "Wrote 96 lines", lineCount: 1) == "Wrote 96 lines")
        #expect(TranscriptEntryRow.resultText(firstLine: "38 matches", lineCount: 38) == "38 matches  (+37 lines)")
        #expect(TranscriptEntryRow.resultText(firstLine: "", lineCount: 0) == "(no output)")
    }

    // MARK: Header

    @Test func theHeaderNamesTheSubagentAndItsStateReadsRunningOrFinished() {
        var record = SubagentRecord(id: "a1", agentType: "implementer", description: "draft:core-map", startedAt: t0)
        #expect(SubagentHeaderRow.agentTitle(record) == "implementer · draft:core-map")
        record.description = nil
        #expect(SubagentHeaderRow.agentTitle(record) == "implementer")
        #expect(SubagentHeaderRow.agentTitle(nil) == "Subagent")

        #expect(SubagentPillContent(record: record, now: t0.addingTimeInterval(10)).label == "Running")
        let running = SubagentPillContent(record: record, now: t0.addingTimeInterval(4 * 60 + 5))
        #expect(running.label == "Running 4m" && running.indicator == .working)
        record.endedAt = t0.addingTimeInterval(7 * 60)
        let finished = SubagentPillContent(record: record, now: t0.addingTimeInterval(3_600))
        #expect(finished.label == "Finished 7m" && finished.indicator == .idle)
        #expect(StatePillStyle(.working, label: "Running 4m")?.label == "Running 4m")
        #expect(StatePillStyle(.working)?.label == "Working")
        #expect(StatePillStyle(.idle, label: "Finished 7m")?.showsIndicator == false)
    }

    // MARK: Catalog model

    private struct Rig {
        let root: URL
        let hub: SessionEventHub
        let model: CatalogModel
        let ids: [UUID]
        let intents: TranscriptIntents

        @MainActor func cleanup() {
            model.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Resolves transcripts against a temporary projects folder, the way the controller does against the profile's.
    @MainActor
    final class TranscriptIntents: ConversationIntents {
        var projects: URL?
        private(set) var asked: [String] = []
        func start(provider: ManagedSession.Provider, projectID: UUID?) {}
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { nil }
        func subagentTranscript(path: String, agentID: String) async -> SubagentTranscriptFile? {
            asked.append(path)
            guard let projects else { return nil }
            return SubagentTranscriptLocation.resolve(path: path, agentID: agentID, projectsDirectory: projects)
        }
    }

    private func makeRig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-panel-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var ids: [UUID] = []
        for index in 0..<2 {
            let session = ManagedSession(provider: .claude, providerConversationID: "conv-\(index)", workingDirectory: root.path)
            try await catalog.insertSession(
                session, title: "Session \(index)", createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle)
            ids.append(session.id)
        }
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub, preferences: UIPreferencesStore(url: root.appendingPathComponent("prefs.json")))
        let intents = TranscriptIntents()
        model.intents = intents
        await model.start()
        return Rig(root: root, hub: hub, model: model, ids: ids, intents: intents)
    }

    private func record(_ id: String = "a1", running: Bool = true, path: String? = nil) -> SubagentRecord {
        SubagentRecord(id: id, agentType: "implementer", description: "map the module", startedAt: t0,
                       endedAt: running ? nil : t0.addingTimeInterval(60), transcriptPath: path)
    }

    /// A live run for session `index` with `records`, applied through the hub like the runtime does.
    @discardableResult
    private func goLive(_ rig: Rig, _ index: Int, _ records: [SubagentRecord]) async throws -> UUID {
        let run = UUID()
        await rig.hub.publish(sessionID: rig.ids[index], change: .runStarted(run))
        await rig.hub.publish(sessionID: rig.ids[index], change: .subagents(records))
        let applied = await waitUntil { rig.model.liveStates[rig.ids[index]]?.subagents == records }
        #expect(applied)
        return run
    }

    @Test func aSubagentRowOpensItsPanelAndSelectsTheParentSession() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        try await goLive(rig, 1, [record()])
        rig.model.select(rig.ids[0])
        #expect(rig.model.viewedSubagent == nil)

        // The row's tap is "open subagent" for a running and a finished one.
        let content = SubagentTreeContent(records: [record("r"), record("f", running: false)], now: t0, finishedExpanded: true, runningExpanded: false)
        #expect(content.rows.filter(\.opensSubagent).map(\.id) == ["r", "f"])

        rig.model.openSubagent("a1", in: rig.ids[1])
        #expect(rig.model.selectedSessionID == rig.ids[1])
        #expect(rig.model.viewedSubagent == ViewedSubagent(sessionID: rig.ids[1], agentID: "a1"))
        let panel = try #require(rig.model.subagentPanel)
        #expect(panel.agentID == "a1" && panel.isRunning && !panel.isFeeding)
        let state = try #require(rig.model.subagentPanelState)
        #expect(state.agentID == "a1" && state.entryCount == 0 && state.isRunning && !state.isFeeding)

        // A subagent the session does not list opens nothing and changes nothing.
        rig.model.openSubagent("ghost", in: rig.ids[1])
        #expect(rig.model.viewedSubagent?.agentID == "a1")
        rig.model.closeSubagent()
        rig.model.openSubagent("a1", in: rig.ids[0])
        #expect(rig.model.viewedSubagent == nil && rig.model.selectedSessionID == rig.ids[1], "a session with no such subagent")
    }

    @Test func everyWayBackReturnsToTheTerminal() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let run = try await goLive(rig, 1, [record()])
        let parent = rig.ids[1]
        func open() {
            rig.model.openSubagent("a1", in: parent)
            #expect(rig.model.viewedSubagent != nil)
        }

        // Esc and the Session control.
        open(); rig.model.closeSubagent()
        #expect(rig.model.viewedSubagent == nil && rig.model.subagentPanel == nil && rig.model.selectedSessionID == parent)
        // A click on the parent card, the same session's tab, and another session.
        open(); rig.model.selectFromList(parent)
        #expect(rig.model.viewedSubagent == nil && rig.model.selectedSessionID == parent)
        open(); rig.model.selectTab(parent)
        #expect(rig.model.viewedSubagent == nil)
        open(); rig.model.select(rig.ids[0])
        #expect(rig.model.viewedSubagent == nil && rig.model.selectedSessionID == rig.ids[0])
        // A selection of another session never opens a panel of its own.
        rig.model.select(parent)
        #expect(rig.model.viewedSubagent == nil)

        // The record drops out at the next real prompt.
        open()
        await rig.hub.publish(sessionID: parent, change: .subagents([]))
        #expect(await waitUntil { rig.model.viewedSubagent == nil })
        #expect(rig.model.subagentPanel == nil)

        // The run ends.
        await rig.hub.publish(sessionID: parent, change: .subagents([record()]))
        #expect(await waitUntil { rig.model.liveStates[parent]?.subagents.count == 1 })
        open()
        await rig.hub.publish(sessionID: parent, change: .runEnded(run, .processExited))
        #expect(await waitUntil { rig.model.viewedSubagent == nil })
        #expect(rig.model.subagentPanel == nil && rig.model.selectedSessionID == parent)
    }

    @Test func thePanelFollowsItsSubagentsRecord() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let tree = try Tree(text: textLine("hello") + "\n")
        defer { tree.remove() }
        rig.intents.projects = tree.projects
        rig.model.setWindowVisible(true)
        // The meta file is not read yet: no path.
        try await goLive(rig, 1, [record()])
        rig.model.openSubagent("a1", in: rig.ids[1])
        let panel = try #require(rig.model.subagentPanel)
        panel.setOnScreen(true)
        #expect(panel.phase == .unavailable)

        // Its meta file is found: the path arrives with the record and the panel starts reading.
        await rig.hub.publish(sessionID: rig.ids[1], change: .subagents([record(path: tree.transcript.path)]))
        #expect(await waitUntil { panel.isFeeding && panel.items.count == 1 })
        #expect(rig.intents.asked == [tree.transcript.path])
        #expect(panel.isRunning)

        // It finishes: the panel stays, and says so.
        await rig.hub.publish(sessionID: rig.ids[1], change: .subagents([record(running: false, path: tree.transcript.path)]))
        #expect(await waitUntil { !panel.isRunning })
        #expect(rig.model.viewedSubagent != nil && rig.model.subagentPanelState?.isRunning == false)
    }

    @Test func theFeedStopsWhenTheWindowIsHiddenAndStartsWhenItIsShownAgain() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let tree = try Tree(text: textLine("hello") + "\n")
        defer { tree.remove() }
        rig.intents.projects = tree.projects
        rig.model.setWindowVisible(true)
        try await goLive(rig, 1, [record(path: tree.transcript.path)])
        rig.model.openSubagent("a1", in: rig.ids[1])
        let panel = try #require(rig.model.subagentPanel)
        panel.setOnScreen(true)
        #expect(await waitUntil { panel.isFeeding && panel.items.count == 1 })

        rig.model.setWindowVisible(false)
        #expect(!panel.isFeeding)
        #expect(rig.model.subagentPanelState?.isFeeding == false)
        rig.model.setWindowVisible(true)
        #expect(await waitUntil { panel.isFeeding })

        // Closing the panel ends the feed with it.
        rig.model.closeSubagent()
        #expect(!panel.isFeeding)
    }

    // MARK: Hosted

    @Test func theDetailPaneShowsThePanelInPlaceOfTheTerminalAndGivesItBack() async throws {
        enableAccessibilityTree()
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let line = { (block: String) in
            #"{"type":"assistant","message":{"role":"assistant","content":[\#(block)]}}"#
        }
        let tree = try Tree(text: #"{"type":"user","message":{"role":"user","content":"Map the module"}}"# + "\n"
            + line(#"{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"CoreConfig.java"}}"#) + "\n")
        defer { tree.remove() }
        rig.intents.projects = tree.projects
        rig.model.setWindowVisible(true)
        try await goLive(rig, 1, [record(path: tree.transcript.path)])
        rig.model.select(rig.ids[1])
        await rig.model.settle()

        let hosting = NSHostingController(rootView: DetailView(model: rig.model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 900, height: 600))
        window.isReleasedWhenClosed = false // never ordered front: the layout runs against a window nobody sees
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(100))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        func labels() -> [String] { accessibilityElements(in: hosting.view).compactMap { $0.accessibilityLabel?() } }
        func roles() -> [String] { accessibilityElements(in: hosting.view).compactMap { $0.accessibilityRole?()?.rawValue } }
        try await settle()
        #expect(!labels().contains("Back to the session"), "the session's own header while no panel is open")

        rig.model.openSubagent("a1", in: rig.ids[1])
        try await settle()
        #expect(labels().contains("Back to the session"), "the Session control is in the header")
        // The view put the panel on screen: the feed runs and the file's entries are drawn.
        let panel = try #require(rig.model.subagentPanel)
        #expect(await waitUntil { panel.isFeeding && panel.items.count == 1 })
        try await settle()
        #expect(roles().contains("AXScrollArea"), "the transcript is drawn")
        #expect(roles().count(where: { $0 == "AXStaticText" }) >= 4, "the crumb, the pill and the rows are text")

        rig.model.closeSubagent()
        try await settle()
        #expect(!labels().contains("Back to the session") && !panel.isFeeding)
    }

    @Test func openingTheShownSubagentAgainKeepsItsPanelReading() async throws {
        let rig = try await makeRig()
        defer { rig.cleanup() }
        let tree = try Tree(text: #"{"type":"user","message":{"role":"user","content":"Map the module"}}"# + "\n"
            + #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reading"}]}}"# + "\n")
        defer { tree.remove() }
        rig.intents.projects = tree.projects
        rig.model.setWindowVisible(true)
        try await goLive(rig, 1, [record(path: tree.transcript.path)])
        rig.model.select(rig.ids[1])
        await rig.model.settle()

        let hosting = NSHostingController(rootView: DetailView(model: rig.model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 900, height: 600))
        window.isReleasedWhenClosed = false // never ordered front: the layout runs against a window nobody sees
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(100))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        rig.model.openSubagent("a1", in: rig.ids[1])
        try await settle()
        let first = try #require(rig.model.subagentPanel)
        #expect(await waitUntil { first.isFeeding && first.items.count == 1 })

        // A second click on the same row changes nothing: the panel goes on reading.
        rig.model.openSubagent("a1", in: rig.ids[1])
        try await settle()
        #expect(rig.model.subagentPanel === first && first.isFeeding)

        // Closed and opened again before the view could go away: the new panel is put on screen as well.
        rig.model.closeSubagent()
        rig.model.openSubagent("a1", in: rig.ids[1])
        try await settle()
        let second = try #require(rig.model.subagentPanel)
        #expect(second !== first)
        #expect(await waitUntil { second.isFeeding && second.items.count == 1 })
    }
}
