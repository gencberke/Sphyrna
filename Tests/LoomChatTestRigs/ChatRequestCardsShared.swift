import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// What both halves of `ChatRequestCardsTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ChatRequestCardsShared {
    static func pending(_ tool: String, _ input: JSONValue, suggestions: [JSONValue] = [], toolUseID: String = "toolu_1",
                         agent: ChatRequestAgent? = nil) -> ChatPendingRequest {
        var fields: [String: JSONValue] = [
            "subtype": "can_use_tool", "tool_name": .string(tool), "input": input, "tool_use_id": .string(toolUseID),
        ]
        if !suggestions.isEmpty { fields["permission_suggestions"] = .array(suggestions) }
        let request = ToolPermissionRequest(json: .object(fields))!
        return ChatPendingRequest(requestID: "req-1", request: request, arrivedAt: Date(timeIntervalSince1970: 0), agent: agent)
    }

    static let bashInput: JSONValue = ["command": "rm -rf build", "description": "Remove the build folder"]
}
