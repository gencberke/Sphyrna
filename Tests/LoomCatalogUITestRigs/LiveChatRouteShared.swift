import AppKit
import Foundation
import LoomCore
import LoomTerminal
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `LiveChatRouteTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum LiveChatRouteShared {
    @MainActor
    final class Intents: ConversationIntents {
        func start(provider: ManagedSession.Provider, projectID: UUID?) {}
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { nil }
        func endedScreen(sessionID: UUID) -> TerminalScreenSnapshot? { nil }
    }
}

/// `LiveChatRouteTests`'s fixtures, for both halves of the suite.
@MainActor protocol LiveChatRouteFixtures {}

extension LiveChatRouteFixtures {
    typealias Intents = LiveChatRouteShared.Intents

    func waitUntil(_ timeout: Double = 6, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
