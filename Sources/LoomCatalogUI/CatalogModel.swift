import AppKit
import Foundation
import LoomCore
import Observation

public enum CatalogListKey: Hashable, Sendable {
    case activity
    case project(UUID)
    case unassigned
}

/// The open rename dialog. Held by the model (not view `@State`) so the
/// dialog needs no view-local state.
@MainActor @Observable
public final class RenameDraft: Identifiable {
    public nonisolated let id: UUID
    public var text: String
    public var failure: String?
    public var saving = false

    init(id: UUID, text: String) {
        self.id = id
        self.text = text
    }
}

/// What the user can ask of the conversation runtime. The model only forwards
/// intents; starting, waiting and cleanup happen off MainActor in the runtime.
@MainActor
public protocol ConversationIntents: AnyObject {
    func start(provider: ManagedSession.Provider, projectID: UUID?)
    func resume(sessionID: UUID)
    func stop(sessionID: UUID)
    func answer(sessionID: UUID, requestID: String, accept: Bool)
    func viewed(sessionID: UUID)
    /// The answers to an agent's request to open a session (D-40). Defaults do nothing, so an intents
    /// object without a runtime stays valid.
    func approveOpen(requestID: UUID)
    func denyOpen(requestID: UUID)
    func dismissOpen(requestID: UUID)
    /// The live terminal of a conversation that currently owns a run.
    func terminalView(sessionID: UUID) -> NSView?
    // Permanent deletion (CP4-D). Defaults refuse, so an intents object without a runtime stays valid.
    func deletionPreview(sessionID: UUID) async throws -> ConversationDeletionPreview
    func deleteConversation(sessionID: UUID) async throws -> ConversationDeletionOutcome
    func retryDeletion(sessionID: UUID) async throws -> ConversationDeletionOutcome
    func pendingDeletions() async throws -> [PendingConversationDeletion]
    func deletionRecoveryFailure() async -> String?
    /// The last screen of a session whose run ended, kept read-only while the session is selected or a tab
    /// (D-45). Defaults: none.
    func endedTerminalView(sessionID: UUID) -> NSView?
    /// "Show Details": lets go of the kept screen so the session shows its record.
    func closeEndedScreen(sessionID: UUID)
    /// The selection or the pinned tabs changed: kept screens of sessions that are neither are released.
    func sessionVisibilityChanged()
}

public enum ConversationBusy: Equatable, Sendable {
    case starting
    case resuming
    case stopping
}

/// A new-conversation request that is still starting (one per provider and project).
public struct StartKey: Hashable, Sendable {
    public let provider: ManagedSession.Provider
    public let projectID: UUID?
    public init(provider: ManagedSession.Provider, projectID: UUID?) {
        self.provider = provider
        self.projectID = projectID
    }
}

/// A development terminal shown in the detail pane (A slice fixture). Never
/// created by opening the app or by selecting a conversation.
public struct DevTerminal {
    public let panel: NSView
    public init(panel: NSView) { self.panel = panel }
}

public struct CatalogModelStatistics: Sendable {
    public var pageQueries = 0
    public var framesApplied = 0
    public var fastPathFrames = 0
    public var fullReconciles = 0
    public var rowModels = 0
    public var loadedRows = 0
    /// Lists re-read from the top (`reload`), one per list and pass.
    public var listReloads = 0
    /// One-session reads that patched the lists instead of re-reading them (`patchRows`).
    public var rowPatches = 0
    /// Search queries over the whole catalog (one per settled search, whatever the number of lists).
    public var searchQueries = 0
    /// `start()` until projects, counts and the first page of each visible list are shown.
    public var startMilliseconds = 0.0
}

/// One card. The record comes from the catalog, `live` from the core's latest
/// event state; the model only joins them for display.
@MainActor @Observable
public final class SessionRowModel: Identifiable {
    public nonisolated let id: UUID
    public private(set) var record: CatalogSession
    public private(set) var live: SessionViewState?
    /// This session's agent asked to open a session and the user has not answered (D-40).
    public private(set) var awaitingOpenApproval: Bool
    /// This is the selected session. Held per row (the model sets the old and the new row), so a card reads
    /// its own flag and a selection change redraws two cards, not all of them.
    public private(set) var isSelected: Bool

    init(record: CatalogSession, live: SessionViewState?, awaitingOpenApproval: Bool = false,
         isSelected: Bool = false) {
        id = record.session.id
        self.record = record
        self.live = live
        self.awaitingOpenApproval = awaitingOpenApproval
        self.isSelected = isSelected
    }

    func apply(selected: Bool) { if selected != isSelected { isSelected = selected } }

    func apply(record: CatalogSession) { if record != self.record { self.record = record } }
    func apply(live: SessionViewState?) { if live != self.live { self.live = live } }
    func apply(awaitingOpenApproval: Bool) {
        if awaitingOpenApproval != self.awaitingOpenApproval { self.awaitingOpenApproval = awaitingOpenApproval }
    }

    public var indicator: SessionIndicator {
        SessionIndicator(record: record, live: live, awaitingOpenApproval: awaitingOpenApproval)
    }

    /// How many times this row formatted its tooltip date (a test counts it).
    @ObservationIgnored private(set) var tooltipFormats = 0
    @ObservationIgnored private var tooltipCache: (date: Date, zone: TimeZone, text: String)?

    /// "Last activity <date>", formatted once per activity time: the card asks for it in every body pass.
    public var activityTooltip: String {
        let date = record.lastActivityAt
        let zone = TimeZone.current
        if let cached = tooltipCache, cached.date == date, cached.zone == zone { return cached.text }
        tooltipFormats += 1
        let text = "Last activity " + date.formatted(date: .abbreviated, time: .shortened)
        tooltipCache = (date, zone, text)
        return text
    }
}

@MainActor @Observable
public final class SessionListModel {
    public private(set) var rows: [SessionRowModel] = []
    public private(set) var hasMore = false
    public private(set) var isLoaded = false
    @ObservationIgnored var cursor: CatalogCursor?
    @ObservationIgnored var generation = 0
    @ObservationIgnored var isStale = false
    @ObservationIgnored var isLoadingMore = false
    /// Reloads that have started and not finished. A "load more" page that a reload outdated is read again
    /// when the last one ends, or at once when none is running (the last row's `onAppear` will not fire again).
    @ObservationIgnored var activeReloads = 0
    @ObservationIgnored var pendingMore = false
    /// Counts the writes of `rows`, so the day sections know when the list changed.
    @ObservationIgnored private var rowsRevision = 0
    @ObservationIgnored private var sectionsCache: SectionsCache?

    private struct SectionsCache {
        let revision: Int
        let today: Date
        let calendar: Calendar
        let activity: [Date]
        let sections: [DaySection]
    }

    /// Writes `rows` only when the order or the row models differ: an equal write redraws the list.
    func setRows(_ rows: [SessionRowModel]) {
        guard rows.count != self.rows.count || !zip(rows, self.rows).allSatisfy({ $0 === $1 }) else { return }
        self.rows = rows
        rowsRevision += 1
    }

    /// An equal reload (same row models in the same order, same paging state) writes nothing observed.
    func replace(rows: [SessionRowModel], cursor: CatalogCursor?) {
        setRows(rows)
        self.cursor = cursor
        if hasMore != (cursor != nil) { hasMore = cursor != nil }
        if !isLoaded { isLoaded = true }
        isStale = false
    }

    func append(_ more: [SessionRowModel], cursor: CatalogCursor?) {
        let known = Set(rows.map(\.id))
        let fresh = more.filter { !known.contains($0.id) }
        if !fresh.isEmpty { rows += fresh; rowsRevision += 1 }
        self.cursor = cursor
        if hasMore != (cursor != nil) { hasMore = cursor != nil }
    }

