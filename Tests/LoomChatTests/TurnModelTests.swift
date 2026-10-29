import Foundation
import LoomCore
import Testing
@testable import LoomChat
@testable import LoomChatTestRigs

/// The model fed from the live stream: turns, stable rows, the thinking rule, raw unknown records.
@Suite(.timeLimit(.minutes(1)))
struct TurnModelLiveTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @discardableResult
    private func apply(_ model: inout TurnModel, _ lines: String..., at time: Date? = nil) -> ModelDelta {
        var delta = ModelDelta()
        for line in lines { delta.merge(model.apply(Fixture.message(line), at: time ?? t0)) }
        return delta
    }

    // MARK: Delivery (S1)

    @Test func theInitializeAnswerIsReadyAndDropsTheAccount() async throws {
        let channel = ControlChannel(makeRequestID: { "req-1" })
        var lines = channel.outgoing.makeAsyncIterator()
        let reply = Task { try await channel.request(.initialize) }
        _ = await lines.next()
        await channel.receive(Fixture.message(Fixture.line(["type": "control_response", "response": ["subtype": "success", "request_id": "req-1", "response": [
            "pid": 220, "claude_code_version": "2.1.300", "current_permission_mode": "default", "session_state": "idle", "capabilities": ["ui_surface_v1"],
            "account": ["email": "user@example.invalid", "organization": "Org", "subscriptionType": "max"],
            "models": [["value": "default", "resolvedModel": "claude-opus-5-5", "displayName": "Default", "supportedEffortLevels": ["low", "high"]]],
            "commands": [["name": "review", "description": "Review", "argumentHint": "<x>"]]]]])))
        let answer = try await reply.value
        #expect(answer.payload["account"] == nil && !answer.payload.serializedString.contains("example.invalid"))
        let ready = answer.initializeResponse
        #expect(ready.currentPermissionMode == "default" && ready.sessionState == "idle" && ready.pid == 220)
        #expect(ready.models.first?.supportedEffortLevels == ["low", "high"] && ready.commands.first?.name == "review")
        // `initialize` lists only ui_surface_v1: it must not close the gate that system/init opens.
        #expect(await channel.knownCapabilities == nil)
        var model = TurnModel(source: .live)
        model.apply(ready: ready, at: t0)
        #expect(model.ready?.currentPermissionMode == "default" && model.markers == [.sessionStart(model: nil, permissionMode: "default")])
        apply(&model, Fixture.initMessage)
        #expect(model.markers.count == 1)
    }
}
