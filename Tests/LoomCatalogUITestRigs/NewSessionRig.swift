import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// Shared by `NewSessionTests` and the tests of other tiers that reuse its fixtures (DEVELOPMENT §3.1).
enum NewSessionRig {
    /// The runtime's side of a draft send: records what was asked and lets the test answer.
    @MainActor
    final class DraftIntents: NewSessionIntents {
        var sends: [(projectID: UUID?, launch: NewSessionLaunch, focus: NewSessionFocus, outcome: @MainActor (NewSessionOutcome) -> Void)] = []
        var plainStarts = 0
        func start(provider: ManagedSession.Provider, projectID: UUID?) { plainStarts += 1 }
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { nil }
        func startSession(projectID: UUID?, launch: NewSessionLaunch, focus: NewSessionFocus,
                          outcome: @escaping @MainActor (NewSessionOutcome) -> Void) {
            sends.append((projectID, launch, focus, outcome))
        }
    }
}
