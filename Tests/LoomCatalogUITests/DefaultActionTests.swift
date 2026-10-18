import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import Testing
import LoomCore
import LoomTerminal
@testable import LoomCatalogUI

/// A stand-in for the live terminal: it takes first responder and records the keys it receives.
@MainActor
private final class KeyRecordingTerminal: NSView {
    var keys: [String] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { keys.append(event.characters ?? "") }
}

/// Records what the real terminal view would send to the provider.
@MainActor
private final class InputRecorder: NSObject, TerminalViewDelegate {
    var sent: [[UInt8]] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

@MainActor
private final class AnswerRecordingIntents: ConversationIntents {
    let terminal: NSView?
    init(terminal: NSView?) { self.terminal = terminal }
    var answers: [(String, Bool)] = []
    func start(provider: ManagedSession.Provider, projectID: UUID?) {}
    func resume(sessionID: UUID) {}
    func stop(sessionID: UUID) {}
    func answer(sessionID: UUID, requestID: String, accept: Bool) { answers.append((requestID, accept)) }
    func viewed(sessionID: UUID) {}
    func terminalView(sessionID: UUID) -> NSView? { terminal }
}

/// Window tests that send key and mouse events share the app's key window and first responder, so they run
/// one at a time (Swift Testing runs separate suites in parallel).
@Suite(.serialized)
enum WindowEventTests {}

extension WindowEventTests {
/// I3: with an approval card above a live terminal, Return belongs to the terminal.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct DefaultActionTests {
    private func returnKey(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    /// A window with the real detail view: an approval card above `terminal`, which has the focus.
    private func hostApprovalCard(terminal: NSView?, root: URL, provider: ManagedSession.Provider = .claude) async throws
        -> (window: NSWindow, intents: AnswerRecordingIntents) {
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let session = ManagedSession(provider: provider, workingDirectory: root.path)
        try await catalog.insertSession(session, title: "Needs approval", lifecycle: .idle)
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let intents = AnswerRecordingIntents(terminal: terminal)
        model.intents = intents
        await model.start()
        await model.stopAndWait()
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()
        model.apply(try #require(await iterator.next()))
        await hub.publish(sessionID: session.id, change: .runStarted(UUID()))
        await hub.publish(sessionID: session.id, change: .userRequests(
            [ProviderUserRequest(id: "r1", kind: .command, summary: "Run a command")]))
        model.apply(try #require(await iterator.next()))
        model.select(session.id)
        #expect(model.selectedRow?.live?.userRequests.count == 1)

        let hosting = NSHostingController(rootView: DetailView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 700, height: 500))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        if let terminal { #expect(terminal.window === window, "the terminal is hosted below the approval card") }
        return (window, intents)
    }

    /// Return belongs to the CLI. Focus on the window (after Esc leaves the search field, or a click
    /// on the card) used to let the default action approve a permission instead.
    @Test func returnNeverApprovesWhileATerminalIsHostedBelowTheCard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let surface = TerminalSurface()
        let recorder = InputRecorder()
        surface.view.terminalDelegate = recorder
        let (window, intents) = try await hostApprovalCard(terminal: surface.view, root: root)
        defer { window.orderOut(nil) }

        // Focus on the bare window: nothing may approve.
        #expect(window.makeFirstResponder(nil))
        NSApp.sendEvent(try returnKey(in: window))
        try await Task.sleep(for: .milliseconds(200))
        #expect(intents.answers.isEmpty, "Return with the focus off the terminal must not approve")

        // Focus on the terminal: Return reaches it as a carriage return.
        #expect(window.makeFirstResponder(surface.view))
        NSApp.sendEvent(try returnKey(in: window))
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.sent == [[13]], "Return reaches the focused terminal as a carriage return")
        #expect(intents.answers.isEmpty, "Return must not answer the approval card")
    }

    @Test func approveIsTheDefaultActionOnARecordWithoutATerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A Codex record: the detail view's own card. A Claude session without a terminal shows the Chat, where
        // Return never approves (SessionChatView), so it is not this screen.
        let (window, intents) = try await hostApprovalCard(terminal: nil, root: root, provider: .codex)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(nil))
        NSApp.sendEvent(try returnKey(in: window))
        try await Task.sleep(for: .milliseconds(200))
        #expect(intents.answers.map(\.1) == [true], "no terminal below: the card's Approve stays the default action")
    }
}
}
