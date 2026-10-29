import Darwin
import CryptoKit
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// Scripted PTY writer: each call accepts at most the next scripted count
/// (0 models EAGAIN), recording exactly the accepted prefix.
private final class ScriptedWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Int]
    private var stored = Data()
    private var count = 0
    private let failAfter: Int?

    init(script: [Int], failAfter: Int? = nil) {
        self.script = script
        self.failAfter = failAfter
    }

    func write(_ data: Data) throws -> Int {
        try lock.withLock {
            count += 1
            if let failAfter, stored.count >= failAfter { throw LoomError.message("terminal closed") }
            let limit = script.isEmpty ? data.count : script.removeFirst()
            let accepted = min(limit, data.count)
            stored.append(data.prefix(accepted))
            return accepted
        }
    }
    var received: Data { lock.withLock { stored } }
    var calls: Int { lock.withLock { count } }
}

private final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [TerminalInputError] = []
    func append(_ error: TerminalInputError) { lock.withLock { errors.append(error) } }
    var values: [TerminalInputError] { lock.withLock { errors } }
}

/// A task write held in its permit until `release()`; the permit then refuses it.
private final class PausedTaskWrite: @unchecked Sendable {
    private let gate = ActorFreezeGate()
    func permit() -> Bool {
        gate.hold()
        return false
    }
    var isEntered: Bool { gate.entered }
    func release() { gate.release() }
}

private final class PTYOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ value: Data) { lock.withLock { bytes.append(value) } }
    var data: Data { lock.withLock { bytes } }
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

