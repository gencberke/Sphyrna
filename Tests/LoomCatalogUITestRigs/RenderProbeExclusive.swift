import Foundation
import Testing
@testable import LoomCatalogUI
import LoomTerminal
import LoomTestSupport

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
            try await Self.$isHeld.withValue(true) {
                // What the test held or watched is let go before the next test takes the lock, however it ended.
                do { try await function() } catch {
                    await Self.release()
                    throw error
                }
                await Self.release()
            }
        }
    }
}

extension RenderProbeExclusive {
    /// Starts counting the views of one scope on `ChatRenderProbe`, after checking that this test holds the probe lock.
    /// The scope is the `probeScope` of the context the test hosts (a session id of its own, or a fresh uuid): the probe
    /// counts nothing of another suite's chat.
    @MainActor static func watchChat(scope: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(isHeld, "a test that watches the probe holds the probe lock (.renderProbe)", sourceLocation: sourceLocation)
        ChatRenderProbe.watch(scope: scope)
    }

    /// The same for `HeaderRenderProbe`.
    @MainActor static func watchHeader(_ ids: Set<UUID>, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(isHeld, "a test that watches the probe holds the probe lock (.renderProbe)", sourceLocation: sourceLocation)
        HeaderRenderProbe.watch(ids)
    }
}

/// The other switches a test sets for the whole process, behind the same lock: the pane tone every view reads
/// (`LoomTheme.ThemeState`, and the terminal's background with it), the evidence run's held hover (`HoverForce`, through
/// `LookEvidence`), the user row's body counters (`ChatUserText.watchedID`) and the drag-source probe (`SessionDragProbe`). Each helper checks the lock first, and the trait lets everything go when the test ends, so a test
/// running beside it never draws a forced hover or counts into it.
extension RenderProbeExclusive {
    /// Arms the held hover (`LookEvidence.arm`): rows drawn from now on read it. Before the rows draw, as the evidence run does.
    @MainActor static func armHover(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(isHeld, "a test that holds a hover holds the probe lock (.renderProbe)", sourceLocation: sourceLocation)
        HoverForce.shared.armed = true
    }

    /// Holds the hover on the row with this key (nil: none), as the evidence run's `hover:` command does.
    @MainActor static func holdHover(_ key: String?, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(isHeld, "a test that holds a hover holds the probe lock (.renderProbe)", sourceLocation: sourceLocation)
        HoverForce.shared.armed = true
        HoverForce.shared.hold(key)
    }

    /// Starts counting the body evaluations of one user row (`ChatUserText`) from zero.
    @MainActor static func watchUserText(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(isHeld, "a test that watches the user row's counters holds the probe lock (.renderProbe)", sourceLocation: sourceLocation)
        ChatUserText.resetProbe()
        ChatUserText.watchedID = id
    }

    /// Starts recording which sessions' views carry a drag source (`SessionDragProbe`), from none.
    @MainActor static func watchDragSources(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(isHeld, "a test that watches the drag sources holds the probe lock (.renderProbe)", sourceLocation: sourceLocation)
        SessionDragProbe.watch()
    }

    /// Sets the pane tone every view reads (`LoomTheme.ThemeState`) and returns the one it replaced.
    @discardableResult
    @MainActor static func holdTone(_ tone: PaneTone, sourceLocation: SourceLocation = #_sourceLocation) -> PaneTone {
        #expect(isHeld, "a test that sets the pane tone holds the probe lock (.renderProbe)", sourceLocation: sourceLocation)
        let previous = LoomTheme.ThemeState.shared.tone
        LoomTheme.ThemeState.shared.tone = tone
        return previous
    }

    @MainActor static func release() {
        LoomTheme.ThemeState.shared.tone = .neutral
        let canvas = LoomTheme.Surface.terminalBackground(tone: .neutral).bytes
        TerminalTheme.setBackground(TerminalRGB(red: UInt8(canvas.0), green: UInt8(canvas.1), blue: UInt8(canvas.2)))
        HoverForce.shared.hold(nil)
        HoverForce.shared.armed = false
        ChatUserText.watchedID = nil
        ChatUserText.resetProbe()
        SessionDragProbe.stop()
    }
}

extension Trait where Self == RenderProbeExclusive {
    /// Runs the test alone among the tests that watch or reset a render probe (`SidebarRenderProbe`, `ChatRenderProbe`,
    /// `HeaderRenderProbe`) or set another development switch (the held hover, `ChatUserText`, `SessionDragProbe`).
    static var renderProbe: Self { RenderProbeExclusive() }
}

/// A first-come, first-served async lock (a waiting test gives its thread back, unlike a blocking lock).
actor RenderProbeLock {
    static let shared = RenderProbeLock()

    var held = false
    var waiters: [CheckedContinuation<Void, Never>] = []

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
