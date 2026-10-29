import Foundation
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomChat

private actor ManagedWireGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class ManagedPipeEcho: PipeOutputSink, Sendable {
    let received = Mutex(Data())
    func receive(_ data: Data, from stream: PipeStream) {
        guard stream == .standardOutput else { return }
        received.withLock { $0.append(data.prefix(max(0, 256 - $0.count))) }
    }
    func ended(_ stream: PipeStream) {}
}

private final class ManagedClaudeWire: @unchecked Sendable {
    struct State {
        var events: [ManagedTaskControllerEvent] = []
        var frames: [JSONValue] = []
        var pending = 0
        var invalidations = 0
        var interruptFinished = false
        var waitingWrite = false
    }
    let state = Mutex(State())
    let run = ManagedTaskRun(taskID: UUID(), sessionID: UUID(), runID: UUID(), generation: UUID(),
        workingDirectory: "/private/tmp", requestedChoices: .init(harness: .claude, model: "haiku", effort: "low", mode: .askBeforeEdits),
        expectedNativeSessionID: UUID().uuidString.lowercased())
    var ingress: ManagedTaskIngress {
        .init(begin: { self.state.withLock { $0.pending += 1 } },
              end: { self.state.withLock { $0.pending -= 1 } },
              invalidate: { self.state.withLock { $0.invalidations += 1 } },
              emit: { event in self.state.withLock { $0.events.append(event) } })
    }

    func connect(_ controller: ManagedClaudeTaskController, gate: ManagedWireGate? = nil,
                 gateSubtype: String? = nil, autoInitialize: Bool = true) async throws {
        let sink = controller.outputSink
        try await controller.connect { data, admission in
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .unknown }
            let subtype = json["request"]?["subtype"]?.string ?? json["type"]?.string
            if let gate, subtype == gateSubtype {
                self.state.withLock { $0.waitingWrite = true }
                await gate.wait()
            }
            do {
                let bytes = try admission {
                    self.state.withLock { $0.frames.append(json) }
                    return data.count
                }
                guard bytes == data.count else { return .deferred }
                if autoInitialize, subtype == "initialize", let id = json["request_id"]?.string {
                    sink.receive(ControlWire.successLine(id: id, [
                        "current_permission_mode": "default", "session_state": "idle",
                        "models": [["value": "haiku", "resolvedModel": "claude-haiku-5-5"]],
                    ]), from: .standardOutput)
                }
                return .submitted
            } catch { return .unknown }
        }
    }

    func input(binding: SessionTaskBinding? = nil) throws -> ManagedTaskInput {
        try .init(run: run, roundID: UUID(), operationID: UUID(), binding: binding,
                  clientMessageID: UUID(), pointer: "Read the assigned input with the scoped Sphyrna task command.")
    }

    func feed(_ json: JSONValue, to controller: ManagedClaudeTaskController) {
        controller.outputSink.receive(ControlWire.line(json), from: .standardOutput)
    }

    func initialize(_ controller: ManagedClaudeTaskController, overriding: [String: JSONValue] = [:]) {
        var fields: [String: JSONValue] = [
            "type": "system", "subtype": "init", "session_id": .string(run.expectedNativeSessionID!),
            "cwd": .string(run.workingDirectory), "model": "claude-haiku-5-5", "effort": "low",
            "permissionMode": "default", "capabilities": ["msg_lifecycle_v1", "interrupt_receipt_v1"],
        ]
        fields.merge(overriding) { _, newer in newer }
        feed(.object(fields), to: controller)
    }

    func started(_ input: ManagedTaskInput, on controller: ManagedClaudeTaskController, state: String = "started") {
        feed(["type": "command_lifecycle", "command_uuid": .string(input.clientMessageID.uuidString.lowercased()),
              "state": .string(state)], to: controller)
    }

    func end(on controller: ManagedClaudeTaskController) {
        feed(["type": "result", "subtype": "success", "is_error": false,
              "session_id": .string(run.expectedNativeSessionID!), "queued_turn_count": 0], to: controller)
    }

    var observations: [ManagedTaskInputObservation] {
        state.withLock { $0.events.compactMap { if case let .inputObserved(value) = $0.kind { value } else { nil } } }
    }
    var permissions: [ManagedTaskPermissionOccurrence] {
        state.withLock { $0.events.compactMap { if case let .permissionRequested(value) = $0.kind { value } else { nil } } }
    }
    var nativeBinding: SessionTaskBinding? { observations.last?.binding }

    static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(predicate(), "the expected protocol observation did not arrive")
    }
}

