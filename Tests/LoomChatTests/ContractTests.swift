import Darwin
import Foundation
import LoomCore
import Synchronization
import Testing
@testable import LoomChat

// Contract tests: the same four situations, once as the fake provider really prints them and once as the real CLI 2.1.300
// printed them (S1 recordings, trimmed in S1Recordings.swift), go through the same pipeline, the one the chat engine uses:
// bytes -> StreamJSONDecoder -> ControlChannel and TurnModel. One set of assertions checks both, so the fake cannot drift
// from the recordings (record order, capabilities, receipts) without a test failing.
//
//   plain turn | interrupt that returns queued sends | interrupt while a can_use_tool is pending | api_error

private final class BundleAnchor: NSObject {}

/// The decoder, the channel and the model, fed with bytes.
private final class Wire: Sendable {
    struct State: Sendable {
        var decoder = StreamJSONDecoder()
        var model = TurnModel(source: .live)
        var frames: [StreamFrame] = []
        var events: [ControlEvent] = []
        var written: [Data] = []
    }

    let channel: ControlChannel
    let state = Mutex(State())

    /// `requestIDs` are used in order for the requests Loom sends (a recording knows its ids); random ones after that.
    init(requestIDs: [String] = []) {
        let queue = Mutex(requestIDs)
        channel = ControlChannel(defaultTimeout: .seconds(20), makeRequestID: {
            queue.withLock { $0.isEmpty ? "loom-" + UUID().uuidString.lowercased() : $0.removeFirst() }
        })
    }

    /// Starts collecting what the channel says and writes; `sink` gets every line for the process's stdin.
    func start(sink: @escaping @Sendable (Data) -> Void = { _ in }) {
        let channel = channel
        Task { for await event in channel.events { state.withLock { $0.events.append(event) } } }
        // The harness is the host: like the driver, it tells the live model when it sent an interrupt (only then is an
        // aborted turn the user's stop).
        Task {
            for await line in channel.outgoing {
                let isInterrupt = (try? JSONDecoder().decode(JSONValue.self, from: line))?["request"]?["subtype"]?.string == "interrupt"
                state.withLock {
                    $0.written.append(line)
                    if isInterrupt { $0.model.noteInterruptSent() }
                }
                sink(line)
            }
        }
    }

    func feed(_ data: Data) async {
        let batch = state.withLock { state -> [StreamFrame] in
            let frames = state.decoder.feed(data)
            state.frames.append(contentsOf: frames)
            return frames
        }
        for frame in batch {
            if case let .message(message) = frame { await channel.receive(message) }
            state.withLock { state in
                if case let .message(message) = frame { state.model.apply(message) } else { state.model.apply(frame) }
            }
        }
    }

    /// The `initialize` exchange: the model becomes Ready.
    func initialize() async throws -> InitializeResponse {
        let reply = try await channel.request(.initialize)
        let ready = reply.initializeResponse
        state.withLock { _ = $0.model.apply(ready: ready) }
        return ready
    }

    func sent(_ uuid: String, _ text: String) { state.withLock { _ = $0.model.appendPendingUser(uuid: uuid, text: text) } }

    /// A recording plays the interrupt before the turn it stops exists here: the host notes it for that turn.
    func noteInterrupt() { state.withLock { $0.model.noteInterruptSent() } }

    func snapshot() -> State { state.withLock { $0 } }

    func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: (State) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(snapshot()) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ContractTimeout(what: what, tail: snapshot().frames.suffix(4).map { String(describing: $0).prefix(120).description })
    }
}

private struct ContractTimeout: Error, CustomStringConvertible {
    let what: String
    let tail: [String]
    var description: String { "timed out waiting for \(what); last frames: \(tail)" }
}

