#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore

/// Recording fakes for the two system services (H1-F). Under `--evidence` Loom never calls
/// `UNUserNotificationCenter` or `SMAppService`: no system prompt, no real login item.
@MainActor
final class RecordingNotificationService: NotificationService {
    struct Posted { let id: UUID; let title: String; let body: String }

    var onActivate: ((UUID) -> Void)?
    var status = NotificationAuthorization.notDetermined
    private(set) var posted: [Posted] = []
    private(set) var removed: [UUID] = []
    private(set) var removeAllCount = 0
    private(set) var authorizationRequests = 0
    private(set) var settingsOpened = 0

    func authorization() async -> NotificationAuthorization { status }

    /// A fake user who allows: the first request turns "not determined" into "authorized".
    func requestAuthorization() async -> NotificationAuthorization {
        authorizationRequests += 1
        if status == .notDetermined { status = .authorized }
        return status
    }

    func post(id: UUID, title: String, body: String) { posted.append(Posted(id: id, title: title, body: body)) }
    func remove(ids: [UUID]) { removed += ids }
    func removeAll() { removeAllCount += 1 }
    func openSettings() { settingsOpened += 1 }
}

@MainActor
final class FakeLoginItem: LoginItemService {
    var status = LoginItemStatus.notRegistered
    private(set) var registrations = 0
    private(set) var unregistrations = 0
    private(set) var settingsOpened = 0

    func register() throws {
        registrations += 1
        status = .enabled
    }

    func unregister() async throws {
        unregistrations += 1
        status = .notRegistered
    }

    func openLoginItems() { settingsOpened += 1 }
}

