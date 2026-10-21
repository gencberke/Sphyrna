import AppKit
import LoomChat
import LoomCore
import SwiftUI

/// What the detail panel shows below the header, picked from the model's state in one place. The value
/// holds only identities, so tests can compare it; the views read the objects by id.
enum DetailRoute: Equatable {
    /// The catalog could not be opened.
    case startupError(String)
    /// The development terminal fixture.
    case devTerminal
    /// A live terminal.
    case terminal(sessionID: UUID)
    /// The kept last screen of a run that ended (FB4-3).
    case endedScreen(sessionID: UUID)
    /// The session's record (no run, no kept screen).
    case record(sessionID: UUID)
    /// The read-only Chat view of a session (V13): its transcript, or the kept last screen when none resolves.
    case chat(sessionID: UUID)
    /// The Home screen (V05).
    case home
    /// A project's new-session draft (V07); `nil` is a draft with no project.
    case draft(projectID: UUID?)
    /// A project's page (V08).
    case projectPage(projectID: UUID)
    /// Nothing selected.
    case noSelection

    /// The surface behind the header, banners and content. Every route is the terminal's panel colour today;
    /// a route with its own surface (the chat canvas) changes it here.
    var surface: Color {
        switch self {
        case .startupError, .devTerminal, .terminal, .endedScreen, .record, .noSelection,
             .chat, .home, .draft, .projectPage:
            LoomTheme.Surface.panel
        }
    }

    /// Whether the panel is drawn under a dark colour scheme whatever the appearance is (D-63). Claude's and Codex's
    /// terminal UIs choose their colours for a dark background and Loom never writes their configuration, so a live
    /// terminal, the kept screen of one and the development terminal keep the dark look in the chosen dark tone. The
    /// Chat face, the record, Home, a draft and a project page follow the appearance.
    var drawsDark: Bool {
        switch self {
        case .devTerminal, .terminal, .endedScreen: true
        case .startupError, .record, .chat, .home, .draft, .projectPage, .noSelection: false
        }
    }

    /// Whether the header shows the selected session. Home, a draft and a project page are not about a session.
    var showsSessionHeader: Bool {
        switch self {
        case .terminal, .endedScreen, .record, .chat: true
        case .startupError, .devTerminal, .noSelection, .home, .draft, .projectPage: false
        }
    }

    /// Whether the pane draws its 52 pt header row above the content. Home and the project page do not: their content starts
    /// at the window's top, and the window's buttons, "Show Sidebar" and the "Preparing…" notice float over it on the centre
    /// line (`DetailPageChrome`). Every other route keeps the row: a session's, the development terminal's, the draft's line
    /// (`DraftHeaderLine`) and the bare row of an empty pane or a startup error.
    var drawsHeaderRow: Bool {
        switch self {
        case .home, .projectPage: false
        case .startupError, .devTerminal, .terminal, .endedScreen, .record, .chat, .draft, .noSelection: true
        }
    }

    /// The draft whose line the header row draws; nil on every other route.
    var draftHeader: DraftHeaderTarget? {
        if case .draft(let projectID) = self { DraftHeaderTarget(projectID: projectID) } else { nil }
    }
}

extension CatalogModel {
    /// The first matching state wins, in this order: startup error, development terminal, Home, a draft or a
    /// project page, the selected session (see `sessionRoute`), the empty catalog (Home, which carries the
    /// first-run states itself), no selection.
    /// Reads only what the model holds in memory.
    var detailRoute: DetailRoute {
        if let error = startupError { return .startupError(error) }
        if showsDevTerminal, devTerminal != nil { return .devTerminal }
        switch destination {
        case .home: return .home
        case .draft(let projectID): return .draft(projectID: projectID)
        case .projectPage(let projectID): return .projectPage(projectID: projectID)
        case .session, nil: break
        }
        if let row = selectedRow { return sessionRoute(for: row) }
        if homeCatalogIsEmpty { return .home }
        return .noSelection
    }

