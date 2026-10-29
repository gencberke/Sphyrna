import AppKit
import Foundation
import LoomCore
import LoomTerminal
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `SessionChatViewTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum SessionChatViewShared {
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
}

/// `SessionChatViewTests`'s fixtures, for both halves of the suite.
@MainActor protocol SessionChatViewFixtures {}

extension SessionChatViewFixtures {
    typealias Intents = SessionChatViewShared.Intents

    func keptScreen() throws -> TerminalScreenSnapshot {
        let surface = TerminalSurface()
        surface.view.feed(text: "last screen")
        return try #require(surface.captureVisibleScreen())
    }
}
