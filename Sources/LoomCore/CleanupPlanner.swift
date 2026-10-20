import Foundation

/// Every number the cleanup arithmetic uses (contract section 5, DP-CP4-2).
/// Changing a rule is a change here, not a change in the planner.
public struct CleanupPolicy: Equatable, Sendable {
    /// Fallback stale start for a stale row without a recorded `staleSince`
    /// (last use plus this). Matches `SessionIdlePolicy.staleAfter`.
    public var staleAfter: TimeInterval
    /// How long a conversation must have been stale before it is eligible.
    public var minimumStaleDuration: TimeInterval
    /// A cleanup run is due this long (elapsed time, not calendar months) after the last one.
    public var cadence: TimeInterval
    /// This long since the previous launch counts as a long absence: review required.
    public var longAbsenceThreshold: TimeInterval
    /// More eligible conversations than this: review required.
    public var bulkLimit: Int
    /// True: viewing a stale row (a later `lastUsedAt`) extends the wait.
    /// False: the wait is always `staleSince + minimumStaleDuration`.
    public var viewingExtendsWait: Bool
    /// Off by default. Even when on, a long absence or a bulk list forces a review.
    public var automaticDeletionEnabled: Bool

    public init(
        staleAfter: TimeInterval = 15 * 24 * 60 * 60,
        minimumStaleDuration: TimeInterval = 15 * 24 * 60 * 60,
        cadence: TimeInterval = 30 * 24 * 60 * 60,
        longAbsenceThreshold: TimeInterval = 45 * 24 * 60 * 60,
        bulkLimit: Int = 10,
        viewingExtendsWait: Bool = true,
        automaticDeletionEnabled: Bool = false
    ) {
        self.staleAfter = staleAfter
        self.minimumStaleDuration = minimumStaleDuration
        self.cadence = cadence
        self.longAbsenceThreshold = longAbsenceThreshold
        self.bulkLimit = bulkLimit
        self.viewingExtendsWait = viewingExtendsWait
        self.automaticDeletionEnabled = automaticDeletionEnabled
    }
}

/// Verdict of the worktree protection check (the caller fails closed).
public enum CleanupWorktreeVerdict: Equatable, Sendable {
    case clear
    /// Work that deletion could lose; the text says what (shown to the user).
    case protected(String)
}

/// Whether the conversation is the source or target of an unfinished
/// authorized task. Always `.none` until checkpoint 3 supplies the data.
public enum CleanupTaskLink: Equatable, Sendable {
    case none
    case unfinished
}

public struct CleanupCandidate: Equatable, Sendable {
    public let id: UUID
    public let lifecycle: SessionLifecycle
    public let lastUsedAt: Date
    /// When the row was classified stale; nil for rows classified before it was recorded.
    public let staleSince: Date?
    public let pinned: Bool
    public let isRunning: Bool
    /// A deletion is already pending or in progress for this conversation.
    public let isDeleting: Bool
    public let worktree: CleanupWorktreeVerdict
    public let taskLink: CleanupTaskLink

    public init(
        id: UUID, lifecycle: SessionLifecycle, lastUsedAt: Date, staleSince: Date?,
        pinned: Bool, isRunning: Bool, isDeleting: Bool,
        worktree: CleanupWorktreeVerdict = .clear, taskLink: CleanupTaskLink = .none
    ) {
        self.id = id
        self.lifecycle = lifecycle
        self.lastUsedAt = lastUsedAt
        self.staleSince = staleSince
        self.pinned = pinned
        self.isRunning = isRunning
        self.isDeleting = isDeleting
        self.worktree = worktree
        self.taskLink = taskLink
    }
}

public enum CleanupExclusionReason: Equatable, Sendable {
    case pinned
    case running
    case deleting
    case notStale
    /// Stale, but not yet long enough; eligible at this date unless used again.
    case waitUntil(Date)
    case worktree(String)
    case task
}

public struct CleanupEligible: Equatable, Sendable {
    public let id: UUID
    /// The moment the conversation became eligible (never later than the plan's `now`).
    public let eligibleSince: Date
}

public struct CleanupExclusion: Equatable, Sendable {
    public let id: UUID
    public let reason: CleanupExclusionReason
}

