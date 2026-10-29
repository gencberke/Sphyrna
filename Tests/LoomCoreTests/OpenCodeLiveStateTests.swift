import Foundation
import Testing
@testable import LoomCore

@Suite struct OpenCodeLiveStateTests {
    private let appID = UUID()
    private let roundID = UUID()
    private let runID = UUID()
    private func event(_ type: String, seq: Int64?, session: String = "ses_one", input: String? = nil) -> OpenCodeEvent {
        OpenCodeEvent(id: "evt_\(seq ?? 0)", type: type, sessionID: session, sequence: seq, inboxID: input, version: 1)
    }

    @Test func emptyCreationDoesNotInventReadyAndReceiptDoesNotInventCompletion() throws {
        var state = OpenCodeLiveState(appSessionID: appID, runID: runID, nativeSessionID: "ses_one")
        state.receive(event("session.created", seq: 1))
        #expect(state.snapshot.appSessionID == appID)
        #expect(state.snapshot.nativeSessionID == "ses_one")
        #expect(state.snapshot.creationSequence == 1)
        #expect(state.snapshot.runID == runID)
        #expect(state.snapshot.execution == .unknown)
        try state.begin(roundID: roundID, inputID: "msg_one")
        #expect(state.snapshot.input?.creationSequence == 1)
        try state.receipt(inputID: "msg_one")
        #expect(state.snapshot.input?.state == .accepted)
        #expect(state.snapshot.execution == .unknown)
    }

    @Test func exactInputRequiresDeliveryAndCurrentOrderedExecution() throws {
        var state = OpenCodeLiveState(appSessionID: appID, runID: runID, nativeSessionID: "ses_one")
        try state.begin(roundID: roundID, inputID: "msg_one")
        state.receive(event("session.inbox.enqueued", seq: 7, input: "msg_one"))
        state.receive(event("session.execution.started", seq: 10))
        state.receive(event("session.inbox.delivered", seq: 11, input: "msg_one"))
        state.receive(event("session.execution.succeeded", seq: 13))
        #expect(state.snapshot.input?.state == .pending)
        try state.receipt(inputID: "msg_one")
        #expect(state.snapshot.input?.state == .settled(.succeeded))
        #expect(state.snapshot.input?.startSequence == 10)
        #expect(state.snapshot.input?.deliverySequence == 11)
        #expect(state.snapshot.input?.terminalSequence == 13)
        #expect(state.snapshot.execution == .idle)
        state.disconnected()
        #expect(state.snapshot.input?.state == .unknown)
        #expect(state.snapshot.input?.startSequence == nil)
        #expect(state.snapshot.input?.deliverySequence == nil)
        #expect(state.snapshot.input?.terminalSequence == nil)
    }

    @Test func otherInputOrOldTerminalCannotCompleteTheCurrentRound() throws {
        var state = OpenCodeLiveState(appSessionID: appID, runID: runID, nativeSessionID: "ses_one")
        state.receive(event("session.execution.started", seq: 1))
        state.receive(event("session.execution.succeeded", seq: 2))
        try state.begin(roundID: roundID, inputID: "msg_one")
        try state.receipt(inputID: "msg_one")
        #expect(state.snapshot.input?.state == .accepted)
        state.receive(event("session.execution.started", seq: 3))
        state.receive(event("session.inbox.delivered", seq: 4, input: "msg_other"))
        state.receive(event("session.inbox.delivered", seq: 5, input: "msg_one"))
        state.receive(event("session.execution.succeeded", seq: 6))
        #expect(state.snapshot.input?.state == .unknown)
        #expect(state.snapshot.input?.startSequence == nil)
        #expect(state.snapshot.input?.deliverySequence == nil)
        #expect(state.snapshot.input?.terminalSequence == nil)
    }

