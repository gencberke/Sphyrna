import Foundation
import LoomCore
import Observation
import SwiftUI

/// Trusted application reads and explicit user actions for the selected managed child.
public struct ManagedAgentUIBridge: Sendable {
    public let read: @Sendable (UUID) async throws -> ManagedTaskChildSnapshot?
    public let respond: @MainActor @Sendable (ManagedTaskRun, UUID, ManagedTaskUserDecision) async throws -> ManagedTaskWriteOutcome
    public let takeOver: @MainActor @Sendable (ManagedTaskRun) async throws -> Void

    public init(read: @escaping @Sendable (UUID) async throws -> ManagedTaskChildSnapshot?,
                respond: @escaping @MainActor @Sendable (ManagedTaskRun, UUID, ManagedTaskUserDecision) async throws -> ManagedTaskWriteOutcome,
                takeOver: @escaping @MainActor @Sendable (ManagedTaskRun) async throws -> Void) {
        self.read = read; self.respond = respond; self.takeOver = takeOver
    }
}

/// One selected snapshot only. The runtime bounds its content; this owner never caches other children.
@MainActor @Observable
final class ManagedAgentPaneState {
    struct Key: Equatable {
        let sessionID: UUID
        let taskID: UUID
        let runID: UUID?
        let revision: UInt64
        let source: UInt64
        let retry: UInt64
    }

    private(set) var snapshot: ManagedTaskChildSnapshot?
    private(set) var unavailable = false
    @ObservationIgnored private var request = UUID()
    @ObservationIgnored private var key: Key?

    func load(_ next: Key, using bridge: ManagedAgentUIBridge?) async {
        let token = UUID()
        request = token
        if key?.taskID != next.taskID || key?.sessionID != next.sessionID ||
            key?.runID != next.runID || key?.source != next.source { snapshot = nil }
        key = next
        unavailable = false
        guard let bridge else { snapshot = nil; unavailable = true; return }
        do {
            let result = try await bridge.read(next.sessionID)
            guard !Task.isCancelled, request == token, key == next else { return }
            guard let result, result.task.id == next.taskID, result.task.childSessionID == next.sessionID,
                  let presentation = result.presentation, presentation.run.taskID == next.taskID,
                  presentation.run.sessionID == next.sessionID,
                  next.runID.map({ $0 == presentation.run.runID }) ??
                    (presentation.status == .stopped || presentation.status == .unknown || presentation.status == .notStarted)
            else { snapshot = nil; unavailable = true; return }
            snapshot = result
        } catch {
            guard !Task.isCancelled, request == token, key == next else { return }
            snapshot = nil
            unavailable = true
        }
    }

    func invalidate() {
        request = UUID()
        key = nil
        snapshot = nil
    }
}

@MainActor
struct ManagedAgentPane: View {
    let model: CatalogModel
    let row: SessionRowModel
    let taskID: UUID
    @State private var state = ManagedAgentPaneState()
    @State private var retry: UInt64 = 0
    private typealias M = LoomTheme.ManagedAgents

    var body: some View {
        let source = model.managedAgentSourceRevision
        let key = ManagedAgentPaneState.Key(sessionID: row.id, taskID: taskID, runID: row.live?.runID,
                                            revision: row.managedTaskRevision, source: source, retry: retry)
        Group {
            if let snapshot = state.snapshot, let presentation = snapshot.presentation {
                ManagedAgentView(presentation: presentation, taskName: snapshot.task.childName,
                    respond: { task, occurrence, decision in
                        guard task == presentation.run.taskID,
                              model.managedAgentSourceRevision == source,
                              row.live?.managedTaskID == task,
                              let bridge = model.managedAgentBridge else { return .deferred }
                        do { return try await bridge.respond(presentation.run, occurrence, decision) }
                        catch let error as SessionTaskError where error == .staleBinding || error == .unauthorized || error == .notReady {
                            return .deferred
                        } catch { return .unknown }
                    },
                    takeOver: { run in
                        guard run == presentation.run, model.managedAgentSourceRevision == source,
                              row.live?.managedTaskID == taskID,
                              let bridge = model.managedAgentBridge else { throw SessionTaskError.staleBinding }
                        try await bridge.takeOver(run)
                    })
            } else {
                VStack(alignment: .leading, spacing: M.cardGap) {
                    Text("Managed agent").font(M.title).foregroundStyle(LoomTheme.Text.primary)
                    Text(state.unavailable ? "Live task details are unavailable. No response was sent." : "Loading task details…")
                        .font(M.body).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    if state.unavailable {
                        Button("Try Again") { retry &+= 1 }
                            .buttonStyle(ControlButtonStyle(kind: .outline, size: .regular))
                    }
                }
                .padding(M.pageInset).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("managed-agent-unavailable")
            }
        }
        .task(id: key) { await state.load(key, using: model.managedAgentBridge) }
        .onDisappear { state.invalidate() }
    }
}
