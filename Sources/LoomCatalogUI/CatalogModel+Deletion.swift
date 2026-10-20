import Foundation
import LoomCore
import Observation

// CP4-D: the delete flow as the model sees it. The runtime owns every step (CP4-C: stop, provider
// files, catalog rows, verification); this file only asks for the numbers, forwards the user's
// confirmation, follows the announcements and keeps what the views need: the open confirm sheet,
// the conversations being deleted now and the deletions that did not finish.

/// The open confirm sheet. Held by the model (like `RenameDraft`) so the sheet needs no view state.
@MainActor @Observable
public final class DeletionConfirmation: Identifiable {
    public enum Phase: Equatable {
        /// The dry-run plan is being made; nothing can be confirmed yet.
        case loading
        case ready(ConversationDeletionPreview)
        /// The runtime refused the preview (shared Claude data, unusable data folder); the text says why.
        case unavailable(String)
    }

    public nonisolated let id: UUID
    public let title: String
    public internal(set) var phase: Phase = .loading

    init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }

    /// A folder Loom cannot look inside, and that can hold this session's files, blocks the delete: it
    /// would end half done and could never finish.
    public var canConfirm: Bool {
        if case let .ready(preview) = phase { return preview.unreachable.isEmpty }
        return false
    }

    /// The delete is blocked by such a folder: removing the session from Loom alone is offered instead.
    public var offersRemoveFromLoomOnly: Bool {
        if case let .ready(preview) = phase { return !preview.unreachable.isEmpty }
        return false
    }
}

/// Everything the delete flow shows, apart from the sheet's own text.
@MainActor @Observable
public final class DeletionState {
    public var confirmation: DeletionConfirmation?
    /// The session whose "Remove from Loom Only" waits for the alert's Remove (sheet and banner alike).
    public internal(set) var removalRequest: UUID?
    /// Deletions the runtime has not finished: the failure to show, or one running right now.
    public internal(set) var pending: [UUID: PendingConversationDeletion] = [:]
    /// Conversations whose delete or retry call is in flight in this window.
    public internal(set) var inProgress: Set<UUID> = []
    /// Why launch recovery stopped, when a deletion record could not be read.
    public internal(set) var recoveryFailure: String?
    /// Titles kept for the banner: the row leaves the lists as soon as the runtime fences it.
    public internal(set) var titles: [UUID: String] = [:]
    @ObservationIgnored var finished: Set<UUID> = []
    @ObservationIgnored var seenRevision: UInt64?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    /// Acceptance seam (inert unless set): holds the "Deleting…" state before the runtime is called,
    /// so a screenshot can catch it. Only the development flavor's `--delete-delay` sets it.
    @ObservationIgnored public var pauseBeforeRuntimeCall: Duration = .zero

    public init() {}

    func begin(_ id: UUID, title: String) -> Bool {
        guard inProgress.insert(id).inserted else { return false }
        titles[id] = title
        return true
    }

    func end(_ id: UUID) { inProgress.remove(id) }

    func setPending(_ record: PendingConversationDeletion) {
        guard !finished.contains(record.id) else { return }
        pending[record.id] = record
    }

    func finish(_ id: UUID) {
        finished.insert(id)
        pending[id] = nil
        titles[id] = nil
    }

    /// The runtime's list is the truth, except for what this window already saw finish (a late
    /// read must not bring a finished deletion back).
    func replacePending(_ records: [PendingConversationDeletion], title: (UUID) -> String?) {
        var fresh: [UUID: PendingConversationDeletion] = [:]
        for record in records where !finished.contains(record.id) {
            fresh[record.id] = record
            if titles[record.id] == nil, let known = title(record.id) { titles[record.id] = known }
        }
        if fresh != pending { pending = fresh }
        titles = titles.filter { fresh[$0.key] != nil || inProgress.contains($0.key) }
    }
}

