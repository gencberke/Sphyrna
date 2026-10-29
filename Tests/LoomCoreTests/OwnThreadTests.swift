import Foundation
import LoomCore
import LoomTestSupport
import Synchronization
import Testing

// Not `@testable`: `onOwnThread` is public, so tests and their fixtures run blocking work through the product's own helper
// (DEVELOPMENT §3.1: nothing blocks the cooperative pool; a blocking fixture runs through `onOwnThread`).

/// `onOwnThread` (LoomCore/OwnThread.swift) runs blocking work on threads of its own. Twice as many blocked works as the
/// cooperative pool has threads must leave the pool free: a hop onto it answers while all of them still block. Had the work
/// run on the pool, the hop would wait for the watchdog that ends the blocks after five seconds.
struct OwnThreadTests {
    private final class State: Sendable {
        let holding = Mutex(0)
        let watchdogFired = Mutex(false)
    }

    /// The work's thread runs at the quality of service the caller gives, `.userInitiated` unless it says otherwise.
    @Test func theWorkRunsAtTheGivenQualityOfService() async throws {
        let standard = try await onOwnThread("loom.test.qos-default") { Thread.current.qualityOfService }
        let utility = try await onOwnThread("loom.test.qos-utility", qualityOfService: .utility) { Thread.current.qualityOfService }
        #expect(standard == .userInitiated)
        #expect(utility == .utility)
    }

    @Test func blockingWorkOnItsOwnThreadsLeavesTheCooperativePoolFree() async throws {
        let blocked = 2 * ProcessInfo.processInfo.activeProcessorCount
        let gate = DispatchSemaphore(value: 0)
        let state = State()
        let works = (0..<blocked).map { index in
            Task {
                try await onOwnThread("loom.test.blocked-\(index)") {
                    state.holding.withLock { $0 += 1 }
                    gate.wait()
                }
            }
        }
        // Ends the blocks after five seconds whatever happens, so a broken helper fails this test instead of hanging the run.
        // A thread of its own: a GCD timer did not fire while every pool thread blocked (the mutation check of this test).
        let done = DispatchSemaphore(value: 0)
        let watchdog = Thread {
            guard done.wait(timeout: .now() + 5) == .timedOut else { return }
            state.watchdogFired.withLock { $0 = true }
            for _ in 0..<blocked { gate.signal() }
        }
        watchdog.start()

        await waitFor("all \(blocked) works to block on their threads", within: .seconds(4),
                      observe: { state.holding.withLock { $0 } }, until: { $0 == blocked })
        let hop = await Task.detached { 1 }.value
        let late = state.watchdogFired.withLock { $0 }
        #expect(hop == 1 && !late, "a hop onto the pool answered only after the watchdog ended the blocks")

        if !late {
            done.signal()
            for _ in 0..<blocked { gate.signal() }
        }
        for work in works { try await work.value }
    }
}
