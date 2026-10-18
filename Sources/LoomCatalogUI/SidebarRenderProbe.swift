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
    /// Controls currently on screen by name (appeared minus disappeared), for a test that asks "how many Resume
    /// buttons does this screen draw".
    private(set) static var onScreen: [String: Int] = [:]
    private(set) static var projectListBodies = 0
    private(set) static var draftRowBodies: [String: Int] = [:]
    /// How often a row's pill (its hover state) evaluated, by the pill's key (`sidebar-card:<id>`).
    private(set) static var pillBodies: [String: Int] = [:]

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

    /// The project view's list evaluated (counted while a test watches anything).
    static func projectList() {
        guard !watched.isEmpty else { return }
        projectListBodies += 1
    }

    static func appeared(_ control: String) {
        guard !watched.isEmpty else { return }
        onScreen[control, default: 0] += 1
    }

    static func disappeared(_ control: String) {
        guard !watched.isEmpty else { return }
        onScreen[control, default: 0] -= 1
    }

    static func pill(_ key: String?) {
        guard !watched.isEmpty, let key else { return }
        pillBodies[key, default: 0] += 1
    }

    static func draftRow(_ id: String) {
        guard !watched.isEmpty else { return }
        draftRowBodies[id, default: 0] += 1
    }

    static func watch(_ ids: [UUID]) {
        watched = Set(ids)
        reset()
    }

    static func reset() {
        cardBodies = [:]
        timeLabelBodies = [:]
        groupings = 0
        projectListBodies = 0
        draftRowBodies = [:]
        pillBodies = [:]
        onScreen = [:]
    }
}

/// Development evidence: lets the acceptance run turn the probe on in a running app and read what it counted
/// (the numbers of `SidebarRenderTests`, from the real window). Off unless asked; counting is the probe's own
/// emptiness check otherwise.
@MainActor
public enum RenderEvidence {
    /// Starts counting every row the model lists now, and the project list and draft rows.
    public static func start(model: CatalogModel) {
        var ids = Set<UUID>([UUID()])
        for key in [CatalogListKey.activity, .unassigned] + model.projects.map({ CatalogListKey.project($0.id) }) {
            for row in model.list(for: key).rows { ids.insert(row.id) }
        }
        SidebarRenderProbe.watch(Array(ids))
    }

    public static func reset() { SidebarRenderProbe.reset() }

    public static var counts: [String: Any] {
        ["cards": SidebarRenderProbe.cardTotal, "projectLists": SidebarRenderProbe.projectListBodies,
         "draftRows": SidebarRenderProbe.draftRowBodies, "onScreen": SidebarRenderProbe.onScreen]
    }
}
