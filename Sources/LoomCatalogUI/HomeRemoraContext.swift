import Foundation
import LoomCore
import LoomRemora

/// Everything Remora's section draws, worked out from the model and Home's reads each time it draws (nothing is kept between
/// draws). A session that is not in the catalog now, or is being deleted, is in none of it.
struct HomeRemoraContext {
    let state: HomeRemoraState
    let brief: HomeRemoraBrief?
    /// The brief's tiles and lines when the state shows the brief; none while Remora reads; the catalog's tiles otherwise.
    let tiles: [HomeRemoraTile]
    /// The empty frames that stand in the tiles' places while Remora reads (DESIGN §9 Reading and writing); 0 in every other state.
    let readingFrames: Int
    let further: [HomeRemoraFurther]
    let quiet: [HomeRemoraQuiet]
    let pickedUp: Int
    let now: Date

    @MainActor
    static func make(model: CatalogModel, reads: HomeRemoraReads, ui: HomeRemoraUI) -> HomeRemoraContext {
        let remora = model.remora
        let excluded = remora.preferences.excludedProjects
        let brief = HomeRemoraBrief.current(kept: remora.keptBrief, lastAnswer: remora.lastAnswer)
        let existing = existingSessions(model: model, reads: reads)
        let recent = reads.recent.compactMap { model.homeRemoraSession($0) }
        let projects = model.projects.map { HomeRemoraProject(id: $0.id, name: $0.name, tone: $0.tone) }
        var latest: [UUID: Date] = [:]
        for session in recent { if let project = session.projectID { latest[project] = max(latest[project] ?? .distantPast, session.lastActivityAt) } }
        let plan = HomeRemoraTiles.brief(
            chips: brief?.chips ?? [], drafts: brief?.drafts ?? [], sessions: existing, excluded: excluded,
            projects: projects, latest: latest, before: brief?.startedAt)
        let picked = HomeRemoraTiles.pickedUp(plan.tiles, since: brief?.startedAt)

        var input = HomeRemoraState.Inputs()
        input.hasHost = model.hasRemora
        input.isOn = remora.preferences.isOn
        input.hasSessions = model.sessionCounts.values.reduce(0, +) > 0
        input.phase = remora.phase
        // A question that failed shows under the field (Home's own) or in ⌘K; only a brief's failure takes the brief's place.
        input.briefFailure = remora.call?.kind == .brief ? remora.lastFailure : nil
        input.decision = remora.lastBriefDecision
        input.stopped = remora.stopped
        input.hasBrief = brief != nil
        input.pickedUp = picked
        input.expanded = ui.expanded
        let state = HomeRemoraState.choose(input)

        let showsBrief = state == .brief || state == .folded
        // While a brief is written the tiles' places hold empty frames, an older brief kept or not; the brief's tiles take them.
        let reading = state == .reading
        let catalog = showsBrief || reading ? [] : HomeRemoraTiles.catalog(recent: recent, excluded: excluded)
        return HomeRemoraContext(
            state: state, brief: brief, tiles: showsBrief ? plan.tiles : catalog,
            readingFrames: reading ? HomeRemoraTiles.maxTiles : 0, further: showsBrief ? plan.further : [],
            quiet: showsBrief ? plan.quiet : [], pickedUp: picked, now: model.now)
    }

    /// The sessions the brief and the answers name that exist now.
    @MainActor
    static func existingSessions(model: CatalogModel, reads: HomeRemoraReads) -> [UUID: HomeRemoraSession] {
        var found: [UUID: HomeRemoraSession] = [:]
        for (id, record) in reads.sessions { if let session = model.homeRemoraSession(record) { found[id] = session } }
        return found
    }
}

extension HomeRemoraReads {
    /// The record Put in Draft needs for a session: the live one when the model holds it, else what Home read.
    @MainActor
    func record(of id: UUID, model: CatalogModel) -> CatalogSession? {
        model.rowModels[id]?.record ?? model.liveRecords[id] ?? sessions[id] ?? recent.first { $0.session.id == id }
    }
}
