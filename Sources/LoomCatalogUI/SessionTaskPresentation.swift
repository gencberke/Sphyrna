import Foundation
import LoomCore
import SwiftUI

/// Presentation never supplies the parent's model or treats a ready process as a reported result.
enum SessionTaskPresentation {
    struct Model: Equatable {
        let text: String
        let spoken: String
    }

    static func nativeName(_ record: SubagentRecord) -> String {
        let role = record.agentType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { return role }
        let short = String(record.id.prefix(8))
        return short.isEmpty ? "Subagent" : "Subagent \(short)"
    }

    static func model(_ task: SessionTaskProjection) -> Model {
        if let effective = task.effectiveModel?.trimmingCharacters(in: .whitespacesAndNewlines), !effective.isEmpty {
            return Model(text: effective, spoken: "reported model \(effective)")
        }
        guard task.requestedChoices.harness == task.harness else {
            return Model(text: "Model unknown", spoken: "model unknown")
        }
        guard let raw = task.requestedChoices.model else {
            return Model(text: "CLI default · requested", spoken: "requested CLI default, actual model unknown")
        }
        let requested = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return Model(text: "Model unknown", spoken: "model unknown") }
        return Model(text: "\(requested) · requested", spoken: "requested model \(requested), actual model unknown")
    }

    static func status(_ task: SessionTaskProjection) -> String {
        switch task.lifecycle {
        case .revoked: return "Authority revoked"
        case .stopping: return "Stopping"
        case .stopUnverified: return "Stop unverified"
        case .stopped: return "Stopped"
        case .identityChanged: return "Identity changed"
        case .active:
            if task.currentAttentionID != nil { return "Needs parent input" }
            if task.activeRoundID != nil { return "Active round" }
            if task.pendingRoundID != nil { return "Round queued" }
            return "No active round"
        }
    }

    static func needsParentInput(_ task: SessionTaskProjection) -> Bool {
        task.lifecycle == .active && task.currentAttentionID != nil
    }

    static func harnessName(_ id: HarnessID) -> String {
        HarnessCatalogue.descriptor(for: id)?.displayName ?? id.rawValue
    }

    static func label(_ task: SessionTaskProjection) -> String {
        "\(task.childName), \(harnessName(task.harness)), \(model(task).spoken), \(status(task).lowercased())"
    }

    static func eventTitle(_ event: SessionTaskEvent) -> String {
        switch event.kind {
        case .completed: "Result"
        case .failed: "Failure"
        case .needsParentInput: "Needs parent input"
        }
    }
}

/// The selected task's bounded reported events are held by this view only and released when it closes. They are read again
/// when the task's own revision changes (a new report raises it), and the last read stays shown while the next one runs.
struct SessionTaskDetailView: View {
    let model: CatalogModel
    let task: SessionTaskProjection
    let back: () -> Void
    @State private var read: SessionTaskUIState.EventRead = .unavailable
    @State private var readTask: UUID?

    private struct ReadKey: Equatable {
        let task: UUID
        let generation: UInt64
        let revision: Int64
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LoomTheme.Agents.sectionGap) {
                HStack(spacing: LoomTheme.Agents.columnGap) {
                    Button("Back to Agents", action: back)
                        .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                    Spacer(minLength: 0)
                    Button("Open Session") { model.openSessionTaskChild(task.id, parentID: task.parentSessionID) }
                        .buttonStyle(ControlButtonStyle(kind: .secondary, size: .small))
                }
                HStack(spacing: LoomTheme.Agents.columnGap) {
                    ProviderIcon(harness: task.harness, size: LoomTheme.Branches.harnessMark).accessibilityHidden(true)
                    Text(verbatim: task.childName).projectType(LoomTheme.Agents.name).foregroundStyle(LoomTheme.Text.primary)
                        .lineLimit(LoomTheme.Agents.nameLines)
                }
                Text(SessionTaskPresentation.model(task).spoken).projectType(LoomTheme.Agents.detail)
                    .foregroundStyle(LoomTheme.Text.secondaryStyle)
                Text(SessionTaskPresentation.status(task)).projectType(LoomTheme.Agents.note)
                    .foregroundStyle(SessionTaskPresentation.needsParentInput(task) ? AnyShapeStyle(LoomTheme.Status.attentionLight)
                                                                                  : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                if readTask != task.id {
                    Text("Reading task reports…").projectType(LoomTheme.Agents.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                } else {
                    reports
                }
            }
            .padding(LoomTheme.Inspector.bodyInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("session-task-detail")
        .task(id: ReadKey(task: task.id, generation: model.sessionTasks.sourceGeneration, revision: task.revision)) {
            let result = await model.sessionTasks.readEvents(for: task.id)
            guard !Task.isCancelled else { return }
            read = result
            readTask = task.id
        }
        .focusable().focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard press.key == .escape else { return .ignored }
            back()
            return .handled
        }
    }

    @ViewBuilder private var reports: some View {
        switch read {
        case .unavailable:
            Text("Task reports are unavailable.").projectType(LoomTheme.Agents.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
        case .failed:
            Text("Task reports could not be read.").projectType(LoomTheme.Agents.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
        case let .ready(batch):
            if batch.events.isEmpty && !batch.partial {
                Text(SessionTaskPresentation.needsParentInput(task) ? "The request details could not be read."
                                                                    : "No reported result or request.")
                    .projectType(LoomTheme.Agents.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
            ForEach(batch.events, id: \.id) { event in
                VStack(alignment: .leading, spacing: LoomTheme.Agents.lineGap) {
                    Text(SessionTaskPresentation.eventTitle(event)).projectType(LoomTheme.Agents.type)
                        .foregroundStyle(LoomTheme.Text.primary)
                    Text(verbatim: event.payload).projectType(LoomTheme.Agents.detail)
                        .foregroundStyle(LoomTheme.Text.secondaryStyle).textSelection(.enabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(SessionTaskPresentation.eventTitle(event)): \(event.payload)")
                .accessibilityIdentifier("task-event:\(event.id)")
            }
            if batch.partial {
                Text("Some reports could not be shown.").projectType(LoomTheme.Agents.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
            }
        }
    }
}