/// The fake provider as a child process, speaking to a `Wire`.
private final class FakeChild: @unchecked Sendable {
    let root: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(wire: Wire, emitSessionState: Bool = false) throws {
        let executable = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("loom-fake-provider")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ContractTimeout(what: "the loom-fake-provider binary next to the tests (run swift build first)", tail: [executable.path])
        }
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-contract-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        process.executableURL = executable
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
                             "--session-id", UUID().uuidString.lowercased()]
        process.currentDirectoryURL = root
        var environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": root.appendingPathComponent("config").path,
                           "LOOM_FAKE_CHAT_DELAY_MS": "1"]
        if emitSessionState { environment["CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS"] = "1" }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let handle = output.fileHandleForReading
        Task.detached {
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                await wire.feed(data)
            }
        }
        let writer = input.fileHandleForWriting
        wire.start { line in try? writer.write(contentsOf: line) }
    }

    func send(_ message: OutgoingUserMessage) { try? input.fileHandleForWriting.write(contentsOf: message.line()) }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
}

/// A recording played into a `Wire`, a line at a time, cut into odd-sized chunks.
private func play(_ lines: [String], into wire: Wire, answering: ((IncomingControlRequest) async -> Void)? = nil) async {
    for line in lines {
        let bytes = Data((line + "\n").utf8)
        var start = 0
        while start < bytes.count {
            let end = min(bytes.count, start + 331)
            await wire.feed(bytes.subdata(in: start..<end))
            start = end
        }
        if let answering, case let .message(message)? = wire.snapshot().frames.last, case let .controlRequest(request) = message {
            await answering(request)
        }
    }
}

// MARK: What was observed

private struct Observed {
    var state: Wire.State
    var ready: InitializeResponse
    var capabilities: Set<String>?
    var receipt: InterruptReceipt?
    var pending: [IncomingControlRequest]

    var model: TurnModel { state.model }
    var messages: [StreamMessage] { state.frames.compactMap { if case let .message(message) = $0 { message } else { nil } } }

    func index(of match: (StreamMessage) -> Bool) -> Int? { messages.firstIndex(where: match) }
    func isToolResult(_ message: StreamMessage) -> Bool { if case let .user(user) = message { user.hasToolResult } else { false } }
    func isResult(_ message: StreamMessage) -> Bool { if case .result = message { true } else { false } }
    func isCancel(_ message: StreamMessage) -> Bool { if case .controlCancel = message { true } else { false } }
    func isReply(to id: String, _ message: StreamMessage) -> Bool {
        if case let .controlResponse(response) = message { response.requestID == id } else { false }
    }
    func isLifecycle(_ state: CommandLifecycle.State, _ message: StreamMessage) -> Bool {
        if case let .commandLifecycle(lifecycle) = message { lifecycle.state == state } else { false }
    }

    /// The request id of the interrupt Loom sent.
    var interruptID: String? {
        state.written.lazy.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0.dropLast()) }
            .first { $0["request"]?["subtype"] == "interrupt" }?["request_id"]?.string
    }
}

private func delivery(_ model: TurnModel, _ uuid: String) -> UserPrompt.Delivery? {
    if case let .user(prompt)? = model.entry(id: uuid)?.body { prompt.delivery } else { nil }
}

private func observe(_ wire: Wire, ready: InitializeResponse, receipt: InterruptReceipt? = nil) async -> Observed {
    let channel = wire.channel
    return Observed(state: wire.snapshot(), ready: ready, capabilities: await channel.knownCapabilities, receipt: receipt,
                    pending: await channel.pendingRequests)
}

// MARK: Shared expectations