    /// The rows grouped into calendar days, kept until the rows, a row's activity time, the calendar day or
    /// the calendar change: the minute tick and every other body pass of the list reuse it. `today` is the
    /// start of the model's current day (`CatalogModel.today`), which is all the headings depend on.
    func daySections(today: Date, calendar: Calendar = .current) -> [DaySection] {
        if let cached = sectionsCache, cached.revision == rowsRevision, cached.today == today,
           cached.calendar == calendar, cached.activity.count == rows.count,
           zip(cached.activity, rows).allSatisfy({ $0 == $1.record.lastActivityAt }) {
            return cached.sections
        }
        let sections = DayGrouping.sections(rows, now: today, calendar: calendar)
        sectionsCache = SectionsCache(revision: rowsRevision, today: today, calendar: calendar,
                                      activity: rows.map(\.record.lastActivityAt), sections: sections)
        return sections
    }
}

/// Presentation projection of the catalog and the core's event state. It owns
/// no process or lifecycle authority: rows come from paged catalog queries and
/// live state from the single event consumer below.
@MainActor @Observable
public final class CatalogModel {
    public private(set) var projects: [CatalogProject] = []
    /// The tone of each project that has one, read from the projects the lists already load; views look
    /// colours up here and never walk `projects`. `projectColorsEnabled` is Settings → Project colors.
    public private(set) var projectTones: [UUID: ProjectTone] = [:]
    public private(set) var projectColorsEnabled: Bool
    /// Settings → General → Show in menu bar and Notify when a session needs approval (D-49, D-52).
    public private(set) var showInMenuBar: Bool
    public private(set) var notifyApprovals: Bool
    public private(set) var sessionCounts: [UUID?: Int] = [:]
    public private(set) var searchText = ""
    public private(set) var viewMode: CatalogViewMode
    public private(set) var selectedSessionID: UUID?
    public private(set) var selectedRow: SessionRowModel?
    public private(set) var errorMessage: String?
    public private(set) var infoMessage: String?
    public private(set) var isReady = false
    public private(set) var now = Date()
    /// The start of the day `now` is in. The day headings read this instead of `now`, so the minute tick does
    /// not redraw them; it changes at midnight.
    public private(set) var today = Calendar.current.startOfDay(for: Date())
    public private(set) var windowIsActive = false
    /// The window can be seen (visible, not occluded, not minimized, app not hidden), key or not.
    /// The relative times tick while this is true.
    public private(set) var windowIsVisible = false
    /// Full screen hides the native window buttons (written by the window owner).
    public private(set) var isFullScreen = false
    public private(set) var sidebarCollapsed: Bool
    public private(set) var showsDevTerminal = false
    public let startupError: String?
    public var ownershipNotice: String?
    /// Progress or state that is not an error: Quit progress, terminal status. Shown in the banner area.
    public var statusMessage: String?
    public var renameDraft: RenameDraft?
    public var devTerminal: DevTerminal?
    /// Acceptance-only override; normal launches follow the system preference.
    public var sidebarTransparencyOverride: Bool?
    public var effectiveReduceTransparency: Bool {
        sidebarTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
    public var effectiveSidebarMaterial: String { effectiveReduceTransparency ? "opaque" : "glass" }
    public private(set) var terminalFontSize: Double
    public private(set) var branches: [String: GitBranch] = [:]
    /// The requests of agents to open a session, and the notices that a ticket already has one (D-40).
    /// The runtime owns them; the controller mirrors its list here.
    public private(set) var openRequests: [OpenSessionRequest] = []
    /// Sessions whose agent waits for the user's answer (their indicator reads "Needs approval").
    public private(set) var awaitingOpenApproval: Set<UUID> = []
    /// The sessions that opened others, read once per id (the requester of a card's origin line);
    /// a loaded row is always preferred, so a rename shows at once. `missingOrigins`: no longer in the catalog.
    public private(set) var origins: [UUID: CatalogSession] = [:]
    public private(set) var missingOrigins: Set<UUID> = []
    /// Opens the one Settings window; nil keeps the section it shows (the gear), a section jumps to it (the usage chip).
    @ObservationIgnored public var onShowSettings: ((SettingsSection?) -> Void)?
    /// Set once by the app before the first view exists; the sidebar footer and Settings read it.
    @ObservationIgnored public var usage: UsageModel?
    @ObservationIgnored public var onTerminalFontSizeChange: ((Double) -> Void)?
    @ObservationIgnored public var onToggleSidebar: (() -> Void)?
    /// The runtime may attach after the first page is shown (it starts alongside the model);
    /// the selected conversation is then counted as viewed from that moment.
    @ObservationIgnored public weak var intents: (any ConversationIntents)? {
        didSet {
            intentsRevision &+= 1
            if intents != nil, isReady { updateViewing(); refreshPendingDeletionsSoon() }
        }
    }
    /// New-conversation requests that have no card yet (the toolchain is still resolving).
    public private(set) var preparingStarts: Set<StartKey> = []
    /// Observed stand-in for the attach of `intents` (which is not itself observed), so views
    /// that read `actionsAvailable` re-evaluate when the runtime attaches after the first page.
    public private(set) var intentsRevision = 0
    public private(set) var busy: [UUID: ConversationBusy] = [:]
    /// The Conversations section's model; set by the app only where permanent deletion is offered (CP4-G).
    public internal(set) var cleanupReview: CleanupReviewModel?
    public private(set) var startingKeys: Set<StartKey> = []
    /// Bumped whenever a live terminal appears or goes away, so the detail
    /// pane re-evaluates which terminal (if any) it shows.
    public private(set) var terminalRevision = 0
    /// Bumped when the row behind a tab or the selection is first read, so the strip redraws its title.
    public private(set) var tabRowsRevision = 0
    public var quitting = false
    @ObservationIgnored public internal(set) var statistics = CatalogModelStatistics()
    /// Reads Git branches off the main thread (`BranchCache`); `branchReader` is the test seam.
    @ObservationIgnored private var branchCache = BranchCache()
    @ObservationIgnored private var branchTask: Task<Void, Never>?
    @ObservationIgnored var branchReader: @Sendable (String) -> GitBranch = { GitBranch.read(directory: $0) } {
        didSet { branchCache = BranchCache(reader: branchReader) }
    }
    /// Test seams for the minute tick: the clock and the wait until a date.
    @ObservationIgnored var currentDate: @Sendable () -> Date = { Date() }
    @ObservationIgnored var sleepUntil: @Sendable (Date) async throws -> Void = { date in
        try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
    }
    /// Runs only while the window is active (see `setWindowActive`).
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// `now` moves forward only when a relative time ("5m") could read differently.
    @ObservationIgnored private let nowResolution: TimeInterval = 10

    @ObservationIgnored let catalog: SessionCatalog?
    @ObservationIgnored private let events: SessionEventHub
    @ObservationIgnored private let preferences: UIPreferencesStore
    @ObservationIgnored var lists: [CatalogListKey: SessionListModel] = [:]
    @ObservationIgnored var rowModels: [UUID: SessionRowModel] = [:]
    @ObservationIgnored var liveStates: [UUID: SessionViewState] = [:]
    @ObservationIgnored var liveRecords: [UUID: CatalogSession] = [:]
    @ObservationIgnored private var lookingUp: Set<UUID> = []
    /// Bumped when a live state or a looked-up record changes, so project dots redraw.
    public private(set) var liveRevision = 0
    /// Sessions that need the user (`AttentionOrder`), kept for the Dock badge. Updated whenever live state,
    /// a record or an open-session wait changes; `onAttentionCountChange` fires on a change only.
    @ObservationIgnored public internal(set) var attentionCount = 0
    @ObservationIgnored public var onAttentionCountChange: (@MainActor (Int) -> Void)?
    /// The menu bar item in numbers (working changes the Dock badge never sees), kept beside the count and
    /// fired from the same places on a change only. The menu itself is built when it opens (`menuBarState()`).
    @ObservationIgnored public internal(set) var menuBarSummary = MenuBarSummary.idle
    @ObservationIgnored public var onMenuBarChange: (@MainActor (MenuBarSummary) -> Void)?
    /// The Show in menu bar and Notify switches in Settings changed; the app reads `showInMenuBar` and `notifyApprovals`.
    @ObservationIgnored public var onShowInMenuBarChange: (@MainActor () -> Void)?
    @ObservationIgnored public var onNotifyApprovalsChange: (@MainActor () -> Void)?
    /// What the system says about notifications and the login item, and the calls Settings makes (the app installs them).
    public let integration = SystemIntegration()
    /// The sidebar scrolls to this session (selection changed by something other than a click in the list).
    public internal(set) var revealRequest: SessionRevealRequest?
    @ObservationIgnored var revealSerial = 0
    @ObservationIgnored var revealTask: Task<Void, Never>?
    /// Test seam: a point read of one session (the tab rows). Nil reads the catalog.
    @ObservationIgnored var sessionReader: ((UUID) async throws -> CatalogSession?)?
    /// Test seam: runs after a "load more" page was read, before it is published.
    @ObservationIgnored var afterMoreRead: (() async -> Void)?
    /// Test seam: runs after a search query was read, before its result is published.
    @ObservationIgnored var afterSearchRead: (() async -> Void)?
    @ObservationIgnored private var requestedRefresh: Set<UUID> = []
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var lastCatalogRevision: UInt64?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var refreshDirty = false
    /// Sessions whose catalog row one frame changed, read once and patched into the lists (`CatalogModel+Patching`).
    @ObservationIgnored var pendingPatches: Set<UUID> = []
    @ObservationIgnored var patchTask: Task<Void, Never>?
    /// Counts the search reads; a result is published only by the newest one (`CatalogModel+Search`).
    @ObservationIgnored var searchGeneration = 0
    /// Test seam: runs after a refresh read finished, before it is published as done.
    @ObservationIgnored var afterRefreshRead: (() async -> Void)?
    @ObservationIgnored private var viewingTask: Task<Void, Never>?
    @ObservationIgnored private var preferenceWriteTask: Task<Void, Never>?
    /// How long selection changes wait before the preferences file is written,
    /// so rapid tab switching costs one write. Tests shorten it.
    @ObservationIgnored var preferenceWriteDelay: Duration = .milliseconds(300)
    /// Pinned conversation tabs (D-33); the selected conversation joins them as a transient tab.
    public let tabs: ConversationTabs
    /// The delete flow's state (confirm sheet, unfinished deletions); logic in `CatalogModel+Deletion.swift`.
    public let deletions = DeletionState()

    /// `catalog == nil` means the catalog could not be opened (`startupError`
    /// says why); nothing is created or overwritten in that state.
    public init(catalog: SessionCatalog?, startupError: String? = nil, events: SessionEventHub,
                preferences: UIPreferencesStore,
                startableProviders: Set<ManagedSession.Provider> = [.claude, .codex]) {
        self.startableProviders = startableProviders
        self.catalog = catalog
        self.startupError = startupError
        self.events = events
        self.preferences = preferences
        viewMode = preferences.current.viewMode
        selectedSessionID = preferences.current.selectedSessionID
        sidebarCollapsed = preferences.current.sidebarCollapsed
        terminalFontSize = preferences.current.terminalFontSize
        projectColorsEnabled = preferences.current.projectColors
        showInMenuBar = preferences.current.showInMenuBar
        notifyApprovals = preferences.current.notifyApprovals
        tabs = ConversationTabs(pinned: preferences.current.openTabs)
        today = Calendar.current.startOfDay(for: now)
    }

    deinit {
        eventTask?.cancel()
        searchTask?.cancel()
        refreshTask?.cancel()
        patchTask?.cancel()
        preferenceWriteTask?.cancel()
        branchTask?.cancel()
        tickTask?.cancel()
    }

    /// Providers a user may start. The production build lists only Claude;
    /// Codex stays compiled but has no entry point (D-14, D-28). Existing
    /// conversations of any provider still display.
    public let startableProviders: Set<ManagedSession.Provider>

    public var preferencesSnapshot: UIPreferences { preferences.current }
    public var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isSearching: Bool { !trimmedSearch.isEmpty }

    // MARK: Lifecycle

    /// Reads projects and the first page of each visible list, restores the
    /// selection, then starts the one event consumer. Starts no process.
    public func start() async {
        if let notice = preferences.loadNotice { infoMessage = notice }
        LoomSignposts.begin(.firstPage)
        defer {
            LoomSignposts.end(.firstPage)
            LoomSignposts.end(.launchToFirstPage)
        }
        guard catalog != nil else { isReady = true; return }
        // Taken before the lists are read, so a batch landing meanwhile is seen.
        lastCatalogRevision = await events.snapshot().catalogRevision
        let began = ContinuousClock.now
        await refreshProjects()
        await reloadVisibleLists(force: true)
        await ensureTabRows()
        if selectedSessionID != nil { await ensureSelectedRow() }
        let elapsed = ContinuousClock.now - began
        statistics.startMilliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        isReady = true
        usage?.refresh(reason: .launch)
        eventTask = Task { [weak self, events] in
            let stream = await events.subscribe()
            for await frame in stream {
                guard let self else { return }
                self.apply(frame)
            }
        }
        updateViewing()
        refreshPendingDeletionsSoon()
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        stopTicking()
        flushPreferences()
    }

    /// Like `stop()`, but returns only after the event consumer has ended.
    public func stopAndWait() async {
        let task = eventTask
        stop()
        await task?.value
    }

    /// Waits for debounced searches and coalesced refreshes (tests, evidence).
    public func settle() async {
        await searchTask?.value
        await patchTask?.value // a patch that cannot be applied falls back to a refresh
        await refreshTask?.value
        await viewingTask?.value
        await preferenceWriteTask?.value
        await branchTask?.value
        await revealTask?.value
        await deletions.refreshTask?.value
    }

    // MARK: Lists

    public func list(for key: CatalogListKey) -> SessionListModel {
        if let existing = lists[key] { return existing }
        let created = SessionListModel()
        lists[key] = created
        return created
    }

    public func projectName(for record: CatalogSession) -> String? {
        guard let id = record.projectID else { return nil }
        return projects.first { $0.id == id }?.name
    }

    public func title(of row: SessionRowModel, repeatsProject: Bool = true) -> String {
        row.record.displayTitle(projectName: projectName(for: row.record), repeatsProject: repeatsProject)
    }

    /// The strongest signal among the project's live conversations. Taken from
    /// the in-memory live states, so it also works for a collapsed project whose
    /// rows were never loaded.
    public func attention(forProject id: UUID) -> ProjectAttention? {
        _ = liveRevision
        var indicators: [SessionIndicator] = []
        for (sessionID, state) in liveStates {
            guard let record = rowModels[sessionID]?.record ?? liveRecords[sessionID],
                  record.projectID == id else { continue }
            indicators.append(SessionIndicator(record: record, live: state,
                                               awaitingOpenApproval: awaitingOpenApproval.contains(sessionID)))
        }
        return ProjectAttention.strongest(of: indicators)
    }

    /// One point lookup per live conversation the lists do not hold, so its
    /// project is known without paging the project's list.
    private func lookUpLiveRecord(_ id: UUID) {
        guard let catalog, liveRecords[id] == nil, lookingUp.insert(id).inserted else { return }
        Task { [weak self] in
            let record = try? await catalog.session(id: id)
            guard let self else { return }
            self.lookingUp.remove(id)
            guard let record, self.liveStates[id] != nil else { return }
            self.liveRecords[id] = record
            self.liveRevision &+= 1
            self.updateAttentionCount()
        }
    }

    public func visibleListKeys() -> [CatalogListKey] {
        switch viewMode {
        case .activity: return [.activity]
        case .projects:
            var keys: [CatalogListKey] = projects.filter { isSearching || !$0.collapsed }
                .map { .project($0.id) }
            if isSearching || (sessionCounts[nil] ?? 0) > 0 { keys.append(.unassigned) }
            return keys
        }
    }

    private func query(for key: CatalogListKey) -> CatalogQuery {
        switch key {
        case .activity: CatalogQuery(scope: .all, order: .recentActivity, search: trimmedSearch)
        case let .project(id): CatalogQuery(scope: .project(id), order: .creation, search: trimmedSearch)
        case .unassigned: CatalogQuery(scope: .unassigned, order: .creation, search: trimmedSearch)
        }
    }

    private func markAllStale() {
        for list in lists.values { list.isStale = true }
    }

    func reloadVisibleLists(force: Bool = false) async {
        if isSearching {
            // One query over the whole catalog serves every visible list (`CatalogModel+Search`).
            let keys = visibleListKeys()
            if force || keys.contains(where: { !list(for: $0).isLoaded || list(for: $0).isStale }) {
                await reloadSearchResults()
            }
            pruneRowModels()
            return
        }
        for key in visibleListKeys() {
            let list = list(for: key)
            if force || !list.isLoaded || list.isStale { await reload(key) }
        }
        pruneRowModels()
    }

    /// Re-reads a list from the top, keeping as many rows as were loaded so a
    /// change never throws the user back to the first page.
    private func reload(_ key: CatalogListKey) async {
        guard let catalog else { return }
        let list = list(for: key)
        list.generation += 1
        list.activeReloads += 1
        statistics.listReloads += 1
        defer { endReload(of: list, key) }
        let generation = list.generation
        let wanted = max(list.rows.count, 1)
        do {
            var records: [CatalogSession] = []
            var cursor: CatalogCursor?
            repeat {
                statistics.pageQueries += 1
                let page = try await catalog.sessionPage(query(for: key), after: cursor)
                records += page.sessions
                cursor = page.next
            } while cursor != nil && records.count < wanted
            await ensureBranches(for: records)
            await ensureOrigins(for: records)
            guard generation == list.generation else { return }
            advanceNow(covering: records)
            list.replace(rows: records.map(row(for:)), cursor: cursor)
        } catch {
            report(error, "Sessions could not be read")
        }
    }

    /// A reload of `list` ended: a "load more" page the reload outdated is read again once none is running.
    func endReload(of list: SessionListModel, _ key: CatalogListKey) {
        list.activeReloads -= 1
        if list.activeReloads == 0, list.pendingMore {
            list.pendingMore = false
            if list.hasMore { loadMore(key) }
        }
    }

    public func loadMore(_ key: CatalogListKey) {
        let list = list(for: key)
        guard let catalog, let cursor = list.cursor, !list.isLoadingMore else { return }
        list.isLoadingMore = true
        let generation = list.generation
        Task {
            var outdated = false
            do {
                statistics.pageQueries += 1
                let page = try await catalog.sessionPage(query(for: key), after: cursor)
                await ensureBranches(for: page.sessions)
                await ensureOrigins(for: page.sessions)
                await afterMoreRead?()
                if generation == list.generation {
                    list.append(page.sessions.map(row(for:)), cursor: page.next)
                } else {
                    outdated = true
                }
            } catch {
                report(error, "More sessions could not be read")
            }
            list.isLoadingMore = false
            // A reload replaced the list while this page was read, so the page was dropped. Nothing else
            // asks for it again: the rows the user sees did not change, so the last row never reappears.
            guard outdated else { return }
            if list.activeReloads > 0 { list.pendingMore = true }
            else if list.hasMore { loadMore(key) }
        }
    }

    func row(for record: CatalogSession) -> SessionRowModel {
        let id = record.session.id
        if let existing = rowModels[id] {
            existing.apply(record: record)
            return existing
        }
        let created = SessionRowModel(record: record, live: liveStates[id],
                                      awaitingOpenApproval: awaitingOpenApproval.contains(id),
                                      isSelected: id == selectedSessionID)
        rowModels[id] = created
        if liveStates[id] != nil { updateAttentionCount() }
        if tabs.isPinned(id) || id == selectedSessionID { tabRowsRevision &+= 1 }
        return created
    }

    func pruneRowModels() {
        var keep = Set(lists.values.flatMap { $0.rows.map(\.id) })
        if let selectedSessionID { keep.insert(selectedSessionID) }
        keep.formUnion(tabs.pinned)
        // A live conversation keeps its project known for the project dot after its row is gone.
        for (id, row) in rowModels where !keep.contains(id) && liveStates[id] != nil {
            liveRecords[id] = row.record
        }
        rowModels = rowModels.filter { keep.contains($0.key) }
        updateAttentionCount()
        pruneOrigins()
        pruneBranches()
        statistics.rowModels = rowModels.count
        statistics.loadedRows = lists.values.reduce(0) { $0 + $1.rows.count }
    }

    // MARK: Branches and the clock

    /// Branches of the records' folders that are not shown yet, read off the main thread.
    func ensureBranches(for records: [CatalogSession]) async {
        let missing = Set(records.map(\.session.workingDirectory)).filter { branches[$0] == nil }
        guard !missing.isEmpty else { return }
        publishBranches(await branchCache.branches(for: missing), onlyKnown: false)
    }

    /// Re-reads the folders in the background and publishes only what changed.
    private func refreshBranches(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        let previous = branchTask
        branchTask = Task { [weak self] in
            await previous?.value // publishes keep the order the reads were asked in
            guard let self else { return }
            self.publishBranches(await self.branchCache.refresh(paths), onlyKnown: true)
        }
    }

    private func publishBranches(_ fresh: [String: GitBranch], onlyKnown: Bool) {
        for (path, branch) in fresh where branches[path] != branch {
            if onlyKnown, branches[path] == nil { continue }
            branches[path] = branch
        }
    }

    /// Keeps a branch only while a card, the selection or a tab shows its folder (the selection's and the
    /// tabs' rows are always in `rowModels`, see `pruneRowModels`; the header chip reads the same data).
    private func pruneBranches() {
        // A requester's folder stays too: the origin line compares its branch with the card's.
        let shown = Set(rowModels.values.map { $0.record.session.workingDirectory })
            .union(origins.values.map { $0.session.workingDirectory })
        guard branches.keys.contains(where: { !shown.contains($0) }) else { return }
        branches = branches.filter { shown.contains($0.key) }
        Task { [branchCache] in await branchCache.retain(shown) }
    }

    // MARK: Origins

    /// Reads the sessions that opened the records' sessions, so a card never queries the catalog
    /// while it draws. A requester a loaded row or a live record already holds costs no query. A
    /// failed read is left for the next reload; only a session the catalog does not have is "missing".
    func ensureOrigins(for records: [CatalogSession]) async {
        let wanted = Set(records.compactMap(\.openedBy))
            .filter { origins[$0] == nil && !missingOrigins.contains($0) }
        guard !wanted.isEmpty else { return }
        var found: [CatalogSession] = []
        var missing: Set<UUID> = []
        for id in wanted {
            if let known = rowModels[id]?.record ?? liveRecords[id] {
                found.append(known)
            } else if let catalog {
                statistics.pageQueries += 1
                do {
                    if let record = try await catalog.session(id: id) { found.append(record) }
                    else { missing.insert(id) }
                } catch {
                    continue // not "missing": the next reload asks again
                }
            }
        }
        await ensureBranches(for: found)
        for record in found { origins[record.session.id] = record }
        missingOrigins.formUnion(missing)
    }

    private func pruneOrigins() {
        let referenced = Set(rowModels.values.compactMap { $0.record.openedBy })
        if origins.keys.contains(where: { !referenced.contains($0) }) {
            origins = origins.filter { referenced.contains($0.key) }
        }
        if missingOrigins.contains(where: { !referenced.contains($0) }) {
            missingOrigins = missingOrigins.filter { referenced.contains($0) }
        }
    }

    /// How a card's origin line reads, or nil for a session nobody opened (and while the requester is still being read).
    public func origin(of row: SessionRowModel) -> SessionOrigin? {
        guard let requesterID = row.record.openedBy else { return nil }
        let own = branches[row.record.session.workingDirectory] ?? .unavailable
        if missingOrigins.contains(requesterID) {
            return SessionOrigin(requesterTitle: nil, requesterBranch: nil, ownBranch: own)
        }
        guard let requester = rowModels[requesterID]?.record ?? origins[requesterID] else { return nil }
        return SessionOrigin(
            requesterTitle: requester.displayTitle(projectName: projectName(for: requester), repeatsProject: false),
            requesterBranch: branches[requester.session.workingDirectory], ownBranch: own)
    }

    /// Advances `now` when relative times could read differently, or when a row is newer than it.
    func advanceNow(covering records: [CatalogSession] = []) {
        let current = currentDate()
        if abs(current.timeIntervalSince(now)) >= nowResolution || records.contains(where: { $0.lastActivityAt > now }) {
            setNow(current)
        }
    }

    /// The one writer of `now`; `today` follows it.
    private func setNow(_ date: Date) {
        if date != now { now = date }
        let day = Calendar.current.startOfDay(for: date)
        if day != today { today = day }
    }

    private func refreshProjects() async {
        guard let catalog else { return }
        do {
            let freshProjects = try await catalog.projects()
            if freshProjects != projects {
                projects = freshProjects
                projectTones = Dictionary(uniqueKeysWithValues: freshProjects.compactMap { project in
                    project.tone.map { (project.id, $0) }
                })
            }
            let freshCounts = try await catalog.sessionCounts()
            if freshCounts != sessionCounts { sessionCounts = freshCounts }
        } catch {
            report(error, "Projects could not be read")
        }
    }

    // MARK: Search, mode, selection

    public func setSearchText(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.markAllStale()
            await self.reloadVisibleLists()
        }
    }

