#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// The command palette (V06), driven the way a user does: ⌘K through the real main menu, typing and keys as native
/// events to the window, so the keyboard path (field focus, arrows, Return, Esc) is the one under test.
///
/// - `palette-open`: what ⌘K runs (it closes an open palette).
/// - `palette-menu`: ⌘K as a key event through the real main menu (writes `ack-palette-menu-handled.json`).
/// - `palette-type:<text>`: each character as a key event to the first responder.
/// - `palette-key:<up|down|return|cmd-return|escape>`: that key as a native event.
/// - `palette-state:<label>`: writes `ack-palette-<label>.json` without doing anything.
///
/// Every command writes `ack-palette-<label>.json` (the label is the argument's first word) with what the palette shows
/// and which responder has the keyboard. Content is left out when the run redacts it.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not a palette command.
    func handlePaletteCommand(_ name: String, _ argument: String) -> Bool {
        guard name.hasPrefix("palette-"), let app, let model = app.model, let window = app.window else { return false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        switch name {
        case "palette-open":
            // What the menu item runs; the key equivalent itself is checked by the menu-validation tests.
            ShellCommand.commandPalette.run(on: model)
        case "palette-menu":
            // ⌘K as a key event through the real main menu, as the user's keystroke reaches it.
            let home = argument == "home"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: home ? [.control, .command] : [.command],
                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                         characters: home ? "h" : "k", charactersIgnoringModifiers: home ? "h" : "k",
                                         isARepeat: false, keyCode: home ? 4 : 40)
            let handled = event.map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false
            write("ack-palette-menu-handled", ["handled": handled])
        case "palette-type":
            for character in argument { app.sendKeyForEvidence(String(character), keyCode: 0, modifiers: []) }
        case "palette-key":
            switch argument {
            case "up": app.sendKeyForEvidence("\u{F700}", keyCode: 126, modifiers: [.numericPad, .function])
            case "down": app.sendKeyForEvidence("\u{F701}", keyCode: 125, modifiers: [.numericPad, .function])
            case "return": app.sendKeyForEvidence("\r", keyCode: 36, modifiers: [])
            case "cmd-return": app.sendKeyForEvidence("\r", keyCode: 36, modifiers: [.command])
            case "escape": app.sendKeyForEvidence("\u{1b}", keyCode: 53, modifiers: [])
            default: return false
            }
        case "palette-state": break
        default: return false
        }
        let label = argument.split(separator: " ").first.map(String.init) ?? name
        let tag = (argument.isEmpty ? name : name + "-" + label).filter { $0.isLetter || $0.isNumber || $0 == "-" }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(name == "palette-type" ? 700 : 400))
            let palette = model.palette
            let responder = window.firstResponder
            write("ack-" + tag, [
                "open": palette.isOpen,
                "query": app.redactsContent ? "" : palette.query,
                "searching": palette.isSearching,
                "coverage": app.redactsContent ? "" : (palette.coverageNote ?? ""),
                "selected": palette.selectedID ?? NSNull(),
                "groups": palette.groups.map { group in
                    ["section": group.title, "items": group.items.map { item in
                        ["title": app.redactsContent ? "" : item.title, "detail": app.redactsContent ? "" : (item.detail ?? ""),
                         "trailing": app.redactsContent ? "" : (item.trailing ?? ""), "id": item.id] as [String: Any]
                    }] as [String: Any]
                },
                "firstResponder": responder.map { String(describing: type(of: $0)) } ?? "none",
                "firstResponderIsTextInput": responder is NSText,
                "selectedSession": model.selectedSessionID?.uuidString ?? NSNull(),
                "destination": String(describing: model.destination),
            ])
        }
        return true
    }
}
#endif