@Suite(.serialized, .processHeavy)
struct ManagedClaudeTaskTests {
    @Test func threeRoundsRequireNativeConsumptionAndKeepTheSameObservedChild() async throws {
        let wire = ManagedClaudeWire()
        let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
        try await wire.connect(controller)
        for round in 0..<3 {
            let input = try wire.input(binding: wire.nativeBinding)
            #expect(await controller.submit(input, admission: { try $0() }) == .submitted)
            wire.initialize(controller)
            wire.started(input, on: controller, state: "queued")
            try await ManagedClaudeWire.wait { wire.state.withLock { $0.pending == 0 } }
            #expect(wire.observations.count == round, "queued and successful writes do not prove consumption")
            if round == 1 {
                wire.feed(["type": "user", "uuid": .string(input.clientMessageID.uuidString.lowercased()),
                    "session_id": .string(wire.run.expectedNativeSessionID!), "isReplay": true,
                    "origin": ["kind": "human"], "message": ["content": .string(input.pointer)]], to: controller)
            } else { wire.started(input, on: controller) }
            try await ManagedClaudeWire.wait { wire.observations.count == round + 1 }
            #expect(wire.observations.last?.execution == .appInputObservation(input.clientMessageID))
            wire.end(on: controller)
            try await ManagedClaudeWire.wait { wire.state.withLock { $0.pending == 0 } }
        }
        #expect(Set(wire.observations.map(\.binding.nativeSessionID)).count == 1)
        #expect(wire.state.withLock { $0.frames.filter { $0["type"]?.string == "user" }.count } == 3)
        #expect(wire.state.withLock { $0.invalidations } == 0)
        await controller.close()
    }

    @Test(arguments: ["session_id", "cwd", "model", "effort", "permissionMode"])
    func mismatchedNativeSettingsNeverBecomeInputProof(field: String) async throws {
        let wire = ManagedClaudeWire()
        let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
        try await wire.connect(controller)
        let input = try wire.input()
        #expect(await controller.submit(input, admission: { try $0() }) == .submitted)
        wire.initialize(controller, overriding: [field: .string(field == "cwd" ? "/usr/bin" : "wrong")])
        wire.started(input, on: controller)
        try await ManagedClaudeWire.wait { wire.state.withLock { $0.invalidations > 0 } }
        #expect(wire.observations.isEmpty)
        #expect(await controller.submit(try wire.input(), admission: { try $0() }) == .deferred)
        await controller.close()
    }

    @Test func oneApprovalUsesOnlyItsExactOriginalInputAndCannotBeRepeated() async throws {
        let wire = ManagedClaudeWire()
        let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
        try await wire.connect(controller)
        let input = try wire.input()
        _ = await controller.submit(input, admission: { try $0() })
        wire.initialize(controller); wire.started(input, on: controller)
        try await ManagedClaudeWire.wait { wire.observations.count == 1 }
        let original: JSONValue = ["command": "printf synthetic", "description": "One synthetic command"]
        wire.feed(["type": "control_request", "request_id": "native-one", "request": [
            "subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "tool-one", "input": original,
            "permission_suggestions": [["type": "setMode", "mode": "bypassPermissions"]],
        ]], to: controller)
        try await ManagedClaudeWire.wait { wire.permissions.count == 1 }
        let occurrence = try #require(wire.permissions.first)
        #expect(await controller.respond(occurrenceID: occurrence.id, decision: .allow, admission: { try $0() }) == .submitted)
        let count = wire.state.withLock { $0.frames.count }
        #expect(await controller.respond(occurrenceID: occurrence.id, decision: .allow, admission: { try $0() }) == .deferred)
        #expect(wire.state.withLock { $0.frames.count } == count)
        let answer = try #require(wire.state.withLock { $0.frames.last })
        #expect(answer["response"]?["request_id"]?.string == "native-one")
        #expect(answer["response"]?["response"]?["updatedInput"] == original)
        #expect(answer["response"]?["response"]?["updatedPermissions"] == nil)
        await controller.close()
    }

    @Test func closeRetiresAUserWriteStillWaitingForItsActualAdmission() async throws {
        let wire = ManagedClaudeWire(), gate = ManagedWireGate()
        let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
        try await wire.connect(controller, gate: gate, gateSubtype: "user")
        let input = try wire.input()
        let send = Task { await controller.submit(input, admission: { try $0() }) }
        try await ManagedClaudeWire.wait { wire.state.withLock { $0.waitingWrite } }
        await controller.close()
        await gate.release()
        _ = await send.value
        #expect(wire.state.withLock { $0.frames.filter { $0["type"]?.string == "user" }.isEmpty })
        #expect(wire.state.withLock { $0.pending } == 0)
    }

