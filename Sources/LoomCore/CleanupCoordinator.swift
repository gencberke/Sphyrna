import Foundation

// CP4-G: gathers what the pure `CleanupPlanner` needs (catalog rows, running state, worktree
// verdicts, the two app-state timestamps), shows the user a reviewable snapshot and, only for
// rows the user confirmed and the planner still finds eligible, runs the normal manual deletion.
// Nothing here deletes by itself; the caller supplies the confirmation.

// MARK: Worktree protection

/// DP-CP4-3 default: a conversation whose working directory is a linked worktree is protected
/// while the worktree holds work deletion could lose. Fails closed: any change, unpushed commit,
/// stash, timeout or error protects. Git runs read-only through an injected capture (production:
/// `ProcessSupervisor.captureHelper`, so the helper is owned and timed out).
public struct CleanupWorktreeProtection: Sendable {
    /// Runs `git` with these arguments and returns its standard output; throws on a non-zero
    /// exit, a timeout or any other failure.
    public typealias Capture = @Sendable (_ arguments: [String]) async throws -> String

    private let capture: Capture

    public init(capture: @escaping Capture) { self.capture = capture }

    /// Git through the supervisor's owned, bounded helper path.
    public static func live(supervisor: ProcessSupervisor, timeout: TimeInterval = 10) -> CleanupWorktreeProtection {
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LC_ALL": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        return CleanupWorktreeProtection { arguments in
            try await supervisor.captureHelper("/usr/bin/git", arguments, environment: environment, timeout: timeout)
        }
    }

    /// Whether the nearest `.git` above `directory` is a file (a linked worktree, as `GitBranch`
    /// detects). A main checkout, a folder outside Git and a missing folder are not worktrees.
    public static func isLinkedWorktree(directory: String) -> Bool {
        var root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".git").path, isDirectory: &isDirectory
            ) {
                return !isDirectory.boolValue
            }
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { return false }
            root = parent
        }
    }

    public func verdict(workingDirectory: String) async -> CleanupWorktreeVerdict {
        guard Self.isLinkedWorktree(directory: workingDirectory) else { return .clear }
        let base = ["--no-optional-locks", "-C", workingDirectory]
        do {
            let status = try await capture(base + ["status", "--porcelain=v2", "--branch"])
            if status.split(separator: "\n").contains(where: { !$0.hasPrefix("#") }) {
                return .protected("The worktree has uncommitted changes.")
            }
            // HEAD is listed too, so commits on a detached HEAD count as unpushed.
            let unpushed = try await capture(base + ["rev-list", "--count", "HEAD", "--branches", "--not", "--remotes"])
            guard let count = Int(unpushed.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return .protected("The worktree could not be checked.")
            }
            if count > 0 { return .protected("The worktree has commits that are not pushed.") }
            let stash = try await capture(base + ["stash", "list"])
            if !stash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .protected("The repository has a stash.")
            }
            return .clear
        } catch {
            return .protected("The worktree could not be checked.")
        }
    }
}

// MARK: Review snapshot

public struct CleanupEligibleRow: Sendable, Equatable, Identifiable {
    public var id: UUID { record.session.id }
    public let record: CatalogSession
    /// When the conversation became eligible.
    public let eligibleSince: Date
    /// What a deletion removes (CP4-A dry run); nil when the dry run could not be made.
    public let byteCount: Int64?
    public let fileCount: Int?
}

public struct CleanupExcludedRow: Sendable, Equatable, Identifiable {
    public var id: UUID { record.session.id }
    public let record: CatalogSession
    public let reason: CleanupExclusionReason
}

/// A snapshot. The confirm step re-plans and never applies an older snapshot.
public struct CleanupReview: Sendable, Equatable {
    public let generatedAt: Date
    public let due: CleanupDue
    public let mode: CleanupMode
    public let eligible: [CleanupEligibleRow]
    public let excluded: [CleanupExcludedRow]

    public var isDue: Bool { due == .due }
}

public enum CleanupRowResult: Sendable, Equatable {
    case deleted
    /// The deletion is recorded but a step has not finished; it can be retried.
    case incomplete(String)
    case failed(String)
    /// Not deleted: the fresh plan no longer lists the conversation as eligible.
    case skipped(CleanupExclusionReason)
}

