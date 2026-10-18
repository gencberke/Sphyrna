import AppKit

/// The menu items Studio adds, with their titles, keys, enabling and actions in one place: the app's menu
/// (`AppDelegate+Menus`) only draws them, and the tests read the same table. Each action calls a method of
/// the feature's holder file (`CatalogModel+Home.swift`, `+Palette`, `+NewSession`, `InspectorState.swift`,
/// `DetailRoute.swift`), so a slice that fills a feature changes that file and not the menu.
///
/// Keys are checked against the current menus, macOS defaults and the Turkish Q layout (UI-MAP → Keyboard
/// shortcuts). A letter that already has another item with other modifiers is avoided where a free one
/// exists, because AppKit does not reliably tell Cmd+J from Shift+Cmd+J (see `SessionShortcut`).
public enum ShellCommand: Int, CaseIterable, Sendable {
    case home
    case commandPalette
    case newSession
    case showChat
    case showTerminal
    case toggleInspector

    public var title: String {
        switch self {
        case .home: "Home"
        case .commandPalette: "Command Palette…"
        case .newSession: "New Claude Session"
        case .showChat: "Show Chat"
        case .showTerminal: "Show Terminal"
        case .toggleInspector: "Toggle Inspector"
        }
    }

    public var keyEquivalent: String {
        switch self {
        case .home: "h"
        case .commandPalette: "k"
        case .newSession: "n"
        case .showChat: "c"
        case .showTerminal: "t"
        case .toggleInspector: "b"
        }
    }

    public var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .home: [.control, .command]
        case .commandPalette, .newSession: [.command]
        case .showChat, .showTerminal, .toggleInspector: [.option, .command]
        }
    }

    /// Whether the command applies right now; a disabled item is greyed and its key does nothing.
    @MainActor public func isEnabled(on model: CatalogModel) -> Bool {
        switch self {
        case .home, .commandPalette: true
        case .newSession: model.canStart(.claude, projectID: model.contextProjectID)
        case .showChat, .showTerminal: model.canChooseFace
        case .toggleInspector: model.selectedSessionID != nil
        }
    }

    @MainActor public func run(on model: CatalogModel) {
        switch self {
        case .home: model.showHome()
        case .commandPalette: model.openPalette()
        case .newSession: model.beginNewSessionFromCommand()
        case .showChat: model.showFace(.chat)
        case .showTerminal: model.showFace(.terminal)
        case .toggleInspector: model.toggleInspector()
        }
    }

    /// Whether running it shows something in the main window, which the app then brings forward.
    public var needsWindow: Bool {
        switch self {
        case .home, .commandPalette, .newSession: true
        case .showChat, .showTerminal, .toggleInspector: false
        }
    }
}