    @Test func interruptDoesNotReleaseTheNextRoundUntilItsOwnReplyAndTurnEnd() async throws {
        let wire = ManagedClaudeWire()
        let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
        try await wire.connect(controller)
        let input = try wire.input()
        _ = await controller.submit(input, admission: { try $0() })
        wire.initialize(controller); wire.started(input, on: controller)
        try await ManagedClaudeWire.wait { wire.observations.count == 1 }
        let binding = try #require(wire.nativeBinding)
        let target = SessionTaskRoundTarget(taskID: wire.run.taskID, roundID: input.roundID,
            inputOperationID: input.operationID, binding: binding, nativeTurnID: nil,
            execution: .appInputObservation(input.clientMessageID))
        let stop = Task {
            let result = await controller.interrupt(target, admission: { try $0() })
            wire.state.withLock { $0.interruptFinished = true }
            return result
        }
        try await ManagedClaudeWire.wait { wire.state.withLock { $0.frames.contains { $0["request"]?["subtype"]?.string == "interrupt" } } }
        wire.end(on: controller)
        try await ManagedClaudeWire.wait { wire.state.withLock { $0.pending == 0 } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!wire.state.withLock { $0.interruptFinished }, "the old interrupt can still be pending after normal completion")
        #expect(await controller.submit(try wire.input(binding: binding), admission: { try $0() }) == .deferred)
        let id = try #require(wire.state.withLock { $0.frames.last { $0["request"]?["subtype"]?.string == "interrupt" }?["request_id"]?.string })
        wire.feed(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id),
            "response": ["still_queued": [], "cancelled": []]]], to: controller)
        if case .verified = await stop.value {} else { Issue.record("exact acknowledged interrupt did not settle") }
        await controller.close()
    }

    @Test func overflowingProofInboxInvalidatesAndBalancesEveryIngressFence() {
        let wire = ManagedClaudeWire()
        let sink = ManagedClaudeTaskSink(ingress: wire.ingress)
        for _ in 0..<8 { sink.receive(ControlWire.line(["type": "keep_alive"]), from: .standardOutput) }
        #expect(wire.state.withLock { $0.invalidations } == 1)
        #expect(wire.state.withLock { $0.pending } == 0)
        sink.close()
        #expect(wire.state.withLock { $0.pending } == 0)
    }

    @Test func cancelledInitializationCannotPublishReadyOrAdmitALateFirstInput() async throws {
        let wire = ManagedClaudeWire()
        let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
        let connection = Task { try await wire.connect(controller, autoInitialize: false) }
        try await ManagedClaudeWire.wait { wire.state.withLock { !$0.frames.isEmpty } }
        connection.cancel()
        do { try await connection.value; Issue.record("cancelled initialization should fail") }
        catch {}
        let id = try #require(wire.state.withLock { $0.frames.first?["request_id"]?.string })
        wire.feed(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id),
            "response": ["current_permission_mode": "default", "session_state": "idle"]]], to: controller)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!wire.state.withLock { $0.events.contains { if case .initialized = $0.kind { true } else { false } } })
        #expect(await controller.submit(try wire.input(), admission: { try $0() }) == .deferred)
        await controller.close()
    }

    @Test func malformedAuthorityFrameInvalidatesInsteadOfLeavingAUsableBinding() async throws {
        let wire = ManagedClaudeWire()
        let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
        try await wire.connect(controller)
        let input = try wire.input()
        _ = await controller.submit(input, admission: { try $0() })
        wire.initialize(controller); wire.started(input, on: controller)
        try await ManagedClaudeWire.wait { wire.observations.count == 1 }
        wire.feed(["type": "control_cancel_request"], to: controller)
        try await ManagedClaudeWire.wait { wire.state.withLock { $0.invalidations > 0 } }
        wire.end(on: controller)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await controller.submit(try wire.input(binding: wire.nativeBinding), admission: { try $0() }) == .deferred)
        await controller.close()
    }

    @Test func aTurnThatEndsBeforeInterruptAdmissionReceivesNoOldInterrupt() async throws {
        let wire = ManagedClaudeWire(), gate = ManagedWireGate()
        let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
        try await wire.connect(controller, gate: gate, gateSubtype: "interrupt")
        let input = try wire.input()
        _ = await controller.submit(input, admission: { try $0() })
        wire.initialize(controller); wire.started(input, on: controller)
        try await ManagedClaudeWire.wait { wire.observations.count == 1 }
        let binding = try #require(wire.nativeBinding)
        let target = SessionTaskRoundTarget(taskID: wire.run.taskID, roundID: input.roundID,
            inputOperationID: input.operationID, binding: binding, nativeTurnID: nil,
            execution: .appInputObservation(input.clientMessageID))
        let stop = Task { await controller.interrupt(target, admission: { try $0() }) }
        try await ManagedClaudeWire.wait { wire.state.withLock { $0.waitingWrite } }
        wire.end(on: controller)
        try await ManagedClaudeWire.wait { wire.state.withLock { $0.pending == 0 } }
        await gate.release()
        try await Task.sleep(for: .milliseconds(30))
        let request = wire.state.withLock { $0.frames.last { $0["request"]?["subtype"]?.string == "interrupt" } }
        #expect(request == nil, "a queued old interrupt must not reach a successor's input boundary")
        if let id = request?["request_id"]?.string {
            wire.feed(["type": "control_response", "response": ["subtype": "success", "request_id": .string(id),
                "response": ["still_queued": [], "cancelled": []]]], to: controller)
        }
        if case .deferred = await stop.value {} else { Issue.record("no interrupt byte should have been admitted") }
        #expect(await controller.submit(try wire.input(binding: binding), admission: { try $0() }) == .submitted)
        await controller.close()
    }

    @Test func partialProofRemainsFencedUntilTheCompletedBatchIsApplied() async throws {
        let wire = ManagedClaudeWire()
        let sink = ManagedClaudeTaskSink(ingress: wire.ingress)
        sink.receive(Data(#"{"type":"keep_alive""#.utf8), from: .standardOutput)
        #expect(wire.state.withLock { $0.pending } == 1)
        sink.receive(Data("}\n".utf8), from: .standardOutput)
        var iterator = sink.batches.makeAsyncIterator()
        let batch = try #require(await iterator.next())
        #expect(wire.state.withLock { $0.pending } > 0)
        sink.applied(batch.id)
        #expect(wire.state.withLock { $0.pending } == 0)
        #expect(wire.state.withLock { $0.invalidations } == 0)
        sink.close()
    }

    @Test(arguments: [false, true])
    func anUnownedStartedLifecycleRetiresAuthorityEvenAfterThePriorTurnEnded(afterEnd: Bool) async throws {
        let wire = ManagedClaudeWire()
        let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
        try await wire.connect(controller)
        let input = try wire.input()
        _ = await controller.submit(input, admission: { try $0() })
        wire.initialize(controller); wire.started(input, on: controller)
        try await ManagedClaudeWire.wait { wire.observations.count == 1 }
        if afterEnd {
            wire.end(on: controller)
            try await ManagedClaudeWire.wait { wire.state.withLock { $0.pending == 0 } }
        }
        wire.feed(["type": "command_lifecycle", "command_uuid": .string(UUID().uuidString.lowercased()),
                   "state": "started"], to: controller)
        try await ManagedClaudeWire.wait { wire.state.withLock { $0.invalidations > 0 } }
        #expect(await controller.submit(try wire.input(binding: wire.nativeBinding), admission: { try $0() }) == .deferred)
        await controller.close()
    }

    @Test func anExactEarlyStartedFrameWaitsForObservedIdentityAndCapability() async throws {
        let wire = ManagedClaudeWire()
        let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
        try await wire.connect(controller)
        let input = try wire.input()
        _ = await controller.submit(input, admission: { try $0() })
        wire.started(input, on: controller)
        try await ManagedClaudeWire.wait { wire.state.withLock { $0.pending == 0 } }
        #expect(wire.observations.isEmpty)
        wire.initialize(controller)
        try await ManagedClaudeWire.wait { wire.observations.count == 1 }
        #expect(wire.observations.first?.input == input)
        #expect(wire.state.withLock { $0.invalidations } == 0)
        await controller.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectedSecondAttachCannotCloseAnUnrelatedOwnedPipe() async throws {
        let rig = try await Rig.make()
        do {
            let echo = ManagedPipeEcho()
            let session = ManagedSession(provider: .synthetic, workingDirectory: rig.root.path)
            try await rig.supervisor.createSession(session)
            let launch = try await rig.supervisor.launchPipes(sessionID: session.id, executable: "/bin/cat", arguments: [],
                environment: LaunchEnvironment.make(base: ["PATH": "/usr/bin:/bin", "HOME": rig.home.path],
                    runID: rig.supervisor.ownershipRunID, sessionID: session.id), outputSink: echo)
            let wire = ManagedClaudeWire()
            let controller = try ManagedClaudeTaskController(run: wire.run, ingress: wire.ingress)
            try await wire.connect(controller)
            await #expect(throws: SessionTaskError.staleBinding) { try await controller.attach(pipe: launch.pipe) }
            await controller.close()
            let marker = Data("still-owned-and-open\n".utf8)
            try await launch.pipe.write(marker)
            try await ManagedClaudeWire.wait { echo.received.withLock { $0 == marker } }
        } catch {
            await rig.finish()
            throw error
        }
        await rig.finish()
    }
}
