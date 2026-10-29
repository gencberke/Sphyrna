import AppKit
import Foundation
import LoomCore
import LoomTerminal
import SwiftTerm
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

// What the inspector's tests share: a catalog of Claude sessions whose terminals are real terminal views with
// a spy on their size, and an offscreen window. The window tests host the real `DetailView` in it and order it in
// (LoomWindowTests/InspectorRigHosted.swift).

let inspectorT0 = Date(timeIntervalSince1970: 1_000_000)

/// Answers the model's questions with a real terminal view per session.
@MainActor
final class InspectorIntents: ConversationIntents {
    var terminals: [UUID: NSView] = [:]
    func start(provider: ManagedSession.Provider, projectID: UUID?) {}
    func resume(sessionID: UUID) {}
    func stop(sessionID: UUID) {}
    func answer(sessionID: UUID, requestID: String, accept: Bool) {}
    func viewed(sessionID: UUID) {}
    func terminalView(sessionID: UUID) -> NSView? { terminals[sessionID] }
    func subagentTranscript(path: String, agentID: String) async -> SubagentTranscriptFile? { nil }
}

/// Stands between a terminal view and its surface. `sizes` is every grid change the view reported (each one
/// asks the surface for a PTY resize) and `frames` every size the view was given, in order; both pass on.
@MainActor
final class TerminalSizeSpy: NSObject, TerminalViewDelegate {
    let surface: TerminalSurface
    private(set) var sizes: [String] = []
    private(set) var frames: [CGSize] = []
    var observer: (any NSObjectProtocol)?

    init(_ surface: TerminalSurface) {
        self.surface = surface
        super.init()
        surface.view.terminalDelegate = self
        let view = surface.view
        frames = [view.frame.size]
        observer = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.frames.last != view.frame.size else { return }
                self.frames.append(view.frame.size)
            }
        }
    }

    /// The sizes the view really had, in order. A view taken out of the window is zero for a moment and comes
    /// back to the size it had; that is not a size change.
    var laidOutSizes: [CGSize] {
        var result: [CGSize] = []
        for size in frames where size.width > 0 && size.height > 0 && result.last != size { result.append(size) }
        return result
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sizes.append("\(newCols)x\(newRows)")
        surface.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) { surface.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { surface.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
}

@MainActor
struct InspectorRig {
    let root: URL
    let hub: SessionEventHub
    let model: CatalogModel
    let ids: [UUID]
    let intents: InspectorIntents
    let spies: [TerminalSizeSpy]
    let window: NSWindow

    static func make(sessions: Int = 2) async throws -> InspectorRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-inspector-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        var ids: [UUID] = []
        for index in 0..<sessions {
            let session = ManagedSession(provider: .claude, providerConversationID: "conv-\(index)", workingDirectory: root.path)
            try await catalog.insertSession(
                session, title: "Session \(index)", createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle)
            ids.append(session.id)
        }
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("prefs.json")))
        let intents = InspectorIntents()
        var spies: [TerminalSizeSpy] = []
        for id in ids {
            let surface = TerminalSurface()
            spies.append(TerminalSizeSpy(surface))
            intents.terminals[id] = surface.view
        }
        model.intents = intents
        await model.start()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return InspectorRig(root: root, hub: hub, model: model, ids: ids, intents: intents, spies: spies, window: window)
    }

    func cleanup() {
        window.contentView = nil
        window.close()
        model.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Lets SwiftUI and AppKit finish whatever a change started (layout, the inspector, any animation).
    func settle() async {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// The accessibility labels of the hosted window.
    func labels() -> [String] {
        guard let view = window.contentView else { return [] }
        return accessibilityElements(in: view).compactMap { $0.accessibilityLabel?() }
    }

    /// A live run for session `index` with `records`, applied through the hub like the runtime does.
    func goLive(_ index: Int, _ records: [SubagentRecord]) async {
        await hub.publish(sessionID: ids[index], change: .runStarted(UUID()))
        await hub.publish(sessionID: ids[index], change: .subagents(records))
        let applied = await inspectorWaitUntil { model.liveStates[ids[index]]?.subagents == records }
        #expect(applied)
    }
}

@MainActor
func inspectorWaitUntil(_ seconds: TimeInterval = 6, _ condition: () -> Bool) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    repeat {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(15))
    } while ProcessInfo.processInfo.systemUptime < deadline
    return false
}

func inspectorRecord(_ id: String = "a1", running: Bool = true, type: String = "implementer",
                     description: String? = "map the module", depth: Int = 1, started: Date? = nil) -> SubagentRecord {
    SubagentRecord(id: id, agentType: type, description: description, depth: depth,
                   startedAt: started ?? inspectorT0, endedAt: running ? nil : inspectorT0.addingTimeInterval(41))
}