extension ConversationIntents {
    public func deletionPreview(sessionID: UUID) async throws -> ConversationDeletionPreview {
        throw SessionRuntimeError.deletionRefused("Deleting is not available here")
    }
    public func deleteConversation(sessionID: UUID) async throws -> ConversationDeletionOutcome {
        throw SessionRuntimeError.deletionRefused("Deleting is not available here")
    }
    public func retryDeletion(sessionID: UUID) async throws -> ConversationDeletionOutcome {
        throw SessionRuntimeError.deletionRefused("Deleting is not available here")
    }
    public func pendingDeletions() async throws -> [PendingConversationDeletion] { [] }
    public func removeFromLoomOnly(sessionID: UUID) async throws {
        throw SessionRuntimeError.deletionRefused("Removing is not available here")
    }
    public func deletionRecoveryFailure() async -> String? { nil }
    public func deleteSideChats(inProject projectID: UUID) async throws {}
}

extension CatalogModel {
    // MARK: Entry points

    /// A delete or retry of this conversation is running, here or in launch recovery.
    public func isDeleting(_ id: UUID) -> Bool {
        deletions.inProgress.contains(id) || deletions.pending[id]?.isRunning == true
    }

    /// Why Delete is disabled for this row; nil when it is allowed.
    public func deletionDisabledReason(for row: SessionRowModel) -> String? {
        switch row.record.session.provider {
        case .claude: break
        case .codex: return "Codex sessions can't be deleted from Loom yet."
        case .synthetic: return "This is not a provider session."
        }
        if !actionsAvailable { return "Deleting isn't available right now." }
        if isDeleting(row.id) || deletions.pending[row.id] != nil { return "This session is already being deleted." }
        switch busy[row.id] {
        case .starting?, .resuming?: return "Wait until it has finished starting."
        case .stopping?: return "Wait until it has finished stopping."
        case nil: return nil
        }
    }

    public func canDelete(_ row: SessionRowModel) -> Bool {
        deletionDisabledReason(for: row) == nil
    }

    /// An unfinished deletion that nothing is working on: Try Again / Retry Deleting.
    public func canRetryDeletion(_ id: UUID) -> Bool {
        guard actionsAvailable, !deletions.inProgress.contains(id), let record = deletions.pending[id] else { return false }
        return !record.isRunning
    }

    // MARK: Confirm

    /// "Delete Permanently…": opens the confirm sheet and asks the runtime what would be removed.
    /// Nothing is removed until `confirmDeletion`.
    public func requestDeletion(_ id: UUID) {
        guard let row = tabRow(id), canDelete(row) else { return }
        let confirmation = DeletionConfirmation(id: id, title: title(of: row))
        deletions.confirmation = confirmation
        Task { [weak self, weak confirmation] in
            guard let intents = self?.intents else { return }
            let phase: DeletionConfirmation.Phase
            do { phase = .ready(try await intents.deletionPreview(sessionID: id)) }
            catch {
                if case let SessionRuntimeError.deletionRefused(reason)? = error as? SessionRuntimeError {
                    phase = .unavailable(reason.last == "." ? reason : reason + ".")
                } else {
                    phase = .unavailable(Self.userMessage(for: error, context: "Loom could not check what deleting this session removes"))
                }
            }
            guard let confirmation, self?.deletions.confirmation === confirmation else { return }
            confirmation.phase = phase
        }
    }

    public func cancelDeletion() { deletions.confirmation = nil }

    /// The sheet's "Delete Permanently" button.
    public func confirmDeletion() async {
        guard let confirmation = deletions.confirmation, confirmation.canConfirm else { return }
        deletions.confirmation = nil
        await performDeletion(id: confirmation.id, title: confirmation.title, retry: false)
    }

    /// "Try Again" and "Retry Deleting": resumes the recorded deletion from the step that failed.
    public func retryDeletion(_ id: UUID) async {
        guard canRetryDeletion(id) else { return }
        await performDeletion(id: id, title: deletions.titles[id] ?? "", retry: true)
    }

    /// A deletion failed and the user has seen why (the banner's failure): the session may be removed
    /// from Loom alone. Not while something is working on it.
    public func canRemoveFromLoomOnly(_ id: UUID) -> Bool {
        guard actionsAvailable, !deletions.inProgress.contains(id), let record = deletions.pending[id] else { return false }
        return !record.isRunning && record.lastFailure != nil
    }

