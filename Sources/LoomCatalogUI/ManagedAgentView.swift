import Foundation
import LoomCore
import Observation
import SwiftUI

/// A task-only child surface. The caller supplies the selected task snapshot and owns every effect.
/// A response receipt is not a native resolution; the request remains until the next snapshot removes it.
@MainActor
public struct ManagedAgentView: View {
    public typealias Respond = @MainActor (UUID, UUID, ManagedTaskUserDecision) async -> ManagedTaskWriteOutcome
    /// The caller returns only after verified transfer; errors leave the surface in place.
    public typealias TakeOver = @MainActor (ManagedTaskRun) async throws -> Void

    private let presentation: ManagedTaskPresentation
    private let taskName: String
    private let respond: Respond
    private let takeOver: TakeOver
    @State private var actions = ManagedAgentActions()
    private typealias M = LoomTheme.ManagedAgents

    public init(presentation: ManagedTaskPresentation, taskName: String,
                respond: @escaping Respond, takeOver: @escaping TakeOver) {
        self.presentation = presentation
        self.taskName = taskName
        self.respond = respond
        self.takeOver = takeOver
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: M.sectionGap) {
                header
                settings
                if let error = actions.takeOverMessage {
                    notice(error, identifier: "managed-takeover-message")
                }
                if !presentation.permissions.isEmpty {
                    VStack(alignment: .leading, spacing: M.cardGap) {
                        Text("Needs your attention").font(M.heading).foregroundStyle(LoomTheme.Text.primary)
                        ForEach(presentation.permissions) { occurrence in
                            let ticket = actions.ticket(for: occurrence)
                            ManagedAgentRequestCard(occurrence: occurrence,
                                                    available: actions.available(occurrence, ticket: ticket),
                                                    message: actions.message(for: occurrence.id)) { decision in
                                guard let ticket else { return }
                                actions.respond(to: occurrence, ticket: ticket, decision: decision, using: respond)
                            }
                            .id(presentation.run.generation)
                        }
                    }
                }
                progress
            }
            .padding(M.pageInset)
            .frame(maxWidth: M.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("managed-agent-surface")
        .onChange(of: presentation, initial: true) { _, next in actions.update(next) }
        .onDisappear { actions.deactivate() }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: M.rowGap) {
                identity
                Spacer(minLength: M.rowGap)
                takeOverButton.id(presentation.run.generation)
            }
            VStack(alignment: .leading, spacing: M.rowGap) {
                identity
                takeOverButton.id(presentation.run.generation)
            }
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: M.lineGap) {
            HStack(spacing: M.rowGap) {
                ProviderIcon(harness: presentation.run.requestedChoices.harness, size: M.mark)
                Text(verbatim: taskName).font(M.title).foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(2).truncationMode(.tail)
            }
            HStack(spacing: M.rowGap) {
                Text(SessionTaskPresentation.harnessName(presentation.run.requestedChoices.harness))
                    .font(M.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                Text(Self.status(presentation.status)).font(M.detail)
                    .foregroundStyle(presentation.status == .waitingForUser || presentation.status == .unknown
                                     ? AnyShapeStyle(LoomTheme.Status.attentionLight) : AnyShapeStyle(LoomTheme.Text.secondaryStyle))
                    .accessibilityIdentifier("managed-agent-status")
            }
        }
    }

    private var takeOverButton: some View {
        Button("Take Over") { actions.takeOver(presentation, using: takeOver) }
            .buttonStyle(ControlButtonStyle(kind: .outline, size: .regular))
            .disabled(!actions.canTakeOver(presentation))
            .help(presentation.canTakeOver ? "Open this child in its terminal" : "Take Over is not available yet")
            .accessibilityIdentifier("managed-takeover")
    }

    @ViewBuilder private var settings: some View {
        let choices = presentation.run.requestedChoices
        let effective = presentation.effectiveSettings
        let values: [(String, String, Bool)] = [
            Self.setting("Model", reported: effective?.model, requested: choices.model, omitDefault: true),
            Self.setting("Effort", reported: effective?.effort, requested: choices.effort),
            Self.setting("Mode", reported: effective?.permissionMode, requested: choices.mode?.title)
        ].compactMap { $0 }
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: M.lineGap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text("\(value.0): \(value.1)\(value.2 ? " · requested" : " · reported")")
                        .font(M.metadata).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("managed-settings")
        }
    }

    private static func setting(_ name: String, reported: String?, requested: String?, omitDefault: Bool = false)
        -> (String, String, Bool)? {
        func usable(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !omitDefault || value.lowercased() != "default" else { return nil }
            return value
        }
        if let value = usable(reported) { return (name, value, false) }
        if let value = usable(requested) { return (name, value, true) }
        return nil
    }

    private static func status(_ status: SessionTaskNativeStatus) -> String {
        switch status {
        case .notStarted: "Not started"
        case .ready: "Ready"
        case .working: "Working"
        case .waitingForUser: "Waiting for you"
        case .stopped: "Stopped"
        case .unknown: "Status unknown"
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: M.cardGap) {
            Text("Progress").font(M.heading).foregroundStyle(LoomTheme.Text.primary)
            if presentation.progress.isEmpty {
                Text("No progress reported yet.").font(M.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
            } else {
                ForEach(Array(presentation.progress.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: M.lineGap) {
                        Text(Self.progressTitle(row.kind)).font(M.metadata).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        Text(verbatim: row.text).font(M.body).foregroundStyle(LoomTheme.Text.primary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityIdentifier("managed-progress")
    }

    private static func progressTitle(_ kind: ManagedTaskProgress.Kind) -> String {
        switch kind {
        case .message: "Message"
        case .tool: "Tool"
        case .notice: "Notice"
        }
    }

    private func notice(_ text: String, identifier: String) -> some View {
        Text(verbatim: text).font(M.detail).foregroundStyle(LoomTheme.Status.attentionLight)
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(identifier)
    }
}

/// Local interaction fences are scoped to one visible run. The runtime must also revalidate the occurrence at dispatch.
@MainActor @Observable
final class ManagedAgentActions {
    private struct RunKey: Equatable {
        let task: UUID
        let session: UUID
        let run: UUID
        let generation: UUID
        init(_ run: ManagedTaskRun) {
            task = run.taskID; session = run.sessionID; self.run = run.runID; generation = run.generation
        }
    }
    private struct Entry {
        let occurrence: ManagedTaskPermissionOccurrence
        let ticket: UUID
    }
    private enum State { case scheduled(UUID), busy(UUID), submitted, unknown, deferred }
    private var run: RunKey?
    private var entries: [UUID: Entry] = [:]
    private var states: [UUID: State] = [:]
    private var conflicts: Set<UUID> = []
    private var acceptingRequests = false
    private var takeOverBusy = false
    private var takeOverDispatched = false
    private var takeOverAttempt: UUID?
    private var takeOverEligible = false
    private var takeOverLocked = false
    private var lifetime = UUID()
    private(set) var takeOverMessage: String?

    func update(_ presentation: ManagedTaskPresentation) {
        let nextRun = RunKey(presentation.run)
        if run != nextRun { deactivate(); run = nextRun }
        let accepts = presentation.status != .notStarted && presentation.status != .stopped
        if acceptingRequests != accepts { acceptingRequests = accepts }
        if !accepts {
            let pending = states.compactMap { id, state -> UUID? in
                if case .scheduled = state { return id }
                return nil
            }
            for id in pending { states[id] = nil }
        }
        if takeOverEligible != presentation.canTakeOver { takeOverEligible = presentation.canTakeOver }
        if !takeOverEligible && takeOverBusy && !takeOverDispatched {
            takeOverBusy = false
            takeOverAttempt = nil
        }
        let incoming = Dictionary(uniqueKeysWithValues: presentation.permissions.map { ($0.id, $0) })
        let retained = Set(incoming.keys)
        let nextConflicts = conflicts.intersection(retained)
        if nextConflicts != conflicts { conflicts = nextConflicts }
        for (id, occurrence) in incoming {
            if let old = entries[id], old.occurrence != occurrence {
                // A reused occurrence ID cannot inherit the earlier card's decisions or authority.
                conflicts.insert(id)
                entries[id] = Entry(occurrence: occurrence, ticket: UUID())
                states[id] = nil
            } else if entries[id] == nil {
                entries[id] = Entry(occurrence: occurrence, ticket: UUID())
            }
        }
        for id in Set(entries.keys).subtracting(retained) { entries[id] = nil; states[id] = nil }
    }

    func deactivate() {
        lifetime = UUID()
        run = nil; entries = [:]; states = [:]; conflicts = []; acceptingRequests = false
        takeOverBusy = false; takeOverDispatched = false; takeOverAttempt = nil
        takeOverEligible = false; takeOverLocked = false; takeOverMessage = nil
    }

    func ticket(for occurrence: ManagedTaskPermissionOccurrence) -> UUID? {
        guard let entry = entries[occurrence.id], entry.occurrence == occurrence else { return nil }
        return entry.ticket
    }

    func available(_ occurrence: ManagedTaskPermissionOccurrence, ticket: UUID?) -> Bool {
        guard let ticket, run?.task == occurrence.taskID, acceptingRequests, !takeOverBusy, !takeOverLocked,
              !conflicts.contains(occurrence.id), entries[occurrence.id]?.ticket == ticket,
              entries[occurrence.id]?.occurrence == occurrence else { return false }
        return switch states[occurrence.id] {
        case .scheduled(_)?, .busy(_)?, .submitted?, .unknown?: false
        case .deferred?, nil: true
        }
    }

    func message(for id: UUID) -> String? {
        if conflicts.contains(id) { return "This request changed. Take Over to review it." }
        return switch states[id] {
        case .scheduled(_)?, .busy(_)?: "Sending response…"
        case .submitted?: "Response sent; waiting for the request to close."
        case .unknown?: "The response could not be verified. Take Over to review it."
        case .deferred?: "The response could not be sent. You can try again."
        case nil: nil
        }
    }

    func respond(to occurrence: ManagedTaskPermissionOccurrence, ticket: UUID, decision: ManagedTaskUserDecision,
                 using callback: @escaping ManagedAgentView.Respond) {
        guard available(occurrence, ticket: ticket), let key = run else { return }
        let attempt = UUID()
        states[occurrence.id] = .scheduled(attempt)
        Task { @MainActor in
            guard run == key, entries[occurrence.id]?.ticket == ticket,
                  entries[occurrence.id]?.occurrence == occurrence,
                  case let .scheduled(current)? = states[occurrence.id], current == attempt else { return }
            guard acceptingRequests, !takeOverBusy, !takeOverLocked, !conflicts.contains(occurrence.id) else {
                states[occurrence.id] = nil
                return
            }
            states[occurrence.id] = .busy(attempt)
            let result = await callback(occurrence.taskID, occurrence.id, decision)
            guard run == key, entries[occurrence.id]?.ticket == ticket,
                  entries[occurrence.id]?.occurrence == occurrence,
                  case let .busy(current)? = states[occurrence.id], current == attempt else { return }
            switch result {
            case .submitted: states[occurrence.id] = .submitted
            case .deferred: states[occurrence.id] = .deferred
            case .unknown: states[occurrence.id] = .unknown
            }
        }
    }

    func canTakeOver(_ presentation: ManagedTaskPresentation) -> Bool {
        run == RunKey(presentation.run) && takeOverEligible && presentation.canTakeOver && !takeOverBusy && !takeOverLocked
            && !states.values.contains {
                switch $0 {
                case .scheduled, .busy: true
                case .submitted, .unknown, .deferred: false
                }
            }
    }

    func takeOver(_ presentation: ManagedTaskPresentation, using callback: @escaping ManagedAgentView.TakeOver) {
        guard canTakeOver(presentation), let key = run else { return }
        let lifetime = self.lifetime
        let attempt = UUID()
        takeOverBusy = true
        takeOverDispatched = false
        takeOverAttempt = attempt
        takeOverMessage = nil
        Task { @MainActor in
            guard run == key, self.lifetime == lifetime, takeOverAttempt == attempt,
                  takeOverBusy, !takeOverDispatched, takeOverEligible else { return }
            takeOverDispatched = true
            do {
                try await callback(presentation.run)
                guard run == key, self.lifetime == lifetime, takeOverAttempt == attempt else { return }
                takeOverBusy = false
                takeOverDispatched = false
                takeOverAttempt = nil
                takeOverLocked = true
                takeOverMessage = "Opening the child session…"
            } catch {
                guard run == key, self.lifetime == lifetime, takeOverAttempt == attempt else { return }
                takeOverBusy = false
                takeOverDispatched = false
                takeOverAttempt = nil
                // The callback did not verify transfer; an ambiguous effect must not be replayed locally.
                takeOverLocked = true
                takeOverMessage = "Take Over could not be verified: \(String(error.localizedDescription.prefix(512)))"
            }
        }
    }
}
