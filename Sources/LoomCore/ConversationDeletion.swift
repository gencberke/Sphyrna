import Darwin
import Foundation
import Synchronization

// CP4-C: deletes one conversation end to end (contract section 8) on top of the pieces below it:
// the CP4-A inventory and deleter (files), the CP4-B deletion record and fences (catalog) and the
// supervisor's discard and provider-id fence. The record's state is the step in progress; a step
// that fails records its failure and stays, so a retry (manual, or at the next launch) resumes it.

/// Something that keeps data for a conversation and must drop it when the conversation is
/// deleted (the usage index, open tabs, caches). Called in the verifying step with the Loom id
/// and every provider id; it must be idempotent, and a throw keeps the deletion open.
public protocol ConversationForgetting: Sendable {
    func forget(sessionID: UUID, providerIDs: [String]) async throws
}

/// The registration list. `shared` exists so the app can register a hook before the runtime is
/// built (the usage index is created first); a runtime uses the list in its configuration.
public final class ConversationForgetters: Sendable {
    public static let shared = ConversationForgetters()

    private struct Closure: ConversationForgetting {
        let body: @Sendable (UUID, [String]) async throws -> Void
        func forget(sessionID: UUID, providerIDs: [String]) async throws {
            try await body(sessionID, providerIDs)
        }
    }

    private let list = Mutex<[any ConversationForgetting]>([])

    public init() {}

    public func register(_ forgetter: any ConversationForgetting) {
        list.withLock { $0.append(forgetter) }
    }

    public func register(_ body: @escaping @Sendable (_ sessionID: UUID, _ providerIDs: [String]) async throws -> Void) {
        register(Closure(body: body))
    }

    var registered: [any ConversationForgetting] { list.withLock { $0 } }
}

public enum DeletionFailpointPhase: Sendable { case before, after }

/// What the confirm dialog shows before anything is removed. Nothing here is content.
public struct ConversationDeletionPreview: Sendable, Equatable {
    public let sessionID: UUID
    /// Files and folders (a folder counts once) that deletion removes, including tier 2.
    public let fileCount: Int
    public let byteCount: Int64
    /// The Claude config directory the files are in.
    public let configDirectory: String
    /// The conversation has a live run; deleting stops it first.
    public let isRunning: Bool
    /// Entries that exist and are not removed (shared history, other conversations' memory).
    public let notRemoved: [String]
    /// Folders the scan cannot enter (links, other devices); deleting is not complete while any exists.
    public let unreachable: [String]
}

/// A deletion that has not finished, as the UI shows it.
public struct PendingConversationDeletion: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The step in progress or the one that failed.
    public let state: CatalogDeletionState
    public let attempts: Int
    /// Category and at most a file name; never a path or content.
    public let lastFailure: String?
    public let requestedAt: Date
    public let updatedAt: Date
    /// A step is executing in this process right now.
    public let isRunning: Bool
}

public enum ConversationDeletionOutcome: Sendable, Equatable {
    case deleted
    case incomplete(PendingConversationDeletion)
}

/// A step's failure, already reduced to what may be stored.
struct DeletionStepFailure: Error {
    let failure: CatalogDeletionFailure
    init(_ category: String, file: String? = nil) {
        failure = CatalogDeletionFailure(category: category, file: file)
    }
}

extension SessionRuntime {
    // MARK: Public entry points

    /// What deleting this conversation would remove, without removing anything. Throws the same
    /// refusals as `deleteConversation` (Codex, shared provider data, unusable config directory).
    public func deletionPreview(id: UUID) async throws -> ConversationDeletionPreview {
        let candidate = try await deletionCandidate(id)
        return ConversationDeletionPreview(
            sessionID: id,
            fileCount: candidate.plan.items.count + candidate.plan.temporaryItems.count,
            byteCount: candidate.plan.totalBytes,
            configDirectory: candidate.plan.configDirectory,
            isRunning: await supervisor.session(id: id)?.currentRun != nil,
            notRemoved: candidate.plan.residual,
            unreachable: candidate.plan.unreachable
        )
    }

