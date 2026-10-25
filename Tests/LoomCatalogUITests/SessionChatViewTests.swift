import AppKit
import Foundation
import LoomCore
import LoomTerminal
import SwiftUI
import Testing
@testable import LoomCatalogUI

extension ChatHosted {
    /// The read-only Chat view in the session route (V13 routed by the Release A glue): it reads the transcript below the
    /// config directory the app gave the model, draws today's kept screen when none resolves, and looks again when the
    /// session's run starts or its status changes. Transcripts are fixtures in temporary folders; the real `~/.claude` is
    /// never read.
    @MainActor
    @Suite
    struct SessionChatViewTests {
        @MainActor
        final class Intents: ConversationIntents {
            var screens: [UUID: TerminalScreenSnapshot] = [:]
            func start(provider: ManagedSession.Provider, projectID: UUID?) {}
            func resume(sessionID: UUID) {}
            func stop(sessionID: UUID) {}
            func answer(sessionID: UUID, requestID: String, accept: Bool) {}
            func viewed(sessionID: UUID) {}
            func terminalView(sessionID: UUID) -> NSView? { nil }
            func endedScreen(sessionID: UUID) -> TerminalScreenSnapshot? { screens[sessionID] }
        }

        private struct Rig {
            let root: URL
            let config: URL
            let hub: SessionEventHub
            let intents: Intents
            let model: CatalogModel
            let sessionID: UUID
            let claudeID: String
        }