/// Serialized: a `PausedTaskWrite` holds the thread the queue's write runs on (a thread of the cooperative pool) until the test
/// releases it, and four such tests at once, with the other suites' waits, held every pool thread their releases needed.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalInputQueueTests {
    @Test func aDirtyIdleComposerDoesNotScheduleAnAutomaticRetry() {
        let queue = TerminalInputQueue(writer: { $0.count }, onError: { _ in })
        queue.noteUnclassifiedInput()
        let result = IdleResult()
        #expect(!queue.notifyWhenAutomaticMayProceed { result.append(true) })
        #expect(result.values.isEmpty)
    }
    @Test func externalTaskInputRequiresAnUnchangedCleanComposerAtTheActualWrite() throws {
        let queue = TerminalInputQueue(capacity: 1024, writer: { $0.count },
            automaticWriter: { bytes, transaction in try transaction { bytes.count } }, onError: { _ in })
        #expect(queue.establishFreshCleanInput())
        let first = try #require(queue.reserveAutomaticInput())
        #expect(queue.reserveAutomaticInput() == nil)
        queue.noteUnclassifiedInput()
        var writes = 0
        #expect(queue.writeReservedAutomatic(first) { writes += 1; return 7 } == nil)
        #expect(writes == 0)
        queue.releaseReservedAutomatic(first)
        #expect(queue.reserveAutomaticInput() == nil, "user input remains dirty")

        let clean = TerminalInputQueue(capacity: 1024, writer: { $0.count },
            automaticWriter: { bytes, transaction in try transaction { bytes.count } }, onError: { _ in })
        #expect(clean.establishFreshCleanInput())
        let retryable = try #require(clean.reserveAutomaticInput())
        clean.releaseReservedAutomatic(retryable)
        let committed = try #require(clean.reserveAutomaticInput())
        #expect(clean.writeReservedAutomatic(committed) { 7 } == 7)
        clean.releaseReservedAutomatic(committed)
        #expect(clean.reserveAutomaticInput() == nil, "a write is held until provider proof")
        #expect(clean.confirmAutomaticInput(committed))
        #expect(clean.reserveAutomaticInput() != nil)
    }
    @Test func providerEventBeforeWriteCancelsOnlyTheAutomaticChunk() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try writer.write($0) },
            automaticWriter: { bytes, transaction in try transaction { try writer.write(bytes) } }, onError: { _ in })
        let pause = PausedTaskWrite()
        #expect(queue.establishFreshCleanInput())
        let proposed = queue.enqueueAutomatic(Data("task pointer\r".utf8), transaction: { write in
            guard pause.permit() else { return nil }
            return try write()
        })
        let ticket = try #require(proposed)
        #expect(try await SessionRuntimeRig.waitUntil(2) { pause.isEntered })
        #expect(queue.enqueue(Data("user draft".utf8)))
        pause.release()
        #expect(await ticket.writeOutcome() == .notWritten)
        try await waitUntilIdle(queue)
        #expect(writer.received == Data("user draft".utf8))
        #expect(queue.enqueueAutomatic(Data("another\r".utf8), transaction: { try $0() }) == nil)
    }

    @Test func aWrittenTerminalPointerCannotBeReleasedBeforeProviderObservation() async throws {
        let queue = TerminalInputQueue(capacity: 1024, writer: { $0.count },
            automaticWriter: { bytes, transaction in try transaction { bytes.count } }, onError: { _ in })
        #expect(queue.establishFreshCleanInput())
        let ticket = try #require(queue.reserveAutomaticInput())
        let accepted = queue.enqueueReservedAutomatic(ticket, bytes: Data("pointer\r".utf8), transaction: { try $0() })
        #expect(accepted)
        #expect(await ticket.writeOutcome() == .written)
        queue.releaseReservedAutomatic(ticket)
        #expect(queue.reserveAutomaticInput() == nil)
        #expect(queue.confirmAutomaticInput(ticket))
    }

    @Test func onlyALaterExactPlainSubmissionCanRestoreTheManualInputBoundary() async throws {
        let queue = TerminalInputQueue(capacity: 1024, writer: { $0.count }, onError: { _ in })
        #expect(queue.enqueue(Data("plain request\r".utf8)))
        try await waitUntilIdle(queue)
        let digest = Data(SHA256.hash(data: Data("plain request".utf8)))
        if case .unverified = queue.confirmManualInput(digest: digest, observedAt: 0) {} else {
            Issue.record("An old provider event must not clear a later submission")
        }
        #expect(queue.reserveAutomaticInput() == nil)
        if case .confirmed = queue.confirmManualInput(digest: digest, observedAt: .max) {} else {
            Issue.record("The exact later input observation should restore the clean boundary")
        }
        let ticket = try #require(queue.reserveAutomaticInput())
        queue.releaseReservedAutomatic(ticket)
        #expect(queue.enqueue(Data("new draft".utf8)))
        #expect(queue.reserveAutomaticInput() == nil)
    }

    @Test func editedOrMultilineManualBytesNeverCreateAPlainSubmissionProof() async throws {
        for bytes in [Data("abc\u{7f}d\r".utf8), Data("first\nsecond\r".utf8)] {
            let queue = TerminalInputQueue(capacity: 1024, writer: { $0.count }, onError: { _ in })
            #expect(queue.enqueue(bytes))
            try await waitUntilIdle(queue)
            let digest = Data(SHA256.hash(data: Data("abd".utf8)))
            if case .unverified = queue.confirmManualInput(digest: digest, observedAt: .max) {} else {
                Issue.record("Edited or multiline bytes cannot prove a plain input")
            }
            #expect(queue.reserveAutomaticInput() == nil)
        }
    }

    @Test func providerEventAfterPartialTaskWriteIsUnknownAndNeverRetried() async throws {
        let writer = ScriptedWriter(script: [1])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try writer.write($0) },
            automaticWriter: { bytes, transaction in try transaction { try writer.write(bytes) } }, onError: { _ in })
        let permit = PermitOnce()
        #expect(queue.establishFreshCleanInput())
        let proposed = queue.enqueueAutomatic(Data("pointer\r".utf8), transaction: { write in
            guard permit.check() else { return nil }
            return try write()
        })
        let ticket = try #require(proposed)
        #expect(await ticket.writeOutcome() == .unknown)
        try await waitUntilIdle(queue)
        #expect(queue.enqueue(Data("user".utf8)))
        try await waitUntilIdle(queue)
        #expect(writer.received == Data("puser".utf8))
        #expect(queue.enqueueAutomatic(Data("retry\r".utf8), transaction: { try $0() }) == nil)
    }

    @Test func ingressAfterAsyncEnqueueStillFencesTheActualWrite() async throws {
        let writer = ScriptedWriter(script: []), pause = PausedTaskWrite(), lease = SessionTaskRunLease()
        let queue = TerminalInputQueue(capacity: 1024, writer: { try writer.write($0) },
            automaticWriter: { bytes, transaction in
                _ = pause.permit()
                return try transaction { try writer.write(bytes) }
            }, onError: { _ in })
        let revision = try #require(lease.admit { $0 })
        #expect(queue.establishFreshCleanInput())
        let proposed = queue.enqueueAutomatic(Data("task pointer\r".utf8), transaction: { write in
            try lease.withAdmission(revision: revision, write)
        })
        let ticket = try #require(proposed)
        #expect(try await SessionRuntimeRig.waitUntil(2) { pause.isEntered })
        lease.beginHook()
        lease.finishHook()
        #expect(queue.enqueue(Data("user draft".utf8)))
        pause.release()
        #expect(await ticket.writeOutcome() == .notWritten)
        try await waitUntilIdle(queue)
        #expect(writer.received == Data("user draft".utf8))
    }

    @Test func userInputBeforeTheActualWriteCancelsTheQueuedPointer() async throws {
        let writer = ScriptedWriter(script: []), pause = PausedTaskWrite()
        let queue = TerminalInputQueue(capacity: 1024, writer: { try writer.write($0) },
            automaticWriter: { bytes, transaction in
                _ = pause.permit()
                return try transaction { try writer.write(bytes) }
            }, onError: { _ in })
        #expect(queue.establishFreshCleanInput())
        let proposed = queue.enqueueAutomatic(Data("task pointer\r".utf8), transaction: { try $0() })
        let ticket = try #require(proposed)
        #expect(try await SessionRuntimeRig.waitUntil(2) { pause.isEntered })
        queue.noteUnclassifiedInput()
        #expect(queue.enqueue(Data("user draft".utf8)))
        pause.release()
        #expect(await ticket.writeOutcome() == .notWritten)
        try await waitUntilIdle(queue)
        #expect(writer.received == Data("user draft".utf8))
    }

    @Test func realPTYTransactionRefusesBeforeSyscallAndOrdinaryInputStillFlows() async throws {
        let process = try PTYProcess(executable: "/bin/cat", arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                                     directory: "/tmp", rows: 24, columns: 80)
        defer { _ = Darwin.kill(process.pid, SIGKILL); _ = Darwin.waitpid(process.pid, nil, WNOHANG) }
        let output = PTYOutput(), pause = PausedTaskWrite(), lease = SessionTaskRunLease()
        let transport = EventDrivenPTYProcess(process: process, onOutput: { output.append($0) }, onExit: { _ in })
        let revision = try #require(lease.admit { $0 })
        let attempt = Task {
            try await transport.writeAutomatically(Data("unexpected\n".utf8), transaction: { write in
                _ = pause.permit()
                return try lease.withAdmission(revision: revision, write)
            })
        }
        #expect(try await SessionRuntimeRig.waitUntil(2) { pause.isEntered })
        lease.beginHook()
        lease.finishHook()
        pause.release()
        #expect(try await attempt.value == nil)
        #expect(try await transport.write(Data("ordinary\n".utf8)) == 9)
        #expect(try await SessionRuntimeRig.waitUntil(2) {
            String(decoding: output.data, as: UTF8.self).contains("ordinary")
        })
        #expect(!String(decoding: output.data, as: UTF8.self).contains("unexpected"))
        _ = Darwin.kill(process.pid, SIGTERM)
        _ = try await transport.finish(outputDrainSeconds: 2)
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
        let queue = TerminalInputQueue(capacity: 1024, writer: { try writer.write($0) },
            automaticWriter: { bytes, transaction in try transaction { try writer.write(bytes) } }, onError: { _ in })
        let gate = TerminalInputGate(), runID = UUID()
        gate.register(runID: runID, queue: queue)
        #expect(gate.establishFreshCleanInput(runID: runID))
        #expect(queue.enqueue(Data("unsent draft".utf8)))
        try await waitUntilIdle(queue)
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("task pointer\r".utf8), transaction: { try $0() }) == nil)
        try await waitUntilIdle(queue)
        #expect(writer.received == Data("unsent draft".utf8))
    }

    @Test func automaticProofCannotClearLaterUnclassifiedInput() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try writer.write($0) },
            automaticWriter: { bytes, transaction in try transaction { try writer.write(bytes) } }, onError: { _ in })
        let gate = TerminalInputGate(), runID = UUID()
        gate.register(runID: runID, queue: queue)
        #expect(gate.establishFreshCleanInput(runID: runID))
        let proposed = gate.enqueueAutomatic(runID: runID, bytes: Data("first\r".utf8), transaction: { try $0() })
        let ticket = try #require(proposed)
        try await waitUntilIdle(queue)
        #expect(queue.enqueue(Data("next draft".utf8)))
        try await waitUntilIdle(queue)
        #expect(!gate.confirmAutomaticInput(runID: runID, ticket: ticket))
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("second\r".utf8), transaction: { try $0() }) == nil)
        try await waitUntilIdle(queue)
        #expect(writer.received == Data("first\rnext draft".utf8))
    }

    @Test func automaticInputRequiresAProvenCleanBoundaryAndOnePrintableLine() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try writer.write($0) },
            automaticWriter: { bytes, transaction in try transaction { try writer.write(bytes) } }, onError: { _ in })
        let gate = TerminalInputGate(), runID = UUID()
        gate.register(runID: runID, queue: queue)
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("first\r".utf8), transaction: { try $0() }) == nil)
        #expect(gate.establishFreshCleanInput(runID: runID))
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("first\nsecond\r".utf8), transaction: { try $0() }) == nil)
        let proposed = gate.enqueueAutomatic(runID: runID, bytes: Data("first\r".utf8), transaction: { try $0() })
        let first = try #require(proposed)
        try await waitUntilIdle(queue)
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("second\r".utf8), transaction: { try $0() }) == nil)
        #expect(gate.confirmAutomaticInput(runID: runID, ticket: first))
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("second\r".utf8), transaction: { try $0() }) != nil)
        try await waitUntilIdle(queue)
        #expect(writer.received == Data("first\rsecond\r".utf8))
        gate.unregister(runID: runID)
        #expect(gate.enqueueAutomatic(runID: runID, bytes: Data("third\r".utf8), transaction: { try $0() }) == nil)
    }

    @Test func idleCallbackRechecksFreshBoundaryWithoutLosingDrainRace() async throws {
        let pause = PausedTaskWrite(), result = IdleResult()
        let queue = TerminalInputQueue(capacity: 1024, writer: { data in
            _ = pause.permit()
            return data.count
        }, onError: { _ in })
        #expect(queue.enqueueTerminalResponse(Data("\u{1b}[1;1R".utf8)))
        #expect(try await SessionRuntimeRig.waitUntil(2) { pause.isEntered })
        #expect(queue.notifyWhenIdle { result.append(queue.establishFreshCleanInput()) })
        #expect(!queue.notifyWhenIdle { result.append(false) })
        pause.release()
        #expect(try await SessionRuntimeRig.waitUntil(2) { !result.values.isEmpty })
        #expect(result.values == [true])
        #expect(queue.notifyWhenIdle { result.append(queue.establishFreshCleanInput()) })
        #expect(result.values == [true, true])
    }

    @Test func parserRepliesDoNotDirtyAnOtherwiseFreshInputQueue() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try writer.write($0) },
            automaticWriter: { bytes, transaction in try transaction { try writer.write(bytes) } }, onError: { _ in })
        #expect(queue.enqueueTerminalResponse(Data("\u{1b}[1;1R".utf8)))
        try await waitUntilIdle(queue)
        #expect(queue.establishFreshCleanInput())
        #expect(writer.received == Data("\u{1b}[1;1R".utf8))
    }

    @Test func priorUnclassifiedInputCannotBeDeclaredFresh() async throws {
        let writer = ScriptedWriter(script: [])
        let queue = TerminalInputQueue(capacity: 1024, writer: { try writer.write($0) },
            automaticWriter: { bytes, transaction in try transaction { try writer.write(bytes) } }, onError: { _ in })
        #expect(queue.enqueue(Data("\u{1b}[1;1R".utf8)))
        try await waitUntilIdle(queue)
        #expect(!queue.establishFreshCleanInput())
        #expect(queue.enqueueAutomatic(Data("pointer\r".utf8), transaction: { try $0() }) == nil)
        #expect(writer.received == Data("\u{1b}[1;1R".utf8))
    }

    @Test func shortAndBlockedWritesKeepEveryByteInCallerOrder() async throws {
        let writer = ScriptedWriter(script: [1, 0, 3, 0, 0, 2, 7, 1])
        let errors = ErrorLog()
        let queue = TerminalInputQueue(capacity: 1024, writer: { try writer.write($0) },
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
        #expect(writer.received == expected)
        #expect(queue.pendingByteCount == 0)
        #expect(errors.values.isEmpty)
    }

    @Test func overflowRejectsWholePayloadAndLaterInputStillFlows() async throws {
        let writer = ScriptedWriter(script: Array(repeating: 0, count: 5))
        let errors = ErrorLog()
        let queue = TerminalInputQueue(capacity: 8, writer: { try writer.write($0) },
                                       onError: errors.append)
        #expect(queue.enqueue(Data("12345".utf8)))
        #expect(!queue.enqueue(Data("6789".utf8)))
        #expect(queue.enqueue(Data("abc".utf8)))
        try await waitUntilIdle(queue)
        #expect(writer.received == Data("12345abc".utf8))
        #expect(errors.values == [.overflow(pending: 5, rejected: 4, capacity: 8)])
    }

    @Test func writeFailureIsReportedAndLaterInputIsRefused() async throws {
        let writer = ScriptedWriter(script: [], failAfter: 3)
        let errors = ErrorLog()
        let queue = TerminalInputQueue(capacity: 64, writer: { try writer.write($0) },
                                       onError: errors.append)
        #expect(queue.enqueue(Data("abc".utf8)))
        try await waitUntilIdle(queue)
        #expect(queue.enqueue(Data("def".utf8)))
        try await waitUntilIdle(queue)
        #expect(!queue.enqueue(Data("ghi".utf8)))
        #expect(writer.received == Data("abc".utf8))
        let values = errors.values
        #expect(values.count == 2)
        #expect(values.allSatisfy { if case .writeFailed = $0 { true } else { false } })
        #expect(queue.pendingByteCount == 0)
    }
}