    /// Deletes one Claude conversation completely: stops its run, removes its provider files and
    /// catalog rows, verifies, then announces the removal. A step that cannot finish leaves the
    /// conversation visible as pending (`pendingDeletions`) and returns `.incomplete`; the
    /// deletion record, not this call, is the authority. Codex and synthetic conversations are
    /// refused (D-28), as is one that shares provider data with another conversation.
    @discardableResult
    public func deleteConversation(id: UUID) async throws -> ConversationDeletionOutcome {
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        if try await catalog.isDeletionPending(id) { return try await retryDeletion(id: id) }
        guard !startingSessions.contains(id) else { throw SessionRuntimeError.alreadyStarting(id) }
        guard deletionsInFlight.insert(id).inserted else { throw SessionRuntimeError.deletionInProgress(id) }
        defer { deletionsInFlight.remove(id) }
        let candidate = try await deletionCandidate(id)
        // From here every start, resume, view and input for the id is refused.
        try await catalog.beginDeletion(
            sessionID: id,
            plan: CatalogDeletionPlan(
                provider: .claude, providerIDs: candidate.providerIDs,
                configDirectory: candidate.plan.configDirectory,
                workingDirectory: candidate.workingDirectory
            )
        )
        return try await runDeletion(id)
    }

    /// Resumes a recorded deletion from the step that failed (the user's manual retry).
    @discardableResult
    public func retryDeletion(id: UUID) async throws -> ConversationDeletionOutcome {
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        guard try await catalog.isDeletionPending(id) else { throw SessionRuntimeError.deletionNotPending(id) }
        guard deletionsInFlight.insert(id).inserted else { throw SessionRuntimeError.deletionInProgress(id) }
        defer { deletionsInFlight.remove(id) }
        return try await runDeletion(id)
    }

    /// Every unfinished deletion with its step and last failure, oldest first.
    public func pendingDeletions() async throws -> [PendingConversationDeletion] {
        try await catalog.pendingDeletions().map { pending($0) }
    }

    /// Why launch recovery stopped, when a deletion record could not be read.
    public func deletionRecoveryFailure() -> String? { deletionRecoveryIssue }

    /// Waits for the recovery `start()` began (tests and evidence).
    public func finishDeletionRecovery() async { await deletionRecovery?.value }

    // MARK: Recovery

    /// Runs every recorded deletion from its state, one after another. A failure stays on its
    /// record; nothing retries by itself.
    func recoverDeletions() async {
        let records: [CatalogDeletion]
        do { records = try await catalog.pendingDeletions() }
        catch {
            deletionRecoveryIssue = "Interrupted deletions could not be read: \(error)"
            return
        }
        for record in records {
            guard !shuttingDown else { return }
            guard deletionsInFlight.insert(record.sessionID).inserted else { continue }
            defer { deletionsInFlight.remove(record.sessionID) }
            _ = try? await runDeletion(record.sessionID)
        }
    }

    // MARK: Request

    private struct DeletionCandidate {
        let plan: DeletionPlan
        let providerIDs: [String]
        let workingDirectory: String
    }

    /// Refusals and the dry-run plan. The plan ignores a live process: a running conversation is
    /// stopped by the deletion itself, and the files are planned again when they are removed.
    private func deletionCandidate(_ id: UUID) async throws -> DeletionCandidate {
        guard let record = try await catalog.session(id: id) else { throw SessionRuntimeError.sessionNotFound(id) }
        switch record.session.provider {
        case .claude: break
        case .codex:
            throw SessionRuntimeError.deletionRefused("Codex sessions cannot be deleted from Loom yet")
        case .synthetic:
            throw SessionRuntimeError.deletionRefused("This is not a provider session")
        }
        let providerIDs = try await catalog.providerIDs(of: id)
        for providerID in providerIDs {
            if try await catalog.isProviderIDShared(providerID, excluding: id) {
                throw SessionRuntimeError.deletionRefused(
                    "Another session uses the same Claude session data"
                )
            }
        }
        let configDirectory = claudeConfigDirectory()
        switch Self.configFolderState(configDirectory.path) {
        case .present: break
        case .absent: throw SessionRuntimeError.deletionRefused("The Claude data folder was not found")
        case .unavailable:
            throw SessionRuntimeError.deletionRefused("The Claude data folder is not available (is its volume mounted?)")
        }
        let temporaryRoot = configuration.claudeTemporaryRoot
        let ids = Self.fileIDs(providerIDs)
        let plan: DeletionPlan
        do {
            plan = try await Task.detached {
                try ClaudeDataInventory.plan(
                    sessionIDs: ids, configDirectory: configDirectory,
                    temporaryRoot: temporaryRoot, ignoringLiveSessions: true
                )
            }.value
        } catch {
            throw SessionRuntimeError.deletionRefused(Self.reason(for: error))
        }
        return DeletionCandidate(plan: plan, providerIDs: providerIDs, workingDirectory: record.session.workingDirectory)
    }

    /// Provider ids that name files: only a UUID can; anything else has nothing to claim.
    private static func fileIDs(_ providerIDs: [String]) -> [String] {
        providerIDs.filter { (try? ClaudeDataFiles.normalize([$0])) != nil }
    }

