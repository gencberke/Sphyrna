import Foundation
import LoomCore

/// What the menu bar item's badge slot holds (D-52): the working spinner, or the dot of the most urgent
/// session that needs the user. The dot wins when both apply. The raw values are the evidence names.
public enum MenuBarBadge: String, Equatable, Sendable {
    case none, working, failure, attention, unviewed

    init(_ attention: ProjectAttention) {
        switch attention {
        case .failure: self = .failure
        case .attention: self = .attention
        case .unviewed: self = .unviewed
        }
    }

    /// The class of a dot badge; nil for none and working.
    public var dotClass: ProjectAttention? {
        switch self {
        case .failure: .failure
        case .attention: .attention
        case .unviewed: .unviewed
        case .none, .working: nil
        }
    }
}

/// The menu bar item in numbers: cheap to derive on every live change (no strings), compared so the
/// item and the notifier hear only about real changes. Working changes the Dock badge never sees, so
/// the menu bar has its own summary.
public struct MenuBarSummary: Equatable, Sendable {
    public var badge: MenuBarBadge
    /// Sessions that need the user (`SessionIndicator.needsAttention`).
    public var needsYou: Int
    /// Sessions that are working and need nobody.
    public var working: Int
    /// Sessions at Needs approval, including an agent's wait on an open-session request (D-40).
    public var approvals: Set<UUID>

    public static let idle = MenuBarSummary(badge: .none, needsYou: 0, working: 0, approvals: [])

    public static func derive(_ candidates: [AttentionCandidate]) -> MenuBarSummary {
        var needsYou = 0, working = 0
        var strongest: ProjectAttention?
        var approvals = Set<UUID>()
        for candidate in candidates {
            if candidate.indicator == .waitingForApproval { approvals.insert(candidate.id) }
            if let attention = ProjectAttention(candidate.indicator) {
                needsYou += 1
                strongest = max(strongest ?? attention, attention)
            } else if candidate.indicator == .working {
                working += 1
            }
        }
        let badge: MenuBarBadge = strongest.map(MenuBarBadge.init) ?? (working > 0 ? .working : .none)
        return MenuBarSummary(badge: badge, needsYou: needsYou, working: working, approvals: approvals)
    }

    /// The status item's accessibility label: "Loom", "Loom, 2 sessions working",
    /// "Loom, 1 session needs you, 2 working".
    public var accessibilityLabel: String {
        func sessions(_ count: Int) -> String { count == 1 ? "1 session" : "\(count) sessions" }
        switch (needsYou, working) {
        case (0, 0): return "Loom"
        case (0, _): return "Loom, \(sessions(working)) working"
        case (_, 0): return "Loom, \(sessions(needsYou)) \(needsYou == 1 ? "needs" : "need") you"
        default: return "Loom, \(sessions(needsYou)) \(needsYou == 1 ? "needs" : "need") you, \(working) working"
        }
    }
}

/// A session as the menu bar menu reads it: the attention candidate plus what the row prints.
public struct MenuBarEntry: Equatable, Sendable {
    public let id: UUID
    public let indicator: SessionIndicator
    public let lastActivityAt: Date
    public let title: String
    public let project: String?

    public init(id: UUID, indicator: SessionIndicator, lastActivityAt: Date, title: String, project: String?) {
        self.id = id
        self.indicator = indicator
        self.lastActivityAt = lastActivityAt
        self.title = title
        self.project = project
    }

    var candidate: AttentionCandidate {
        AttentionCandidate(id: id, indicator: indicator, lastActivityAt: lastActivityAt)
    }
}

/// One session row of the menu. `attention` is the class of its dot; nil for a working session.
public struct MenuBarRow: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let project: String?
    public let attention: ProjectAttention?
}

/// The menu bar item and its menu at one moment (D-49, D-52): two sections of at most five rows each,
/// and how many more there are. Built from the live sessions every time the menu opens.
public struct MenuBarState: Equatable, Sendable {
    public static let maxRows = 5