    /// A session's route: the live Chat when a pipe run drives it, or when it is stopped and the switch in Settings
    /// says Chat (V19, D-69: its composer resumes it); then (with `readOnlyChatEnabled`, Claude sessions only) the read-only chat when
    /// the user picked it, or by default when the session is stopped, then the live terminal, the
    /// kept screen and the record. A start, resume or stop under way is not "stopped": the record stays until
    /// the terminal arrives. Codex and synthetic sessions keep the old routes.
    private func sessionRoute(for row: SessionRowModel) -> DetailRoute {
        let id = row.id
        // A pipe run has no terminal: it is the live Chat face, whatever the flags say.
        if runEndpoint(of: row) == .pipe { return .chat(sessionID: id) }
        // A stopped session the Chat face owns shows its live chat: the composer resumes it in that face.
        if showsStoppedLiveChat(row) { return .chat(sessionID: id) }
        let hasTerminal = terminalView(for: id) != nil
        if faces.readOnlyChatEnabled, row.record.session.provider == .claude {
            switch faces.choice(for: id) {
            case .chat: return .chat(sessionID: id)
            case .terminal: break
            case nil: if !hasTerminal && busy[id] == nil { return .chat(sessionID: id) }
            }
        }
        if hasTerminal { return .terminal(sessionID: id) }
        if endedScreen(for: id) != nil { return .endedScreen(sessionID: id) }
        return .record(sessionID: id)
    }

    /// How the session's live run is driven, nil when it has none. "Running" is a run, not a terminal view: a
    /// Chat-face (pipe) run has no terminal (V16).
    public func runEndpoint(of row: SessionRowModel) -> RunEndpointKind? {
        guard let live = row.live, live.runID != nil else { return nil }
        return live.runEndpoint ?? (terminalView(for: row.id) != nil ? .terminal : nil)
    }

    /// The session runs: a live run of either kind, or a terminal still attached.
    public func isRunning(_ row: SessionRowModel) -> Bool {
        runEndpoint(of: row) != nil || terminalView(for: row.id) != nil
    }

    /// The case of `detailRoute` without its identities ("chat", "terminal", "draft"): what acceptance runs read.
    public var detailRouteKind: String {
        String(String(describing: detailRoute).prefix { $0 != "(" })
    }

    /// The flag behind the read-only Chat view; see `SessionFaces`.
    public var readOnlyChatEnabled: Bool {
        get { faces.readOnlyChatEnabled }
        set { faces.readOnlyChatEnabled = newValue }
    }

    /// Whether the selected session has a Chat and a Terminal face to look at: a Claude session, with the Chat view
    /// switched on, that the Chat face does not run. A Chat-face run has no terminal to show, and a stopped session
    /// shows its live chat while the switch in Settings says Chat (D-69).
    public var canChooseFace: Bool {
        guard readOnlyChatEnabled, let row = selectedRow, row.record.session.provider == .claude else { return false }
        return runEndpoint(of: row) != .pipe && !showsStoppedLiveChat(row)
    }

    /// "Show Chat" and "Show Terminal": the face the selected session shows from now on, until a relaunch.
    /// A stopped session shown as Terminal reads as it did before the Chat view: its kept screen or its record.
    public func showFace(_ face: SessionFace) {
        guard canChooseFace, let id = selectedSessionID else { return }
        closeSubagent()
        faces.choose(face, for: id)
    }
}

/// The panel's content for a route, one branch per case. `DetailView` picks the route once and draws the
/// header, the banners and the fill (`DetailRoute.surface`) around it.
struct DetailContent: View {
    let model: CatalogModel
    let route: DetailRoute

    var body: some View {
        Group {
            switch route {
            case .startupError(let error):
                Message(symbol: "exclamationmark.triangle", title: "Loom could not open its catalog",
                        text: "\(error)\n\nThe catalog file was left untouched. Nothing was created or overwritten.")
            case .devTerminal:
                if let terminal = model.devTerminal { TerminalHost(panel: terminal.panel) }
            case .terminal:
                if let row = model.selectedRow, let terminal = model.terminalView(for: row.id) {
                    VStack(spacing: 0) {
                        RequestList(model: model, row: row, returnApproves: false)
                        TerminalHost(panel: terminal).id(ObjectIdentifier(terminal))
                    }
                }
            case .endedScreen:
                // The run ended and its last screen is kept (FB4-3): a static copy below a notice.
                if let row = model.selectedRow, let screen = model.endedScreen(for: row.id) {
                    VStack(spacing: 0) {
                        RequestList(model: model, row: row, returnApproves: false)
                        EndedScreenNotice(model: model, row: row)
                        EndedScreenView(snapshot: screen, fontSize: model.terminalFontSize)
                    }
                }
            case .record:
                if let row = model.selectedRow { ConversationDetail(model: model, row: row) }
            case .chat:
                if let row = model.selectedRow { SessionChatView(model: model, row: row).id(row.id) }
            case .home:
                HomeView(model: model)
            case .draft(let projectID):
                DraftSessionView(model: model, projectID: projectID)
            case .projectPage(let projectID):
                ProjectPageView(model: model, projectID: projectID)
            case .noSelection:
                Message(symbol: "text.bubble", title: "No session selected",
                        text: "Choose a session in the sidebar to see its details.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
