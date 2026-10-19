import Foundation
import Testing

/// `SidebarRenderProbe` is one global: `watch` replaces what is watched and `reset` clears every count. Swift Testing runs
/// different suites side by side, so a test that watches the probe (`SidebarRenderTests`, the Resume test of
/// `SessionChatViewTests`) must be the only one that does for its whole run, or another suite's `watch([])` or `reset()`
/// lands in the middle of its counting. A test or suite with this trait holds one async lock for its run (tests of a
/// suite one by one, so the lock is held no longer than a test needs); the tests inside also ask `isHeld`, so a test that
/// loses the trait fails on the spot instead of at random.
///
/// The probe's own cost is not touched: nothing is counted while nothing is watched.
struct RenderProbeExclusive: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    @TaskLocal static var isHeld = false

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        // The suite itself runs nothing; its tests take the lock one by one. A test already inside the lock (a trait on
        // both the suite and the test) must not wait for itself.
        guard !test.isSuite, !Self.isHeld else { return try await function() }
        try await RenderProbeLock.shared.exclusive {
            try await Self.$isHeld.withValue(true) { try await function() }
        }
    }
}

extension Trait where Self == RenderProbeExclusive {
    /// Runs the test alone among the tests that watch or reset `SidebarRenderProbe`.
    static var renderProbe: Self { RenderProbeExclusive() }
}

/// A first-come, first-served async lock (a waiting test gives its thread back, unlike a blocking lock).
actor RenderProbeLock {
    static let shared = RenderProbeLock()

    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if held {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            held = true
        }
        defer {
            if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