    /// "Remove from Loom Only" on the blocked confirm sheet or the failed deletion's banner: asks for
    /// the alert (`DeletionCopy.removeTitle`). Nothing is removed until `removeFromLoomOnly`.
    public func requestRemoveFromLoomOnly(_ id: UUID) {
        if let confirmation = deletions.confirmation, confirmation.id == id {
            guard confirmation.offersRemoveFromLoomOnly else { return }
        } else {
            guard canRemoveFromLoomOnly(id) else { return }
        }
        deletions.removalRequest = id
    }

    public func cancelRemoveFromLoomOnly() { deletions.removalRequest = nil }

    /// The alert's Remove. It removes the session and Loom's own data for it and never a file of
    /// Claude's; without the alert's request it does nothing. The request is taken at once (the alert
    /// closes right after its button runs), the removal runs in the returned task.
    @discardableResult
    public func removeFromLoomOnly(_ id: UUID) -> Task<Void, Never>? {
        guard deletions.removalRequest == id else { return nil }
        deletions.removalRequest = nil
        let title: String
        if let confirmation = deletions.confirmation, confirmation.id == id {
            guard confirmation.offersRemoveFromLoomOnly else { return nil }
            title = confirmation.title
            deletions.confirmation = nil
        } else {
            guard canRemoveFromLoomOnly(id) else { return nil }
            title = deletions.titles[id] ?? ""
        }
        guard intents != nil, deletions.begin(id, title: title) else { return nil }
        return Task { await performRemoval(id) }
    }

    private func performRemoval(_ id: UUID) async {
        defer { deletions.end(id) }
        if selectedSessionID == id { select(nil) }
        do {
            try await intents?.removeFromLoomOnly(sessionID: id)
            deletionFinished(id)
        } catch {
            reportFailure(Self.userMessage(for: error, context: "The session could not be removed from Loom"))
            await refreshPendingDeletions()
        }
    }

    // MARK: Running

    private func performDeletion(id: UUID, title: String, retry: Bool) async {
        guard let intents, deletions.begin(id, title: title) else { return }
        defer { deletions.end(id) }
        // The detail pane leaves the conversation at once (persisted); its tab goes when the runtime says it is gone.
        if selectedSessionID == id { select(nil) }
        if deletions.pauseBeforeRuntimeCall > .zero { try? await Task.sleep(for: deletions.pauseBeforeRuntimeCall) }
        do {
            let outcome = retry ? try await intents.retryDeletion(sessionID: id) : try await intents.deleteConversation(sessionID: id)
            switch outcome {
            case .deleted: deletionFinished(id)
            case let .incomplete(record): deletions.setPending(record)
            }
        } catch {
            reportFailure(Self.userMessage(for: error, context: "The session could not be deleted"))
            await refreshPendingDeletions()
        }
    }

    /// The conversation is gone: its tab closes and a selection that named it is cleared
    /// (not handed to a neighboring tab, which closing a tab would do).
    func deletionFinished(_ id: UUID) {
        deletions.finish(id)
        // Its Chat queue, draft and driver went with it: the Chat host is a `ConversationForgetter` of the runtime.
        let wasSelected = selectedSessionID == id
        forget(sessionID: id)
        if wasSelected { select(nil) }
        scheduleRefresh()
    }

    // MARK: Following the runtime

    /// A deletion announcement, or any change of the catalog revision (a launch recovery that ended
    /// before this model subscribed shows up as a moved revision on the first frame).
    func handleDeletionFrame(_ frame: SessionEventFrame) {
        if frame.change == .conversationDeleted, let id = frame.sessionID { deletionFinished(id) }
        if deletions.seenRevision != frame.catalogRevision {
            deletions.seenRevision = frame.catalogRevision
            refreshPendingDeletionsSoon()
        }
    }

    func refreshPendingDeletionsSoon() {
        guard intents != nil else { return }
        deletions.refreshTask = Task { [weak self] in await self?.refreshPendingDeletions() }
    }

