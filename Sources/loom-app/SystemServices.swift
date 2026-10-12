import AppKit
import LoomCatalogUI
import LoomCore
import ServiceManagement
import UserNotifications

/// The two system services of H1-F behind small protocols, so an evidence run (`--evidence`) swaps in
/// recording fakes and never calls `UNUserNotificationCenter` or `SMAppService` (no system prompt, no real
/// login item). The live implementations are the only code that touches either framework.
@MainActor
protocol NotificationService: AnyObject {
    /// Called with a session id when the user clicks its banner.
    var onActivate: ((UUID) -> Void)? { get set }
    func authorization() async -> NotificationAuthorization
    /// Asks the system once; the answer is the resulting authorization.
    func requestAuthorization() async -> NotificationAuthorization
    func post(id: UUID, title: String, body: String)
    /// Takes the banners back, delivered and pending.
    func remove(ids: [UUID])
    func removeAll()
    func openSettings()
}

@MainActor
protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() async throws
    func openLoginItems()
}

@MainActor
struct SystemServices {
    let notifications: any NotificationService
    let loginItem: any LoginItemService

    static func live(bundleIdentifier: String?) -> SystemServices {
        SystemServices(notifications: UserNotificationService(bundleIdentifier: bundleIdentifier),
                       loginItem: MainAppLoginItem())
    }
}

/// Banners through `UserNotifications`: the session id is the request identifier, no sound, the default
/// interruption level, no actions. A click on a banner reports the session.
@MainActor
final class UserNotificationService: NSObject, NotificationService, UNUserNotificationCenterDelegate {
    var onActivate: ((UUID) -> Void)?
    private let bundleIdentifier: String?
    private var center: UNUserNotificationCenter { .current() }

    init(bundleIdentifier: String?) {
        self.bundleIdentifier = bundleIdentifier
        super.init()
        center.delegate = self
    }

    func authorization() async -> NotificationAuthorization {
        Self.map(await center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> NotificationAuthorization {
        _ = try? await center.requestAuthorization(options: [.alert])
        return await authorization()
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .authorized
        @unknown default: .denied
        }
    }

    func post(id: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)
        center.add(request) { error in
            if let error { LoomLog.error(.lifecycle, "A needs-approval banner could not be posted (\(LoomLog.category(of: error)))") }
        }
    }

    func remove(ids: [UUID]) {
        let identifiers = ids.map(\.uuidString)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeAll() {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    /// Loom's page in System Settings → Notifications; the pane itself when the page cannot be named.
    func openSettings() {
        let page = bundleIdentifier.map { "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\($0)" }
        for text in [page, "x-apple.systempreferences:com.apple.Notifications-Settings.extension"].compactMap({ $0 }) {
            if let url = URL(string: text), NSWorkspace.shared.open(url) { return }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            if let id = UUID(uuidString: identifier) { self.onActivate?(id) }
            completionHandler()
        }
    }

    /// A banner posted while Loom was elsewhere may arrive after Loom came forward: it is not shown then.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }
}

/// Open at login: `SMAppService.mainApp`. Loom registers only when the user turns the switch on.
@MainActor
final class MainAppLoginItem: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() async throws { try await SMAppService.mainApp.unregister() }
    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