    enum ConfigFolderState: Equatable { case present, absent, unavailable }

    /// A folder counts as absent only when `lstat` says it does not exist while its parent does:
    /// the same answer comes from an unmounted volume or a folder that cannot be searched, and
    /// neither is a folder with nothing left in it.
    static func configFolderState(_ path: String) -> ConfigFolderState {
        var info = stat()
        if lstat(path, &info) == 0 { return .present }
        guard errno == ENOENT else { return .unavailable }
        let parent = (path as NSString).deletingLastPathComponent
        guard stat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .unavailable }
        return .absent
    }

    private static func reason(for error: Error) -> String {
        switch error as? ClaudeDataError {
        case .unsafeDirectory: "The Claude data folder is not safe to change (owner or permissions)"
        case .liveSession: "A Claude process is still using this session"
        case .sessionRegistryUnreadable: "Claude's session registry cannot be read"
        case .invalidSessionID: "The session has an identity Loom cannot match to files"
        case nil: "The Claude data folder could not be inspected"
        }
    }

    // MARK: Steps

    /// `running` is false for what a finished attempt returns: its runner is about to leave.
    private func pending(_ record: CatalogDeletion, running: Bool? = nil) -> PendingConversationDeletion {
        PendingConversationDeletion(
            id: record.sessionID, state: record.state, attempts: record.attempts,
            lastFailure: record.lastError, requestedAt: record.requestedAt, updatedAt: record.updatedAt,
            isRunning: running ?? deletionsInFlight.contains(record.sessionID)
        )
    }

    /// Runs the record from its state until it is finished or a step fails. Each state's body
    /// runs only after the state was persisted; a success persists the next one, a failure
    /// records itself on the same state. Every body is idempotent.
    private func runDeletion(_ id: UUID) async throws -> ConversationDeletionOutcome {
        while true {
            guard let record = try await catalog.deletion(for: id) else { return .deleted }
            guard !shuttingDown else { return .incomplete(pending(record, running: false)) }
            do {
                try deletionFailpoint?(record.state, .before)
                let next = try await perform(record)
                // The last step removes the record itself: nothing is left to fail after it.
                guard let next else {
                    await supervisor.events.publishDeletion(sessionID: id, change: .conversationDeleted)
                    return .deleted
                }
                try deletionFailpoint?(record.state, .after)
                try await catalog.advanceDeletion(sessionID: id, to: next)
            } catch {
                let failure = (error as? DeletionStepFailure)?.failure ?? CatalogDeletionFailure(category: "step_failed")
                try await catalog.advanceDeletion(sessionID: id, to: record.state, error: failure)
                guard let latest = try await catalog.deletion(for: id) else { return .deleted }
                await supervisor.events.publishDeletion(sessionID: id, change: .deletionIncomplete)
                return .incomplete(pending(latest, running: false))
            }
        }
    }

    /// Performs the state's body and returns the state to persist next; nil when the deletion
    /// is finished.
    private func perform(_ record: CatalogDeletion) async throws -> CatalogDeletionState? {
        let id = record.sessionID
        switch record.state {
        case .requested:
            return .stopping
        case .stopping:
            try await stopRun(of: id)
            return .providerData
        case .providerData:
            try await removeProviderData(record)
            return .catalog
        case .catalog:
            try await catalog.deleteSessionRows(sessionID: id)
            return .verifying
        case .verifying:
            try await verifyAndForget(record)
            return nil
        }
    }

    /// The run owned by this card goes first; an unverified stop keeps everything. A run that
    /// moved to another card (`/clear`) is not this conversation's and needs no stop.
    private func stopRun(of id: UUID) async throws {
        guard let run = await supervisor.session(id: id)?.currentRun else { return }
        // Nothing more may be typed into a conversation that is being deleted.
        inputGate.close(runID: run.id, reason: "This session is being deleted")
        let report: SessionStopReport
        do { report = try await stopConversation(sessionID: id) }
        catch SessionRuntimeError.notRunning { return }   // exited or moved to another card meanwhile
        catch { throw DeletionStepFailure("stop_failed") }
        guard report.succeeded else { throw DeletionStepFailure("stop_unverified") }
    }

    private func removeProviderData(_ record: CatalogDeletion) async throws {
        guard record.plan.provider == .claude, let directory = record.plan.configDirectory else {
            throw DeletionStepFailure("unsupported_provider")
        }
        switch Self.configFolderState(directory) {
        case .absent: return   // a folder that is gone has nothing left to claim
        case .unavailable: throw DeletionStepFailure("config_unavailable")
        case .present: try await removeFiles(of: record, in: directory)
        }
    }

    /// Plans again now, with the live-process check (the files change between the request and a
    /// retry, a restart or a late write, and the record keeps no file list), and removes what is there.
    private func removeFiles(of record: CatalogDeletion, in directory: String) async throws {
        let ids = Self.fileIDs(record.plan.providerIDs)
        let configDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        let temporaryRoot = configuration.claudeTemporaryRoot
        let outcome: Result<(DeletionResult, [String]), Error> = await Task.detached {
            Result {
                let plan = try ClaudeDataInventory.plan(
                    sessionIDs: ids, configDirectory: configDirectory, temporaryRoot: temporaryRoot
                )
                return (ClaudeDataDeleter.execute(plan), plan.unreachable)
            }
        }.value
        let result: DeletionResult
        let unreachable: [String]
        do { (result, unreachable) = try outcome.get() }
        catch ClaudeDataError.liveSession { throw DeletionStepFailure("live_session") }
        catch ClaudeDataError.unsafeDirectory { throw DeletionStepFailure("unsafe_directory") }
        catch { throw DeletionStepFailure("plan_failed") }
        if let refusal = result.refusal {
            switch refusal {
            case .liveSession: throw DeletionStepFailure("live_session")
            case .unsafeDirectory: throw DeletionStepFailure("unsafe_directory")
            default: throw DeletionStepFailure("refused")
            }
        }
        if let failed = result.entries.first(where: { if case .failed = $0.outcome { return true }; return false }) {
            throw DeletionStepFailure("partial_failure", file: failed.item.relativePath)
        }
        // Folders the scan cannot enter may hold this conversation's data: not complete.
        if let first = unreachable.first { throw DeletionStepFailure("unreachable_folder", file: first) }
    }

    /// The last step before the record is finished: nothing may be left anywhere, every
    /// registered component dropped its copy, and only then is the record removed.
    private func verifyAndForget(_ record: CatalogDeletion) async throws {
        let id = record.sessionID
        let providerIDs = record.plan.providerIDs
        guard try await catalog.session(id: id) == nil else { throw DeletionStepFailure("catalog_row_remains") }
        // A request refuses shared ids, so a row that names one now is the conversation coming back
        // (another conversation that is itself being deleted does not count).
        for providerID in providerIDs {
            if try await catalog.isProviderIDShared(providerID, excluding: id) {
                throw DeletionStepFailure("provider_id_reappeared")
            }
        }
        do { try await supervisor.discardSession(id, providerIDs: providerIDs) }
        catch { throw DeletionStepFailure("still_running") }
        await claudeAdapter.forget(sessionID: id)
        if let directory = record.plan.configDirectory {
            switch Self.configFolderState(directory) {
            case .absent: break
            case .unavailable: throw DeletionStepFailure("config_unavailable")
            case .present:
                var leftovers = try await remainingFiles(of: providerIDs, in: directory)
                if !leftovers.isEmpty {
                    // Something wrote again after the files were removed (a run that moved to another
                    // card by `/clear` keeps its debug log, or a start raced the request): remove it
                    // now and look once more. A process that still holds the conversation fails this
                    // step visibly (`live_session`) and a retry resumes here.
                    try await removeFiles(of: record, in: directory)
                    leftovers = try await remainingFiles(of: providerIDs, in: directory)
                }
                if let first = leftovers.first { throw DeletionStepFailure("leftover_files", file: first.relativePath) }
            }
        }
        for forgetter in configuration.forgetters.registered {
            do { try await forgetter.forget(sessionID: id, providerIDs: providerIDs) }
            catch { throw DeletionStepFailure("forget_hook_failed") }
        }
        // Last: a late publish for the id would recreate the hub entry, so it goes after every await
        // that could still be racing the run's end.
        await supervisor.events.forget(sessionID: id)
        try await catalog.finishDeletion(sessionID: id)
        // `finishDeletion` removed every backup (one may have held this session): take a fresh one.
        scheduleCatalogBackup(force: true)
    }

    private func remainingFiles(of providerIDs: [String], in directory: String) async throws -> [DeletionPlan.Item] {
        let ids = Self.fileIDs(providerIDs)
        let configDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        let temporaryRoot = configuration.claudeTemporaryRoot
        let result = await Task.detached {
            Result { try ClaudeDataDeleter.verify(sessionIDs: ids, configDirectory: configDirectory, temporaryRoot: temporaryRoot) }
        }.value
        do { return try result.get() } catch { throw DeletionStepFailure("verify_failed") }
    }
}
