import CryptoKit
import Foundation

extension SessionRuntime {
    private struct TaskCreationFingerprint: Encodable {
        let name: String
        let project: String?
        let message: String
        let harness: String
        let model: String?
        let effort: String?
        let mode: String?
    }

    func submitTaskRequest(_ call: SessionTaskWireRequest) async -> SessionTaskWireReply {
        do {
            guard let taskID = call.taskID, let operationID = call.operationID,
                  let name = call.name, let message = call.message, let harness = call.harness,
                  let coordinator = taskCoordinator else { throw SessionTaskError.invalidPayload }
            try SessionTaskLimits.text(message)
            _ = try OpenSessionInput.validated(title: name, project: call.project, message: message,
                harness: harness, model: call.model, effort: call.effort, mode: call.mode)
            guard let parent = await authenticateTaskRun(call.claim) else { throw SessionTaskError.unauthorized }
            let fingerprintInput = TaskCreationFingerprint(name: name, project: call.project, message: message,
                harness: harness, model: call.model, effort: call.effort, mode: call.mode)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let digest = SHA256.hash(data: try encoder.encode(fingerprintInput))
            let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
            if let existing = try await coordinator.projectionForUser(taskID: taskID) {
                guard existing.parentBinding == parent, existing.creationOperationID == operationID,
                      existing.creationFingerprint == fingerprint else { throw SessionTaskError.conflictingOperation }
                let receipt = try await coordinator.requestRound(taskID: taskID, parent: call.claim,
                                                                   operationID: operationID, message: message)
                return .init(status: "ok", receipt: receipt, task: existing)
            }
            if let existing = taskChildReservations[taskID] {
                guard existing.operationID == operationID, existing.fingerprint == fingerprint,
                      await authenticateTaskRun(existing.parent) == parent,
                      let current = taskChildReservations[taskID], current.operationID == operationID,
                      current.fingerprint == fingerprint else { throw SessionTaskError.conflictingOperation }
                return .init(status: current.offered ? "pending" : "unavailable")
            }
            let childID = UUID()
            try await reserveTaskChild(taskID: taskID, childID: childID, parent: call.claim,
                                       operationID: operationID, fingerprint: fingerprint)
            let grant = OpenSessionTaskRequest(taskID: taskID, childID: childID, operationID: operationID)
            let open = OpenSessionCall(sessionID: call.sessionID, managedRunID: call.runID,
                title: name, project: call.project, message: message,
                model: call.model, effort: call.effort, mode: call.mode, harness: harness)
            let response = await openRequests.submitTask(open, task: grant) { [weak self] in
                await self?.authenticateTaskRun(call.claim) == parent
            }
            guard response.status == .pending else {
                taskChildReservations[taskID] = nil
                return .init(status: "refused", detail: response.detail)
            }
            taskChildReservations[taskID]?.offered = true
            return .init(status: "pending")
        } catch let error as SessionTaskError { return .init(status: "refused", detail: String(describing: error)) }
        catch { return .init(status: "invalid", detail: "the task request was not accepted") }
    }
}
