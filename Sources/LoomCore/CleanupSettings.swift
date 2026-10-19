import Foundation

// D-69 point 10: the two numbers of the cleanup arithmetic that change what the user is offered are
// theirs to change (Settings → Sessions → Cleanup). They live in the catalog's `app_state`, next to the
// two cleanup timestamps, and `CleanupCoordinator` reads them on every review, so a change applies to
// the next plan and never to one already on screen. A key that was never written (or no longer parses)
// leaves the coordinator's base policy in force, which is the product default. The long-absence and
// bulk thresholds only word the due notice while automatic deletion is off, so they are not settings.

public struct CleanupSettings: Equatable, Sendable {
    /// Review again this many days after the last cleanup.
    public var reviewIntervalDays: Int
    /// A stale session can be deleted this many days after it went stale or after the user last opened it.
    public var deletionWaitDays: Int

    public static let reviewIntervalDaysRange = 7...365
    public static let deletionWaitDaysRange = 1...180

    /// The product defaults (contract §12.4, D-69).
    public static let standard = CleanupSettings(reviewIntervalDays: 30, deletionWaitDays: 15)

    /// Every value is held inside its range.
    public init(reviewIntervalDays: Int, deletionWaitDays: Int) {
        self.reviewIntervalDays = Self.reviewIntervalDaysRange.clamping(reviewIntervalDays)
        self.deletionWaitDays = Self.deletionWaitDaysRange.clamping(deletionWaitDays)
    }

    /// What `policy` says, in whole days.
    public init(policy: CleanupPolicy) {
        func days(_ interval: TimeInterval) -> Int { Int((interval / Self.day).rounded()) }
        self.init(reviewIntervalDays: days(policy.cadence), deletionWaitDays: days(policy.minimumStaleDuration))
    }

    public var isStandard: Bool { self == .standard }

    static let day: TimeInterval = 24 * 60 * 60

    // MARK: Storage

    enum Key {
        static let reviewIntervalDays = "cleanup_review_interval_days"
        static let deletionWaitDays = "cleanup_deletion_wait_days"
        static let all = [reviewIntervalDays, deletionWaitDays]
    }
}

private extension ClosedRange where Bound == Int {
    func clamping(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

extension SessionCatalog {
    private func storedNumber(_ key: String) throws -> Int? {
        try appState(key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The settings in force: each stored number over `base`'s, a number that was never written (or
    /// does not read as a whole number) taken from `base`, every value held inside its range.
    public func cleanupSettings(base: CleanupPolicy = CleanupPolicy()) throws -> CleanupSettings {
        let fallback = CleanupSettings(policy: base)
        return CleanupSettings(
            reviewIntervalDays: try storedNumber(CleanupSettings.Key.reviewIntervalDays) ?? fallback.reviewIntervalDays,
            deletionWaitDays: try storedNumber(CleanupSettings.Key.deletionWaitDays) ?? fallback.deletionWaitDays
        )
    }

    /// `base` with the numbers the user stored; a number never stored leaves `base`'s own value
    /// exactly as it is (not rounded to days).
    func cleanupPolicy(base: CleanupPolicy) throws -> CleanupPolicy {
        func days(_ value: Int, _ range: ClosedRange<Int>) -> TimeInterval {
            TimeInterval(range.clamping(value)) * CleanupSettings.day
        }
        var policy = base
        if let value = try storedNumber(CleanupSettings.Key.reviewIntervalDays) {
            policy.cadence = days(value, CleanupSettings.reviewIntervalDaysRange)
        }
        if let value = try storedNumber(CleanupSettings.Key.deletionWaitDays) {
            policy.minimumStaleDuration = days(value, CleanupSettings.deletionWaitDaysRange)
        }
        return policy
    }

    public func setCleanupSettings(_ settings: CleanupSettings) throws {
        try setAppState(CleanupSettings.Key.reviewIntervalDays, to: String(settings.reviewIntervalDays))
        try setAppState(CleanupSettings.Key.deletionWaitDays, to: String(settings.deletionWaitDays))
    }

    /// Forgets the user's numbers: the base policy (the defaults) is in force again.
    public func resetCleanupSettings() throws {
        for key in CleanupSettings.Key.all { try removeAppState(key) }
    }
}
