import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomChat
@testable import LoomCatalogUI
import LoomTestSupport

/// A box a test moves under a model's clock closures.
final class Mutex2<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// What both halves of `PinnedFixRoundTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum PinnedFixRoundShared {
    static func request(_ id: String, tool: String = "Bash", input: JSONValue = ["command": "make", "description": "Build"],
                         suggestions: [JSONValue] = []) -> ChatPendingRequest {
        var fields: [String: JSONValue] = ["subtype": "can_use_tool", "tool_name": .string(tool), "input": input,
                                           "tool_use_id": .string("toolu_" + id)]
        if !suggestions.isEmpty { fields["permission_suggestions"] = .array(suggestions) }
        return ChatPendingRequest(requestID: id, request: ToolPermissionRequest(json: .object(fields))!,
                                  arrivedAt: Date(timeIntervalSince1970: 1), agent: nil)
    }

    static func state(_ requests: [ChatPendingRequest], phase: ChatDriverPhase = .needsYou) -> ChatLiveState {
        ChatLiveState(sessionID: UUID(), phase: phase, requests: requests)
    }

    final class ComposerSpy: PinnedNoteLink {
        var focusCount = 0
        var notes: [String] = []
        func cardSetNote(_ text: String) { notes.append(text) }
        func focusComposer() { focusCount += 1 }
    }
}
