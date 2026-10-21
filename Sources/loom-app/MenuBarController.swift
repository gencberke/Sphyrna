import AppKit
import LoomCatalogUI

/// The menu bar status item and its menu (D-49, D-52). The item is made and removed with the setting; its
/// face follows `MenuBarSummary`; the menu is built each time it opens from the live sessions.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// What a click does. `showSession` brings Loom forward and selects the session; the others are the
    /// app's own actions.
    struct Actions {
        var showSession: (UUID) -> Void
        var bringForward: () -> Void
        var canStartSession: () -> Bool
        var newClaudeSession: () -> Void
        var openSettings: () -> Void
        var quit: () -> Void
    }

    private let model: CatalogModel
    private let actions: Actions
    private(set) var statusItem: NSStatusItem?
    private(set) var face: MenuBarFace?
    private var summary = MenuBarSummary.idle

    init(model: CatalogModel, actions: Actions) {
        self.model = model
        self.actions = actions
    }

    var isVisible: Bool { statusItem != nil }

    /// On makes the item; off removes it entirely.
    func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "loom-status"
            item.isVisible = true // a user's earlier Command-drag out of the bar must not hide a switch that is on
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self
            item.menu = menu
            if let button = item.button {
                let face = MenuBarFace(button: button)
                face.apply(summary)
                self.face = face
            }
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            face = nil
        }
    }

    func summaryChanged(_ summary: MenuBarSummary) {
        self.summary = summary
        face?.apply(summary)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for spec in currentItems() { menu.addItem(menuItem(for: spec)) }
    }

    func currentItems() -> [MenuBarMenuItem] {
        MenuBarMenu.items(for: model.menuBarState(), canStartSession: actions.canStartSession())
    }

    private func menuItem(for spec: MenuBarMenuItem) -> NSMenuItem {
        switch spec.kind {
        case .separator:
            return .separator()
        case .header:
            return .sectionHeader(title: spec.title)
        case .empty:
            let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .needsYouSession, .workingSession:
            let item = NSMenuItem(title: spec.title, action: #selector(sessionClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec.sessionID
            item.attributedTitle = MenuBarRowText.attributed(title: spec.title, project: spec.project)
            item.image = spec.attention.map(MenuBarArt.rowDotImage) ?? MenuBarArt.rowSpinnerImage()
            return item
        case .more:
            return target(NSMenuItem(title: spec.title, action: #selector(bringForwardClicked(_:)), keyEquivalent: ""))
        case .newSession:
            let item = target(NSMenuItem(title: spec.title, action: #selector(newSessionClicked(_:)), keyEquivalent: "n"))
            item.keyEquivalentModifierMask = [.command]
            item.isEnabled = spec.enabled
            return item
        case .openLoom:
            return target(NSMenuItem(title: spec.title, action: #selector(bringForwardClicked(_:)), keyEquivalent: ""))
        case .settings:
            let item = target(NSMenuItem(title: spec.title, action: #selector(settingsClicked(_:)), keyEquivalent: ","))
            item.keyEquivalentModifierMask = [.command]
            return item
        case .quit:
            let item = target(NSMenuItem(title: spec.title, action: #selector(quitClicked(_:)), keyEquivalent: "q"))
            item.keyEquivalentModifierMask = [.command]
            return item
        }
    }

    private func target(_ item: NSMenuItem) -> NSMenuItem {
        item.target = self
        return item
    }

    @objc private func sessionClicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { actions.showSession(id) }
    }
    @objc private func bringForwardClicked(_ sender: Any?) { actions.bringForward() }
    @objc private func newSessionClicked(_ sender: Any?) { actions.newClaudeSession() }
    @objc private func settingsClicked(_ sender: Any?) { actions.openSettings() }
    @objc private func quitClicked(_ sender: Any?) { actions.quit() }

    /// Evidence and tests: the same action as clicking the item of that kind.
    func perform(_ spec: MenuBarMenuItem) {
        switch spec.kind {
        case .needsYouSession, .workingSession: if let id = spec.sessionID { actions.showSession(id) }
        case .more, .openLoom: actions.bringForward()
        case .newSession: if spec.enabled { actions.newClaudeSession() }
        case .settings: actions.openSettings()
        case .quit: actions.quit()
        case .header, .empty, .separator: break
        }
    }
}
