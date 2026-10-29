import Testing
@testable import LoomChat

// The handover's one state (`ChatSessionDriver.HandoverState`), without a driver: which transitions move from which state,
// and that the five flags it replaced (hold, cancelled, cleared, committed, stopping) read the same off it. The driver's
// own handover behaviour is `ChatHandoverTests`.

struct ChatHandoverStateTests {
    typealias State = ChatSessionDriver.HandoverState

    private static let all: [State] = [
        .none, .waiting, .cancelled(byClear: false), .cancelled(byClear: true), .committed, .stopping,
    ]

    /// What the old flags read in each state: (hold, cancelled, cleared, committed, stopping).
    private static func flags(of state: State) -> (hold: Bool, cancelled: Bool, cleared: Bool, committed: Bool, stopping: Bool) {
        switch state {
        case .none: (false, false, false, false, false)
        case .waiting: (true, false, false, false, false)
        case .cancelled(byClear: false): (true, true, false, false, false)
        case .cancelled(byClear: true): (true, true, true, false, false)
        case .committed: (true, false, false, true, false)
        case .stopping: (true, false, false, true, true)
        }
    }

    @Test func theQueriesReadWhatTheFiveFlagsRead() {
        for state in Self.all {
            let old = Self.flags(of: state)
            #expect(state.isHolding == old.hold, "\(state)")
            #expect(state.isCancelled == old.cancelled, "\(state)")
            #expect(state.wasCleared == old.cleared, "\(state)")
            #expect(state.isCommitted == old.committed, "\(state)")
            #expect(state.isStopping == old.stopping, "\(state)")
        }
    }

    @Test func noStateIsBothCancelledAndCommitted() {
        for state in Self.all {
            #expect(!(state.isCancelled && state.isCommitted), "\(state)")
            #expect(!state.isCancelled || state.isHolding, "\(state): a cancelled wait still holds the session")
            #expect(!state.isCommitted || state.isHolding, "\(state)")
            #expect(!state.isStopping || state.isCommitted, "\(state): a stop is committed")
            #expect(!state.wasCleared || state.isCancelled, "\(state)")
        }
    }

    @Test func aMoveWalksNoneWaitingCommittedStoppingCommittedNone() {
        var state = State.none
        state.beginWaiting()
        #expect(state == .waiting)
        state.commit()
        #expect(state == .committed)
        state.beginStopping()
        #expect(state == .stopping)
        // The stop returned: the hold stays for `finishHandover()`.
        state.endStopping()
        #expect(state == .committed)
        #expect(state.isHolding)
        state.release()
        #expect(state == .none)
    }

    @Test func aSessionWithNoRunIsCommittedAtOnce() {
        var state = State.none
        state.commit()
        #expect(state == .committed)
        #expect(state.isHolding && state.isCommitted && !state.isCancelled)
    }

    @Test func aUserCancelEndsTheWaitWithoutClearing() {
        var state = State.waiting
        state.cancel()
        #expect(state == .cancelled(byClear: false))
        #expect(state.isCancelled && !state.wasCleared && state.isHolding && !state.isCommitted)
    }

    @Test func aClearEndsTheWaitAsCleared() {
        var state = State.waiting
        state.endByClear()
        #expect(state == .cancelled(byClear: true))
        #expect(state.isCancelled && state.wasCleared)
    }

    @Test func aCancelThenAClearIsCleared() {
        var state = State.waiting
        state.cancel()
        state.endByClear()
        #expect(state == .cancelled(byClear: true), "the move ended because the run was cleared, whatever the user did first")
    }

    @Test func aClearThenACancelStaysCleared() {
        var state = State.waiting
        state.endByClear()
        state.cancel()
        #expect(state == .cancelled(byClear: true), "a later cancel keeps the reason")
    }

    @Test func aCancelOrAClearDoesNothingPastThePointOfNoReturn() {
        for start in [State.committed, .stopping] {
            var cancelled = start
            cancelled.cancel()
            #expect(cancelled == start, "cancel in \(start)")
            var cleared = start
            cleared.endByClear()
            #expect(cleared == start, "clear in \(start)")
        }
    }

    @Test func aCancelOrAClearWithNoHandoverBuildsNothing() {
        var cancelled = State.none
        cancelled.cancel()
        #expect(cancelled == .none)
        var cleared = State.none
        cleared.endByClear()
        #expect(cleared == .none)
    }

    @Test func onlyAStopEndsAsAStop() {
        for start in Self.all where start != .stopping {
            var state = start
            state.endStopping()
            #expect(state == start, "endStopping in \(start)")
        }
        var stopping = State.stopping
        stopping.endStopping()
        #expect(stopping == .committed)
    }

    @Test func beginningAgainStartsOverAndReleaseEndsFromAnyState() {
        // `holdForTerminal` starts from `none` (a second call is refused while a hold stands); the start resets the rest.
        for start in Self.all {
            var state = start
            state.beginWaiting()
            #expect(state == .waiting, "beginWaiting from \(start)")
            var released = start
            released.release()
            #expect(released == .none, "release from \(start)")
        }
    }
}