    /// Reads the runtime's unfinished deletions (and why recovery stopped, if it did).
    public func refreshPendingDeletions() async {
        guard let intents else { return }
        guard let records = try? await intents.pendingDeletions() else { return }
        deletions.replacePending(records) { [self] id in tabRow(id).map { title(of: $0) } }
        let failure = await intents.deletionRecoveryFailure()
        if failure != deletions.recoveryFailure { deletions.recoveryFailure = failure }
    }
}

/// The delete flow's texts (DESIGN §6: say what happened, what Loom did or did not do, what the user can do).
public enum DeletionCopy {
    public static func confirmBody(_ preview: ConversationDeletionPreview) -> String {
        let files = preview.fileCount == 1 ? "1 file" : "\(preview.fileCount) files"
        let size = preview.byteCount == 0 ? "0 bytes" : ByteCountFormatter.string(fromByteCount: preview.byteCount, countStyle: .file)
        let lead = preview.isRunning
            ? "It is running now, so Loom stops it first, then removes it from Loom and deletes Claude's local files for it"
            : "Loom removes it from Loom and deletes Claude's local files for it"
        return "\(lead): the transcript, subagent transcripts, file snapshots and session folders "
            + "(\(files), \(size), in \(preview.configDirectory)). This can't be undone.\n\n"
            + "Not removed: your prompts in Claude's shared prompt history, project files and worktrees, "
            + "and anything already sent to Anthropic."
    }

    /// The alert both "Remove from Loom Only" buttons ask for.
    public static let removeTitle = "Remove this session from Loom?"
    public static let removeMessage = "Loom forgets the session and its own data for it. Claude's files stay where they are, and Loom can't bring the session back."
    public static let removeButton = "Remove"

    public static func unreachableNote(_ folders: [String]) -> String {
        "Deleting cannot finish: Loom cannot look inside \(folders.joined(separator: ", ")) (it is a link or on another disk), "
            + "so it cannot tell whether Claude keeps files for this session there. Nothing was removed. "
            + "You can remove the session from Loom only; Claude's files stay where they are."
    }

    /// What failed, in a sentence without a final period. `lastFailure` is the runtime's
    /// `category` or `category: file name`.
    public static func failureReason(_ lastFailure: String?) -> String {
        guard let lastFailure, !lastFailure.isEmpty else { return "Loom stopped before it could finish" }
        let parts = lastFailure.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let category = parts.first ?? ""
        let file = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        switch category {
        case "stop_failed": return "Loom could not stop the running session"
        case "stop_unverified": return "Loom could not confirm that the session stopped"
        case "live_session": return "A Claude process is still using this session"
        case "unsafe_directory": return "Claude's data folder is not safe to change (its owner or permissions are not what Loom expects)"
        case "partial_failure": return file.map { "Loom could not remove \($0)" } ?? "Loom could not remove some of Claude's files"
        case "refused": return "Loom was refused when it tried to remove Claude's files"
        case "plan_failed": return "Loom could not read Claude's data folder"
        case "unreachable_folder":
            return "Loom cannot look inside \(file ?? "a folder of Claude's data") (it is a link or on another disk), "
                + "so it cannot tell whether Claude keeps files for this session there"
        case "catalog_row_remains": return "Loom's own record of the session could not be removed"
        case "provider_id_reappeared": return "Another session now uses the same Claude data"
        case "still_running": return "A process of this session is still running"
        case "leftover_files":
            return file.map { "\($0) was still there after Loom removed it" } ?? "Some of Claude's files were still there after Loom removed them"
        case "verify_failed": return "Loom could not check that Claude's files are gone"
        case "forget_hook_failed": return "Loom could not clear its usage figures for this session"
        case "unsupported_provider": return "Loom cannot delete this provider's files"
        default:
            let readable = category.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            return "A step failed" + (readable.isEmpty || readable == "step failed" ? "" : " (\(readable))")
        }
    }

    /// The banner for a deletion that did not finish.
    public static func bannerText(lastFailure: String?) -> String {
        var reason = failureReason(lastFailure)
        while reason.last == "." { reason.removeLast() }
        return "Deleting this session isn't finished. \(reason). Nothing else was touched."
    }
}