    @Test func staleMissingSequenceAndDisconnectMakeEvidenceUnknown() throws {
        var state = OpenCodeLiveState(appSessionID: appID, runID: runID, nativeSessionID: "ses_one")
        try state.begin(roundID: roundID, inputID: "msg_one")
        try state.receipt(inputID: "msg_one")
        state.receive(event("session.execution.started", seq: 20))
        state.receive(event("session.inbox.delivered", seq: 21, input: "msg_one"))
        #expect(state.snapshot.execution == .running)
        #expect(state.snapshot.input?.state == .delivered)
        state.receive(event("session.execution.succeeded", seq: 19))
        #expect(state.snapshot.execution == .unknown)
        #expect(state.snapshot.input?.state == .unknown)

        var other = OpenCodeLiveState(appSessionID: appID, runID: runID, nativeSessionID: "ses_one")
        try other.begin(roundID: roundID, inputID: "msg_one")
        other.receive(event("session.execution.started", seq: nil))
        #expect(other.snapshot.execution == .unknown)
        #expect(other.snapshot.input?.state == .unknown)
        other.disconnected()
        #expect(other.snapshot.execution == .unknown)
        #expect(other.snapshot.input?.state == .unknown)
    }
    @Test func uncertainAdmissionCannotBeClearedByAnOlderIdleEvent() throws {
        var state = OpenCodeLiveState(appSessionID: appID, runID: runID, nativeSessionID: "ses_one")
        state.receive(event("session.execution.started", seq: 1))
        state.receive(event("session.execution.succeeded", seq: 2))
        try state.begin(roundID: roundID, inputID: "msg_one")
        state.indeterminate(inputID: "msg_one")
        #expect(state.snapshot.input?.state == .unknown)
        #expect(throws: OpenCodeError.conflict) {
            try state.begin(roundID: UUID(), inputID: "msg_two")
        }
        #expect(state.snapshot.input?.inputID == "msg_one")
    }

    @Test func competingDeliveryErasesPreviouslyObservedCorrelation() throws {
        var state = OpenCodeLiveState(appSessionID: appID, runID: runID, nativeSessionID: "ses_one")
        state.receive(event("session.created", seq: 1))
        try state.begin(roundID: roundID, inputID: "msg_one")
        #expect(state.snapshot.input?.creationSequence == 1)
        try state.receipt(inputID: "msg_one")
        state.receive(event("session.execution.started", seq: 5))
        state.receive(event("session.inbox.delivered", seq: 6, input: "msg_one"))
        #expect(state.snapshot.input?.startSequence == 5)
        #expect(state.snapshot.input?.deliverySequence == 6)
        state.receive(event("session.inbox.delivered", seq: 7, input: "msg_other"))
        #expect(state.snapshot.input?.state == .unknown)
        #expect(state.snapshot.input?.creationSequence == nil)
        #expect(state.snapshot.input?.startSequence == nil)
        #expect(state.snapshot.input?.deliverySequence == nil)
        state.receive(event("session.execution.succeeded", seq: 8))
        #expect(state.snapshot.input?.state == .unknown)
        #expect(state.snapshot.input?.terminalSequence == nil)
    }

    @Test func aLaterNativeBusyPeriodDoesNotRetagAnEarlierSettledInput() throws {
        var state = OpenCodeLiveState(appSessionID: appID, runID: runID, nativeSessionID: "ses_one")
        try state.begin(roundID: roundID, inputID: "msg_one")
        try state.receipt(inputID: "msg_one")
        state.receive(event("session.execution.started", seq: 1))
        state.receive(event("session.inbox.delivered", seq: 2, input: "msg_one"))
        state.receive(event("session.execution.succeeded", seq: 3))
        state.receive(event("session.execution.started", seq: 4))
        state.receive(event("session.inbox.delivered", seq: 5, input: "msg_other"))
        #expect(state.snapshot.execution == .running)
        #expect(state.snapshot.input?.roundID == roundID)
        #expect(state.snapshot.input?.state == .settled(.succeeded))
        #expect(state.snapshot.input?.startSequence == 1)
        #expect(state.snapshot.input?.deliverySequence == 2)
        #expect(state.snapshot.input?.terminalSequence == 3)

        var delayed = OpenCodeLiveState(appSessionID: appID, runID: runID, nativeSessionID: "ses_one")
        try delayed.begin(roundID: roundID, inputID: "msg_one")
        delayed.receive(event("session.execution.started", seq: 1))
        delayed.receive(event("session.inbox.delivered", seq: 2, input: "msg_one"))
        delayed.receive(event("session.execution.succeeded", seq: 3))
        delayed.receive(event("session.execution.started", seq: 4))
        delayed.receive(event("session.inbox.delivered", seq: 5, input: "msg_other"))
        try delayed.receipt(inputID: "msg_one")
        #expect(delayed.snapshot.input?.state == .settled(.succeeded))
        #expect(delayed.snapshot.input?.startSequence == 1)
        #expect(delayed.snapshot.input?.deliverySequence == 2)
        #expect(delayed.snapshot.input?.terminalSequence == 3)
    }

}
