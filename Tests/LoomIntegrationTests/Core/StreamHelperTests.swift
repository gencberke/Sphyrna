import Darwin
import Foundation
import Synchronization
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// `ProcessSupervisor.streamHelper`: an owned one-shot child that is fed a stdin and answers as a stream
/// (Remora's `claude -p` call is its user). Shell children stand in for the model.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct StreamHelperTests {
    private let environment = ["PATH": "/usr/bin:/bin"]

    private func supervisor() throws -> ProcessSupervisor { try ProcessSupervisor(ledger: OwnershipLedger()) }

    private func pidFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("loom-stream-pid-\(UUID())")
    }

    private func readPID(_ file: URL) async -> Int32? {
        var pid: Int32?
        _ = await SessionRuntimeRig.waitUntil(5) {
            pid = (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return pid != nil
        }
        return pid
    }

    private func alive(_ pid: Int32) throws -> Bool {
        try ProcessTable.snapshot().contains { $0.identity.pid == pid && !$0.zombie }
    }

    private func gone(_ pid: Int32, within seconds: TimeInterval = 3) async throws -> Bool {
        try await SessionRuntimeRig.waitUntil(seconds) { try !alive(pid) }
    }

    /// Runs `script` under sh with its pid written to `file` first.
    private func script(_ body: String, pids file: URL) -> [String] { ["-c", "echo $$ > \(file.path); \(body)"] }

    // MARK: Streaming

    @Test func chunksArriveBeforeTheChildExits() async throws {
        let supervisor = try supervisor()
        // The child writes its second line only after the test saw the first (the gate file). A helper that held the output
        // until the exit would never let the test see it, and the stream would end at the deadline instead: ordering, not a
        // clock, so a loaded machine cannot fail it.
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("stream-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gate) }
        var text = ""
        for try await chunk in supervisor.streamHelper(
            "/bin/sh", ["-c", "echo one; while [ ! -e \(gate.path) ]; do sleep 0.02; done; echo two"],
            environment: environment, timeout: 20
        ) {
            if text.isEmpty { FileManager.default.createFile(atPath: gate.path, contents: nil) }
            text += String(decoding: chunk, as: UTF8.self)
        }
        #expect(text == "one\ntwo\n")
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func stdinIsDeliveredWholeAndClosed() async throws {
        let supervisor = try supervisor()
        // `cat` leaves only at the end of its input, and 300 KB is several pipe buffers: this fails when the pack is not
        // written in pieces while the child runs, or when the pipe is not closed afterwards.
        let pack = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        var received = Data()
        for try await chunk in supervisor.streamHelper("/bin/cat", [], environment: environment, input: pack, timeout: 20) {
            received.append(chunk)
        }
        #expect(received == pack)
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func aChildThatNeverReadsItsInputDoesNotBlockTheCall() async throws {
        let supervisor = try supervisor()
        var text = ""
        for try await chunk in supervisor.streamHelper(
            "/bin/sh", ["-c", "echo done"], environment: environment, input: Data(count: 400_000), timeout: 10
        ) { text += String(decoding: chunk, as: UTF8.self) }
        #expect(text == "done\n")
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func aNonZeroExitFinishesWithTheStatusAndTheHeadOfStderr() async throws {
        let supervisor = try supervisor()
        var text = ""
        var failure: (any Error)?
        do {
            for try await chunk in supervisor.streamHelper(
                "/bin/sh", ["-c", "echo partial; echo broken >&2; exit 3"], environment: environment, timeout: 10
            ) { text += String(decoding: chunk, as: UTF8.self) }
        } catch { failure = error }
        #expect(text == "partial\n")
        guard case let .helperExit(status, detail)? = failure as? LoomError else {
            Issue.record("expected helperExit, got \(String(describing: failure))")
            return
        }
        #expect(status == 3)
        #expect(detail == "broken")
        #expect((await supervisor.shutdown()).succeeded)
    }

    // MARK: Bounds

    @Test func theDeadlineSendsSIGTERMThenSIGKILL() async throws {
        let supervisor = try supervisor()
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        // Ignores SIGTERM, so only the SIGKILL after the grace can end it.
        let arguments = script("trap '' TERM; echo ready; while :; do sleep 1; done", pids: file)
        let clock = ContinuousClock()
        var failure: (any Error)?
        var text = ""
        let elapsed = await clock.measure {
            do {
                for try await chunk in supervisor.streamHelper(
                    "/bin/sh", arguments, environment: environment, timeout: 0.6, terminationGrace: 0.4
                ) { text += String(decoding: chunk, as: UTF8.self) }
            } catch { failure = error }
        }
        #expect(failure as? StreamHelperError == .timedOut)
        #expect(text == "ready\n")
        #expect(elapsed > .seconds(0.9), "SIGKILL came before the grace: \(elapsed)")
        // The child never ends by itself: any end is the SIGKILL. The bound only catches a hang, with room for a loaded machine.
        #expect(elapsed < .seconds(15), "took \(elapsed)")
        let pid = try #require(await readPID(file))
        #expect(try await gone(pid))
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func theDeadlineEndsAChildThatLeavesOnSIGTERMAtOnce() async throws {
        let supervisor = try supervisor()
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = ContinuousClock()
        var failure: (any Error)?
        let elapsed = await clock.measure {
            do {
                for try await _ in supervisor.streamHelper(
                    "/bin/sh", script("exec sleep 60", pids: file), environment: environment, timeout: 0.4, terminationGrace: 30
                ) {}
            } catch { failure = error }
        }
        #expect(failure as? StreamHelperError == .timedOut)
        #expect(elapsed < .seconds(15), "waited out the 30 s grace: \(elapsed)")
        let pid = try #require(await readPID(file))
        #expect(try await gone(pid))
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func aCancelEndsTheChildAtOnce() async throws {
        let supervisor = try supervisor()
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let consumer = Task {
            var count = 0
            for try await chunk in supervisor.streamHelper(
                "/bin/sh", script("echo started; exec sleep 60", pids: file), environment: environment, timeout: 60
            ) { count += chunk.count }
            return count
        }
        let pid = try #require(await readPID(file))
        #expect(try alive(pid))
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            consumer.cancel()
            _ = try? await consumer.value
        }
        // At once, against a child and a deadline of 60 s; the bound leaves room for a loaded machine.
        #expect(elapsed < .seconds(10), "the consumer waited \(elapsed)")
        #expect(try await gone(pid, within: 10))
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func droppingTheStreamEndsTheChildToo() async throws {
        let supervisor = try supervisor()
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var stream: AsyncThrowingStream<Data, any Error>? = supervisor.streamHelper(
            "/bin/sh", script("echo started; exec sleep 60", pids: file), environment: environment, timeout: 60
        )
        var iterator = stream?.makeAsyncIterator()
        _ = try await iterator?.next() // the first chunk: the child is running
        let pid = try #require(await readPID(file))
        iterator = nil
        stream = nil
        #expect(try await gone(pid, within: 3))
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func outputBeyondTheBoundThrowsAndStopsTheChild() async throws {
        let supervisor = try supervisor()
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var failure: (any Error)?
        var seen = 0
        do {
            for try await chunk in supervisor.streamHelper(
                "/bin/sh", script("exec yes", pids: file), environment: environment, timeout: 20, outputLimit: 100_000
            ) { seen += chunk.count }
        } catch { failure = error }
        guard case let .outputTooLarge(limit)? = failure as? LoomError else {
            Issue.record("expected outputTooLarge, got \(String(describing: failure))")
            return
        }
        #expect(limit == 100_000)
        #expect(seen <= 100_000)
        let pid = try #require(await readPID(file))
        #expect(try await gone(pid))
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func stderrBeyondItsBoundThrows() async throws {
        let supervisor = try supervisor()
        var failure: (any Error)?
        do {
            for try await _ in supervisor.streamHelper(
                "/bin/sh", ["-c", "yes >&2"], environment: environment, timeout: 20, errorLimit: 50_000
            ) {}
        } catch { failure = error }
        guard case let .outputTooLarge(limit)? = failure as? LoomError else {
            Issue.record("expected outputTooLarge, got \(String(describing: failure))")
            return
        }
        #expect(limit == 50_000)
        #expect((await supervisor.shutdown()).succeeded)
    }

    // MARK: Ownership

    @Test func aRunningStreamIsOwnedAndShutdownCancelsAndAwaitsIt() async throws {
        let supervisor = try supervisor()
        let file = pidFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let consumer = Task {
            var text = ""
            for try await chunk in supervisor.streamHelper(
                "/bin/sh", script("echo started; exec sleep 60", pids: file), environment: environment, timeout: 60
            ) { text += String(decoding: chunk, as: UTF8.self) }
            return text
        }
        let pid = try #require(await readPID(file))
        #expect(await supervisor.helperJobCount == 1)
        // The supervisor has seen the child (registered when it started, sampled while it runs).
        #expect(await SessionRuntimeRig.waitUntil(3) {
            await supervisor.liveHelperIdentities().contains { $0.pid == pid }
        })
        let report = await supervisor.shutdown()
        #expect(report.succeeded, "\(report.errors)")
        #expect(await supervisor.helperJobCount == 0)
        #expect(try !alive(pid))
        await #expect(throws: (any Error).self) { _ = try await consumer.value }
    }

    @Test func aStreamStartedAfterShutdownIsRefused() async throws {
        let supervisor = try supervisor()
        #expect((await supervisor.shutdown()).succeeded)
        var failure: (any Error)?
        do { for try await _ in supervisor.streamHelper("/bin/echo", ["x"], environment: environment, timeout: 5) {} }
        catch { failure = error }
        #expect(failure != nil)
    }
}