/// What every case must show, whoever printed it.
private func expectWellFormed(_ seen: Observed, sourceLocation: SourceLocation = #_sourceLocation) {
    let frames = seen.state.frames
    #expect(!frames.isEmpty, sourceLocation: sourceLocation)
    #expect(frames.allSatisfy { if case .message = $0 { true } else { false } }, "no malformed or oversized line", sourceLocation: sourceLocation)
    #expect(seen.model.raws.isEmpty && seen.model.unknownRecordCount == 0, "every record is typed", sourceLocation: sourceLocation)
    // The initialize answer lists only ui_surface_v1; the ten capabilities come with the first system/init (S1 Q4).
    #expect(seen.ready.capabilities == ["ui_surface_v1"], sourceLocation: sourceLocation)
    #expect(seen.ready.sessionState == "idle" && seen.ready.currentPermissionMode != nil && (seen.ready.pid ?? 0) > 0,
            sourceLocation: sourceLocation)
    #expect(!seen.ready.models.isEmpty && !seen.ready.commands.isEmpty, sourceLocation: sourceLocation)
    let capabilities = seen.capabilities ?? []
    #expect(capabilities.isSuperset(of: ["msg_lifecycle_v1", "interrupt_cancel_queued_v1", "interrupt_receipt_v1", "ui_surface_v1"]),
            sourceLocation: sourceLocation)
    #expect(seen.model.latestInit != nil && seen.model.markers.filter { if case .sessionStart = $0 { true } else { false } }.count == 1,
            "one start marker", sourceLocation: sourceLocation)
    #expect(seen.model.pendingUserMessageIDs.isEmpty, "every send is settled", sourceLocation: sourceLocation)
    // No account reaches the model, the events or the log of what was written.
    for event in seen.state.events { #expect(!String(describing: event).contains("@"), sourceLocation: sourceLocation) }
    #expect(!String(describing: seen.model).contains("example.invalid"), sourceLocation: sourceLocation)
}

private func expectPlainTurn(_ seen: Observed, uuid: String, sourceLocation: SourceLocation = #_sourceLocation) {
    expectWellFormed(seen, sourceLocation: sourceLocation)
    let model = seen.model
    #expect(delivery(model, uuid) == .read, sourceLocation: sourceLocation)
    #expect(model.turns.count == 1 && model.turns[0].status == .succeeded && model.turns[0].hasUserPrompt, sourceLocation: sourceLocation)
    #expect(model.turns[0].result?.subtype == .success && model.turns[0].result?.isError == false, sourceLocation: sourceLocation)
    #expect(model.turns[0].result?.terminalReason == "completed" && model.turns[0].result?.errors.isEmpty == true, sourceLocation: sourceLocation)
    #expect(model.texts.count == 1 && model.texts[0].isStreaming == false && !model.texts[0].text.isEmpty, sourceLocation: sourceLocation)
    #expect(model.contextUsage != nil && model.rateLimit != nil && model.turns[0].durationMs != nil, sourceLocation: sourceLocation)
    // queued, started, then the echo; completed after the result.
    let started = seen.index { seen.isLifecycle(.started, $0) }
    let result = seen.index(of: seen.isResult)
    let completed = seen.index { seen.isLifecycle(.completed, $0) }
    #expect(started != nil && result != nil && completed != nil && started! < result! && result! < completed!, sourceLocation: sourceLocation)
}

private func expectInterruptWithQueued(_ seen: Observed, first: String, queued: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    expectWellFormed(seen, sourceLocation: sourceLocation)
    let model = seen.model
    // The receipt names every send the CLI held, and nothing stays queued.
    #expect(Set(seen.receipt?.cancelled ?? []) == Set(queued) && seen.receipt?.stillQueued.isEmpty == true, sourceLocation: sourceLocation)
    #expect(delivery(model, first) == .read, sourceLocation: sourceLocation)
    for uuid in queued { #expect(delivery(model, uuid) == .cancelled, "\(uuid) is cancelled, not read", sourceLocation: sourceLocation) }
    #expect(model.turns.count == 1 && model.turns[0].status == .interrupted, sourceLocation: sourceLocation)
    #expect(model.turns[0].result?.subtype == .errorDuringExecution && model.turns[0].result?.terminalReason == "aborted_tools",
            sourceLocation: sourceLocation)
    #expect(model.markers.contains(.interrupted(afterMs: model.turns[0].result?.durationMs)), sourceLocation: sourceLocation)
    #expect(model.tools.count == 1 && model.tools[0].name == "Bash" && model.tools[0].status == .denied, sourceLocation: sourceLocation)
    // Order: the cancelled sends, then the answer, then the result (S1 t08:30-33,37).
    let cancelled = seen.messages.indices.filter { seen.isLifecycle(.cancelled, seen.messages[$0]) }
    let reply = seen.interruptID.flatMap { id in seen.index { seen.isReply(to: id, $0) } }
    let result = seen.index(of: seen.isResult)
    #expect(cancelled.count == queued.count + 1, "a cancelled line for each send and for the interrupted one", sourceLocation: sourceLocation)
    #expect(reply != nil && result != nil && reply! < result!, sourceLocation: sourceLocation)
    #expect(cancelled.prefix(queued.count).allSatisfy { reply != nil && $0 < reply! } && cancelled.last.map { result != nil && $0 > result! } == true,
            sourceLocation: sourceLocation)
}

