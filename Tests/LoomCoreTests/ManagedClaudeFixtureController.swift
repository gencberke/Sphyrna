import Foundation
@testable import LoomCore

actor ManagedClaudeFixtureInputGate {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        if released { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

final class ManagedClaudeFixtureAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func note(_ value: String) { lock.withLock { values.append(value) } }
    var summary: String { lock.withLock { values.joined(separator: ",") } }
}

/// Test-only stream adapter. It proves the runtime's contract using the fake
/// process's actual init, started and replay records, never a write receipt.
private final class ManagedClaudeFixtureSink: PipeOutputSink, @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let ingress: ManagedTaskIngress

    init(ingress: ManagedTaskIngress) {
        self.ingress = ingress
        var continuation: AsyncStream<Data>.Continuation!
        stream = AsyncStream(bufferingPolicy: .bufferingOldest(64)) { continuation = $0 }
        self.continuation = continuation
    }

    func receive(_ data: Data, from stream: PipeStream) {
        guard case .standardOutput = stream else { return }
        ingress.begin()
        switch continuation.yield(data) {
        case .enqueued: break
        case .dropped, .terminated: ingress.invalidate(); ingress.end()
        @unknown default: ingress.invalidate(); ingress.end()
        }
    }

    func ended(_ stream: PipeStream) {
        if case .standardOutput = stream { continuation.finish() }
    }
}