extension AppDelegate {
    /// The system's services in a normal development run; recording fakes under `--evidence`.
    func makeSystemServices() -> SystemServices {
        options.isEvidence
            ? SystemServices(notifications: RecordingNotificationService(), loginItem: FakeLoginItem())
            : .live(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    var fakeNotifications: RecordingNotificationService? { systemServices?.notifications as? RecordingNotificationService }
    var fakeLoginItem: FakeLoginItem? { systemServices?.loginItem as? FakeLoginItem }

    /// Snapshot fields `menuBar`, `notifications` and `loginItem`. Ids only: titles and projects are
    /// written in the menu dump and the posted list when the run is not redacted.
    var systemEvidence: [String: Any] {
        let state = model?.menuBarState()
        let summary = model?.menuBarSummary ?? .idle
        let menuBar: [String: Any] = [
            "visible": menuBar?.isVisible ?? false,
            "badge": summary.badge.rawValue,
            "accessibilityLabel": summary.accessibilityLabel,
            "needsYou": state?.needsYou.map(\.id.uuidString) ?? [],
            "working": state?.working.map(\.id.uuidString) ?? [],
            "needsYouMore": state?.needsYouMore ?? 0,
            "workingMore": state?.workingMore ?? 0,
            "chaseRunning": menuBar?.face?.isChaseRunning ?? false,
            "buttonAppearance": menuBar?.face?.appearanceName ?? NSNull(),
            "systemIncreaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
        ]
        let fake = fakeNotifications
        let notifications: [String: Any] = [
            "authorization": fake?.status.rawValue ?? NSNull(),
            "posted": (fake?.posted ?? []).map {
                ["id": $0.id.uuidString, "title": redactsContent ? "" : $0.title, "body": redactsContent ? "" : $0.body]
            },
            "removed": (fake?.removed ?? []).map(\.uuidString),
            "removeAll": fake?.removeAllCount ?? 0,
            "authorizationRequests": fake?.authorizationRequests ?? 0,
            "settingsOpened": fake?.settingsOpened ?? 0,
        ]
        let loginItem: [String: Any] = [
            "status": fakeLoginItem?.status.rawValue ?? NSNull(),
            "registrations": fakeLoginItem?.registrations ?? 0,
            "unregistrations": fakeLoginItem?.unregistrations ?? 0,
            "settingsOpened": fakeLoginItem?.settingsOpened ?? 0,
        ]
        return ["menuBar": menuBar, "notifications": notifications, "loginItem": loginItem]
    }

    var generalSettingsEvidence: [String: Any] {
        ["showInMenuBar": model?.showInMenuBar ?? NSNull(), "notifyApprovals": model?.notifyApprovals ?? NSNull(),
         "notificationAuthorization": model?.integration.notificationAuthorization.rawValue ?? NSNull(),
         "loginItemStatus": model?.integration.loginItemStatus.rawValue ?? NSNull()]
    }
}

/// Menu bar, notification and login item commands (H1-F):
///
/// - `menubar-menu:<label>`: writes `menubar-menu-<label>.json`, the items the menu would show
///   (kind, title, project, enabled, sessionID) without opening it; titles and projects are empty for real providers.
/// - `menubar-click:<session id|more|new|open|settings>`: the action of that item.
/// - `screenshot-menubar:<label>`: the item's current drawing at 2x on a dark and a light bar, the chase on
///   its first frame (`screenshot-menubar-<label>-dark.png`, `-light.png`).
/// - `settings-set:<menubar|notify|login>:<on|off>`: the three Settings → General switches.
/// - `app-active:<on|off>`: the notifier treats Loom as the active app or not.
/// - `notify-auth:<authorized|denied|notDetermined>`, `login-status:<enabled|requiresApproval|notRegistered>`: set the fakes.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not one of these commands.
    func handleSystemCommand(_ name: String, _ argument: String) async -> Bool {
        guard let app, let model = app.model else { return false }
        let label = argument.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        switch name {
        case "menubar-menu":
            let items = app.menuBar?.currentItems() ?? []
            let redacted = app.redactsContent
            write("menubar-menu-\(label)", ["items": items.map { item -> [String: Any] in
                ["kind": item.kind.rawValue, "title": redacted && item.sessionID != nil ? "" : item.title,
                 "project": redacted ? NSNull() : (item.project ?? NSNull()), "enabled": item.enabled,
                 "sessionID": item.sessionID?.uuidString ?? NSNull(), "key": item.key ?? NSNull()]
            }])
        case "menubar-click":
            let items = app.menuBar?.currentItems() ?? []
            let chosen: MenuBarMenuItem?
            if let id = UUID(uuidString: argument) {
                chosen = items.first { $0.sessionID == id }
            } else {
                let kinds: [String: MenuBarMenuItem.Kind] = ["more": .more, "new": .newSession, "open": .openLoom,
                                                             "settings": .settings]
                chosen = kinds[argument].flatMap { kind in items.first { $0.kind == kind } }
            }
            if let chosen { app.menuBar?.perform(chosen) }
        case "screenshot-menubar":
            let badge = model.menuBarSummary.badge
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            for (suffix, dark) in [("dark", true), ("light", false)] {
                let data = MenuBarArt.evidencePNG(badge: badge, darkBar: dark, increasedContrast: contrast)
                try? data?.write(to: directory.appendingPathComponent("screenshot-menubar-\(label)-\(suffix).png"), options: .atomic)
            }
        case "settings-set":
            let parts = argument.split(separator: ":").map(String.init)
            guard parts.count == 2, parts[1] == "on" || parts[1] == "off" else { return true }
            let on = parts[1] == "on"
            switch parts[0] {
            case "menubar": model.setShowInMenuBar(on)
            case "notify": model.setNotifyApprovals(on)
            case "login": model.integration.setLoginItem(on)
            default: break
            }
            try? await Task.sleep(for: .milliseconds(150)) // the login item and permission calls are asynchronous
        case "app-active":
            let on = argument == "on"
            app.approvalNotifier?.isAppActive = { on }
        case "notify-auth":
            if let status = NotificationAuthorization(rawValue: argument) {
                app.fakeNotifications?.status = status
                await app.approvalNotifier?.refreshAuthorization()
            }
        case "login-status":
            if let status = LoginItemStatus(rawValue: argument) {
                app.fakeLoginItem?.status = status
                app.refreshSystemStatus()
            }
        default: return false
        }
        return true
    }
}
#endif
