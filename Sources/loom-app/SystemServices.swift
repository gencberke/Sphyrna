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
protocol ResetNotificationActivating: AnyObject {
    var onResetActivate: ((String) -> Void)? { get set }
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
final class UserNotificationService: NSObject, NotificationService, ResetNotificationActivating, UNUserNotificationCenterDelegate {
    var onActivate: ((UUID) -> Void)?
    var onResetActivate: ((String) -> Void)?
    var finishedGeneration: UInt64 = 0
    private var scheduledResetIDs: Set<String> = []
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
        scheduledResetIDs.removeAll()
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
        let action = response.actionIdentifier
        Task { @MainActor in
            if identifier.hasPrefix(LimitResetNotifier.identifierPrefix) {
                if action == UNNotificationDefaultActionIdentifier || action == LimitResetNotifier.continueActionIdentifier {
                    self.onResetActivate?(identifier)
                }
            } else if let id = UUID(uuidString: identifier) {
                self.onActivate?(id)
            }
            completionHandler()
        }
    }

    /// A reset can arrive while the app is active; approval and finished-turn banners remain suppressed in the foreground.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix(LimitResetNotifier.identifierPrefix) ? [.banner, .list] : [])
    }
}

extension UserNotificationService: LimitResetScheduling {
    func registerNotificationCategories() async {
        let open = UNNotificationAction(identifier: LongTurnWatch.openActionIdentifier, title: LongTurnWatch.openActionTitle,
                                        options: [.foreground])
        let next = UNNotificationAction(identifier: LimitResetNotifier.continueActionIdentifier, title: "Continue",
                                        options: [.foreground])
        var categories = await center.notificationCategories()
        categories = Set(categories.filter { $0.identifier != LongTurnWatch.categoryIdentifier
            && $0.identifier != LimitResetNotifier.categoryIdentifier })
        categories.insert(UNNotificationCategory(identifier: LongTurnWatch.categoryIdentifier, actions: [open], intentIdentifiers: []))
        categories.insert(UNNotificationCategory(identifier: LimitResetNotifier.categoryIdentifier, actions: [next], intentIdentifiers: []))
        center.setNotificationCategories(categories)
    }

    func scheduleReset(_ notice: LimitResetNotice) async -> Bool {
        scheduledResetIDs.insert(notice.identifier)
        guard await authorization() == .authorized, scheduledResetIDs.contains(notice.identifier) else {
            scheduledResetIDs.remove(notice.identifier)
            return false
        }
        await registerNotificationCategories()
        let delay = notice.resetsAt.timeIntervalSinceNow
        guard scheduledResetIDs.contains(notice.identifier), delay >= 1 else {
            scheduledResetIDs.remove(notice.identifier)
            return false
        }
        let content = UNMutableNotificationContent()
        content.title = "Claude's \(notice.windowName) limit has reset"
        content.categoryIdentifier = LimitResetNotifier.categoryIdentifier
        content.interruptionLevel = .passive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: trigger))
            guard scheduledResetIDs.contains(notice.identifier) else {
                center.removePendingNotificationRequests(withIdentifiers: [notice.identifier])
                return false
            }
            return true
        } catch {
            scheduledResetIDs.remove(notice.identifier)
            LoomLog.error(.lifecycle, "A limit-reset notice could not be scheduled (\(LoomLog.category(of: error)))")
            return false
        }
    }

    func cancelResets(_ identifiers: [String]) {
        scheduledResetIDs.subtract(identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cancelAllResets() {
        let known = Array(scheduledResetIDs)
        scheduledResetIDs.removeAll()
        center.removePendingNotificationRequests(withIdentifiers: known)
        center.removeDeliveredNotifications(withIdentifiers: known)
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(LimitResetNotifier.identifierPrefix) }
            Task { @MainActor in
                guard let self else { return }
                self.center.removePendingNotificationRequests(withIdentifiers: ids.filter { !self.scheduledResetIDs.contains($0) })
            }
        }
        center.getDeliveredNotifications { [weak self] delivered in
            let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(LimitResetNotifier.identifierPrefix) }
            Task { @MainActor in
                guard let self else { return }
                self.center.removeDeliveredNotifications(withIdentifiers: ids.filter { !self.scheduledResetIDs.contains($0) })
            }
        }
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
