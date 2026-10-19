import AppKit
import LoomCatalogUI
import LoomCore

/// The main menu. Every item targets this delegate or the shell target; later slices add their items here.
extension AppDelegate {
    func installMenus() {
        let shell = ShellMenuTarget(model: { [weak self] in self?.model },
                                    bringForward: { [weak self] in self?.presentMainWindow(reason: "shell-menu") })
        func addShellItem(_ command: ShellCommand, to menu: NSMenu) { _ = shell.addItem(command, to: menu) }
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Loom", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Loom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add Project…", action: #selector(addProjectFromMenu(_:)),
                         keyEquivalent: "o").target = self
        // New conversations start in the selected conversation's project (or none), through the new-session holder.
        addShellItem(.newSession, to: fileMenu)
        // Codex is listed in every build (D-69). A build that cannot start it shows the item disabled
        // (`validateMenuItem` asks the model) with the reason under it.
        let codex = fileMenu.addItem(withTitle: "New Codex Session", action: #selector(newCodexFromMenu(_:)),
                                     keyEquivalent: "n")
        codex.keyEquivalentModifierMask = [.command, .shift]
        codex.target = self
        if let reason = CatalogModel.newSessionUnavailableReason(.codex, startable: startableProviders) {
            codex.subtitle = reason
            codex.toolTip = reason
        }
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Resume Session", action: #selector(resumeFromMenu(_:)),
                         keyEquivalent: "r").target = self
        let stop = fileMenu.addItem(withTitle: "Stop Session", action: #selector(stopFromMenu(_:)),
                                    keyEquivalent: ".")
        stop.target = self
        fileMenu.addItem(.separator())
        let delete = fileMenu.addItem(withTitle: "Delete Permanently…", action: #selector(deleteFromMenu(_:)),
                                      keyEquivalent: "\u{8}")
        delete.target = self
        fileMenu.addItem(.separator())
        installDevelopmentMenuItems(in: fileMenu)
        // Cmd+W keeps closing the window; the tab closes with Opt+Cmd+W.
        let closeTab = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeTabFromMenu(_:)),
                                        keyEquivalent: "w")
        closeTab.keyEquivalentModifierMask = [.command, .option]
        closeTab.target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // Undo, Redo and Cut go to the first responder as the standard selectors; the composer's text view answers them, and a
        // view that does not (the terminal) leaves them disabled.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find", action: #selector(findFromMenu(_:)), keyEquivalent: "f").target = self
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // The same path as the Hide and Show buttons (SidebarCollapseSync), not AppKit's own toggle.
        addShellItem(.home, to: viewMenu)
        addShellItem(.commandPalette, to: viewMenu)
        viewMenu.addItem(.separator())
        addShellItem(.showChat, to: viewMenu)
        addShellItem(.showTerminal, to: viewMenu)
        viewMenu.addItem(.separator())
        let sidebar = viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebarFromMenu(_:)),
                                       keyEquivalent: "s")
        sidebar.target = self
        sidebar.keyEquivalentModifierMask = [.control, .command]
        addShellItem(.toggleInspector, to: viewMenu)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Recent Activity", action: #selector(showActivityView(_:)),
                         keyEquivalent: "1").target = self
        viewMenu.addItem(withTitle: "Group by Project", action: #selector(showProjectView(_:)),
                         keyEquivalent: "2").target = self
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        // Tab shortcuts (DP-U2): Shift+Cmd+] / [ are the visible items; Ctrl+Tab / Ctrl+Shift+Tab and
        // the shifted characters a keyboard layout may report are hidden twins of the same action.
        let tabKeys: [(String, Selector, String, NSEvent.ModifierFlags, Bool)] = [
            ("Show Next Tab", #selector(showNextTab(_:)), "]", [.command, .shift], false),
            ("Show Next Tab", #selector(showNextTab(_:)), "}", [.command, .shift], true),
            ("Show Next Tab", #selector(showNextTab(_:)), "\t", [.control], true),
            ("Show Previous Tab", #selector(showPreviousTab(_:)), "[", [.command, .shift], false),
            ("Show Previous Tab", #selector(showPreviousTab(_:)), "{", [.command, .shift], true),
            ("Show Previous Tab", #selector(showPreviousTab(_:)), "\u{19}", [.control, .shift], true),
        ]
        for (title, action, key, mask, hidden) in tabKeys {
            let item = windowMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = self
            item.isHidden = hidden
        }
        windowMenu.addItem(.separator())
        // Between sessions (D-45). Key equivalents reach the menu before a focused terminal sees the key.
        // Shift+Cmd+J may arrive as an uppercase J, which a lowercase key equivalent does not match: a hidden
        // twin takes it. Which of the two J items AppKit fires is not reliable; the action reads Shift itself.
        let previousAttention = SessionShortcut.jumpToPreviousAttention
        let twin = windowMenu.addItem(withTitle: previousAttention.title, action: #selector(jumpToPreviousAttention(_:)),
                                      keyEquivalent: previousAttention.keyEquivalent.uppercased())
        twin.keyEquivalentModifierMask = previousAttention.modifiers
        twin.target = self
        twin.isHidden = true
        let sessionKeys: [(SessionShortcut, Selector)] = [
            (.jumpToNextAttention, #selector(jumpToNextAttention(_:))),
            (.jumpToPreviousAttention, #selector(jumpToPreviousAttention(_:))),
            (.selectNextSession, #selector(selectNextSession(_:))),
            (.selectPreviousSession, #selector(selectPreviousSession(_:))),
        ]
        for (shortcut, action) in sessionKeys {
            if action == #selector(selectNextSession(_:)) { windowMenu.addItem(.separator()) }
            let item = windowMenu.addItem(withTitle: shortcut.title, action: action, keyEquivalent: shortcut.keyEquivalent)
            item.keyEquivalentModifierMask = shortcut.modifiers
            item.target = self
        }
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Loom", action: #selector(showMainWindow), keyEquivalent: "").target = self
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Collect Diagnostics…", action: #selector(collectDiagnosticsFromMenu(_:)),
                         keyEquivalent: "").target = self
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }
}