    /// Counts requests to focus the search field (Edit > Find); the field reacts to each change.
    public private(set) var searchFocusRequest = 0

    /// Moves the keyboard to the search field. A collapsed sidebar is shown first and the field
    /// is asked once the sidebar has had time to open (a hidden field cannot take focus).
    public func requestSearchFocus() {
        guard sidebarCollapsed else { searchFocusRequest &+= 1; return }
        onToggleSidebar?()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.searchFocusRequest &+= 1
        }
    }

    public func setViewMode(_ mode: CatalogViewMode) {
        guard mode != viewMode else { return }
        viewMode = mode
        persist { $0.viewMode = mode }
        Task { await reloadVisibleLists() }
    }

    /// Selecting a row only shows it. It never starts a provider or a PTY. `revealInList: false` is for a
    /// click in the sidebar list itself, which must not scroll it; every other change of the selection
    /// (tabs, shortcuts, "Show Session", a `/clear` move) brings the session's card into view.
    public func select(_ id: UUID?, revealInList: Bool = true) {
        select(id, waiting: .selectToTerminal, revealInList: revealInList)
    }

    /// A click on a card in the sidebar list (or on a subagent row under it): selects, and never scrolls the list.
    public func selectFromList(_ id: UUID) { select(id, revealInList: false) }

    /// `waiting` names the signpost interval that runs until the terminal view reaches the detail pane.
    private func select(_ id: UUID?, waiting interval: LoomSignposts.Interval, revealInList: Bool = true) {
        showsDevTerminal = false
        if id != selectedSessionID {
            let previous = selectedSessionID
            selectedSessionID = id
            // Only a conversation that owns a run has a terminal to wait for.
            if let id, liveStates[id]?.runID != nil { LoomSignposts.begin(interval) }
            selectedRow = id.flatMap { rowModels[$0] }
            // Each card reads its own flag: only the old and the new card are redrawn.
            previous.flatMap { rowModels[$0] }?.apply(selected: false)
            selectedRow?.apply(selected: true)
            persistSelection(id)
            if id != nil, selectedRow == nil { Task { await ensureSelectedRow() } }
            if revealInList, let id { requestReveal(id) }
            intents?.sessionVisibilityChanged()
        }
        updateViewing()
    }

    private func ensureSelectedRow() async {
        guard let catalog, let id = selectedSessionID else { return }
        if let existing = rowModels[id] { selectedRow = existing; return }
        do {
            statistics.pageQueries += 1
            guard let record = try await catalog.session(id: id) else {
                forgetTab(id)
                if selectedSessionID == id { select(nil) }
                return
            }
            await ensureOrigins(for: [record])
            // Last, with nothing awaited before the row exists: the row is what keeps its folder's
            // branch, and a prune in between would drop the branch the header is about to show.
            await ensureBranches(for: [record])
            guard selectedSessionID == id else { return }
            selectedRow = row(for: record)
        } catch {
            report(error, "The selected session could not be read")
        }
    }

    // MARK: Conversation tabs

    /// Pinned tabs plus the selected conversation as one transient tab.
    public var visibleTabIDs: [UUID] { tabs.visible(selected: selectedSessionID) }

    /// The row behind a tab (title and indicator); nil only while it is still being read.
    /// Observed: a row that is read later (`ensureTabRows`, the selected conversation) redraws the strip.
    public func tabRow(_ id: UUID) -> SessionRowModel? {
        _ = tabRowsRevision
        return rowModels[id]
    }

    /// Shows a tab's conversation (a click on the strip or a tab shortcut). Pins nothing, starts nothing.
    public func selectTab(_ id: UUID) {
        select(id, waiting: .tabToTerminal)
    }

    /// Unpins a tab without changing what is shown: the selected tab becomes the transient one.
    public func unpinTab(_ id: UUID) {
        if tabs.unpin(id) { persistTabs() }
    }

    /// The selected conversation when it is not pinned: the strip's one transient tab.
    public func isTransientTab(_ id: UUID) -> Bool { id == selectedSessionID && !tabs.isPinned(id) }

    /// "Open in Tab": pins the conversation and shows it. Never starts anything.
    /// When the strip is full of running or attention tabs the pin is refused
    /// with a reason; the conversation is still shown as the transient tab.
    @discardableResult
    public func openTab(_ id: UUID, revealInList: Bool = true) -> TabPinResult {
        let result = pinTab(id)
        if case let .refused(reason) = result { infoMessage = reason }
        select(id, revealInList: revealInList)
        return result
    }

    /// Closing only unpins; a run stays alive. Closing the selected tab shows
    /// its right neighbor, else its left, else nothing.
    public func closeTab(_ id: UUID) {
        let next = id == selectedSessionID ? tabs.neighbor(ofClosing: id, selected: selectedSessionID) : nil
        if tabs.unpin(id) { persistTabs() }
        if id == selectedSessionID { select(next) }
    }

    /// A conversation was deleted (CP4): its tab goes away like a closed tab, and a card it opened no
    /// longer names it.
    public func forget(sessionID id: UUID) {
        origins[id] = nil
        missingOrigins.insert(id)
        closeTab(id)
    }

    /// A started or resumed conversation takes a tab (best effort: a full strip
    /// of running tabs leaves it as the transient tab) and is shown.
    func showStarted(_ id: UUID) {
        pinTab(id)
        select(id)
    }

    /// `/clear` or `/new` moved the terminal to a new card: a pinned old owner
    /// is replaced in place by it.
    func tabOwnerMoved(from old: UUID, to new: UUID) {
        guard tabs.replace(old, with: new) else { return }
        persistTabs()
        Task { await ensureTabRows() }
    }

    @discardableResult
    private func pinTab(_ id: UUID) -> TabPinResult {
        let result = tabs.pin(id, canEvict: canEvictTab)
        if case .pinned = result { persistTabs() }
        return result
    }

    /// Only a tab that is not running and does not need the user may make room.
    private func canEvictTab(_ id: UUID) -> Bool {
        if busy[id] != nil { return false }
        let live = liveStates[id]
        if live?.runID != nil { return false }
        guard let record = rowModels[id]?.record ?? liveRecords[id] else { return live == nil }
        return !SessionIndicator(record: record, live: live,
                                 awaitingOpenApproval: awaitingOpenApproval.contains(id)).needsAttention
    }

    private func readSession(_ id: UUID, catalog: SessionCatalog) async throws -> CatalogSession? {
        if let sessionReader { return try await sessionReader(id) }
        return try await catalog.session(id: id)
    }

    private func forgetTab(_ id: UUID) {
        if tabs.forget(id) { persistTabs() }
    }

    /// Reads the rows of pinned tabs the lists do not hold (at most one point
    /// lookup each); a tab whose conversation is gone is dropped.
    func ensureTabRows() async {
        guard let catalog else { return }
        for id in tabs.pinned where rowModels[id] == nil {
            do {
                statistics.pageQueries += 1
                // Only a definite "no such session" unpins a tab; a read that failed leaves it for a later pass.
                guard let record = try await readSession(id, catalog: catalog) else { forgetTab(id); continue }
                guard tabs.isPinned(id) else { continue }
                await ensureOrigins(for: [record])
                await ensureBranches(for: [record]) // last: see `ensureSelectedRow`
                guard tabs.isPinned(id) else { continue }
                _ = row(for: record)
            } catch {
                report(error, "A tab's session could not be read")
            }
        }
    }

    public func showDevTerminal(_ terminal: DevTerminal) {
        devTerminal = terminal
        showsDevTerminal = true
        updateViewing()
    }

    public func setWindowActive(_ active: Bool) {
        guard active != windowIsActive else { return }
        windowIsActive = active
        if active {
            advanceNow()
            refreshBranches(Set(branches.keys))
        }
        updateViewing()
    }

    /// The window's visibility edge (written by the window owner): the minute tick follows it, not
    /// the key or active state, so a visible window behind another app keeps true times. `now`
    /// catches up at once when the window becomes visible.
    public func setWindowVisible(_ visible: Bool) {
        guard visible != windowIsVisible else { return }
        windowIsVisible = visible
        if visible {
            advanceNow()
            startTicking()
        } else {
            stopTicking()
        }
    }

    /// Moves `now` to each minute boundary while the window is visible, so "5m" and the day
    /// headings stay true (midnight is a boundary). Nothing is scheduled while it cannot be seen.
    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let (next, sleep) = self?.nextTick() else { return }
                do { try await sleep(next) } catch { return }
                guard !Task.isCancelled, let self else { return }
                let current = self.currentDate()
                self.setNow(current)
                self.usage?.minuteTick() // the usage chip says "Today": a new day reads it again
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func nextTick() -> (Date, @Sendable (Date) async throws -> Void) {
        let seconds = currentDate().timeIntervalSinceReferenceDate
        return (Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60 + 60), sleepUntil)
    }

    public func setFullScreen(_ value: Bool) {
        if value != isFullScreen { isFullScreen = value }
    }

    public func setSidebarCollapsed(_ collapsed: Bool) {
        guard collapsed != sidebarCollapsed else { return }
        sidebarCollapsed = collapsed
        persist { $0.sidebarCollapsed = collapsed }
    }

    public func showSettings(_ section: SettingsSection? = nil) { onShowSettings?(section) }

    public func setTerminalFontSize(_ size: Double) {
        terminalFontSize = UIPreferences.clampedFontSize(size)
        persist { $0.terminalFontSize = terminalFontSize }
        onTerminalFontSizeChange?(terminalFontSize)
    }

    /// The window moved or was resized: remembered at once, written after the debounce (or at Quit).
    public func setWindowFrame(_ frame: CGRect) {
        let saved = WindowFrame(frame)
        guard saved != preferences.current.windowFrame else { return }
        preferences.apply { $0.windowFrame = saved }
        scheduleFlush()
    }

    /// Shown while a new conversation is still being prepared (no card yet).
    public var preparingNotice: String? {
        let names = Set(preparingStarts.map(\.provider)).map(ProviderName.title).sorted()
        return names.isEmpty ? nil : "Preparing " + names.joined(separator: " and ") + "…"
    }

    public func setSidebarWidth(_ width: Double) {
        persist { $0.sidebarWidth = width }
    }

    /// Only a selected conversation in a visible, active window counts as
    /// viewed. List refreshes and event frames never do.
    private func updateViewing() {
        let target = windowIsActive && !showsDevTerminal ? selectedSessionID : nil
        let previous = viewingTask
        viewingTask = Task { [events] in
            await previous?.value
            await events.setViewed(sessionID: target)
        }
        // A deliberate view also counts as use (persistent, never reactivates a stale row).
        if let target { intents?.viewed(sessionID: target) }
    }

    /// "Mark as Read": the user is done with an unviewed finish or a wait at the prompt. The core hub
    /// holds the acknowledgement, so cards and the project dot read the same state.
    public func markRead(_ id: UUID) {
        let previous = viewingTask
        viewingTask = Task { [events] in
            await previous?.value
            await events.markRead(sessionID: id)
        }
    }

    /// The runtime recorded a use of this conversation; show the new time.
    func viewRecorded(_ id: UUID) async { await refreshRow(id) }

    // MARK: Projects

    @discardableResult
    public func addProject(path: String) async -> CatalogAddedProject? {
        guard let catalog else { return nil }
        do {
            let added = try await catalog.addProject(path: path)
            if added.alreadyPresent {
                infoMessage = "“\(added.project.name)” is already in Loom."
                if added.project.collapsed { try await catalog.setProjectCollapsed(id: added.project.id, collapsed: false) }
            } else { infoMessage = nil }
            errorMessage = nil
            await refreshProjects()
            setViewMode(.projects)
            markAllStale()
            await reloadVisibleLists()
            return added
        } catch {
            report(error, "The project could not be added")
            return nil
        }
    }

    public func removeProject(_ id: UUID) async {
        guard let catalog else { return }
        do {
            try await catalog.removeProject(id: id)
            errorMessage = nil
            lists[.project(id)] = nil
            await refreshProjects()
            markAllStale()
            await reloadVisibleLists()
        } catch SessionCatalogError.projectNotEmpty {
            report(nil, "Only an empty project can be removed. Its sessions stay in the catalog.")
        } catch {
            report(error, "The project could not be removed")
        }
    }

    /// Settings → General → Project colors (D-48).
    public func setProjectColors(_ enabled: Bool) {
        guard enabled != projectColorsEnabled else { return }
        projectColorsEnabled = enabled
        persist { $0.projectColors = enabled }
    }

    /// Settings → General → Show in menu bar. Touches nothing else.
    public func setShowInMenuBar(_ enabled: Bool) {
        guard enabled != showInMenuBar else { return }
        showInMenuBar = enabled
        persist { $0.showInMenuBar = enabled }
        onShowInMenuBarChange?()
    }

    /// Settings → General → Notify when a session needs approval. Touches nothing else.
    public func setNotifyApprovals(_ enabled: Bool) {
        guard enabled != notifyApprovals else { return }
        notifyApprovals = enabled
        persist { $0.notifyApprovals = enabled }
        onNotifyApprovalsChange?()
    }

    /// The Color menu: a tone, or nil for None. The projects are read again (the one project-change
    /// path); the lists hold no tone, so they are not reloaded.
    public func setProjectTone(_ id: UUID, _ tone: ProjectTone?) async {
        guard let catalog else { return }
        do {
            try await catalog.setProjectTone(id: id, tone: tone)
            errorMessage = nil
            await refreshProjects()
        } catch {
            report(error, "The project color could not be changed")
        }
    }

    public func moveProject(_ id: UUID, by offset: Int) async {
        guard let catalog, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        do {
            try await catalog.moveProject(id: id, toIndex: index + offset)
            errorMessage = nil
            await refreshProjects()
            await reloadVisibleLists()
        } catch {
            report(error, "The project could not be moved")
        }
    }

    /// Expands a collapsed project; an expanded one is left alone (never toggles back).
    func expandProject(_ id: UUID) async {
        guard let catalog, projects.first(where: { $0.id == id })?.collapsed == true else { return }
        do {
            try await catalog.setProjectCollapsed(id: id, collapsed: false)
            await refreshProjects()
            await reloadVisibleLists()
        } catch {
            report(error, "The project could not be updated")
        }
    }

    public func toggleCollapsed(_ id: UUID) async {
        guard let catalog, let project = projects.first(where: { $0.id == id }) else { return }
        do {
            try await catalog.setProjectCollapsed(id: id, collapsed: !project.collapsed)
            await refreshProjects()
            await reloadVisibleLists()
        } catch {
            report(error, "The project could not be updated")
        }
    }

    /// The window a folder panel is attached to as a sheet. Independent of which
    /// window is key, so it works while Loom is not the active application; a
    /// hidden or absent window falls back to a standalone panel.
    @ObservationIgnored public var presentingWindow: (@MainActor () -> NSWindow?)?

    public func presentAddProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a project folder. Loom only remembers its path; nothing in the folder changes."
        let finish: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self else { return }
            self.folderPanelFinished(accepted: response == .OK, url: panel?.url)
        }
        if let window = presentingWindow?(), window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Result of the folder panel: only an accepted choice adds a project.
    public func folderPanelFinished(accepted: Bool, url: URL?) {
        guard accepted, let url else { return }
        Task { await addProject(path: url.path) }
    }

    // MARK: Titles

    public func beginRename(_ id: UUID) {
        guard let row = rowModels[id] else { return }
        renameDraft = RenameDraft(id: id, text: row.record.title ?? "")
    }

    /// Save button and Return key of the rename dialog.
    public func commitRename() async {
        guard let draft = renameDraft, !draft.saving else { return }
        draft.saving = true
        draft.failure = nil
        do {
            try await rename(sessionID: draft.id, to: draft.text)
            if renameDraft === draft { renameDraft = nil }
        } catch {
            draft.failure = "The title was not saved: \(error)"
            draft.saving = false
        }
    }

    /// Throws when the title could not be saved; nothing is shown as saved then.
    public func rename(sessionID: UUID, to title: String) async throws {
        guard let catalog else { return }
        do {
            try await catalog.renameSession(sessionID: sessionID, to: title)
        } catch {
            report(error, "The title could not be saved")
            throw error
        }
        await refreshRow(sessionID)
    }

    /// Path for titles announced by a terminal or provider: never replaces a
    /// title the user set.
    public func terminalTitleChanged(sessionID: UUID, title: String) async {
        guard let catalog else { return }
        do {
            if try await catalog.recordTerminalTitle(sessionID: sessionID, title: title) {
                await refreshRow(sessionID)
            }
        } catch {
            report(error, "The terminal title could not be saved")
        }
    }

    func refreshRow(_ id: UUID) async {
        guard let catalog else { return }
        do {
            statistics.pageQueries += 1
            if let record = try await catalog.session(id: id), let existing = rowModels[id] {
                existing.apply(record: record)
            }
            markAllStale()
            // A title is a search key: while a search is open the result set may
            // gain or lose this conversation. Without a search membership and
            // order cannot change, so a frequent terminal title costs no query.
            // The selected detail row stays (pruning keeps it) either way.
            if isSearching { await reloadVisibleLists() }
        } catch {
            report(error, "The session could not be refreshed")
        }
    }

    // MARK: Open requests

    /// The runtime's whole list (the controller calls this on every change). The requesting sessions'
    /// indicators move with it, through `SessionRowModel` and the project dots.
    func setOpenRequests(_ requests: [OpenSessionRequest]) {
        if requests != openRequests { openRequests = requests }
        let awaiting = Set(requests.filter(\.needsUser).map(\.requesterID))
        guard awaiting != awaitingOpenApproval else { return }
        awaitingOpenApproval = awaiting
        for (id, row) in rowModels { row.apply(awaitingOpenApproval: awaiting.contains(id)) }
        liveRevision &+= 1
        updateAttentionCount()
    }

    // MARK: Event consumer

    /// One consumer: a contiguous frame updates one conversation; a gap
    /// (missed frames) is repaired from the frame's full latest state.
    func apply(_ frame: SessionEventFrame) {
        usage?.observeTurnCompletions(frame.turnCompletions)
        handleDeletionFrame(frame)
        statistics.framesApplied += 1
        // Re-read at a reliable turn boundary, never for output/frame rendering.
        if case let .status(status) = frame.change, status?.activity == .turnComplete,
           let id = frame.sessionID, let row = rowModels[id] {
            refreshBranches([row.record.session.workingDirectory])
        }
        let contiguous = lastSequence.map { frame.sequence == $0 &+ 1 } ?? false
        if contiguous, let id = frame.sessionID {
            statistics.fastPathFrames += 1
            setLive(id, frame.sessions[id])
        } else {
            statistics.fullReconciles += 1
            for (id, state) in frame.sessions where liveStates[id] != state { setLive(id, state) }
            for id in liveStates.keys where frame.sessions[id] == nil { setLive(id, nil) }
        }
        lastSequence = frame.sequence
        // Set when one row's patch accounts for the frame's move of the catalog revision.
        var revisionCovered = false
        if let id = frame.sessionID, rowModels[id] != nil {
            switch frame.change {
            case .runStarted, .runEnded, .runDetached, .lifecycle, .conversationIdentity, .activityRecorded:
                // The catalog row (lifecycle, use time, identity, activity time) moved with this frame.
                guard catalog != nil else { break }
                if contiguous, canPatchRow(id) {
                    // Nothing was missed before this frame, so it is the only change: its revision step is
                    // the stamp it announced (a run or lifecycle frame moves none).
                    schedulePatch(id)
                    let stamped = frame.change == .activityRecorded ? 1 : 0
                    revisionCovered = lastCatalogRevision.map { frame.catalogRevision == $0 &+ UInt64(stamped) } ?? false
                } else {
                    scheduleRefresh()
                }
            default: break
            }
        }
        // Batched catalog changes (aging) carry no per-row state: a consumer that
        // saw the frame or skipped it re-reads the visible lists either way.
        if let seen = lastCatalogRevision, seen != frame.catalogRevision, catalog != nil, !revisionCovered {
            scheduleRefresh()
        }
        lastCatalogRevision = frame.catalogRevision
    }

    private func setLive(_ id: UUID, _ state: SessionViewState?) {
        if liveStates[id] != state {
            liveStates[id] = state
            liveRevision &+= 1
        }
        if state == nil { liveRecords[id] = nil }
        rowModels[id]?.apply(live: state)
        updateAttentionCount()
        if state != nil, rowModels[id] == nil { lookUpLiveRecord(id) }
        guard state != nil, rowModels[id] == nil, catalog != nil,
              requestedRefresh.insert(id).inserted else { return }
        // A conversation the lists do not know yet (for example a new one).
        scheduleRefresh()
    }

    func scheduleRefresh() {
        // A change that lands while a refresh reads is not lost: the running
        // refresh loops once more before it finishes.
        guard refreshTask == nil else { refreshDirty = true; return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            while let self {
                self.refreshDirty = false
                self.pendingPatches.removeAll() // this pass re-reads every row a pending patch would
                await self.refreshProjects()
                self.markAllStale()
                await self.reloadVisibleLists()
                await self.ensureTabRows()
                await self.afterRefreshRead?()
                self.requestedRefresh = self.requestedRefresh.filter { self.rowModels[$0] == nil }
                if !self.refreshDirty || Task.isCancelled { break }
            }
            self?.refreshTask = nil
        }
    }

    // MARK: Conversation actions

    /// Actions need a readable catalog and a runtime; a catalog error or a
    /// started Quit blocks them all.
    public var actionsAvailable: Bool {
        _ = intentsRevision
        return startupError == nil && intents != nil && !quitting
    }

    /// Where the "new conversation" commands apply: the selected conversation's project.
    public var contextProjectID: UUID? { selectedRow?.record.projectID }

    public func startConversation(_ provider: ManagedSession.Provider, projectID: UUID?) {
        guard actionsAvailable, startableProviders.contains(provider) else { return }
        intents?.start(provider: provider, projectID: projectID)
        // The new card belongs to this project: show it.
        if let projectID, projects.first(where: { $0.id == projectID })?.collapsed == true {
            Task { [weak self] in await self?.expandProject(projectID) }
        }
    }

    public func resumeConversation(_ id: UUID) {
        guard actionsAvailable else { return }
        // A conversation of a provider this build cannot start is not resumed either (D-14, D-28).
        if let provider = knownProvider(of: id), !startableProviders.contains(provider) { return }
        intents?.resume(sessionID: id)
    }

    public func stopConversation(_ id: UUID) {
        guard actionsAvailable else { return }
        intents?.stop(sessionID: id)
    }

    public func answerRequest(sessionID: UUID, requestID: String, accept: Bool) {
        guard actionsAvailable else { return }
        intents?.answer(sessionID: sessionID, requestID: requestID, accept: accept)
    }

    public func isStarting(_ provider: ManagedSession.Provider, projectID: UUID?) -> Bool {
        startingKeys.contains(StartKey(provider: provider, projectID: projectID))
    }

    public func canStart(_ provider: ManagedSession.Provider, projectID: UUID?) -> Bool {
        actionsAvailable && startableProviders.contains(provider) && !isStarting(provider, projectID: projectID)
    }

    public func canResume(_ row: SessionRowModel) -> Bool {
        actionsAvailable && row.record.session.provider != .synthetic
            && startableProviders.contains(row.record.session.provider)
            && row.live?.runID == nil && busy[row.id] == nil && !isDeleting(row.id)
    }

    /// The provider of a conversation the model has a row for.
    func knownProvider(of id: UUID) -> ManagedSession.Provider? {
        rowModels[id]?.record.session.provider
    }

    /// Why Resume is not offered for a conversation of a provider this build cannot start; nil when
    /// that is not the reason (a busy or running conversation has its own state line).
    public func resumeUnavailableReason(_ row: SessionRowModel) -> String? {
        let provider = row.record.session.provider
        guard provider != .synthetic, !startableProviders.contains(provider) else { return nil }
        return "\(ProviderName.title(provider)) sessions can't be resumed in this version."
    }

    public func canStop(_ row: SessionRowModel) -> Bool {
        actionsAvailable && row.live?.runID != nil && busy[row.id] != .stopping && !isDeleting(row.id)
    }

    /// The conversation's live terminal, if it owns a run right now.
    public func terminalView(for id: UUID) -> NSView? {
        _ = terminalRevision
        let view = intents?.terminalView(sessionID: id)
        if view != nil, id == selectedSessionID {
            LoomSignposts.end(.selectToTerminal)
            LoomSignposts.end(.tabToTerminal)
        }
        return view
    }

    /// The last screen of a session whose run ended, kept read-only (D-45): shown while the session is
    /// selected. Nil for a session with a live terminal or none kept.
    public func endedTerminalView(for id: UUID) -> NSView? {
        _ = terminalRevision
        return intents?.endedTerminalView(sessionID: id)
    }

    /// "Show Details": the session shows its record instead of the ended screen.
    public func closeEndedScreen(_ id: UUID) { intents?.closeEndedScreen(sessionID: id) }

    /// Whether the last screen of an ended run is kept: only while the session is selected or a pinned tab.
    public func keepsEndedScreen(_ id: UUID) -> Bool {
        EndedScreenPolicy.keeps(session: id, selected: selectedSessionID, pinned: tabs.pinned)
    }

    // Called by the conversation controller.

    func beginStart(_ key: StartKey) -> Bool {
        let inserted = startingKeys.insert(key).inserted
        if inserted { preparingStarts.insert(key) }
        return inserted
    }
    /// The card exists now (its own "Starting…" state takes over from the preparing notice).
    func cardCreated(for key: StartKey) { preparingStarts.remove(key) }
    func endStart(_ key: StartKey) {
        startingKeys.remove(key)
        preparingStarts.remove(key)
    }
    func setBusy(_ id: UUID, _ value: ConversationBusy?) { busy[id] = value }
    func terminalsChanged() { terminalRevision &+= 1 }
    func reportFailure(_ text: String) { errorMessage = text }
    func showInfo(_ text: String) { infoMessage = text }

    // MARK: Messages

    public func dismissError() { errorMessage = nil }
    public func dismissInfo() { infoMessage = nil }

    func report(_ error: (any Error)?, _ context: String) {
        errorMessage = Self.userMessage(for: error, context: context)
    }

    /// The banner text for a failed action: the context as a sentence, then what
    /// the error says when that is readable. Loom's own errors and Foundation
    /// errors carry a sentence; anything else gets a generic one plus the
    /// technical detail, so the raw value is never the whole message.
    nonisolated static func userMessage(for error: (any Error)?, context: String) -> String {
        guard let error else { return context }
        func sentence(_ text: String) -> String { text.last.map { ".…?!".contains($0) } == true ? text : text + "." }
        let head = sentence(context)
        let detail: String
        if error is CocoaError || error is URLError || error is POSIXError || type(of: error) is NSError.Type {
            detail = error.localizedDescription
        } else if let described = (error as Any) as? any CustomStringConvertible {
            detail = described.description
        } else {
            detail = "Something unexpected went wrong. Details: \(error)"
        }
        return head + " " + sentence(detail)
    }

    /// Tab order is not high-frequency: written at once.
    private func persistTabs() {
        let pinned = tabs.pinned
        persist { $0.openTabs = pinned }
        intents?.sessionVisibilityChanged()
    }

    /// Selection changes in quick succession (tab switching) coalesce into one write.
    private func persistSelection(_ id: UUID?) {
        preferences.apply { $0.selectedSessionID = id }
        scheduleFlush()
    }

    /// Rapid changes (tab switching, window drags) coalesce into one write after `preferenceWriteDelay`.
    private func scheduleFlush() {
        preferenceWriteTask?.cancel()
        preferenceWriteTask = Task { [weak self] in
            guard let delay = self?.preferenceWriteDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flushPreferences()
        }
    }

    /// Writes pending preference changes now (Quit, `stop()`).
    public func flushPreferences() {
        preferenceWriteTask?.cancel()
        preferenceWriteTask = nil
        do { try preferences.flush() }
        catch { report(error, "Preferences could not be saved") }
    }

    private func persist(_ change: (inout UIPreferences) -> Void) {
        do { try preferences.update(change) }
        catch { report(error, "Preferences could not be saved") }
    }
}
