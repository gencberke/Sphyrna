import AppKit
import Foundation
import LoomCore
import LoomRemora
import Observation
import SwiftUI

/// Home's calls into the model's Remora API, all in this file (`RemoraReachTests` counts them): the automatic brief when Home shows,
/// Catch Me Up (and Catch Me Up Anyway, and Try Again), and a question from the field. Nothing here runs by itself: each is called
/// from a view's task or a button.
@MainActor
enum HomeRemoraCalls {
    /// What Home does each time it shows: reads the day's kept brief again (so a deletion's removal reaches the screen) and, when the
    /// brief is Automatic, asks the model for the morning brief with one reachability read. The model decides the rest (once a day,
    /// only when a session moved, not while the 5-hour limit is low).
    static func homeShown(model: CatalogModel, window: HomeWindowFacts, routeIsHome: Bool = true,
                          isOnline: () async -> Bool = { await NetworkReach.isOnline() }) async {
        await model.loadRemoraKeptBrief()
        let preferences = model.remora.preferences
        guard HomeRemoraShow.asksForBrief(isOn: preferences.isOn, hasHost: model.hasRemora, mode: preferences.briefMode) else { return }
        // Home that is not on screen asks nothing (the model would skip it as well): no reachability read, no decision to hold the
        // next ask back. The view asks again when its window is known.
        let shown = HomeRemoraShow.homeShown(routeIsHome: routeIsHome, window: window)
        guard shown else { return }
        model.briefRemoraIfDue(homeShown: shown, isOnline: await isOnline())
    }

    /// Catch Me Up (also Catch Me Up Anyway and Try Again of a brief): a new brief, whatever the schedule says. The brief takes the
    /// place of the answer under the field.
    @discardableResult
    static func catchMeUp(_ model: CatalogModel, ui: HomeRemoraUI) -> Bool {
        ui.asked = nil
        ui.expanded = false
        return model.briefRemora()
    }

    /// A question from the field. The question before it (when an answer shows) folds into the Earlier line; a retry of the same
    /// question keeps the line as it is. `followUp` carries the last exchange while an answer is up. Refused calls (a call runs,
    /// Remora is off) change nothing on screen.
    @discardableResult
    static func ask(_ model: CatalogModel, ui: HomeRemoraUI, _ question: String, retry: Bool = false) -> Bool {
        let previous = ui.asked
        let showingAnswer = previous != nil && !ui.answerClosed
        let followUp = showingAnswer && !retry && model.remora.lastAnswer?.question != nil
        guard model.askRemora(question, scope: ui.scope, followUp: followUp) else { return false }
        if showingAnswer, !retry { ui.earlier = previous }
        ui.asked = HomeRemoraUI.Asked(question: question, scope: ui.scope, at: Date())
        ui.answerClosed = false
        ui.text = ""
        return true
    }
}

/// The main window's state at the moment Home asks. The view holds its window weakly; nothing observes it.
@MainActor
final class HomeWindowProbe {
    weak var window: NSWindow?

    var facts: HomeWindowFacts {
        guard let window else { return .none }
        return HomeWindowFacts(hasWindow: true, isMiniaturized: window.isMiniaturized,
                               occlusionVisible: window.isVisible && window.occlusionState.contains(.visible))
    }
}

/// A view that tells its owner which window it sits in, once. It draws nothing.
struct HomeWindowProbeView: NSViewRepresentable {
    let probe: HomeWindowProbe
    let attached: () -> Void

    func makeNSView(context: Context) -> ProbeNSView {
        let view = ProbeNSView()
        view.probe = probe
        view.attached = attached
        return view
    }

    func updateNSView(_ view: ProbeNSView, context: Context) {
        view.probe = probe
        view.attached = attached
    }

    final class ProbeNSView: NSView {
        weak var probe: HomeWindowProbe?
        var attached: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            probe?.window = window
            // The owner learns of the window after this layout pass, not inside it.
            Task { @MainActor [weak self] in self?.attached?() }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// What Home reads for Remora's section, once for each time it shows and again when the model's brief, an answer or the catalog's
/// counts change: the sessions Remora names that still exist, the newest sessions for the catalog's tiles, and the project notes.
/// Replaced whole on every read and dropped with the view, so it keeps nothing that outlives a deletion. The tiles are built from
/// it and the model each time Home draws.
@MainActor @Observable
final class HomeRemoraReads {
    private(set) var sessions: [UUID: CatalogSession] = [:]
    private(set) var recent: [CatalogSession] = []
    private(set) var notes: [RemoraHostNote] = []
    private(set) var hasRead = false
    /// The undo token the model held when Home showed: "Remembered" stands only for a fact saved since.
    let baselineUndo: RemoraUndoToken?

    init(baselineUndo: RemoraUndoToken?) { self.baselineUndo = baselineUndo }

    func read(model: CatalogModel) async {
        guard let catalog = model.catalog else { return }
        let state = model.remora
        var wanted: [UUID] = []
        func want(_ id: String) { if let id = UUID(uuidString: id) { wanted.append(id) } }
        if let kept = state.keptBrief {
            kept.chips.forEach { want($0.sessionID) }
            kept.drafts.forEach { want($0.sessionID) }
            wanted += kept.readSessionIDs
        }
        if let answer = state.lastAnswer {
            answer.answer.chips.forEach { want($0.sessionID) }
            answer.answer.drafts.forEach { want($0.sessionID) }
            wanted += answer.readSessionIDs
        }
        var found: [UUID: CatalogSession] = [:]
        for id in Set(wanted) {
            if let record = try? await catalog.listedSession(id: id) { found[id] = record }
        }
        let page = try? await catalog.sessionPage(CatalogQuery(), after: nil)
        let memory = await model.remoraNotes()
        sessions = found
        recent = page?.sessions.filter { !$0.isSideChat } ?? []
        notes = memory
        hasRead = true
    }
}

/// What makes Home read for Remora again.
struct HomeRemoraReadKey: Equatable {
    let home: HomeReadKey
    let kept: RemoraKeptBrief?
    let answer: RemoraHostAnswer?
    let idle: Bool
}

extension CatalogModel {
    var homeRemoraReadKey: HomeRemoraReadKey {
        HomeRemoraReadKey(home: homeReadKey, kept: remora.keptBrief, answer: remora.lastAnswer, idle: !remora.isBusy)
    }

    /// A session as Home names it now: the live record when the model holds one, else what the catalog read gave. A session being
    /// deleted is not named.
    func homeRemoraSession(_ record: CatalogSession) -> HomeRemoraSession? {
        let id = record.session.id
        guard !isDeleting(id) else { return nil }
        let current = rowModels[id]?.record ?? liveRecords[id] ?? record
        let name = projectName(for: current)
        let indicator = SessionIndicator(record: current, live: liveStates[id], awaitingOpenApproval: awaitingOpenApproval.contains(id))
        return HomeRemoraSession(
            id: id, projectID: current.projectID, projectName: name, tone: projectTone(forProject: current.projectID),
            provider: current.session.provider, title: current.displayTitle(projectName: name), lastActivityAt: current.lastActivityAt,
            indicator: indicator)
    }
}
