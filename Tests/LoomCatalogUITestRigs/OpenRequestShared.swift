import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
import LoomTerminal
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `OpenRequestTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum OpenRequestShared {
    static func openRequest(
        requester: UUID = UUID(), phase: OpenSessionRequest.Phase = .waiting, message: String = "Fix the login flow.",
        choices: ClaudeLaunchChoices = ClaudeLaunchChoices()
    ) -> OpenSessionRequest {
        OpenSessionRequest(
            requesterID: requester, requesterTitle: "Planner", projectID: UUID(), projectName: "edd-backend",
            title: "EDDP-412 Fix login", message: message, choices: choices, phase: phase)
    }
}
