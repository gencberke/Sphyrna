import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

extension WindowEventTests {
@MainActor
@Suite(.timeLimit(.minutes(3)))
struct InspectorLayoutWindowTests {
    private func counts(_ rig: InspectorRig) -> (grids: Int, sizes: Int) {
        (rig.spies[0].sizes.count, rig.spies[0].laidOutSizes.count)
    }

    private func resize(_ rig: InspectorRig, toWidth width: CGFloat) async {
        rig.window.setContentSize(NSSize(width: width, height: 700))
        await rig.settle()
    }

    @Test func aNarrowPaneDrawsTheInspectorOverTheTerminalAndResizesNothing() async throws {
        enableAccessibilityTree()
        let rig = try await InspectorRig.make(hosted: true)
        defer { rig.cleanup() }
        await resize(rig, toWidth: 780) // a 764 pt pane: 436 pt would be left beside a 328 pt column
        rig.model.select(rig.ids[0])
        await rig.settle()
        let before = counts(rig)
        let width = try #require(rig.spies[0].laidOutSizes.last).width

        rig.model.toggleInspector()
        await rig.settle()
        #expect(rig.model.inspector.isOpen(for: rig.ids[0]))
        #expect(rig.labels().contains("Overview"), "the inspector is on screen")
        let after = counts(rig)
        #expect(after == before, "the terminal was resized by an overlay: \(rig.spies[0].laidOutSizes)")
        #expect(rig.spies[0].laidOutSizes.last?.width == width)

        // Closing it changes nothing either.
        rig.model.toggleInspector()
        await rig.settle()
        #expect(counts(rig) == before)
    }

    @Test func crossingTheThresholdResizesTheTerminalOnceEachWayAndNoMore() async throws {
        let rig = try await InspectorRig.make(hosted: true)
        defer { rig.cleanup() }
        rig.model.select(rig.ids[0])
        rig.model.toggleInspector()
        await rig.settle()
        // The panes are 16 pt narrower than the window; the column holds from a 808 pt pane (a 824 pt window).
        var previous = counts(rig)
        var placements: [InspectorPlacement] = []
        for width: CGFloat in [840, 832, 824, 816, 808, 816, 824, 832, 840] {
            await resize(rig, toWidth: width)
            let now = counts(rig)
            #expect(now.sizes == previous.sizes + 1, "window \(Int(width)): \(rig.spies[0].laidOutSizes.suffix(3))")
            #expect(now.grids <= previous.grids + 1)
            placements.append(InspectorPlacement.of(open: true, detailWidth: width - 16))
            previous = now
        }
        #expect(placements == [.column, .column, .column, .overlay, .overlay, .overlay, .column, .column, .column])
    }
}
}

extension WindowEventTests {
/// The chat stream's width follows its container (Release A UI fix round, item 2): the real `DetailView` showing a
/// stopped session's chat with the inspector open, the window grown from 780 to 1220 pt.
@MainActor
@Suite(.timeLimit(.minutes(3)))
struct ChatStreamWidthTests {
    private struct Rig {
        let root: URL
        let model: CatalogModel
        let window: NSWindow
    }

    private final class Intents: ConversationIntents {
        func start(provider: ManagedSession.Provider, projectID: UUID?) {}
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { nil }
    }

    private static let long = "Only the logger keeps a static buffer too, but it is lock-protected, so I left it alone; "
        + "nothing else reads the old static, and the suite passes ten runs in a row after the change."

