import AppKit
import Foundation
import SwiftUI
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI

extension ChatHosted {
    /// The public entry view: one model per session, never one per parent render.
    @MainActor
    @Suite
    struct ChatEntryViewTests {
        private func scrollView(in view: NSView) -> ChatScrollView? {
            if let found = view as? ChatScrollView { return found }
            for child in view.subviews { if let found = scrollView(in: child) { return found } }
            return nil
        }

        private func firstPrompt(_ stream: ChatScrollView?) -> String? {
            for row in stream?.controller?.rows ?? [] {
                if case let .user(entry) = row.kind, case let .user(prompt) = entry.body { return prompt.text }
            }
            return nil
        }

        private func settle(_ hosting: NSView, until condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                hosting.layoutSubtreeIfNeeded()
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }

        private func lines(_ prompt: String, uuid: String) -> [String] {
            [ChatFixture.user(prompt, uuid: uuid), ChatFixture.assistant("m\(uuid)", uuid: "a\(uuid)", blocks: [ChatFixture.text("answer to \(prompt)")], at: 1)]
        }

        private func entry(_ id: String, _ root: URL) -> ChatTranscriptView<Color> {
            ChatTranscriptView(sessionID: id, configDirectory: root, workingDirectory: nil) { Color.red }
        }

        @Test func aParentRenderKeepsTheModelAndANewSessionIdShowsTheNewSession() async throws {
            ChatSessionMemoryStore.removeAll()
            let alpha = UUID().uuidString.lowercased(), beta = UUID().uuidString.lowercased()
            let profile = try ChatTranscriptModelTests.Profile(id: alpha, lines: lines("alpha question", uuid: "ua"))
            defer { profile.remove() }
            try profile.addSession(id: beta, lines: lines("beta question", uuid: "ub"))

            ChatRenderProbe.watch()
            defer { ChatRenderProbe.stop() }
            let hosting = NSHostingView(rootView: entry(alpha, profile.root))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

            let shownAlpha = await settle(hosting) { firstPrompt(scrollView(in: hosting)) == "alpha question" }
            #expect(shownAlpha)
            let first = scrollView(in: hosting)

            // The parent renders again and again with the same session: the same stream stays, none is built.
            for _ in 0..<6 {
                hosting.rootView = entry(alpha, profile.root)
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
            }
            #expect(scrollView(in: hosting) === first)
            #expect(ChatRenderProbe.controllersCreated == 1, "one model for the session, however often the parent renders")

            // A new session id shows the new session.
            hosting.rootView = entry(beta, profile.root)
            let shownBeta = await settle(hosting) { firstPrompt(scrollView(in: hosting)) == "beta question" }
            #expect(shownBeta, "shows: \(firstPrompt(scrollView(in: hosting)) ?? "nothing")")
            #expect(scrollView(in: hosting) !== first)
            window.contentView = nil
        }
    }
}
