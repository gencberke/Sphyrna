import Foundation

/// Counts how often a card's views evaluate their `body`, so a test can state which cards a change redraws.
/// Counts only the sessions a test asked to watch: with none (every normal run) each evaluation costs one
/// emptiness check and nothing is kept, and a test's counts are not disturbed by other sidebars alive at the
/// same time.
@MainActor
enum SidebarRenderProbe {
    static var watched: Set<UUID> = []
    private(set) static var cardBodies: [UUID: Int] = [:]
    private(set) static var timeLabelBodies: [UUID: Int] = [:]
    private(set) static var groupings = 0

    static var cardTotal: Int { cardBodies.values.reduce(0, +) }
    static var timeLabelTotal: Int { timeLabelBodies.values.reduce(0, +) }

    static func card(_ id: UUID) {
        guard !watched.isEmpty, watched.contains(id) else { return }
        cardBodies[id, default: 0] += 1
    }

    static func timeLabel(_ id: UUID) {
        guard !watched.isEmpty, watched.contains(id) else { return }
        timeLabelBodies[id, default: 0] += 1
    }

    /// The day sections of a list were built (`DayGrouping.sections`), counted for a list with a watched row.
    static func grouping(of rows: [SessionRowModel]) {
        guard !watched.isEmpty, rows.contains(where: { watched.contains($0.id) }) else { return }
        groupings += 1
    }

    static func watch(_ ids: [UUID]) {
        watched = Set(ids)
        reset()
    }

    static func reset() {
        cardBodies = [:]
        timeLabelBodies = [:]
        groupings = 0
    }
}