private func expectInterruptWhilePending(_ seen: Observed, uuid: String, sourceLocation: SourceLocation = #_sourceLocation) {
    expectWellFormed(seen, sourceLocation: sourceLocation)
    let model = seen.model
    // The request was shown, then withdrawn by the CLI; nothing waits and an answer now has nowhere to go.
    let requests = seen.state.events.compactMap { event -> (String, Bool)? in
        switch event {
        case let .request(request): (request.requestID, false)
        case let .cancelled(request): (request.requestID, true)
        case .unsupported, .progress: nil
        }
    }
    #expect(requests.count == 2 && requests[0].1 == false && requests[1].1 == true && requests[0].0 == requests[1].0, sourceLocation: sourceLocation)
    #expect(seen.pending.isEmpty, sourceLocation: sourceLocation)
    #expect(seen.receipt?.stillQueued.isEmpty == true && seen.receipt?.cancelled.isEmpty == true, sourceLocation: sourceLocation)
    #expect(delivery(model, uuid) == .read, sourceLocation: sourceLocation)
    #expect(model.turns.count == 1 && model.turns[0].status == .interrupted, sourceLocation: sourceLocation)
    #expect(model.turns[0].result?.terminalReason == "aborted_tools" && model.turns[0].result?.isError == true, sourceLocation: sourceLocation)
    #expect(model.tools.count == 1 && model.tools[0].status == .denied, sourceLocation: sourceLocation)
    #expect(model.markers.contains { if case .interrupted = $0 { true } else { false } }, sourceLocation: sourceLocation)
    // The CLI withdraws the request first, then answers the interrupt, then rejects the tool call, then ends the turn
    // (S1 t09-pending-interrupt:26,27,29,31).
    let order = [seen.index(of: seen.isCancel),
                 seen.interruptID.flatMap { id in seen.index { seen.isReply(to: id, $0) } },
                 seen.index(of: seen.isToolResult), seen.index(of: seen.isResult)]
    #expect(order.allSatisfy { $0 != nil } && order.compactMap { $0 } == order.compactMap { $0 }.sorted(), "order \(order)", sourceLocation: sourceLocation)
}

private func expectAPIError(_ seen: Observed, uuid: String, sourceLocation: SourceLocation = #_sourceLocation) {
    expectWellFormed(seen, sourceLocation: sourceLocation)
    let model = seen.model
    // A "success" result that is an error: the turn failed, and says why. The text Claude Code printed is a row.
    #expect(model.turns.count == 1 && model.turns[0].status == .failed("api_error"), sourceLocation: sourceLocation)
    #expect(model.turns[0].result?.subtype == .success && model.turns[0].result?.isError == true, sourceLocation: sourceLocation)
    #expect(model.turns[0].result?.apiErrorStatus == 404 && model.turns[0].result?.terminalReason == "api_error", sourceLocation: sourceLocation)
    #expect(model.texts.count == 1 && !model.texts[0].text.isEmpty && model.contextUsage == nil, sourceLocation: sourceLocation)
    let errors = seen.messages.compactMap { message -> String? in if case let .assistant(assistant) = message { assistant.error } else { nil } }
    #expect(errors == ["model_not_found"], sourceLocation: sourceLocation)
    #expect(delivery(model, uuid) == .read, sourceLocation: sourceLocation)
    // The command is cancelled, not completed.
    #expect(seen.index { seen.isLifecycle(.cancelled, $0) } != nil && seen.index { seen.isLifecycle(.completed, $0) } == nil,
            sourceLocation: sourceLocation)
}

// MARK: The cases

