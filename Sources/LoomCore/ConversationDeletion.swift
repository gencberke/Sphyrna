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
    /// Folders the scan cannot enter (links, other devices) that can hold this session's files: its
    /// project folder or a top-level data folder. Deleting is not complete while any exists (DP-CP4-7).
    public let unreachable: [String]
    /// How many side chats (V22) the session has: deleting it deletes them first, each through the same path.
    public var sideChatCount: Int = 0
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
        return await preview(id, plan: candidate.plan)
    }

    /// The previews of many conversations from ONE scan of the Claude profile (the cleanup review). A conversation
    /// `deletionPreview` would refuse, or whose plan cannot be made, has no entry; every other one equals what
    /// `deletionPreview(id:)` gives for it.
    public func deletionPreviews(ids: [UUID]) async -> [UUID: ConversationDeletionPreview] {
        var requests: [(id: UUID, request: DeletionRequest)] = []
        for id in ids {
            guard let request = try? await deletionRequest(id) else { continue }
            requests.append((id, request))
        }
        guard let first = requests.first?.request else { return [:] }
        let configDirectory = first.configDirectory, temporaryRoot = first.temporaryRoot
        let dryRuns = requests.map {
            ClaudeDataInventory.DryRunRequest(sessionIDs: $0.request.fileIDs, workingDirectory: $0.request.workingDirectory)
        }
        guard let plans = try? await Task.detached(operation: {
            try ClaudeDataInventory.dryRunPlans(dryRuns, configDirectory: configDirectory, temporaryRoot: temporaryRoot)
        }).value else { return [:] }
        var previews: [UUID: ConversationDeletionPreview] = [:]
        for (entry, plan) in zip(requests, plans) { previews[entry.id] = await preview(entry.id, plan: plan) }
        return previews
    }

    private func preview(_ id: UUID, plan: DeletionPlan) async -> ConversationDeletionPreview {
        ConversationDeletionPreview(
            sessionID: id,
            fileCount: plan.items.count + plan.temporaryItems.count,
            byteCount: plan.totalBytes,
            configDirectory: plan.configDirectory,
            isRunning: await supervisor.session(id: id)?.currentRun != nil,
            notRemoved: plan.residual,
            unreachable: plan.unreachable,
            sideChatCount: (try? await catalog.sideChatCount(of: id)) ?? 0
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
        await claudeLimitObserver?.forget(sessionID: id)
        defer { deletionsInFlight.remove(id) }
        // The session's side chats go first, each through this same path (V22): none may outlive its parent.
        try await deleteSideChats(of: id)
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
        LoomLog.notice(.deletion, "Deletion \(LoomLog.ref(id)): started (\(candidate.plan.items.count + candidate.plan.temporaryItems.count) item(s))")
        return try await runDeletion(id)
    }

    /// Resumes a recorded deletion from the step that failed (the user's manual retry).
    @discardableResult
    public func retryDeletion(id: UUID) async throws -> ConversationDeletionOutcome {
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        guard try await catalog.isDeletionPending(id) else { throw SessionRuntimeError.deletionNotPending(id) }
        guard deletionsInFlight.insert(id).inserted else { throw SessionRuntimeError.deletionInProgress(id) }
        defer { deletionsInFlight.remove(id) }
        LoomLog.notice(.deletion, "Deletion \(LoomLog.ref(id)): retried")
        return try await runDeletion(id)
    }

    /// "Remove from Loom only" (DP-CP4-7): after a deletion could not finish (or a folder Loom cannot
    /// look inside may hold the session's files), removes the session from Loom and keeps Claude's files
    /// where they are. It stops the run, removes the catalog rows and the unfinished deletion record, and
    /// has every component that keeps data for the session drop it. It never touches a file of Claude's.
    public func removeFromLoomOnly(id: UUID) async throws {
        guard !shuttingDown else { throw SessionRuntimeError.shuttingDown }
        guard !startingSessions.contains(id) else { throw SessionRuntimeError.alreadyStarting(id) }
        guard deletionsInFlight.insert(id).inserted else { throw SessionRuntimeError.deletionInProgress(id) }
        defer { deletionsInFlight.remove(id) }
        // Its side chats are removed from Loom the same way, first (V22).
        for child in try await catalog.sideChats(of: id, includingDeleting: true) { try await removeFromLoomOnly(id: child.session.id) }
        let providerIDs: [String]
        if let record = try await catalog.deletion(for: id) {
            providerIDs = record.plan.providerIDs
        } else {
            guard let record = try await catalog.session(id: id) else { throw SessionRuntimeError.sessionNotFound(id) }
            guard HarnessCapabilities.intrinsic(of: record.session.provider).deletes else {
                throw SessionRuntimeError.deletionRefused("Only Claude sessions can be removed this way")
            }
            providerIDs = try await catalog.providerIDs(of: id)
            for providerID in providerIDs {
                if try await catalog.isProviderIDShared(providerID, excluding: id) {
                    throw SessionRuntimeError.deletionRefused("Another session uses the same Claude session data")
                }
            }
            // From here every start, resume, view and input for the id is refused, as in a deletion.
            // The record names no Claude folder: should Loom stop before the end, a launch shows the
            // session as an unfinished deletion and offers this again.
            try await catalog.beginDeletion(
                sessionID: id,
                plan: CatalogDeletionPlan(
                    provider: .claude, providerIDs: providerIDs, configDirectory: nil,
                    workingDirectory: record.session.workingDirectory
                )
            )
        }
        LoomLog.notice(.deletion, "Remove from Sphyrna only \(LoomLog.ref(id)): started")
        do {
            try await stopRun(of: id)
            try await catalog.deleteSessionRows(sessionID: id)
            try await dropRuntimeState(of: id, providerIDs: providerIDs)
            try await finishLoomSide(of: id, providerIDs: providerIDs)
        } catch let failure as DeletionStepFailure {
            LoomLog.error(.deletion, "Remove from Sphyrna only \(LoomLog.ref(id)) failed (\(failure.failure.category))")
            throw SessionRuntimeError.deletionRefused(
                "The session could not be removed from Sphyrna (\(failure.failure.stored.replacingOccurrences(of: "_", with: " ")))"
            )
        }
        LoomLog.notice(.deletion, "Remove from Sphyrna only \(LoomLog.ref(id)): removed")
        await supervisor.events.publishDeletion(sessionID: id, change: .conversationDeleted)
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
            LoomLog.error(.deletion, "Interrupted deletions could not be read (\(LoomLog.category(of: error)))")
            deletionRecoveryIssue = "Interrupted deletions could not be read: \(error)"
            return
        }
        if !records.isEmpty { LoomLog.notice(.deletion, "Resuming \(records.count) interrupted deletion(s)") }
        for record in records {
            guard !shuttingDown else { return }
            guard deletionsInFlight.insert(record.sessionID).inserted else { continue }
            defer { deletionsInFlight.remove(record.sessionID) }
            do { _ = try await runDeletion(record.sessionID) } catch {
                LoomLog.error(.deletion, "Deletion \(LoomLog.ref(record.sessionID)): its resume failed (\(LoomLog.category(of: error)))")
            }
        }
    }

    // MARK: Request

    private struct DeletionCandidate {
        let plan: DeletionPlan
        let providerIDs: [String]
        let workingDirectory: String
    }

    /// What a deletion's request is made of, after the refusals and before any scan.
    private struct DeletionRequest {
        let providerIDs: [String]
        /// The provider ids that name files.
        let fileIDs: [String]
        let workingDirectory: String
        let configDirectory: URL
        let temporaryRoot: URL?
    }

    /// The refusals, and what the dry-run plan is made for.
    private func deletionRequest(_ id: UUID) async throws -> DeletionRequest {
        guard let record = try await catalog.session(id: id) else { throw SessionRuntimeError.sessionNotFound(id) }
        guard let harness = harnesses[record.session.provider] else {
            throw SessionRuntimeError.deletionRefused("This is not a provider session")
        }
        if let refusal = harness.deletionRefusal { throw SessionRuntimeError.deletionRefused(refusal) }
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
        return DeletionRequest(
            providerIDs: providerIDs, fileIDs: Self.fileIDs(providerIDs),
            workingDirectory: record.session.workingDirectory,
            configDirectory: configDirectory, temporaryRoot: configuration.claudeTemporaryRoot
        )
    }

    /// Refusals and the dry-run plan. The plan ignores a live process: a running conversation is
    /// stopped by the deletion itself, and the files are planned again when they are removed.
    private func deletionCandidate(_ id: UUID) async throws -> DeletionCandidate {
        let request = try await deletionRequest(id)
        let ids = request.fileIDs, configDirectory = request.configDirectory
        let temporaryRoot = request.temporaryRoot, workingDirectory = request.workingDirectory
        let plan: DeletionPlan
        do {
            plan = try await Task.detached {
                try ClaudeDataInventory.plan(
                    sessionIDs: ids, configDirectory: configDirectory,
                    temporaryRoot: temporaryRoot, ignoringLiveSessions: true,
                    workingDirectory: workingDirectory
                )
            }.value
        } catch {
            throw SessionRuntimeError.deletionRefused(Self.reason(for: error))
        }
        return DeletionCandidate(plan: plan, providerIDs: request.providerIDs, workingDirectory: workingDirectory)
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
        case .invalidSessionID: "The session has an identity Sphyrna cannot match to files"
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
            guard !shuttingDown else {
                LoomLog.notice(.deletion, "Deletion \(LoomLog.ref(id)): left at \(record.state.rawValue), Sphyrna is quitting")
                return .incomplete(pending(record, running: false))
            }
            do {
                try deletionFailpoint?(record.state, .before)
                let next = try await perform(record)
                // The last step removes the record itself: nothing is left to fail after it.
                guard let next else {
                    LoomLog.notice(.deletion, "Deletion \(LoomLog.ref(id)): deleted")
                    await supervisor.events.publishDeletion(sessionID: id, change: .conversationDeleted)
                    return .deleted
                }
                try deletionFailpoint?(record.state, .after)
                try await catalog.advanceDeletion(sessionID: id, to: next)
                LoomLog.debug(.deletion, "Deletion \(LoomLog.ref(id)): \(record.state.rawValue) done, next \(next.rawValue)")
            } catch {
                let failure = (error as? DeletionStepFailure)?.failure ?? CatalogDeletionFailure(category: "step_failed")
                let cause = error is DeletionStepFailure ? failure.category : "\(failure.category), \(LoomLog.category(of: error))"
                LoomLog.error(.deletion, "Deletion \(LoomLog.ref(id)): step \(record.state.rawValue) failed (\(cause)); left incomplete")
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
        guard HarnessCapabilities.intrinsic(of: record.plan.provider).deletes, let directory = record.plan.configDirectory else {
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
        let workingDirectory = record.plan.workingDirectory
        let outcome: Result<(DeletionResult, [String]), Error> = await Task.detached {
            Result {
                let plan = try ClaudeDataInventory.plan(
                    sessionIDs: ids, configDirectory: configDirectory, temporaryRoot: temporaryRoot,
                    workingDirectory: workingDirectory
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
        try await dropRuntimeState(of: id, providerIDs: providerIDs)
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
        try await finishLoomSide(of: id, providerIDs: providerIDs)
    }

    /// What the supervisor and the Claude adapter keep for the conversation.
    private func dropRuntimeState(of id: UUID, providerIDs: [String]) async throws {
        do { try await supervisor.discardSession(id, providerIDs: providerIDs) }
        catch { throw DeletionStepFailure("still_running") }
        await harnesses.claude.forget(sessionID: id)
    }

    /// Every registered component drops its copy, then the deletion record (when there is one) goes.
    private func finishLoomSide(of id: UUID, providerIDs: [String]) async throws {
        do { try await forgetTasksAfterVerifiedStop(sessionID: id) }
        catch { throw DeletionStepFailure("task_stop_unverified") }
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
