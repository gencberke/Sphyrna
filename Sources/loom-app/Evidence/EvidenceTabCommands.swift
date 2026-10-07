#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// Conversation tab commands (U4): the same model calls the strip, the context menus and the menu shortcuts make.
///
/// - `tab-pin:<id>`: "Open in Tab" (pins the conversation and shows it).
/// - `tab-unpin:<id>`: unpins without changing what is shown (the selected tab turns transient).
/// - `tab-select:<id|next|prev>`: a click on a tab, or Show Next / Previous Tab.
/// - `tab-close:<id>`: the tab's close button (only unpins; never stops a run).
/// - `tab-key:<next|prev|ctrl-next|ctrl-prev|close>`: a key equivalent sent through the real main menu
///   (Shift+Cmd+], Shift+Cmd+[, Ctrl+Tab, Ctrl+Shift+Tab, Opt+Cmd+W); writes `ack-tab-key-<arg>.json`
///   with whether the menu handled it and whether the item was enabled.
///
/// The snapshot gains `tabs{ids, pinned, selected, transient, stripVisible, canSelectAdjacent, canClose,
/// rows[{id, title, indicator, live}], attachedTerminals}` and `catalog.preferences.openTabs`.
/// `attachedTerminals` lists the tabs whose terminal view is in the window right now: with a stale
/// pane it would hold a tab other than the selected one.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not a tab command.
    func handleTabCommand(_ name: String, _ argument: String) -> Bool {
        guard let app, let model = app.model else { return false }
        let id = UUID(uuidString: String(argument.prefix(36)))
        switch name {
        case "tab-pin": if let id { model.openTab(id) }
        case "tab-unpin": if let id { model.unpinTab(id) }
        case "tab-select":
            switch argument {
            case "next": model.selectAdjacentTab(.next)
            case "prev": model.selectAdjacentTab(.previous)
            default: if let id { model.selectTab(id) }
            }
        case "tab-close": if let id { model.closeTab(id) }
        case "tab-key": write("ack-tab-key-\(argument.filter { $0.isLetter || $0 == "-" })", app.sendTabKeyForEvidence(argument))
        default: return false
        }
        return true
    }
}

extension AppDelegate {
    var tabsEvidence: [String: Any] {
        guard let model else { return [:] }
        let selected = model.selectedSessionID
        return [
            "ids": model.visibleTabIDs.map(\.uuidString),
            "pinned": model.tabs.pinned.map(\.uuidString),
            "selected": selected?.uuidString ?? NSNull(),
            "transient": selected.flatMap { model.isTransientTab($0) ? $0.uuidString : nil } ?? NSNull(),
            "stripVisible": model.tabStripIsVisible,
            "canSelectAdjacent": model.canSelectAdjacentTab,
            "canClose": model.canCloseSelectedTab,
            "rows": model.visibleTabIDs.map { id in
                let row = model.tabRow(id)
                return ["id": id.uuidString, "title": redactsContent ? "" : (row.map { model.title(of: $0) } ?? ""),
                        "indicator": row?.indicator.label ?? "", "live": row?.live?.runID != nil] as [String: Any]
            },
            "attachedTerminals": model.visibleTabIDs.filter { model.terminalView(for: $0)?.window != nil }.map(\.uuidString),
        ]
    }

    /// Sends the key equivalent through `NSApp.mainMenu`, as the key window would after the responder chain passed.
    /// AppKit maps a key equivalent such as "]" to the character the current keyboard layout puts on that key
    /// (a Turkish layout reports "\u{fc}"), so the event carries the character of the visible menu item.
    func sendTabKeyForEvidence(_ name: String) -> [String: Any] {
        let keys: [String: (String, NSEvent.ModifierFlags, UInt16, String)] = [
            "next": ("]", [.command, .shift], 30, "showNextTab:"),
            "prev": ("[", [.command, .shift], 33, "showPreviousTab:"),
            "ctrl-next": ("\t", [.control], 48, "showNextTab:"),
            "ctrl-prev": ("\u{19}", [.control, .shift], 48, "showPreviousTab:"),
            "close": ("w", [.command, .option], 13, "closeTabFromMenu:"),
        ]
        guard let (fallback, modifiers, code, selector) = keys[name] else { return ["handled": false, "error": "unknown key"] }
        let items = (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
            .filter { $0.action.map(NSStringFromSelector) == selector }
        let item = items.first { !$0.isHidden && $0.keyEquivalentModifierMask == modifiers }
            ?? items.first { $0.keyEquivalentModifierMask == modifiers }
        let characters = (name == "next" || name == "prev") ? (item?.keyEquivalent ?? fallback) : fallback
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        else { return ["handled": false, "error": "no event"] }
        let enabledBefore = item.map { validateMenuItem($0) } ?? false
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        return ["key": name, "handled": handled, "enabledBefore": enabledBefore, "selector": selector,
                "event": characters.unicodeScalars.map { String($0.value, radix: 16) },
                "menuKey": item?.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) } ?? [],
                "layout": NSTextInputContext.current?.selectedKeyboardInputSource ?? "unknown"]
    }
}
#endif