@Suite(.serialized, .timeLimit(.minutes(2)))
struct ContractTests {
    // MARK: Plain turn

    @Test func aPlainTurnFromTheFake() async throws {
        let wire = Wire()
        let child = try FakeChild(wire: wire)
        defer { child.stop() }
        let ready = try await wire.initialize()
        let message = OutgoingUserMessage(text: "Reply with exactly: OK")
        wire.sent(message.uuid, "Reply with exactly: OK")
        child.send(message)
        try await wire.waitUntil("the turn to complete") { state in state.frames.contains { if case let .message(.commandLifecycle(l)) = $0 { l.state == .completed } else { false } } }
        expectPlainTurn(await observe(wire, ready: ready), uuid: message.uuid)
    }

    @Test func aPlainTurnFromTheRecording() async throws {
        let uuid = "3addadf2-651b-4b97-adc6-86f87acffa13"
        let wire = Wire(requestIDs: ["7e9f07a4-c746-4b45-a8e1-50881fac9e06"])
        wire.start()
        let ready = Task { try await wire.initialize() }
        try await wire.waitUntil("initialize to go out") { $0.written.count == 1 }
        wire.sent(uuid, "Reply with exactly: OK")
        await play(S1Recording.plainTurn, into: wire)
        expectPlainTurn(await observe(wire, ready: try await ready.value), uuid: uuid)
    }

    // MARK: Interrupt that returns queued sends

    private let queued = ["queued-later-1", "queued-later-2", "queued-next-1"]

    @Test func anInterruptThatReturnsQueuedSendsFromTheFake() async throws {
        let wire = Wire()
        let child = try FakeChild(wire: wire, emitSessionState: true)
        defer { child.stop() }
        let ready = try await wire.initialize()
        let first = OutgoingUserMessage(text: "/scenario work 3000")
        wire.sent(first.uuid, "/scenario work 3000")
        child.send(first)
        try await wire.waitUntil("the first tool") { state in state.model.tools.contains { $0.status == .running } }
        let held = [OutgoingUserMessage(uuid: queued[0], text: "later one", priority: .later),
                    OutgoingUserMessage(uuid: queued[1], text: "later two", priority: .later),
                    OutgoingUserMessage(uuid: queued[2], text: "next one", priority: .next)]
        for message in held {
            wire.sent(message.uuid, "held")
            child.send(message)
        }
        try await wire.waitUntil("the CLI to hold them") { state in self.queued.allSatisfy { delivery(state.model, $0) == .queued } }
        let receipt = try await wire.channel.request(.interrupt(cancelQueued: true)).interruptReceipt
        try await wire.waitUntil("the turn to end") { state in state.model.turns.last?.status == .interrupted && delivery(state.model, first.uuid) == .read && state.frames.contains { if case let .message(.commandLifecycle(l)) = $0 { l.state == .cancelled && l.commandUUID == first.uuid } else { false } } }
        expectInterruptWithQueued(await observe(wire, ready: ready, receipt: receipt), first: first.uuid, queued: queued)
    }

    @Test func anInterruptThatReturnsQueuedSendsFromTheRecording() async throws {
        let first = "fb92f5d0-b468-455c-bd2d-e90b3f1054c3"
        let held = ["ea79d607-6617-455b-b8a6-11f47d0057af", "488bb4dd-593a-47ee-8de3-eb0a34635c91", "cbcb5e2f-e933-431f-89ca-ebc22a7be934"]
        let wire = Wire(requestIDs: ["59c26c8e-48ea-49a7-96ac-12615494f825", "de437551-fe87-4ef5-9e11-6ecf45ce43a4"])
        wire.start()
        let ready = Task { try await wire.initialize() }
        try await wire.waitUntil("initialize to go out") { $0.written.count == 1 }
        let interrupt = Task { try await wire.channel.request(.interrupt(cancelQueued: true)) }
        try await wire.waitUntil("interrupt to go out") { $0.written.count == 2 }
        for uuid in [first] + held { wire.sent(uuid, "sent") }
        wire.noteInterrupt()
        // The host allows the Bash call as soon as it is asked.
        await play(S1Recording.interruptWithQueued, into: wire) { request in
            if case let .canUseTool(permission) = request.kind {
                _ = await wire.channel.respond(to: request.requestID, with: .allow(updatedInput: permission.input))
            }
        }
        let receipt = try await interrupt.value.interruptReceipt
        let seen = await observe(wire, ready: try await ready.value, receipt: receipt)
        expectInterruptWithQueued(seen, first: first, queued: held)
        #expect(seen.interruptID == "de437551-fe87-4ef5-9e11-6ecf45ce43a4")
    }

