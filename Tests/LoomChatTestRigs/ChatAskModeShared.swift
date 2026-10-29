import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// What both halves of `ChatAskModeTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ChatAskModeShared {
    static func tools(_ snapshot: ChatDriverSnapshot) -> [ToolCall] {
        snapshot.model.entries.compactMap { if case let .tool(call) = $0.body { call } else { nil } }
    }
}
