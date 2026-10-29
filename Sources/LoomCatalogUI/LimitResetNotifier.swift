import Foundation
import LoomCore

/// One quiet, scheduled reset notice. The identifier is separate from approval and turn-finished banners.
public struct LimitResetNotice: Equatable, Sendable {
    public let identifier: String
    public let sessionID: UUID
    public let windowID: String
    public let windowName: String
    public let resetsAt: Date

    public init(identifier: String, sessionID: UUID, windowID: String, windowName: String, resetsAt: Date) {
        self.identifier = identifier
        self.sessionID = sessionID
        self.windowID = windowID
        self.windowName = windowName
        self.resetsAt = resetsAt
    }
}

@MainActor public protocol LimitResetScheduling: AnyObject {
    func scheduleReset(_ notice: LimitResetNotice) async -> Bool
    func cancelResets(_ identifiers: [String])
    func cancelAllResets()
}

/// Event-driven reset notices; this object owns no timer or provider read.
@MainActor public final class LimitResetNotifier {
    public nonisolated static let identifierPrefix = "loom-limit-reset:"
    public nonisolated static let categoryIdentifier = "loom-limit-reset"
    public nonisolated static let continueActionIdentifier = "continue"

    private struct Entry {
        let notice: LimitResetNotice
        let token: UUID
        var scheduled = false
    }

    private let scheduler: any LimitResetScheduling
    private let onContinue: (UUID) -> Void
    private var enabled = false
    private var accountRevision: UInt64?
    private var entries: [String: Entry] = [:]
    private static let maximumEntries = 128
    private static let supportedWindows = Set(["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"])

    /// Account identity stays in the existing in-memory reading; this exposes only whether it is usable.
    public static func hasStableAccount(_ account: HarnessAccount?) -> Bool {
        guard case let .subscription(email, _)? = account, let email else { return false }
        return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(scheduler: any LimitResetScheduling, onContinue: @escaping (UUID) -> Void) {
        self.scheduler = scheduler
        self.onContinue = onContinue
    }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { invalidateAll() }
    }

    public func receive(_ signal: ClaudeLimitResetSignal, reading: HarnessReading, accountRevision: UInt64,
                        authorization: NotificationAuthorization, now: Date) async {
        guard enabled else { return }
        if let old = self.accountRevision, old != accountRevision { invalidateAll() }
        self.accountRevision = accountRevision
        guard authorization == .authorized, reading.provider == ClaudeLimitResetSignal.provider,
              Self.hasStableAccount(reading.account),
              Self.supportedWindows.contains(signal.windowID),
              signal.resetsAt > now, signal.resetsAt.timeIntervalSince(now) <= 8 * 86_400 else { return }
        let matching = reading.windows.filter { $0.id == signal.windowID && $0.isCurrent(at: now)
            && $0.resetsAt.map { abs($0.timeIntervalSince(signal.resetsAt)) < 1 } == true }
        guard matching.count == 1, let window = matching.first else { return }
        cancel { $0.resetsAt <= now }
        guard !entries.values.contains(where: {
            $0.notice.sessionID == signal.sessionID && $0.notice.windowID == signal.windowID
                && abs($0.notice.resetsAt.timeIntervalSince(signal.resetsAt)) < 1
        }) else { return }
        let seconds = Int64(signal.resetsAt.timeIntervalSince1970.rounded())
        let identifier = "\(Self.identifierPrefix)\(signal.sessionID.uuidString):\(signal.windowID):\(seconds):\(UUID().uuidString)"
        cancel(where: { $0.sessionID == signal.sessionID && $0.windowID == signal.windowID })
        guard entries.count < Self.maximumEntries else { return }
        let notice = LimitResetNotice(identifier: identifier, sessionID: signal.sessionID, windowID: signal.windowID,
                                      windowName: window.name, resetsAt: signal.resetsAt)
        let token = UUID()
        entries[identifier] = Entry(notice: notice, token: token)
        let scheduled = await scheduler.scheduleReset(notice)
        guard entries[identifier]?.token == token else {
            if scheduled { scheduler.cancelResets([identifier]) }
            return
        }
        if scheduled { entries[identifier]?.scheduled = true }
        else { entries[identifier] = nil }
    }

    public func accountChanged() {
        accountRevision = nil
        invalidateAll()
    }

    public func sessionDeleted(_ id: UUID) { cancel { $0.sessionID == id } }

    public func readingChanged(_ reading: HarnessReading?, now: Date) {
        guard let reading, reading.provider == ClaudeLimitResetSignal.provider, Self.hasStableAccount(reading.account) else {
            invalidateAll()
            return
        }
        cancel { notice in
            !reading.windows.contains { window in
                window.id == notice.windowID && window.isCurrent(at: now)
                    && window.resetsAt.map { abs($0.timeIntervalSince(notice.resetsAt)) < 1 } == true
            }
        }
    }

    public func activate(identifier: String) {
        guard enabled, let entry = entries[identifier], entry.scheduled else { return }
        onContinue(entry.notice.sessionID)
    }

    private func cancel(where predicate: (LimitResetNotice) -> Bool) {
        let identifiers = entries.values.filter { predicate($0.notice) }.map { $0.notice.identifier }
        guard !identifiers.isEmpty else { return }
        for id in identifiers { entries[id] = nil }
        scheduler.cancelResets(identifiers)
    }

    private func invalidateAll() {
        entries.removeAll()
        scheduler.cancelAllResets()
    }
}
