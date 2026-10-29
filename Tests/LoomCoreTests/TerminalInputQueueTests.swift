import Foundation
import Testing
@testable import LoomCore

/// Scripted PTY writer: each call accepts at most the next scripted count
/// (0 models EAGAIN), recording exactly the accepted prefix.
private actor ScriptedWriter {
    private var script: [Int]
    private(set) var received = Data()
    private(set) var calls = 0
    private let failAfter: Int?

    init(script: [Int], failAfter: Int? = nil) {
        self.script = script
        self.failAfter = failAfter
    }

    func write(_ data: Data) throws -> Int {
        calls += 1
        if let failAfter, received.count >= failAfter {
            throw LoomError.message("terminal closed")
        }
        let limit = script.isEmpty ? data.count : script.removeFirst()
        let accepted = min(limit, data.count)
        received.append(data.prefix(accepted))
        return accepted
    }
}

private final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [TerminalInputError] = []
    func append(_ error: TerminalInputError) { lock.withLock { errors.append(error) } }
    var values: [TerminalInputError] { lock.withLock { errors } }
}

private final class PausedTaskWrite: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    func permit() -> Bool {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return false
    }
    var isEntered: Bool { condition.withLock { entered } }
    func release() { condition.withLock { released = true; condition.broadcast() } }
}

private final class IdleResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    func append(_ value: Bool) { lock.withLock { storage.append(value) } }
    var values: [Bool] { lock.withLock { storage } }
}

private final class PermitOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func check() -> Bool { lock.withLock { calls += 1; return calls == 1 } }
}