    private func rig(width: CGFloat, height: CGFloat) async throws -> Rig {
        ChatSessionMemoryStore.removeAll()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-width-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("project", isDirectory: true)
        let config = root.appendingPathComponent("claude-config", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let projects = config.appendingPathComponent("projects/-tmp-chat-width", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let projectID = try await catalog.addProject(path: folder.path).project.id
        let claudeID = UUID().uuidString.lowercased()
        let session = ManagedSession(provider: .claude, providerConversationID: claudeID, workingDirectory: folder.path)
        try await catalog.insertSession(session, title: "Stopped", lifecycle: .idle, projectID: projectID)
        var lines: [String] = []
        for turn in 0..<6 {
            lines += ChatFixture.turn(turn, answer: Self.long + " (\(turn))", start: turn * 10)
            lines[lines.count - 2] = ChatFixture.user(Self.long + " \(turn)", uuid: "u\(turn)", at: turn * 10)
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: projects.appendingPathComponent("\(claudeID).jsonl"), atomically: true, encoding: .utf8)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        model.intents = Intents()
        model.setClaudeConfigDirectory(config)
        await model.start()
        model.readOnlyChatEnabled = true // the frozen Chat face's read-only chat (D-100)
        model.select(session.id)
        _ = await inspectorWaitUntil { model.selectedRow?.id == session.id }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DetailView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
        window.orderFrontRegardless()
        return Rig(root: root, model: model, window: window)
    }

    private func stream(in view: NSView) -> ChatScrollView? {
        if let found = view as? ChatScrollView { return found }
        for child in view.subviews { if let found = stream(in: child) { return found } }
        return nil
    }

    private func settle(_ rig: Rig) async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(80))
            rig.window.contentView?.layoutSubtreeIfNeeded()
            rig.window.displayIfNeeded()
        }
    }

    /// What the stream holds at the width its container gives it now: the column as wide as the visible area, every
    /// drawn row as wide as the column, and each drawn row's height measured at that width.
    private func expectFollowsContainer(_ rig: Rig, _ note: String) throws {
        let content = try #require(rig.window.contentView)
        let scroll = try #require(stream(in: content))
        let controller = try #require(scroll.controller)
        let visible = scroll.contentSize.width
        var problems: [String] = []
        if visible <= 100 { problems.append("the stream has no width") }
        let column = controller.table.tableColumns[0].width
        if abs(column - visible) >= 1.5 { problems.append("the column is \(column) wide in a \(visible) pt view") }
        let range = controller.table.rows(in: controller.table.visibleRect)
        if range.length == 0 { problems.append("no rows are drawn") }
        for index in range.location..<(range.location + range.length) {
            guard let cell = controller.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatRowCell else { continue }
            if abs(cell.frame.width - visible) >= 1.5 { problems.append("row \(index) is \(cell.frame.width) wide") }
            if controller.heights.measured(controller.rows[index].id, width: visible) == nil {
                problems.append("row \(index) was not measured at \(visible)")
            }
        }
        #expect(problems.isEmpty, "\(note) (\(visible) pt view, table \(controller.table.frame.width)): \(problems.prefix(4))")
    }

    @Test func growingTheWindowWithTheInspectorOpenKeepsTheChatAsWideAsItsContainer() async throws {
        #if DEBUG
        ChatPresentation.verifiesRows = true
        ChatPresentation.onMismatch = { Issue.record("\($0)") }
        defer { ChatPresentation.verifiesRows = false; ChatPresentation.onMismatch = nil }
        #endif
        let rig = try await rig(width: 480, height: 500) // the detail pane of a 780 pt window beside a 300 pt sidebar
        defer { rig.window.contentView = nil; rig.window.close(); rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        _ = await inspectorWaitUntil { rig.model.detailRoute == .chat(sessionID: rig.model.selectedSessionID ?? UUID()) }
        await settle(rig)
        try expectFollowsContainer(rig, "narrow, inspector closed")

        rig.model.toggleInspector()
        await settle(rig)
        try expectFollowsContainer(rig, "narrow, inspector open")

        rig.window.setContentSize(NSSize(width: 920, height: 780)) // a 1220 pt window's pane
        await settle(rig)
        try expectFollowsContainer(rig, "grown to 920 pt")

        // And back, and once more up: the width follows on every pass, not only the first.
        rig.window.setContentSize(NSSize(width: 600, height: 600))
        await settle(rig)
        try expectFollowsContainer(rig, "shrunk to 600 pt")
        rig.window.setContentSize(NSSize(width: 920, height: 780))
        await settle(rig)
        try expectFollowsContainer(rig, "grown again")
    }
}
}