public enum CleanupDue: Equatable, Sendable {
    case notDue(until: Date)
    case due
}

public enum CleanupReviewReason: Equatable, Sendable {
    /// The policy does not allow automatic deletion (the default).
    case automaticDisabled
    case longAbsence
    case bulk
}

public enum CleanupMode: Equatable, Sendable {
    case automaticAllowed
    case reviewRequired(CleanupReviewReason)
}

/// The result is a snapshot. Callers re-plan at confirm time and never apply
/// an older plan; `eligible` and `excluded` are filled even when not due, so a
/// manual review can still use them. `mode` only matters when `due`.
public struct CleanupPlan: Equatable, Sendable {
    public let due: CleanupDue
    public let mode: CleanupMode
    /// Ordered by `eligibleSince`, then id.
    public let eligible: [CleanupEligible]
    /// In candidate order.
    public let excluded: [CleanupExclusion]
}

/// Pure calculation: no I/O, no clock reads. `now` and the two timestamps are
/// passed in so tests and callers decide what time it is.
public enum CleanupPlanner {
    public static func plan(
        candidates: [CleanupCandidate],
        now: Date,
        lastRunAt: Date?,
        lastLaunchAt: Date?,
        policy: CleanupPolicy = CleanupPolicy()
    ) -> CleanupPlan {
        var eligible: [CleanupEligible] = []
        var excluded: [CleanupExclusion] = []
        for candidate in candidates {
            switch classify(candidate, now: now, policy: policy) {
            case .eligible(let since): eligible.append(CleanupEligible(id: candidate.id, eligibleSince: since))
            case .excluded(let reason): excluded.append(CleanupExclusion(id: candidate.id, reason: reason))
            }
        }
        eligible.sort {
            $0.eligibleSince != $1.eligibleSince
                ? $0.eligibleSince < $1.eligibleSince
                : $0.id.uuidString < $1.id.uuidString
        }

        let mode: CleanupMode
        if let lastLaunchAt, now.timeIntervalSince(lastLaunchAt) >= policy.longAbsenceThreshold {
            mode = .reviewRequired(.longAbsence)
        } else if eligible.count > policy.bulkLimit {
            mode = .reviewRequired(.bulk)
        } else if !policy.automaticDeletionEnabled {
            mode = .reviewRequired(.automaticDisabled)
        } else {
            mode = .automaticAllowed
        }
        return CleanupPlan(due: due(now: now, lastRunAt: lastRunAt, policy: policy), mode: mode, eligible: eligible, excluded: excluded)
    }

    /// Whether a review is due: it depends only on the last run and the cadence, never on the catalog's rows.
    public static func due(now: Date, lastRunAt: Date?, policy: CleanupPolicy = CleanupPolicy()) -> CleanupDue {
        if let lastRunAt, now < lastRunAt.addingTimeInterval(policy.cadence) {
            return .notDue(until: lastRunAt.addingTimeInterval(policy.cadence))
        }
        return .due
    }

    private enum Classification {
        case eligible(since: Date)
        case excluded(CleanupExclusionReason)
    }

    /// Reasons are checked from most to least permanent; the wait comes last so
    /// an exception is never hidden behind "wait until".
    private static func classify(
        _ candidate: CleanupCandidate, now: Date, policy: CleanupPolicy
    ) -> Classification {
        if candidate.isDeleting { return .excluded(.deleting) }
        if candidate.isRunning { return .excluded(.running) }
        if candidate.pinned { return .excluded(.pinned) }
        guard candidate.lifecycle == .stale else { return .excluded(.notStale) }
        if case .protected(let detail) = candidate.worktree { return .excluded(.worktree(detail)) }
        if candidate.taskLink == .unfinished { return .excluded(.task) }

        let staleStart = candidate.staleSince ?? candidate.lastUsedAt.addingTimeInterval(policy.staleAfter)
        let waitStart = policy.viewingExtendsWait ? max(staleStart, candidate.lastUsedAt) : staleStart
        let eligibleAt = waitStart.addingTimeInterval(policy.minimumStaleDuration)
        return now >= eligibleAt ? .eligible(since: eligibleAt) : .excluded(.waitUntil(eligibleAt))
    }
}
