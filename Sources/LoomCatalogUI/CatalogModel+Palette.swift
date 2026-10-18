import AppKit
import Foundation
import LoomCore
import Observation

/// The state of the command palette (⌘K). It exists as one object beside the model's other holders, does nothing
/// until `open(on:)` and again nothing after `close()`: no observer, no timer, no task. While it is open each
/// keystroke cancels the search of the one before and starts the next after a short settle.
@MainActor @Observable
public final class PaletteState {
    public private(set) var isOpen = false
    public private(set) var query = ""
    public private(set) var groups: [PaletteGroup] = []
    public private(set) var selectedID: String?
    /// A conversation search is under way.
    public private(set) var isSearching = false
    /// What the conversation search covered, once it has run: "Searched 63 sessions · last 14 days".
    public private(set) var coverageNote: String?
    /// A search that could not run to its end, in plain words (the footer shows it in place of the coverage, so a
    /// failed search never reads as "no matches"). Nil when nothing failed.
    public private(set) var searchFailure: String?
    /// Bumped each time the palette opens, so the view takes the keyboard again.
    public private(set) var openCount = 0

    /// The Claude profile's `projects` folder, set by the app; nil means no conversation search.
    @ObservationIgnored public var transcriptsDirectory: URL?
    /// Settings → General → Search session text (the model keeps it in step). Off, no transcript is read: not to
    /// find a file, not to scan it. The search reads on typing only and keeps no copy.
    @ObservationIgnored public var searchesConversations = true {
        didSet { if oldValue, !searchesConversations { stopTextSearch() } }
    }
    /// Where the keyboard goes back to on close: the window that was key when the palette opened.
    @ObservationIgnored var windowProvider: @MainActor () -> NSWindow? = { NSApp?.keyWindow ?? NSApp?.mainWindow }
    @ObservationIgnored var sourcesOverride: (any PaletteSources)?
    @ObservationIgnored var settle: Duration = .milliseconds(150)

    @ObservationIgnored private weak var model: CatalogModel?
    @ObservationIgnored private var sources: (any PaletteSources)?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private weak var returnWindow: NSWindow?
    @ObservationIgnored private weak var returnResponder: NSResponder?
    @ObservationIgnored private var local: [PaletteGroup] = []
    @ObservationIgnored private var olderRows: [PaletteItem] = []
    @ObservationIgnored private var hitRows: [PaletteItem] = []
    @ObservationIgnored private var offersOlderSearch = false
    /// How many searches started since the palette last opened (a test counts it).
    @ObservationIgnored private(set) var searchesStarted = 0
    @ObservationIgnored private(set) var searchesCancelled = 0
    /// The sessions' titles, projects and reasons folded for matching, kept from open to close: a keystroke folds
    /// nothing it has folded before.
    @ObservationIgnored private var folds = PaletteFoldCache()

    public init() {}

    public var items: [PaletteItem] { groups.flatMap(\.items) }

    var searchIsRunning: Bool { searchTask != nil }

    /// How many sessions were folded since the palette opened (a test counts it: one per session, however many
    /// queries are typed).
    var foldsComputed: Int { folds.computed }

    /// The sources of the open palette, when they are the live ones (a test reads what they looked up).
    var liveSources: LivePaletteSources? { sources as? LivePaletteSources }

    // MARK: Open and close

    /// ⌘K: opens the palette, or closes it when it is open.
    func toggle(on model: CatalogModel) {
        if isOpen { close() } else { open(on: model) }
    }

    func open(on model: CatalogModel) {
        guard !isOpen else { return }
        self.model = model
        let window = windowProvider()
        returnWindow = window
        returnResponder = window?.firstResponder
        sources = sourcesOverride ?? LivePaletteSources(model: model, transcriptsDirectory: { [weak self] in
            self?.searchesConversations == true ? self?.transcriptsDirectory : nil
        })
        query = ""
        resetSearch()
        folds = PaletteFoldCache()
        isOpen = true
        openCount &+= 1
        rebuildLocal()
        selectedID = items.first?.id
    }

    /// Esc, a click outside, or an item chosen. Cancels what is running, frees what was found and gives the
    /// keyboard back to the view that had it.
    public func close() {
        guard isOpen else { return }
        isOpen = false
        cancelSearch()
        resetSearch()
        query = ""
        groups = []
        local = []
        folds = PaletteFoldCache()
        selectedID = nil
        sources = nil
        restoreFocus()
        returnWindow = nil
        returnResponder = nil
    }

    private func restoreFocus() {
        guard let window = returnWindow else { return }
        var target = returnResponder
        // A field being edited answers with its shared field editor; the control is what gets the focus back.
        if let editor = target as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSResponder { target = control }
        if let view = target as? NSView, view.window !== window { target = nil }
        window.makeFirstResponder(target)
    }

    // MARK: Query