    public let summary: MenuBarSummary
    public let needsYou: [MenuBarRow]
    public let needsYouMore: Int
    public let working: [MenuBarRow]
    public let workingMore: Int

    public var isEmpty: Bool { needsYou.isEmpty && working.isEmpty }

    public static func derive(_ entries: [MenuBarEntry]) -> MenuBarState {
        // The class first (failure, attention, unviewed), then the most recent activity, then the id so
        // two equal sessions never swap places between two openings of the menu.
        func recentFirst(_ lhs: MenuBarEntry, _ rhs: MenuBarEntry) -> Bool {
            if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt > rhs.lastActivityAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let needing = entries.compactMap { entry in ProjectAttention(entry.indicator).map { (entry, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return recentFirst(lhs.0, rhs.0)
            }
        let working = entries.filter { $0.indicator == .working }.sorted(by: recentFirst)
        return MenuBarState(
            summary: MenuBarSummary.derive(entries.map(\.candidate)),
            needsYou: needing.prefix(maxRows).map {
                MenuBarRow(id: $0.0.id, title: $0.0.title, project: $0.0.project, attention: $0.1)
            },
            needsYouMore: max(0, needing.count - maxRows),
            working: working.prefix(maxRows).map {
                MenuBarRow(id: $0.id, title: $0.title, project: $0.project, attention: nil)
            },
            workingMore: max(0, working.count - maxRows))
    }
}

/// The menu as a list of items, before AppKit draws it: what `menubar-menu` writes and the controller renders.
public struct MenuBarMenuItem: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case header, needsYouSession, workingSession, more, empty, newSession, openLoom, settings, quit, separator
    }

    public let kind: Kind
    public let title: String
    public let project: String?
    public let enabled: Bool
    public let sessionID: UUID?
    public let attention: ProjectAttention?
    /// The key equivalent shown at the right edge.
    public let key: String?
}

public enum MenuBarMenu {
    public static let emptyTitle = "Nothing is working or waiting."
    public static let needsYouHeader = "Needs you"
    public static let workingHeader = "Working"

    public static func moreTitle(_ count: Int) -> String { "and \(count) more…" }

    /// Sections appear only when they have sessions; with none at all one disabled line says so.
    public static func items(for state: MenuBarState, canStartSession: Bool = true) -> [MenuBarMenuItem] {
        func item(_ kind: MenuBarMenuItem.Kind, _ title: String, project: String? = nil, enabled: Bool = true,
                  id: UUID? = nil, attention: ProjectAttention? = nil, key: String? = nil) -> MenuBarMenuItem {
            MenuBarMenuItem(kind: kind, title: title, project: project, enabled: enabled, sessionID: id,
                            attention: attention, key: key)
        }
        var items: [MenuBarMenuItem] = []
        if state.isEmpty {
            items.append(item(.empty, emptyTitle, enabled: false))
        } else {
            if !state.needsYou.isEmpty {
                items.append(item(.header, needsYouHeader, enabled: false))
                items += state.needsYou.map {
                    item(.needsYouSession, $0.title, project: $0.project, id: $0.id, attention: $0.attention)
                }
                if state.needsYouMore > 0 { items.append(item(.more, moreTitle(state.needsYouMore))) }
            }
            if !state.working.isEmpty {
                items.append(item(.header, workingHeader, enabled: false))
                items += state.working.map { item(.workingSession, $0.title, project: $0.project, id: $0.id) }
                if state.workingMore > 0 { items.append(item(.more, moreTitle(state.workingMore))) }
            }
        }
        items.append(item(.separator, ""))
        items.append(item(.newSession, "New Claude Session", enabled: canStartSession, key: "⌘N"))
        items.append(item(.openLoom, "Open Loom"))
        items.append(item(.separator, ""))
        items.append(item(.settings, "Settings…", key: "⌘,"))
        items.append(item(.quit, "Quit Loom", key: "⌘Q"))
        return items
    }
}
