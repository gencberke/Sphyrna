import AppKit
import LoomCatalogUI

/// The Dock icon's menu (W3-f): built each time the Dock asks, from `CatalogModel.dockMenuItems()`. A session row brings Sphyrna
/// forward with that session selected, as a menu bar row does; New Claude Session is File → New Claude Session.
extension AppDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for spec in model.dockMenuItems() {
            switch spec.kind {
            case .header:
                menu.addItem(.sectionHeader(title: spec.title))
            case .needsYouSession, .workingSession:
                let item = NSMenuItem(title: DockMenu.rowTitle(spec), action: #selector(dockSessionClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = spec.sessionID
                menu.addItem(item)
            case .newSession:
                let item = NSMenuItem(title: spec.title, action: #selector(dockNewSessionClicked(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = spec.enabled
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            case .more, .empty, .openLoom, .settings, .quit:
                break
            }
        }
        return menu
    }

    @objc func dockSessionClicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { showSession(id) }
    }

    @objc func dockNewSessionClicked(_ sender: Any?) {
        bringLoomForward()
        newClaudeFromMenu(nil)
    }
}