@Suite(.timeLimit(.minutes(1)))
struct TerminalInputQueueTests {
    @Test func providerEventBeforeWriteCancelsOnlyTheAutomaticChunk() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try await writer.write($0) }, onError: { _ in })
        let pause = PausedTaskWrite()
        #expect(queue.establishFreshCleanInput())
        let ticket = try #require(queue.enqueueAutomatic(Data("task pointer\r".utf8), permit: pause.permit))
        #expect(try await SessionRuntimeTests.waitUntil(2) { pause.isEntered })
        #expect(queue.enqueue(Data("user draft".utf8)))
        pause.release()
        #expect(await ticket.writeOutcome() == .notWritten)
        try await waitUntilIdle(queue)
        #expect(await writer.received == Data("user draft".utf8))
        #expect(queue.enqueueAutomatic(Data("another\r".utf8)) == nil)
    }

    @Test func providerEventAfterPartialTaskWriteIsUnknownAndNeverRetried() async throws {
        let writer = ScriptedWriter(script: [1])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try await writer.write($0) }, onError: { _ in })
        let permit = PermitOnce()
        #expect(queue.establishFreshCleanInput())
        let ticket = try #require(queue.enqueueAutomatic(Data("pointer\r".utf8), permit: permit.check))
        #expect(await ticket.writeOutcome() == .unknown)
        try await waitUntilIdle(queue)
        #expect(queue.enqueue(Data("user".utf8)))
        try await waitUntilIdle(queue)
        #expect(await writer.received == Data("puser".utf8))
        #expect(queue.enqueueAutomatic(Data("retry\r".utf8)) == nil)
    }

    private func waitUntilIdle(_ queue: TerminalInputQueue) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while queue.isDraining {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("input queue did not drain")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func automaticInputNeverAppendsToUnclassifiedTerminalBytes() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try await writer.write($0) }, onError: { _ in })
        let gate = TerminalInputGate(), runID = UUID()
        gate.register(runID: runID, queue: queue)
        #expect(gate.establishFreshCleanInput(runID: runID))
        #expect(queue.enqueue(Data("unsent draft".utf8)))
        try await waitUntilIdle(queue)
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("task pointer\r".utf8)) == nil)
        try await waitUntilIdle(queue)
        #expect(await writer.received == Data("unsent draft".utf8))
    }

    @Test func automaticProofCannotClearLaterUnclassifiedInput() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try await writer.write($0) }, onError: { _ in })
        let gate = TerminalInputGate(), runID = UUID()
        gate.register(runID: runID, queue: queue)
        #expect(gate.establishFreshCleanInput(runID: runID))
        let ticket = try #require(gate.enqueueAutomatic(runID: runID, bytes: Data("first\r".utf8)))
        try await waitUntilIdle(queue)
        #expect(queue.enqueue(Data("next draft".utf8)))
        try await waitUntilIdle(queue)
        #expect(!gate.confirmAutomaticInput(runID: runID, ticket: ticket))
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("second\r".utf8)) == nil)
        try await waitUntilIdle(queue)
        #expect(await writer.received == Data("first\rnext draft".utf8))
    }

    @Test func automaticInputRequiresAProvenCleanBoundaryAndOnePrintableLine() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try await writer.write($0) }, onError: { _ in })
        let gate = TerminalInputGate(), runID = UUID()
        gate.register(runID: runID, queue: queue)
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("first\r".utf8)) == nil)
        #expect(gate.establishFreshCleanInput(runID: runID))
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("first\nsecond\r".utf8)) == nil)
        let first = try #require(gate.enqueueAutomatic(runID: runID, bytes: Data("first\r".utf8)))
        try await waitUntilIdle(queue)
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("second\r".utf8)) == nil)
        #expect(gate.confirmAutomaticInput(runID: runID, ticket: first))
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("second\r".utf8)) != nil)
        try await waitUntilIdle(queue)
        #expect(await writer.received == Data("first\rsecond\r".utf8))
        gate.unregister(runID: runID)
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("third\r".utf8)) == nil)
    }

    @Test func idleCallbackRechecksFreshBoundaryWithoutLosingDrainRace() async throws {
        let pause = PausedTaskWrite(), result = IdleResult()
        let queue = TerminalInputQueue(capacity: 1024, writer: { data in
            _ = pause.permit()
            return data.count
        }, onError: { _ in })
        #expect(queue.enqueueTerminalResponse(Data("\u{1b}[1;1R".utf8)))
        #expect(try await SessionRuntimeTests.waitUntil(2) { pause.isEntered })
        #expect(queue.notifyWhenIdle { result.append(queue.establishFreshCleanInput()) })
        #expect(!queue.notifyWhenIdle { result.append(false) })
        pause.release()
        #expect(try await SessionRuntimeTests.waitUntil(2) { !result.values.isEmpty })
        #expect(result.values == [true])
        #expect(queue.notifyWhenIdle { result.append(queue.establishFreshCleanInput()) })
        #expect(result.values == [true, true])
    }

    @Test func parserRepliesDoNotDirtyAnOtherwiseFreshInputQueue() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try await writer.write($0) }, onError: { _ in })
        #expect(queue.enqueueTerminalResponse(Data("\u{1b}[1;1R".utf8)))
        try await waitUntilIdle(queue)
        #expect(queue.establishFreshCleanInput())
        #expect(await writer.received == Data("\u{1b}[1;1R".utf8))
    }

    @Test func priorUnclassifiedInputCannotBeDeclaredFresh() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try await writer.write($0) }, onError: { _ in })
        #expect(queue.enqueue(Data("\u{1b}[1;1R".utf8)))
        try await waitUntilIdle(queue)
        #expect(!queue.establishFreshCleanInput())
        #expect(queue.enqueueAutomatic(Data("pointer\r".utf8)) == nil)
        #expect(await writer.received == Data("\u{1b}[1;1R".utf8))
    }

    @Test func shortAndBlockedWritesKeepEveryByteInCallerOrder() async throws {
        let writer = ScriptedWriter(script: [1, 0, 3, 0, 0, 2, 7, 1])
        let errors = ErrorLog()
        let queue = TerminalInputQueue(capacity: 1024, writer: { try await writer.write($0) },
                                       onError: errors.append)
        var expected = Data()
        for index in 0..<50 {
            // Interleaves keystrokes, a multi-byte paste and terminal replies.
            let payload = index % 7 == 0 ? Data("\u{1b}[200~paste ğüş \(index)\u{1b}[201~".utf8)
                : index % 5 == 0 ? Data("\u{1b}[12;40R".utf8) : Data([UInt8(0x61 + index % 26)])
            #expect(queue.enqueue(payload))
            expected.append(payload)
        }
        try await waitUntilIdle(queue)
        #expect(await writer.received == expected)
        #expect(queue.pendingByteCount == 0)
        #expect(errors.values.isEmpty)
    }

    @Test func overflowRejectsWholePayloadAndLaterInputStillFlows() async throws {
        let writer = ScriptedWriter(script: Array(repeating: 0, count: 5))
        let errors = ErrorLog()
        let queue = TerminalInputQueue(capacity: 8, writer: { try await writer.write($0) },
                                       onError: errors.append)
        #expect(queue.enqueue(Data("12345".utf8)))
        #expect(!queue.enqueue(Data("6789".utf8)))
        #expect(queue.enqueue(Data("abc".utf8)))
        try await waitUntilIdle(queue)
        #expect(await writer.received == Data("12345abc".utf8))
        #expect(errors.values == [.overflow(pending: 5, rejected: 4, capacity: 8)])
    }

    @Test func writeFailureIsReportedAndLaterInputIsRefused() async throws {
        let writer = ScriptedWriter(script: [], failAfter: 3)
        let errors = ErrorLog()
        let queue = TerminalInputQueue(capacity: 64, writer: { try await writer.write($0) },
                                       onError: errors.append)
        #expect(queue.enqueue(Data("abc".utf8)))
        try await waitUntilIdle(queue)
        #expect(queue.enqueue(Data("def".utf8)))
        try await waitUntilIdle(queue)
        #expect(!queue.enqueue(Data("ghi".utf8)))
        #expect(await writer.received == Data("abc".utf8))
        let values = errors.values
        #expect(values.count == 2)
        #expect(values.allSatisfy { if case .writeFailed = $0 { true } else { false } })
        #expect(queue.pendingByteCount == 0)
    }
}
