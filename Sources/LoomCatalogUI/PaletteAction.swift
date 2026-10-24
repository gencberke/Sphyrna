import AppKit
import Foundation

/// The commands the palette offers. The Studio menu items (`ShellCommand`) are reused as they are, so their
/// titles, keys, enabling and actions stay in one place; the rest calls the model method the menu or a button
/// already calls. Only an enabled action is listed, so "Show Chat" does not appear before the Chat view exists.
public enum PaletteAction: String, CaseIterable, Sendable {
    case newSession
    case home
    case showChat
    case showTerminal
    case toggleInspector
    case nextAttention
    case openInTab
    case renameSession
    case resumeSession
    case stopSession
    case askQuickQuestion
    case toggleSidebar
    case recentActivityView
    case projectView
    case settings
    case addProject
    case revealInFinder

    /// The menu command behind an action, when there is one.
    public var shellCommand: ShellCommand? {
        switch self {
        case .newSession: .newSession
        case .home: .home
        case .showChat: .showChat
        case .showTerminal: .showTerminal
        case .toggleInspector: .toggleInspector
        default: nil
        }
    }

    public var title: String {
        if let shellCommand {
            return switch shellCommand {
            case .newSession: "New session"
            default: shellCommand.title
            }
        }
        return switch self {
        case .nextAttention: "Jump to the next session that needs you"
        case .openInTab: "Open session in a tab"
        case .renameSession: "Rename session…"
        case .resumeSession: "Resume session"
        case .stopSession: "Stop session"
        case .askQuickQuestion: "Ask a quick question"
        case .toggleSidebar: "Toggle sidebar"
        case .recentActivityView: "Show recent activity"
        case .projectView: "Group sessions by project"
        case .settings: "Settings…"
        case .addProject: "Add project…"
        case .revealInFinder: "Reveal in Finder"
        default: rawValue
        }
    }

    /// Extra words the query can match, so "chat" finds Show Chat.
    public var keywords: [String] {
        switch self {
        case .newSession: ["start", "create", "claude", "compose", "draft", "write", "prompt"]
        case .home: ["overview", "start page"]
        case .showChat: ["messages", "transcript"]
        case .showTerminal: ["console", "claude code"]
        case .toggleInspector: ["panel", "details", "agents", "overview"]
        case .nextAttention: ["approval", "waiting", "needs"]
        case .openInTab: ["pin", "tab"]
        case .renameSession: ["title", "name"]
        case .resumeSession: ["start again", "continue"]
        case .stopSession: ["quit", "end", "interrupt"]
        case .askQuickQuestion: ["btw", "side question", "ask", "one-shot", "aside"]
        case .toggleSidebar: ["hide", "show"]
        case .recentActivityView: ["list", "sort"]
        case .projectView: ["list", "folders"]
        case .settings: ["preferences", "options"]
        case .addProject: ["folder", "repository", "repo", "import", "open"]
        case .revealInFinder: ["finder", "folder", "show", "files", "directory"]
        }
    }

    public var symbol: String {
        switch self {
        case .newSession: "square.and.pencil"
        case .home: "house"
        case .showChat: "text.bubble"
        case .showTerminal: "terminal"
        case .toggleInspector: "sidebar.right"
        case .nextAttention: "bell"
        case .openInTab: "rectangle.stack"
        case .renameSession: "pencil"
        case .resumeSession: "play"
        case .stopSession: "stop"
        case .askQuickQuestion: "questionmark.bubble"
        case .toggleSidebar: "sidebar.left"
        case .recentActivityView: "clock"
        case .projectView: "folder"
        case .settings: "gearshape"
        case .addProject: "folder.badge.plus"
        case .revealInFinder: "folder"
        }
    }

    /// The key the action already has, drawn at the row's right edge.
    public var keyHint: String? {
        if let shellCommand { return PaletteKeyHint.text(modifiers: shellCommand.modifiers, key: shellCommand.keyEquivalent) }
        return switch self {
        case .nextAttention:
            PaletteKeyHint.text(modifiers: SessionShortcut.jumpToNextAttention.modifiers,
                                key: SessionShortcut.jumpToNextAttention.keyEquivalent)
        case .resumeSession: PaletteKeyHint.text(modifiers: [.command], key: "r")
        case .stopSession: PaletteKeyHint.text(modifiers: [.command], key: ".")
        case .askQuickQuestion: PaletteKeyHint.text(modifiers: [.command], key: ";")
        case .toggleSidebar: PaletteKeyHint.text(modifiers: [.control, .command], key: "s")
        case .settings: PaletteKeyHint.text(modifiers: [.command], key: ",")
        default: nil
        }
    }

    /// Whether the action applies right now.
    @MainActor public func isEnabled(on model: CatalogModel) -> Bool {
        if let shellCommand { return shellCommand.isEnabled(on: model) }
        switch self {
        case .nextAttention: return model.canJumpToAttention
        case .settings: return true
        case .toggleSidebar: return model.onToggleSidebar != nil
        case .recentActivityView: return model.viewMode != .activity
        case .projectView: return model.viewMode != .projects
        case .openInTab:
            guard let id = model.selectedSessionID else { return false }
            return !model.tabs.isPinned(id)
        case .renameSession:
            return model.selectedRow != nil
        case .resumeSession:
            return model.selectedRow.map { model.canResume($0) } ?? false
        case .stopSession:
            return model.selectedRow.map { model.canStop($0) } ?? false
        case .askQuickQuestion: return model.canAskQuickQuestion
        case .addProject: return model.isReady
        case .revealInFinder: return model.revealInFinderTarget() != nil
        default: return false
        }
    }

    /// What follows the title: where a new session goes, which session an action is about.
    @MainActor public func detail(on model: CatalogModel) -> String? {
        switch self {
        case .newSession:
            guard let id = model.contextProjectID, let name = model.projects.first(where: { $0.id == id })?.name else { return nil }
            return "in " + name
        case .toggleInspector, .openInTab, .renameSession, .resumeSession, .stopSession, .askQuickQuestion, .showChat,
             .showTerminal:
            guard let row = model.selectedRow else { return nil }
            return "for " + model.title(of: row)
        case .revealInFinder:
            return model.revealInFinderTarget().map { "for " + $0.name }
        default: return nil
        }
    }

    @MainActor public func run(on model: CatalogModel) {
        if let shellCommand { return shellCommand.run(on: model) }
        switch self {
        case .nextAttention: model.jumpToAttention(.next)
        case .openInTab:
            if let id = model.selectedSessionID { model.openTab(id) }
        case .renameSession:
            if let id = model.selectedSessionID { model.beginRename(id) }
        case .resumeSession:
            if let id = model.selectedSessionID { model.resumeConversation(id) }
        case .stopSession:
            if let id = model.selectedSessionID { model.stopConversation(id) }
        case .askQuickQuestion: model.askQuickQuestion()
        case .toggleSidebar: model.onToggleSidebar?()
        case .recentActivityView: model.setViewMode(.activity)
        case .projectView: model.setViewMode(.projects)
        case .settings: model.onShowSettings?(nil)
        case .addProject: model.presentAddProject()
        case .revealInFinder:
            if let target = model.revealInFinderTarget() { SessionLocationActions.reveal(target.path) }
        default: break
        }
    }
}

/// A menu key drawn the way macOS menus draw it: Control, Option, Shift, Command, then the key.
enum PaletteKeyHint {
    static func text(modifiers: NSEvent.ModifierFlags, key: String) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + key.uppercased()
    }
}