    // MARK: Interrupt while a can_use_tool is pending

    @Test func anInterruptWhileARequestIsPendingFromTheFake() async throws {
        let wire = Wire()
        let child = try FakeChild(wire: wire, emitSessionState: true)
        defer { child.stop() }
        let ready = try await wire.initialize()
        let message = OutgoingUserMessage(text: "/scenario approval")
        wire.sent(message.uuid, "/scenario approval")
        child.send(message)
        try await wire.waitUntil("the request") { state in !state.events.isEmpty }
        let receipt = try await wire.channel.request(.interrupt(cancelQueued: false)).interruptReceipt
        try await wire.waitUntil("the turn to end") { state in state.model.turns.last?.status == .interrupted && state.events.count == 2 }
        expectInterruptWhilePending(await observe(wire, ready: ready, receipt: receipt), uuid: message.uuid)
    }

    @Test func anInterruptWhileARequestIsPendingFromTheRecording() async throws {
        let uuid = "5b4326a8-5948-4a38-9fe0-30141ef06d93"
        let wire = Wire(requestIDs: ["5b613e7e-3529-4ab1-a381-febbd897fa7f", "7bd1f9eb-ee00-4a6b-9b01-a1cb8ca2251f"])
        wire.start()
        let ready = Task { try await wire.initialize() }
        try await wire.waitUntil("initialize to go out") { $0.written.count == 1 }
        let interrupt = Task { try await wire.channel.request(.interrupt(cancelQueued: false)) }
        try await wire.waitUntil("interrupt to go out") { $0.written.count == 2 }
        wire.sent(uuid, "sent")
        wire.noteInterrupt()
        await play(S1Recording.interruptWhilePending, into: wire)
        try await wire.waitUntil("both events") { $0.events.count == 2 }
        let receipt = try await interrupt.value.interruptReceipt
        expectInterruptWhilePending(await observe(wire, ready: try await ready.value, receipt: receipt), uuid: uuid)
        // A late answer to the withdrawn request has nowhere to go.
        let id = try #require(wire.snapshot().events.first.flatMap { event -> String? in if case let .request(request) = event { request.requestID } else { nil } })
        #expect(await wire.channel.respond(to: id, with: .deny(message: "late")) == false)
    }

    // MARK: api_error

    @Test func anApiErrorResultFromTheFake() async throws {
        let wire = Wire()
        let child = try FakeChild(wire: wire)
        defer { child.stop() }
        let ready = try await wire.initialize()
        let text = "/scenario result api_error 404 model_not_found"
        let message = OutgoingUserMessage(text: text)
        wire.sent(message.uuid, text)
        child.send(message)
        try await wire.waitUntil("the command to be cancelled") { state in state.frames.contains { if case let .message(.commandLifecycle(l)) = $0 { l.state == .cancelled } else { false } } }
        expectAPIError(await observe(wire, ready: ready), uuid: message.uuid)
    }

    @Test func anApiErrorResultFromTheRecording() async throws {
        let uuid = "6163e963-1e80-4716-9bd5-032d48ba13f3"
        let wire = Wire(requestIDs: ["9567340d-4de0-43b3-afb2-875dfc1c8fbb"])
        wire.start()
        let ready = Task { try await wire.initialize() }
        try await wire.waitUntil("initialize to go out") { $0.written.count == 1 }
        wire.sent(uuid, "Reply with exactly: OK")
        await play(S1Recording.apiError, into: wire)
        expectAPIError(await observe(wire, ready: try await ready.value), uuid: uuid)
    }
}
