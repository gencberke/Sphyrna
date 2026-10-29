import Foundation
import Testing
@testable import LoomCore

struct ManagedTaskPresentationTests {
    @Test func presentationRejectsWrongIdentityAndUnboundedProgress() throws {
        let native = UUID().uuidString
        let run = ManagedTaskRun(taskID: UUID(), sessionID: UUID(), runID: UUID(), generation: UUID(),
            workingDirectory: "/fixture", requestedChoices: HarnessLaunchChoices(harness: .claude),
            expectedNativeSessionID: native)
        let binding = SessionTaskBinding(sessionID: run.sessionID, nativeSessionID: native.lowercased(),
                                         managedRunID: run.runID, generation: run.generation)
        let progress = try ManagedTaskProgress(kind: .message, text: "hello")
        let value = try ManagedTaskPresentation(run: run, binding: binding, effectiveSettings: nil,
            status: .ready, progress: [progress], permissions: [], canTakeOver: true)
        #expect(value.binding == binding && value.progress == [progress])

        let other = SessionTaskBinding(sessionID: run.sessionID, nativeSessionID: UUID().uuidString,
                                       managedRunID: run.runID, generation: run.generation)
        #expect(throws: SessionTaskError.invalidPayload) {
            _ = try ManagedTaskPresentation(run: run, binding: other, effectiveSettings: nil,
                status: .ready, progress: [], permissions: [], canTakeOver: true)
        }
        let row = try ManagedTaskProgress(kind: .message, text: String(repeating: "x", count: 8_192))
        #expect(throws: SessionTaskError.invalidPayload) {
            _ = try ManagedTaskPresentation(run: run, binding: binding, effectiveSettings: nil,
                status: .working, progress: Array(repeating: row, count: 9), permissions: [], canTakeOver: true)
        }
        #expect(throws: SessionTaskError.invalidPayload) {
            _ = try ManagedTaskPresentation(run: run, binding: nil, effectiveSettings: nil,
                status: .notStarted, progress: [], permissions: [], canTakeOver: true)
        }
    }
}
