import AppKit
import LoomCatalogUI
import LoomCore

/// H1-F: the menu bar item, needs-approval banners and Open at login, wired to the model. The services
/// come from `makeSystemServices()` (the system's in a normal run, recording fakes under `--evidence`).
extension AppDelegate {
    func installSystemIntegration(model: CatalogModel) {
        let services = makeSystemServices()
        systemServices = services
        let notifier = ApprovalNotifier(model: model, service: services.notifications)
        approvalNotifier = notifier
        services.notifications.onActivate = { [weak self] id in self?.showSession(id) }
        let bar = MenuBarController(model: model, actions: .init(
            showSession: { [weak self] id in self?.showSession(id) },
            bringForward: { [weak self] in self?.bringLoomForward() },
            canStartSession: { [weak model] in model?.canStart(.claude, projectID: model?.contextProjectID) ?? false },
            newClaudeSession: { [weak self] in
                self?.bringLoomForward()
                self?.newClaudeFromMenu(nil) // the same action as File → New Claude Session
            },
            openSettings: { [weak self] in
                NSApp.activate()
                self?.showSettings(section: nil) // as ⌘, does: the tab already open stays
            },
            quit: { NSApp.terminate(nil) })) // the normal quit path, so the quit question still applies
        menuBar = bar

        let integration = model.integration
        integration.refresh = { [weak self] in self?.refreshSystemStatus() }
        integration.setLoginItem = { [weak self] on in self?.setLoginItem(on) }
        integration.openNotificationSettings = { services.notifications.openSettings() }
        integration.openLoginItems = { services.loginItem.openLoginItems() }

        let keepAwake = KeepAwakeController(assertion: SystemIdleSleepAssertion())
        self.keepAwake = keepAwake
        model.onMenuBarChange = { [weak bar, weak notifier, weak keepAwake] summary in
            bar?.summaryChanged(summary)
            notifier?.approvalsChanged(summary.approvals)
            keepAwake?.workingChanged(summary.working)
        }
        integration.onKeepAwakeChange = { [weak integration, weak keepAwake] in
            keepAwake?.settingChanged(integration?.keepAwake ?? .off)
        }
        model.onShowInMenuBarChange = { [weak bar, weak model] in bar?.setVisible(model?.showInMenuBar ?? false) }
        model.onNotifyApprovalsChange = { [weak notifier] in notifier?.preferenceChanged() }

        bar.summaryChanged(model.menuBarSummary)
        keepAwake.workingChanged(model.menuBarSummary.working)
        keepAwake.settingChanged(integration.keepAwake)
        bar.setVisible(model.showInMenuBar)
        notifier.start()
        refreshSystemStatus()
    }

    /// Brings Loom to the front, opening the main window when it was closed or minimized.
    func bringLoomForward() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        presentMainWindow(reason: "menu-bar")
    }

    /// A menu bar row or a banner was clicked: Loom comes forward with that session selected.
    func showSession(_ id: UUID) {
        bringLoomForward()
        model?.select(id)
    }

    /// Reads the system's side again: the login item's status and the notification permission.
    func refreshSystemStatus() {
        guard let model, let services = systemServices else { return }
        model.integration.update(loginItem: services.loginItem.status)
        Task { await approvalNotifier?.refreshAuthorization() }
    }

    /// Settings → Open at login. The switch shows the system's answer afterwards, so a refused
    /// registration leaves it off.
    func setLoginItem(_ on: Bool) {
        guard let services = systemServices else { return }
        Task {
            do {
                if on { try services.loginItem.register() } else { try await services.loginItem.unregister() }
            } catch {
                LoomLog.error(.lifecycle, key: "login-item", "Open at login could not be changed (\(LoomLog.category(of: error)))")
            }
            refreshSystemStatus()
        }
    }
}