actor ManagedClaudeFixtureController: ManagedTaskController {
    nonisolated let outputSink: any PipeOutputSink
    private let sink: ManagedClaudeFixtureSink
    private let run: ManagedTaskRun
    private let audit: ManagedClaudeFixtureAudit?
    private let ingress: ManagedTaskIngress
    private let inputGate: ManagedClaudeFixtureInputGate?
    private let resultGate: ManagedClaudeFixtureInputGate?
    private let readyStream: AsyncStream<Bool>
    private let readyContinuation: AsyncStream<Bool>.Continuation
    private var reader: Task<Void, Never>?
    private var pipe: PipeEndpoint?
    private var buffer = Data()
    private var pending: ManagedTaskInput?
    private var binding: SessionTaskBinding?
    private var started = false
    private var interruptState: (id: String, input: UUID, ack: Bool, ended: Bool,
                                 continuation: AsyncStream<Bool>.Continuation)?

    init(run: ManagedTaskRun, ingress: ManagedTaskIngress, inputGate: ManagedClaudeFixtureInputGate? = nil,
         resultGate: ManagedClaudeFixtureInputGate? = nil, audit: ManagedClaudeFixtureAudit? = nil) {
        self.run = run
        self.ingress = ingress
        self.inputGate = inputGate
        self.resultGate = resultGate
        self.audit = audit
        let sink = ManagedClaudeFixtureSink(ingress: ingress)
        self.sink = sink
        outputSink = sink
        var continuation: AsyncStream<Bool>.Continuation!
        readyStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        readyContinuation = continuation
    }

    func attach(pipe: PipeEndpoint) async throws {
        guard self.pipe == nil else { throw SessionTaskError.unverified }
        self.pipe = pipe
        let stream = sink.stream, ingress = self.ingress
        reader = Task { [weak self] in
            for await data in stream {
                await self?.receive(data)
                ingress.end()
            }
        }
        let initialize: JSONValue = .object(["type": .string("control_request"), "request_id": .string("fixture-init"),
            "request": .object(["subtype": .string("initialize")])])
        let data = try JSONEncoder().encode(initialize) + Data([0x0a])
        guard await pipe.writeManaged(data, admission: { try $0() }) == .submitted else { throw SessionTaskError.unverified }
        let streamReady = readyStream
        let ready = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await value in streamReady { return value }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard ready else { throw SessionTaskError.unverified }
    }

    func submit(_ input: ManagedTaskInput, admission: @escaping ManagedTaskWriteAdmission) async -> ManagedTaskWriteOutcome {
        guard let pipe, pending == nil else { return .deferred }
        pending = input; started = false
        let message: JSONValue = .object(["type": .string("user"), "uuid": .string(input.clientMessageID.uuidString),
            "message": .object(["role": .string("user"), "content": .string(input.pointer)])])
        guard let encoded = try? JSONEncoder().encode(message) else { pending = nil; return .deferred }
        await inputGate?.hold()
        let outcome = await pipe.writeManaged(encoded + Data([0x0a]), admission: admission)
        if outcome == .deferred { pending = nil }
        return outcome
    }

    func respond(occurrenceID: UUID, decision: ManagedTaskUserDecision,
                 admission: @escaping ManagedTaskWriteAdmission) async -> ManagedTaskWriteOutcome { .deferred }
    func interrupt(_ target: SessionTaskRoundTarget, admission: @escaping ManagedTaskWriteAdmission) async -> SessionTaskEffect {
        guard let pipe, let pending, let binding, pending.roundID == target.roundID,
              pending.operationID == target.inputOperationID, binding == target.binding, started,
              interruptState == nil else { return .deferred }
        let requestID = UUID().uuidString
        var continuation: AsyncStream<Bool>.Continuation!
        let stream = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        interruptState = (requestID, pending.clientMessageID, false, false, continuation)
        let request: JSONValue = .object(["type": .string("control_request"), "request_id": .string(requestID),
                                          "request": .object(["subtype": .string("interrupt")])])
        guard let encoded = try? JSONEncoder().encode(request) else { interruptState = nil; return .deferred }
        let outcome = await pipe.writeManaged(encoded + Data([0x0a]), admission: admission)
        switch outcome {
        case .deferred: audit?.note("write-deferred"); interruptState = nil; return .deferred
        case .unknown: audit?.note("write-unknown"); interruptState = nil; return .unknown
        case .submitted: audit?.note("write-submitted")
        }
        let verified = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await value in stream { return value }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        interruptState = nil
        audit?.note(verified ? "end-verified" : "end-unknown")
        return verified ? .verified : .unknown
    }
    func close() async {
        interruptState?.continuation.finish(); interruptState = nil
        reader = nil; await pipe?.closeInput(); pipe = nil; readyContinuation.finish()
    }

    private func receive(_ data: Data) async {
        buffer.append(data)
        guard buffer.count <= 128 * 1_024 else { ingress.invalidate(); buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: line), let object = value.object else {
                ingress.invalidate(); continue
            }
            await receive(object)
        }
    }

    private func receive(_ value: [String: JSONValue]) async {
        switch value["type"]?.string {
        case "control_response":
            guard let response = value["response"]?.object else { return }
            if var current = interruptState, response["request_id"]?.string == current.id {
                guard response["subtype"]?.string == "success" else { current.continuation.yield(false); return }
                current.ack = true
                audit?.note("ack")
                interruptState = current
                if current.ended { current.continuation.yield(true) }
                return
            }
            guard response["request_id"]?.string == "fixture-init",
                  response["subtype"]?.string == "success", let payload = response["response"]?.object,
                  payload["session_state"]?.string == "idle", let mode = payload["current_permission_mode"]?.string else { return }
            await ingress.emit(.init(run: run, kind: .initialized(nativeSessionID: nil, workingDirectory: nil,
                settings: .init(model: nil, effort: nil, permissionMode: mode))))
            await ingress.emit(.init(run: run, kind: .status(.ready)))
            readyContinuation.yield(true)
        case "system" where value["subtype"]?.string == "init":
            guard let nativeID = value["session_id"]?.string, let cwd = value["cwd"]?.string,
                  let mode = value["permissionMode"]?.string, let model = value["model"]?.string else { ingress.invalidate(); return }
            let observed = SessionTaskBinding(sessionID: run.sessionID, nativeSessionID: nativeID,
                managedRunID: run.runID, generation: run.generation)
            binding = observed
            await ingress.emit(.init(run: run, kind: .initialized(nativeSessionID: nativeID, workingDirectory: cwd,
                settings: .init(model: model, effort: value["effort"]?.string, permissionMode: mode))))
        case "command_lifecycle":
            guard value["state"]?.string == "started" else { return }
            guard let pending, value["command_uuid"]?.string == pending.clientMessageID.uuidString else {
                ingress.invalidate(); return
            }
            started = true
        case "user":
            guard value["isReplay"] == .bool(true) else { return }
            guard let pending, started, let binding,
                  value["uuid"]?.string == pending.clientMessageID.uuidString,
                  value["message"]?.object?["content"]?.string == pending.pointer,
                  let observed = try? ManagedTaskInputObservation(input: pending, binding: binding,
                      execution: .appInputObservation(pending.clientMessageID)) else { ingress.invalidate(); return }
            await ingress.emit(.init(run: run, kind: .inputObserved(observed)))
            await ingress.emit(.init(run: run, kind: .status(.working)))
        case "result":
            if var current = interruptState, current.input == pending?.clientMessageID {
                current.ended = true
                audit?.note("result")
                interruptState = current
                if current.ack {
                    current.continuation.yield(true)
                    await resultGate?.hold()
                }
            }
            pending = nil; started = false
            await ingress.emit(.init(run: run, kind: .status(.ready)))
        default: break
        }
    }
}
