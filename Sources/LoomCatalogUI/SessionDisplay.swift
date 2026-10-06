import Foundation
import LoomCore

/// What a card shows about a conversation's state. Derived only from the
/// catalog row and the core's latest event state; nothing is stored here.
/// A run that ended is never confused with the idle/stale lifecycle.
public enum SessionIndicator: Equatable, Sendable {
    case working
    case waitingForApproval
    case waitingForInput
    /// A live run whose provider state is not known (no reliable signal).
    case unknown
    case failed(String?)
    /// The last stop could not be verified; work may still be running.
    case stopUnverified(String)
    /// The last start, resume or provider connection went wrong (shown with its text).
    case problem(String)
    /// The provider's conversation identity is not certain; nothing was changed.
    case identityUnclear
    /// A reliable turn completion nobody looked at yet.
    case unviewedCompletion
    /// Live run, turn finished and seen.
    case ready
    case idle
    case stale
    /// No live run (history).
    case ended

    public init(record: CatalogSession, live: SessionViewState?) {
        if let failure = live?.stopFailure {
            self = .stopUnverified(failure)
            return
        }
        if let issue = live?.issue {
            self = .problem(issue)
            return
        }
        if let live, live.runID != nil, live.identity == .ambiguous {
            self = .identityUnclear
            return
        }
        if let live, live.runID != nil {
            switch live.status?.activity {
            case nil, .unknown?: self = .unknown
            case .working?: self = .working
            case .waitingForApproval?: self = .waitingForApproval
            case .waitingForInput?: self = .waitingForInput
            case let .failed(message)?: self = .failed(message)
            case .sessionEnded?: self = .ended
            case .turnComplete?:
                if (live.status?.pendingProviderWorkCount ?? 0) > 0 { self = .working }
                else { self = live.unviewedCompletion ? .unviewedCompletion : .ready }
            }
            return
        }
        // The run is over; a reliable finish nobody saw stays visible until viewed.
        if live?.unviewedCompletion == true {
            self = .unviewedCompletion
            return
        }
        switch live?.lifecycle ?? record.lifecycle {
        case .idle: self = .idle
        case .stale: self = .stale
        case .active: self = .ended
        }
    }

    /// Short card label; nil when the card needs none.
    public var label: String? {
        switch self {
        case .working: "Working"
        case .waitingForApproval: "Needs approval"
        case .waitingForInput: "Waiting for you"
        case .unknown: "State unknown"
        case .failed: "Failed"
        case .stopUnverified: "Stop not verified"
        case .problem: "Problem"
        case .identityUnclear: "Identity unclear"
        case .unviewedCompletion: "Finished"
        case .ready: "Ready"
        case .idle: "Idle"
        case .stale: "Stale"
        case .ended: nil
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .waitingForApproval, .waitingForInput, .failed, .stopUnverified, .unviewedCompletion,
             .problem, .identityUnclear: true
        default: false
        }
    }
}

/// What a project row signals about its conversations (DESIGN §4). Priority:
/// failure, then attention, then an unviewed completion.
public enum ProjectAttention: Int, Comparable, Sendable {
    case unviewed = 1, attention, failure

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init?(_ indicator: SessionIndicator) {
        switch indicator {
        case .failed, .stopUnverified, .problem: self = .failure
        case .waitingForApproval, .waitingForInput, .identityUnclear: self = .attention
        case .unviewedCompletion: self = .unviewed
        default: return nil
        }
    }

    public static func strongest(of indicators: [SessionIndicator]) -> ProjectAttention? {
        indicators.compactMap(ProjectAttention.init).max()
    }

    public var label: String {
        switch self {
        case .failure: "A conversation failed"
        case .attention: "A conversation needs you"
        case .unviewed: "A conversation finished"
        }
    }
}

public enum ProviderName {
    public static func title(_ provider: ManagedSession.Provider) -> String {
        switch provider {
        case .claude: "Claude"
        case .codex: "Codex"
        case .synthetic: "Synthetic"
        }
    }
}

extension CatalogSession {
    /// Custom or announced title; otherwise a provider and project based default.
    /// `repeatsProject: false` (inside its project's group) leaves the project name out of the default title.
    public func displayTitle(projectName: String?, repeatsProject: Bool = true) -> String {
        if let title, !title.isEmpty { return title }
        let name = ProviderName.title(session.provider)
        guard repeatsProject || projectName == nil else { return name + " conversation" }
        return name + " · " + (projectName ?? "No project")
    }
}

public enum RelativeTime {
    /// "now", "5m", "3h", "2d", "3w", "1y" (last use, not model working time).
    public static func string(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        if seconds < 7 * 86_400 { return "\(seconds / 86_400)d" }
        if seconds < 365 * 86_400 { return "\(seconds / (7 * 86_400))w" }
        return "\(seconds / (365 * 86_400))y"
    }
}

public struct DaySection: Identifiable {
    public let id: Date
    public let title: String
    public let rows: [SessionRowModel]
}

public enum DayGrouping {
    /// Groups rows already sorted by last use into calendar days.
    @MainActor
    public static func sections(_ rows: [SessionRowModel], now: Date,
                                calendar: Calendar = .current) -> [DaySection] {
        var result: [DaySection] = []
        var current: (day: Date, rows: [SessionRowModel])?
        func flush() {
            guard let current else { return }
            result.append(DaySection(id: current.day, title: title(for: current.day, now: now, calendar: calendar),
                                     rows: current.rows))
        }
        for row in rows {
            let day = calendar.startOfDay(for: row.record.lastUsedAt)
            if current?.day == day { current?.rows.append(row) }
            else {
                flush()
                current = (day, [row])
            }
        }
        flush()
        return result
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US")
        if days < 7 { formatter.dateFormat = "EEEE" }
        else if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MMM d"
        } else { formatter.dateFormat = "MMM d, yyyy" }
        return formatter.string(from: day)
    }
}
