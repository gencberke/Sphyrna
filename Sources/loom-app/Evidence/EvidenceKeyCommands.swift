#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// Key events through the real main window (I3), for the Return and search-focus checks.
///
/// - `focus-terminal`: makes the selected conversation's terminal the first responder (what a click into it does).
/// - `focus-search`: makes the main window's search field the first responder through Edit > Find's own model call.
/// - `key:<return|escape|cmd-f>`: sends that key as a native event (`NSApp.sendEvent` to the main window;
///   Cmd+F through the real main menu, as `tab-key` does). Every command writes `ack-key-<arg>.json`
///   with the first responder's class, whether it is the selected terminal or a text field, the search text
///   and how many requests the selected card still shows, so a Return that answered an approval is visible.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not a key command.
    func handleKeyCommand(_ name: String, _ argument: String) async -> Bool {
        guard let app, let model = app.model, let window = app.window else { return false }
        guard ["focus-terminal", "focus-search", "key"].contains(name) else { return false }
        // A driver that launched the app directly may not have made the window key yet.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        switch name {
        case "focus-terminal":
            // The container only hosts the terminal view; the keyboard belongs to the view inside it.
            if let id = model.selectedSessionID, let container = model.terminalView(for: id),
               let terminal = container.subviews.first(where: \.acceptsFirstResponder) {
                window.makeFirstResponder(terminal)
            }
            write("ack-key-focus-terminal", app.keyEvidence(["command": "focus-terminal"]))
        case "focus-search":
            model.requestSearchFocus()
            try? await Task.sleep(for: .milliseconds(500))
            write("ack-key-focus-search", app.keyEvidence(["command": "focus-search"]))
        case "key":
            var extra: [String: Any] = ["key": argument]
            switch argument {
            case "return": app.sendKeyForEvidence("\r", keyCode: 36, modifiers: [])
            case "escape": app.sendKeyForEvidence("\u{1b}", keyCode: 53, modifiers: [])
            case "cmd-f":
                let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
                    .filter { $0.action.map(NSStringFromSelector) == "findFromMenu:" }
                extra["menuItemFound"] = !items.isEmpty
                extra["enabledBefore"] = items.first.map { app.validateMenuItem($0) } ?? false
                extra["handled"] = app.sendKeyForEvidence("f", keyCode: 3, modifiers: [.command], viaMenu: true)
            default: return false
            }
            try? await Task.sleep(for: .milliseconds(500))
            write("ack-key-\(argument)", app.keyEvidence(extra))
        default: return false
        }
        return true
    }
}

extension AppDelegate {
    @discardableResult
    func sendKeyForEvidence(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                            viaMenu: Bool = false) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
        else { return false }
        if viaMenu { return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false }
        NSApp.sendEvent(event)
        return true
    }

    func keyEvidence(_ extra: [String: Any]) -> [String: Any] {
        let responder = window?.firstResponder
        let terminal = model?.selectedSessionID.flatMap { model?.terminalView(for: $0) }
        let terminalOrInner = [terminal].compactMap { $0 } + (terminal?.subviews ?? [])
        var state: [String: Any] = [
            "firstResponder": responder.map { String(describing: type(of: $0)) } ?? "none",
            "terminalFocused": terminal.map { _ in terminalOrInner.contains { $0 === responder } } ?? false,
            "terminalContainerFocused": terminal.map { $0 === responder } ?? false,
            "textFieldFocused": responder is NSText,
            "windowIsKey": window?.isKeyWindow ?? false,
            "search": model?.searchText ?? "",
            "selectedRequestCount": model?.selectedRow?.live?.userRequests.count ?? 0,
        ]
        state.merge(extra) { _, new in new }
        return state
    }
}
#endif
