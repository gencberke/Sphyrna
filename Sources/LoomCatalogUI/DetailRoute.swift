import AppKit
import LoomCore
import SwiftUI

/// What the detail panel shows below the header, picked from the model's state in one place. The value
/// holds only identities, so tests can compare it; the views read the objects by id.
enum DetailRoute: Equatable {
    /// The catalog could not be opened.
    case startupError(String)
    /// The development terminal fixture.
    case devTerminal
    /// A subagent's transcript in place of its session's terminal (FB4-5).
    case subagentTranscript(sessionID: UUID)
    /// A live terminal.
    case terminal(sessionID: UUID)
    /// The kept last screen of a run that ended (FB4-3).
    case endedScreen(sessionID: UUID)
    /// The session's record (no run, no kept screen).
    case record(sessionID: UUID)
    /// A catalog with nothing in it.
    case addProject
    /// Nothing selected.
    case noSelection

    /// The surface behind the header, banners and content. Every route is the terminal's panel colour today;
    /// a route with its own surface (the chat canvas) changes it here.
    var surface: Color {
        switch self {
        case .startupError, .devTerminal, .subagentTranscript, .terminal, .endedScreen, .record, .addProject, .noSelection:
            LoomTheme.Surface.panel
        }
    }
}

extension CatalogModel {
    /// The first matching state wins, in this order: startup error, development terminal, the selected
    /// session (subagent transcript, live terminal, kept screen, record), the empty catalog, no selection.
    var detailRoute: DetailRoute {
        if let error = startupError { return .startupError(error) }
        if showsDevTerminal, devTerminal != nil { return .devTerminal }
        if let row = selectedRow {
            if let viewed = viewedSubagent, viewed.sessionID == row.id, subagentPanel != nil {
                return .subagentTranscript(sessionID: row.id)
            }
            if terminalView(for: row.id) != nil { return .terminal(sessionID: row.id) }
            if endedScreen(for: row.id) != nil { return .endedScreen(sessionID: row.id) }
            return .record(sessionID: row.id)
        }
        if isReady && projects.isEmpty && list(for: .activity).rows.isEmpty && !isSearching { return .addProject }
        return .noSelection
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
            case .subagentTranscript:
                if let row = model.selectedRow, let panel = model.subagentPanel {
                    // The terminal stays with its controller, running; it is only not shown, and nothing above it changes size.
                    VStack(spacing: 0) {
                        RequestList(model: model, row: row, returnApproves: false)
                        if let issue = SessionIssueNotice.message(for: row.live) { SessionIssueNotice(message: issue) }
                        if row.indicator == .waitingForApproval { SubagentApprovalNotice(model: model) }
                        // One view per panel model: a new model (the same subagent opened again) is put on screen too.
                        SubagentTranscriptView(panel: panel).id(ObjectIdentifier(panel))
                    }
                }
            case .terminal:
                if let row = model.selectedRow, let terminal = model.terminalView(for: row.id) {
                    VStack(spacing: 0) {
                        RequestList(model: model, row: row, returnApproves: false)
                        if let issue = SessionIssueNotice.message(for: row.live) { SessionIssueNotice(message: issue) }
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
            case .addProject:
                VStack(spacing: LoomTheme.Space.emptyStateSpacing) {
                    Message(symbol: "folder.badge.plus", title: "Add a project to begin",
                            text: "Your projects and sessions appear in the sidebar.")
                    HStack {
                        Button("Add Project…") { model.presentAddProject() }
                            .keyboardShortcut("o", modifiers: .command)
                            .buttonStyle(AccentButtonStyle(kind: .filled))
                        Button("New Claude Session") { model.startConversation(.claude, projectID: nil) }
                            .disabled(!model.canStart(.claude, projectID: nil))
                        if model.startableProviders.contains(.codex) {
                            Button("New Codex Session") { model.startConversation(.codex, projectID: nil) }
                                .disabled(!model.canStart(.codex, projectID: nil))
                        }
                    }
                }
            case .noSelection:
                Message(symbol: "text.bubble", title: "No session selected",
                        text: "Choose a session in the sidebar to see its details.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
