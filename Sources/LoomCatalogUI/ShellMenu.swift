import AppKit

/// The target of the Studio menu items (`ShellCommand`): titles, keys, enabling and actions come from the command,
/// so a feature slice changes its holder file and never the menu. It lives here, not in the app target, so a test
/// builds the same items and sends their actions the way AppKit does. The items keep the target alive
/// (`representedObject`), because `NSMenuItem.target` is weak.
///
/// The action is named `runShellCommand`, never `perform`: a method `perform(_:)` takes the selector of
/// `NSObject.perform(_:)`, and AppKit then finds the superclass method and does nothing (the first V02b menu
/// had no working Studio item for that reason).
@MainActor
public final class ShellMenuTarget: NSObject, NSMenuItemValidation {
    private let model: () -> CatalogModel?
    private let bringForward: () -> Void

    public init(model: @escaping () -> CatalogModel?, bringForward: @escaping () -> Void) {
        self.model = model
        self.bringForward = bringForward
    }

    /// Adds the command's item to the menu: its title, key and modifiers, the command's tag, and this target.
    @discardableResult
    public func addItem(_ command: ShellCommand, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: command.title, action: #selector(runShellCommand(_:)),
                                keyEquivalent: command.keyEquivalent)
        item.keyEquivalentModifierMask = command.modifiers
        item.tag = command.rawValue
        item.target = self
        item.representedObject = self
        return item
    }

    @objc func runShellCommand(_ sender: NSMenuItem) {
        guard let command = ShellCommand(rawValue: sender.tag), let model = model() else { return }
        if command.needsWindow { bringForward() }
        command.run(on: model)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = ShellCommand(rawValue: item.tag), let model = model() else { return false }
        return command.isEnabled(on: model)
    }
}
