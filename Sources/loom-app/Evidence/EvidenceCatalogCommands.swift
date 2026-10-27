#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore
import LoomLaunchOptions
import LoomTerminal

/// Catalog, window and conversation commands: the same model calls the sidebar controls and buttons use.
@MainActor
extension DevelopmentEvidence {
    func handleCatalogCommand(_ name: String, _ argument: String) async {
        guard let app, let model = app.model else { return }
        func id(_ text: String) -> UUID? { UUID(uuidString: String(text.prefix(36))) }
        func rest(_ text: String) -> String { String(text.dropFirst(37)) }
        switch name {
        case "toggle-sidebar": app.toggleSidebarForEvidence()
        case "select": model.select(argument == "none" ? nil : id(argument))
        case "search":
            // The sidebar's search is the palette's door: `search:<text>` types into the palette (opening it first), and an
            // empty text closes it.
            if argument.isEmpty {
                model.palette.close()
            } else {
                if !model.palette.isOpen { model.openPalette() }
                model.palette.setQuery(argument)
            }
        case "view-mode": if let mode = CatalogViewMode(rawValue: argument) { model.setViewMode(mode) }
        case "add-project": await model.addProject(path: argument)
        case "remove-project": if let id = id(argument) { await model.removeProject(id) }
        case "move-project":
            if let id = id(argument), let delta = Int(rest(argument)) { await model.moveProject(id, by: delta) }
        case "move-project-to": // a head dragged to a zero-based position
            if let id = id(argument), let index = Int(rest(argument)) { await model.moveProject(id, to: index) }
        case "reorder-project": // a held head released in a gap, through the live reorder's own model path (A1)
            if let id = id(argument), let gap = Int(rest(argument)) { await model.endProjectReorder(id, gap: gap) }
        case "toggle-project": if let id = id(argument) { await model.toggleCollapsed(id) }
        case "rename":
            if let id = id(argument) { try? await model.rename(sessionID: id, to: rest(argument)) }
        case "begin-rename": if let id = id(argument) { model.beginRename(id) }
        case "rename-text": model.renameDraft?.text = argument
        case "rename-commit": await model.commitRename()
        case "open-add-project-panel": model.presentAddProject()
        case "close-panel": app.closeSheetForEvidence()
        case "panel-choose": app.chooseFolderInPanelForEvidence(argument)
        case "start":
            // start:<claude|codex>:<project id|none>
            let parts = argument.split(separator: ":").map(String.init)
            if parts.count == 2, let provider = ManagedSession.Provider(rawValue: parts[0]),
               provider == .claude || provider == .codex {
                model.startConversation(provider, projectID: parts[1] == "none" ? nil : UUID(uuidString: parts[1]))
            }
        case "double-start":
            // Two clicks in the same run-loop turn, like a fast double click.
            let parts = argument.split(separator: ":").map(String.init)
            if parts.count == 2, let provider = ManagedSession.Provider(rawValue: parts[0]),
               provider == .claude || provider == .codex {
                let project = parts[1] == "none" ? nil : UUID(uuidString: parts[1])
                model.startConversation(provider, projectID: project)
                model.startConversation(provider, projectID: project)
            }
        case "resume": if let id = id(argument) { model.resumeConversation(id) }
        case "stop": if let id = id(argument) { model.stopConversation(id) }
        case "type": if let id = id(argument) { _ = app.typeForEvidence(rest(argument), intoSession: id) }
        case "answer":
            // answer:<session id>:<accept|deny>; answers the first request on that card.
            if let id = id(argument), let request = model.selectedRow?.live?.userRequests.first,
               model.selectedSessionID == id {
                model.answerRequest(sessionID: id, requestID: request.id, accept: rest(argument) == "accept")
            }
        case "terminal-title":
            if let id = id(argument) { await model.terminalTitleChanged(sessionID: id, title: rest(argument)) }
        case "sidebar-width": if let width = Double(argument) { app.setSidebarWidthForEvidence(width) }
        case "resize":
            let parts = argument.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { app.resizeForEvidence(width: parts[0], height: parts[1]) }
        case "buttons": write("buttons-\(argument.filter { $0.isLetter || $0.isNumber || $0 == "-" })", app.windowButtonsEvidence())
        case "feed": app.feedForEvidence(path: argument)
        case "toggle-fullscreen": app.toggleFullScreenForEvidence()
        case "screenshot":
            // A picture of a real provider's terminal would put its content on disk.
            guard !app.redactsContent else { return }
            let label = argument.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            await model.settle()
            try? await Task.sleep(for: .milliseconds(300))
            app.saveScreenshot(to: directory.appendingPathComponent("screenshot-\(label).png"))
        default:
            if handleDeletionCommand(name, argument) || handleOpenRequestCommand(name, argument)
                || handleSubagentCommand(name, argument) || handlePaletteCommand(name, argument)
                || handleStudioCommand(name, argument) || handleHomeCommand(name, argument)
                || handleProjectPageCommand(name, argument) { break }
            var handled = await handleSettingsCommand(name, argument) || handleTabCommand(name, argument)
            if !handled { handled = await handleSystemCommand(name, argument) }
            if !handled { handled = await handleChatCommand(name, argument) }
            if !handled { handled = await handleEdgeCommand(name, argument) }
            if !handled { handled = await handleRemoraCommand(name, argument) }
            guard handled else {
                _ = await handleKeyCommand(name, argument)
                return
            }
        }
        await model.settle()
    }
}
#endif