public struct CleanupConfirmation: Sendable, Equatable {
    public let results: [UUID: CleanupRowResult]
    /// The plan the confirmation ran against (taken at confirm time).
    public let review: CleanupReview
}

/// What the review UI needs from the coordinator; a seam so the UI is testable.
public protocol CleanupReviewing: Sendable {
    func review(now: Date) async throws -> CleanupReview
    /// Re-plans, deletes the confirmed rows that are still eligible one by one, reports each
    /// result through `progress` and records the review as done when it was due.
    func confirm(ids: [UUID], now: Date,
                 progress: @escaping @Sendable (UUID, CleanupRowResult) async -> Void) async throws -> CleanupConfirmation
    /// The user dismissed a due review without deleting: it still counts as a run.
    func dismiss(now: Date) async throws
    /// The four numbers in force (D-69): the user's, else the defaults.
    func settings() async throws -> CleanupSettings
    /// Keeps new numbers; they apply from the next review on.
    func setSettings(_ settings: CleanupSettings) async throws
    /// Forgets the user's numbers and returns the defaults now in force.
    func resetSettings() async throws -> CleanupSettings
}

// MARK: Coordinator

public actor CleanupCoordinator: CleanupReviewing {
    public static let lastCleanupKey = "last_cleanup_at"
    public static let lastLaunchKey = "last_launch_at"

    /// The runtime facts the coordinator needs; closures so tests supply their own.
    public struct Host: Sendable {
        public var isRunning: @Sendable (UUID) async -> Bool
        public var worktree: @Sendable (_ workingDirectory: String) async -> CleanupWorktreeVerdict
        public var preview: @Sendable (UUID) async throws -> ConversationDeletionPreview
        public var delete: @Sendable (UUID) async throws -> ConversationDeletionOutcome

        public init(
            isRunning: @escaping @Sendable (UUID) async -> Bool,
            worktree: @escaping @Sendable (String) async -> CleanupWorktreeVerdict,
            preview: @escaping @Sendable (UUID) async throws -> ConversationDeletionPreview,
            delete: @escaping @Sendable (UUID) async throws -> ConversationDeletionOutcome
        ) {
            self.isRunning = isRunning
            self.worktree = worktree
            self.preview = preview
            self.delete = delete
        }
    }

    private let catalog: SessionCatalog
    private let host: Host
    /// The rules the user's four numbers (`CleanupSettings`) are applied to.
    private let policy: CleanupPolicy
    /// `last_launch_at` as it was before this launch overwrote it (long-absence input).
    private var previousLaunchAt: Date?

    public init(catalog: SessionCatalog, host: Host, policy: CleanupPolicy = CleanupPolicy()) {
        self.catalog = catalog
        self.host = host
        self.policy = policy
    }

    public init(runtime: SessionRuntime, policy: CleanupPolicy = CleanupPolicy()) {
        let protection = CleanupWorktreeProtection.live(supervisor: runtime.supervisor)
        self.init(
            catalog: runtime.catalog,
            host: Host(
                isRunning: { [supervisor = runtime.supervisor] id in
                    await supervisor.session(id: id)?.currentRun != nil
                },
                worktree: { await protection.verdict(workingDirectory: $0) },
                preview: { try await runtime.deletionPreview(id: $0) },
                delete: { try await runtime.deleteConversation(id: $0) }
            ),
            policy: policy
        )
    }

    // MARK: Launch

    /// Remembers the previous launch time for the long-absence rule and records this launch.
    public func recordLaunch(now: Date = Date()) async {
        previousLaunchAt = try? await readDate(Self.lastLaunchKey)
        try? await catalog.setAppState(Self.lastLaunchKey, to: Self.encode(now))
    }

    // MARK: Review

    public func review(now: Date) async throws -> CleanupReview {
        try await makeReview(now: now, withSizes: true)
    }

    public func confirm(
        ids: [UUID], now: Date,
        progress: @escaping @Sendable (UUID, CleanupRowResult) async -> Void
    ) async throws -> CleanupConfirmation {
        // Never the snapshot the user looked at: the plan is taken again now.
        let fresh = try await makeReview(now: now, withSizes: false)
        let confirmed = Set(ids)
        let eligible = Set(fresh.eligible.map(\.id))
        var results: [UUID: CleanupRowResult] = [:]
        for id in ids where !eligible.contains(id) {
            let reason = fresh.excluded.first { $0.id == id }?.reason ?? .notStale
            results[id] = .skipped(reason)
            await progress(id, results[id]!)
        }
        for row in fresh.eligible where confirmed.contains(row.id) {
            let result: CleanupRowResult
            do {
                switch try await host.delete(row.id) {
                case .deleted: result = .deleted
                case .incomplete(let pending):
                    result = .incomplete(pending.lastFailure ?? "stopped at \(pending.state.rawValue)")
                }
            } catch {
                result = .failed(Self.describe(error))
            }
            results[row.id] = result
            await progress(row.id, result)
        }
        if fresh.isDue { try await recordRun(now: now) }
        return CleanupConfirmation(results: results, review: fresh)
    }

    public func dismiss(now: Date) async throws {
        if try await makeReview(now: now, withSizes: false).isDue { try await recordRun(now: now) }
    }

    // MARK: Settings

    public func settings() async throws -> CleanupSettings {
        try await catalog.cleanupSettings(base: policy)
    }

    public func setSettings(_ settings: CleanupSettings) async throws {
        try await catalog.setCleanupSettings(settings)
    }

    public func resetSettings() async throws -> CleanupSettings {
        try await catalog.resetCleanupSettings()
        return try await settings()
    }

    // MARK: Internals

    private func makeReview(now: Date, withSizes: Bool) async throws -> CleanupReview {
        // Only Claude conversations can be deleted (D-28 refuses Codex and synthetic ones), so
        // only they are offered; listing a row that can only fail would mislead.
        let stale = try await catalog.sessions().filter { $0.lifecycle == .stale && $0.session.provider == .claude }
        var candidates: [CleanupCandidate] = []
        for record in stale {
            let id = record.session.id
            let running = await host.isRunning(id)
            // Git only runs for rows the other rules have not already excluded.
            let verdict: CleanupWorktreeVerdict = record.pinned || running
                ? .clear : await host.worktree(record.session.workingDirectory)
            candidates.append(CleanupCandidate(
                id: id, lifecycle: record.lifecycle, lastUsedAt: record.lastUsedAt,
                staleSince: record.staleSince, pinned: record.pinned, isRunning: running,
                isDeleting: false, worktree: verdict
            ))
        }
        // The user's numbers are read for every plan, so a change applies to the next one.
        let plan = CleanupPlanner.plan(
            candidates: candidates, now: now,
            lastRunAt: try await readDate(Self.lastCleanupKey), lastLaunchAt: previousLaunchAt,
            policy: try await catalog.cleanupPolicy(base: policy)
        )
        let records = Dictionary(uniqueKeysWithValues: stale.map { ($0.session.id, $0) })
        var eligible: [CleanupEligibleRow] = []
        for entry in plan.eligible {
            guard let record = records[entry.id] else { continue }
            let preview = withSizes ? try? await host.preview(entry.id) : nil
            eligible.append(CleanupEligibleRow(
                record: record, eligibleSince: entry.eligibleSince,
                byteCount: preview?.byteCount, fileCount: preview?.fileCount
            ))
        }
        let excluded = plan.excluded.compactMap { entry in
            records[entry.id].map { CleanupExcludedRow(record: $0, reason: entry.reason) }
        }
        return CleanupReview(generatedAt: now, due: plan.due, mode: plan.mode, eligible: eligible, excluded: excluded)
    }

    private func recordRun(now: Date) async throws {
        try await catalog.setAppState(Self.lastCleanupKey, to: Self.encode(now))
    }

    private func readDate(_ key: String) async throws -> Date? {
        try await catalog.appState(key).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    private static func encode(_ date: Date) -> String { String(date.timeIntervalSince1970) }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? SessionRuntimeError { return error.description }
        return String(describing: error)
    }
}