        /// A catalog with one stopped Claude session; the config directory is empty until the test writes a transcript.
        private func rig() async throws -> Rig {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-route-\(UUID())", isDirectory: true)
            let folder = root.appendingPathComponent("project", isDirectory: true)
            let config = root.appendingPathComponent("claude-config", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: config.appendingPathComponent("projects"), withIntermediateDirectories: true)
            let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
            let projectID = try await catalog.addProject(path: folder.path).project.id
            let claudeID = UUID().uuidString.lowercased()
            let session = ManagedSession(provider: .claude, providerConversationID: claudeID, workingDirectory: folder.path)
            try await catalog.insertSession(session, title: "Stopped", lifecycle: .idle, projectID: projectID)
            let hub = SessionEventHub()
            let intents = Intents()
            let model = CatalogModel(catalog: catalog, events: hub,
                                     preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
            model.intents = intents
            model.setClaudeConfigDirectory(config)
            await model.start()
            model.readOnlyChatEnabled = true // the frozen Chat face's read-only chat (D-100)
            model.select(session.id)
            _ = await waitUntil { model.selectedRow?.id == session.id }
            return Rig(root: root, config: config, hub: hub, intents: intents, model: model, sessionID: session.id, claudeID: claudeID)
        }

        /// The transcript Claude would have written for the session, below the project's folder name.
        private func writeTranscript(_ rig: Rig, prompt: String) throws {
            let folder = rig.config.appendingPathComponent("projects/-tmp-chat-route", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let lines = [ChatFixture.user(prompt, uuid: "u1"),
                         ChatFixture.assistant("m1", uuid: "a1", blocks: [ChatFixture.text("an answer")], at: 1)]
            try (lines.joined(separator: "\n") + "\n").write(
                to: folder.appendingPathComponent("\(rig.claudeID).jsonl"), atomically: true, encoding: .utf8)
        }

        private func waitUntil(_ timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }

        private func stream(in view: NSView) -> ChatScrollView? {
            if let found = view as? ChatScrollView { return found }
            for child in view.subviews { if let found = stream(in: child) { return found } }
            return nil
        }

        private func keptScreen(in view: NSView) -> EndedScreenContainerView? {
            if let found = view as? EndedScreenContainerView { return found }
            for child in view.subviews { if let found = keptScreen(in: child) { return found } }
            return nil
        }

        private func firstPrompt(_ stream: ChatScrollView?) -> String? {
            for row in stream?.controller?.rows ?? [] {
                if case let .user(entry) = row.kind, case let .user(prompt) = entry.body { return prompt.text }
            }
            return nil
        }

        private func keptScreen() throws -> TerminalScreenSnapshot {
            let surface = TerminalSurface()
            surface.view.feed(text: "last screen")
            return try #require(surface.captureVisibleScreen())
        }

        private func hosted(_ rig: Rig) throws -> (NSWindow, NSHostingView<SessionChatView>) {
            let hosting = NSHostingView(rootView: SessionChatView(model: rig.model, row: try #require(rig.model.selectedRow)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            return (window, hosting)
        }

        @Test func aStoppedSessionShowsItsTranscriptAtTheConfigDirectoryTheAppGave() async throws {
            ChatSessionMemoryStore.removeAll()
            let rig = try await rig()
            defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
            try writeTranscript(rig, prompt: "what does the cache do")
            rig.intents.screens[rig.sessionID] = try keptScreen()
            #expect(rig.model.detailRoute == .chat(sessionID: rig.sessionID))

            let (window, hosting) = try hosted(rig)
            defer { window.contentView = nil }
            let shown = await waitUntil { hosting.layoutSubtreeIfNeeded(); return firstPrompt(stream(in: hosting)) == "what does the cache do" }
            #expect(shown)
            #expect(keptScreen(in: hosting) == nil, "the kept screen is only the fallback")
        }

        @Test func withoutATranscriptOrAConfigDirectoryTheFallbackDrawsTheKeptScreen() async throws {
            ChatSessionMemoryStore.removeAll()
            let rig = try await rig()
            defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
            rig.intents.screens[rig.sessionID] = try keptScreen()

            // The config directory is there, the transcript is not.
            let (window, hosting) = try hosted(rig)
            defer { window.contentView = nil }
            let drawn = await waitUntil { hosting.layoutSubtreeIfNeeded(); return keptScreen(in: hosting) != nil }
            #expect(drawn && stream(in: hosting) == nil)

            // No config directory at all (no runtime): the same fallback, without ever looking for a file.
            rig.model.setClaudeConfigDirectory(nil)
            let (other, bare) = try hosted(rig)
            defer { other.contentView = nil }
            let alsoDrawn = await waitUntil { bare.layoutSubtreeIfNeeded(); return keptScreen(in: bare) != nil }
            #expect(alsoDrawn && stream(in: bare) == nil)
        }

        @Test func aRowShownBeforeTheConfigDirectoryIsKnownSwitchesToChatOnceItIs() async throws {
            ChatSessionMemoryStore.removeAll()
            let rig = try await rig()
            defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
            try writeTranscript(rig, prompt: "restored at launch")
            rig.intents.screens[rig.sessionID] = try keptScreen()
            // The window shows a restored session before the folder is known.
            rig.model.setClaudeConfigDirectory(nil)
            let (window, hosting) = try hosted(rig)
            defer { window.contentView = nil }
            #expect(await waitUntil { hosting.layoutSubtreeIfNeeded(); return keptScreen(in: hosting) != nil })
            #expect(stream(in: hosting) == nil)
            // The folder arrives (one value for the Chat view and the palette): the same view switches.
            rig.model.setClaudeConfigDirectory(rig.config)
            let shown = await waitUntil { hosting.layoutSubtreeIfNeeded(); return firstPrompt(stream(in: hosting)) == "restored at launch" }
            #expect(shown)
            #expect(keptScreen(in: hosting) == nil)
            #expect(rig.model.palette.transcriptsDirectory == rig.config.appendingPathComponent("projects", isDirectory: true))
            rig.model.setClaudeConfigDirectory(nil)
            #expect(rig.model.palette.transcriptsDirectory == nil, "the palette follows the same value")
        }

        @Test(.renderProbe) func theFallbackDrawsOneResumeNotTwo() async throws {
            ChatSessionMemoryStore.removeAll()
            let rig = try await rig()
            defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
            // No transcript and no kept screen: the record is the fallback, below the chat's own notice.
            let (window, hosting) = try hosted(rig)
            defer { window.contentView = nil }
            #expect(RenderProbeExclusive.isHeld, "a test that watches the probe holds the probe lock (.renderProbe)")
            SidebarRenderProbe.watch([rig.sessionID])
            defer { SidebarRenderProbe.watch([]) }
            _ = await waitUntil { hosting.layoutSubtreeIfNeeded(); return (SidebarRenderProbe.onScreen["resume"] ?? 0) > 0 }
            try await Task.sleep(for: .milliseconds(300))
            hosting.layoutSubtreeIfNeeded()
            #expect(SidebarRenderProbe.onScreen["resume"] == 1, "the notice has Resume; the record below does not repeat it")
        }

        @Test func theRecordInTheChatLeavesOutWhatTheChatAlreadyDraws() {
            #expect(!ConversationDetail.showsRequests(inChat: true))
            #expect(ConversationDetail.showsRequests(inChat: false))
            // Without a terminal the notice above has Resume; with one there is no notice, so the record keeps it.
            #expect(!ConversationDetail.showsResume(inChat: true, hasTerminal: false))
            #expect(ConversationDetail.showsResume(inChat: true, hasTerminal: true))
            #expect(ConversationDetail.showsResume(inChat: false, hasTerminal: false))
        }

        @Test func theViewLooksAgainWhenTheRunStartsAndTheSessionWorks() async throws {
            ChatSessionMemoryStore.removeAll()
            let rig = try await rig()
            defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
            rig.intents.screens[rig.sessionID] = try keptScreen()
            let (window, hosting) = try hosted(rig)
            defer { window.contentView = nil }
            let fallback = await waitUntil { hosting.layoutSubtreeIfNeeded(); return keptScreen(in: hosting) != nil }
            #expect(fallback, "a new session has no transcript before its first prompt")

            // The first prompt writes the transcript; the run and the status say that something happened.
            try writeTranscript(rig, prompt: "first prompt")
            await rig.hub.publish(sessionID: rig.sessionID, change: .runStarted(UUID()))
            await rig.hub.publish(sessionID: rig.sessionID, change: .status(ProviderWorkState(activity: .working)))
            let shown = await waitUntil { hosting.layoutSubtreeIfNeeded(); return firstPrompt(stream(in: hosting)) == "first prompt" }
            #expect(shown, "the view must not stay on the fallback")
            #expect(keptScreen(in: hosting) == nil)
        }
    }
}

@MainActor
struct ChatRouteKeyTests {
    @Test func theKeyMovesOnlyWhileTheFallbackShowsAndTheRunOrStatusChanges() {
        let run = UUID()
        var key = ChatRouteKey()
        func moved(_ runID: UUID?, _ indicator: SessionIndicator, onFallback: Bool) -> Bool {
            key.update(runID: runID, indicator: indicator, onFallback: onFallback)
        }
        // The first reading is only recorded.
        #expect(!moved(nil, .ended, onFallback: true))
        #expect(!moved(nil, .ended, onFallback: true), "nothing changed")
        #expect(key.epoch == 0)

        #expect(moved(run, .ready, onFallback: true), "a run started")
        #expect(key.epoch == 1)
        #expect(!moved(run, .ready, onFallback: true))
        #expect(moved(run, .working, onFallback: true), "the status changed to working")
        #expect(key.epoch == 2)
        #expect(moved(run, .ready, onFallback: true), "and the turn ended: the file exists by now")
        #expect(key.epoch == 3)

        // With a transcript on screen nothing re-keys: scroll position and folds stay.
        #expect(!moved(run, .working, onFallback: false))
        #expect(!moved(UUID(), .working, onFallback: false))
        #expect(!moved(nil, .ended, onFallback: false))
        #expect(key.epoch == 3)
        // The change that happened meanwhile is not replayed when the fallback shows later.
        #expect(!moved(nil, .ended, onFallback: true))
    }
}