    public func setQuery(_ text: String) {
        guard isOpen, text != query else { return }
        query = text
        cancelSearch()
        resetSearch()
        rebuildLocal()
        selectedID = items.first?.id
        scheduleSearch(budget: .first)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func resetSearch() {
        olderRows = []
        hitRows = []
        offersOlderSearch = false
        isSearching = false
        coverageNote = nil
        searchFailure = nil
    }

    /// The setting went off while the palette is open: the scan that is running stops reading at once and what it
    /// found so far is dropped (a result could still come in after the switch was flipped).
    private func stopTextSearch() {
        guard isOpen else { return }
        cancelSearch()
        isSearching = false
        hitRows = []
        offersOlderSearch = false
        coverageNote = nil
        recompose()
    }

    private func cancelSearch() {
        if let searchTask {
            searchTask.cancel()
            searchesCancelled += 1
        }
        searchTask = nil
        generation &+= 1
    }

    // MARK: Search

    private func scheduleSearch(budget: PaletteSearchBudget) {
        let term = trimmedQuery
        guard !term.isEmpty else { return }
        let current = generation
        searchTask = Task(priority: .utility) { [weak self] in
            // The settle: a key typed meanwhile cancels this task before it reads anything.
            do { try await Task.sleep(for: self?.settle ?? .milliseconds(150)) } catch { return }
            await self?.runSearch(term, budget: budget, generation: current)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { isOpen && self.generation == generation && !Task.isCancelled }

    private func runSearch(_ term: String, budget: PaletteSearchBudget, generation: Int) async {
        guard isCurrent(generation), let sources, let model else { return }
        searchesStarted += 1
        if budget == .first {
            do {
                let found = try await sources.olderSessions(matching: term)
                if isCurrent(generation) {
                    let known = Set(local.flatMap(\.items).compactMap(\.sessionID))
                    olderRows = found.filter { !known.contains($0.session.id) }.map {
                        PaletteRanking.item(for: model.paletteSession(for: $0), now: Date())
                    }
                    recompose()
                }
            } catch {
                // A newer keystroke cancels this one: only a search that is still wanted reports its failure.
                if isCurrent(generation) { searchFailure = "Older sessions could not be searched." }
            }
        }
        guard term.count >= PaletteSearchBudget.minimumQueryLength, searchesConversations, isCurrent(generation) else {
            finishSearch(generation)
            return
        }
        isSearching = true
        let outcome: PaletteTranscriptOutcome?
        do {
            outcome = try await sources.searchTranscripts(query: term, budget: budget) { [weak self] partial in
                guard let self, self.isCurrent(generation), self.isSearching else { return }
                self.apply(partial, budget: budget, finished: false)
            }
        } catch {
            outcome = nil
            if isCurrent(generation) {
                searchFailure = "Session text could not be searched. What is shown may be incomplete."
            }
        }
        guard isCurrent(generation) else { return }
        if let outcome { apply(outcome, budget: budget, finished: true) }
        finishSearch(generation)
    }

    private func finishSearch(_ generation: Int) {
        guard self.generation == generation else { return }
        isSearching = false
        searchTask = nil
        recompose()
    }

    private func apply(_ outcome: PaletteTranscriptOutcome, budget: PaletteSearchBudget, finished: Bool) {
        let now = Date()
        hitRows = outcome.hits.map { hit in
            let age = hit.timestamp.map { RelativeTime.string(from: $0, to: now) }
            return PaletteItem(
                id: hit.id, target: .hit(hit.sessionID), title: hit.title, detail: nil,
                trailing: [hit.project, age].compactMap { $0 }.joined(separator: " · "),
                indicator: nil, symbol: "text.quote", snippet: hit.snippet)
        }
        if finished {
            coverageNote = outcome.coverage.unavailable ? nil
                : PaletteCoverageText.line(outcome.coverage, hits: outcome.hits.count)
            offersOlderSearch = !outcome.coverage.unavailable && budget == .first
        }
        recompose()
    }

    /// "Search older sessions": the wider pass (30 days, 4 GiB, 8 s) for the same query.
    func searchOlder() {
        guard isOpen, !isSearching, searchTask == nil else { return }
        offersOlderSearch = false
        cancelSearch()
        scheduleSearch(budget: .older)
        recompose()
    }

    // MARK: Rows

    private func rebuildLocal() {
        guard let model else { local = []; groups = []; return }
        // An empty query ranks by time and need, not by text: nothing to fold until a word is typed.
        let sessions = model.paletteSessions(folds: PaletteRanking.words(of: query).isEmpty ? nil : folds)
        let projects = model.projects.map { PaletteProjectInfo(id: $0.id, name: $0.name, path: $0.path) }
        let actions = PaletteAction.allCases.filter { $0.isEnabled(on: model) }.map { ($0, $0.detail(on: model)) }
        local = PaletteRanking.groups(query: query, sessions: sessions, projects: projects, actions: actions, now: Date())
        recompose()
    }

    /// The local groups, then what the searches found: older sessions join the sessions group at its end, hits
    /// form the last group. The selection stays on its row when the row is still there.
    private func recompose() {
        var composed = local
        if !olderRows.isEmpty {
            if let index = composed.firstIndex(where: { $0.section == .sessions }) {
                composed[index].items += olderRows
            } else {
                let at = composed.firstIndex { $0.section.rawValue > PaletteSection.sessions.rawValue } ?? composed.endIndex
                composed.insert(PaletteGroup(section: .sessions, title: "Sessions", items: olderRows), at: at)
            }
        }
        var found = hitRows
        if offersOlderSearch {
            found.append(PaletteItem(id: "search-older", target: .searchOlder, title: "Search older sessions",
                                     detail: "last 30 days", trailing: nil, indicator: nil,
                                     symbol: "clock.arrow.circlepath", snippet: nil))
        }
        if !found.isEmpty {
            composed.append(PaletteGroup(section: .conversations, title: "In session text", items: found))
        }
        groups = composed
        if let selectedID, items.contains(where: { $0.id == selectedID }) { return }
        selectedID = items.first?.id
    }

    // MARK: Keyboard

    /// Arrow keys: one row, wrapping at both ends.
    public func move(_ step: Int) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = selectedID.flatMap({ ids.firstIndex(of: $0) }) else {
            selectedID = step > 0 ? ids.first : ids.last
            return
        }
        selectedID = ids[((current + step) % ids.count + ids.count) % ids.count]
    }

    public func select(_ id: String) {
        if items.contains(where: { $0.id == id }) { selectedID = id }
    }

    /// ↵ on the selected row; ⌘↵ opens a session in a tab.
    public func activateSelected(inTab: Bool = false) {
        if let selectedID { activate(selectedID, inTab: inTab) }
    }

    /// Closes the palette (giving the keyboard back first) and then does what the row says, so the place it opens
    /// takes the keyboard from the view that had it. "Search older" keeps the palette open.
    public func activate(_ id: String, inTab: Bool = false) {
        guard let item = items.first(where: { $0.id == id }), let model else { return }
        if item.target == .searchOlder {
            searchOlder()
            return
        }
        close()
        switch item.target {
        case .session(let session), .hit(let session):
            if inTab { model.openTab(session) } else { model.select(session) }
        case .project(let project): model.showProjectPage(project)
        case .action(let action): action.run(on: model)
        case .searchOlder: break
        }
    }
}

/// What a conversation pass says about itself. A pass that stopped early never reads as "no matches".
enum PaletteCoverageText {
    static func line(_ coverage: PaletteTranscriptCoverage, hits: Int) -> String {
        let window = (coverage.windowDays == 1 ? "last day" : "last \(coverage.windowDays) days")
            + (coverage.sessionCap.map { " · newest \($0) sessions only" } ?? "")
        let sessions = coverage.filesInWindow == 1 ? "1 session" : "\(coverage.filesInWindow) sessions"
        let searched = coverage.filesSearched == 1 ? "1 session" : "\(coverage.filesSearched) sessions"
        switch coverage.stop {
        case .completed:
            return (hits == 0 ? "No matches in session text · " : "") + "Searched \(sessions) · \(window)"
        case .cancelled:
            return "Search stopped"
        case .hits:
            return "Showing the first \(hits) matches · \(window)"
        case .time, .bytes:
            let why = coverage.stop == .time ? "time limit" : "size limit"
            return "Searched \(searched) of \(sessions) · \(window) · stopped at the \(why)"
        }
    }
}

extension CatalogModel {
    /// "Command Palette…" (⌘K): opens the palette, or closes it when it is open.
    public func openPalette() { palette.toggle(on: self) }

    /// Every session the model holds in memory, with what the palette ranks on. No catalog read: the palette's
    /// own open costs nothing the sidebar has not already loaded.
    func paletteSessions(folds: PaletteFoldCache? = nil) -> [PaletteSessionInfo] {
        var records = rowModels.mapValues(\.record)
        for (id, record) in liveRecords where records[id] == nil { records[id] = record }
        return records.values.filter { !isDeleting($0.session.id) }.map { paletteSession(for: $0, folds: folds) }
    }

    func paletteSession(for record: CatalogSession, folds: PaletteFoldCache? = nil) -> PaletteSessionInfo {
        let id = record.session.id
        let live = liveStates[id]
        let awaiting = awaitingOpenApproval.contains(id)
        let indicator = SessionIndicator(record: record, live: live, awaitingOpenApproval: awaiting)
        let project = projectName(for: record)
        let title = record.displayTitle(projectName: project)
        let reason = PaletteReasonText.line(reason: live?.reason, indicator: indicator, awaitingOpenApproval: awaiting)
        return PaletteSessionInfo(
            id: id, title: title, project: project, provider: record.session.provider,
            lastActivityAt: record.lastActivityAt, indicator: indicator, reason: reason,
            folded: folds?.folded(for: id, title: title, project: project, reason: reason))
    }
}
