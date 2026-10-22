import Foundation
import LoomCore

/// Needs-approval notifications (D-49, D-52): what to post and what to take back when the set of
/// sessions at Needs approval changes. Pure, so the decision is tested without a notification center;
/// the app's notifier carries it out.
public enum ApprovalNotificationPlanner {
    public struct Plan: Equatable, Sendable {
        /// Sessions that just turned to Needs approval and deserve a banner.
        public var post: [UUID]
        /// Sessions that left Needs approval; their banners (delivered and pending) go.
        public var remove: [UUID]

        public var isEmpty: Bool { post.isEmpty && remove.isEmpty }
    }

    /// A banner only on the transition into Needs approval, while Loom is not the active app and the
    /// setting is on. A session already waiting is never posted again, whatever else changes. A
    /// banner goes whenever its session leaves Needs approval, whether the setting is on or not.
    public static func plan(previous: Set<UUID>, current: Set<UUID>, appIsActive: Bool, enabled: Bool) -> Plan {
        func ordered(_ ids: Set<UUID>) -> [UUID] { ids.sorted { $0.uuidString < $1.uuidString } }
        return Plan(post: enabled && !appIsActive ? ordered(current.subtracting(previous)) : [],
                    remove: ordered(previous.subtracting(current)))
    }

    /// "<project> · Claude is waiting for your approval." Without a project: "Claude is waiting for your approval." A
    /// question and a plan say what they are (`kind`: the first request that waits).
    public static func body(project: String?, kind: ProviderPendingRequest.Kind? = nil) -> String {
        let sentence = switch kind {
        case .question?: "Claude has a question for you."
        case .plan?: "Claude has a plan ready for your review."
        case .approval?, nil: "Claude is waiting for your approval."
        }
        guard let project, !project.isEmpty else { return sentence }
        return "\(project) · \(sentence)"
    }
}

/// What the system says about Loom's notifications.
public enum NotificationAuthorization: String, Equatable, Sendable {
    case authorized, denied, notDetermined
}

/// What the system says about Loom as a login item (`SMAppService.Status`).
public enum LoginItemStatus: String, Equatable, Sendable {
    case enabled, requiresApproval, notRegistered, notFound

    /// The switch shows the system's state: on while registered, also while the user still has to
    /// allow it in Login Items.
    public var switchIsOn: Bool { self == .enabled || self == .requiresApproval }
}

/// The one extra line (and its button) a Settings row adds when macOS says something is wrong.
public struct SettingsNotice: Equatable, Sendable {
    public let text: String
    public let buttonTitle: String

    public static func notifications(_ authorization: NotificationAuthorization) -> SettingsNotice? {
        authorization == .denied
            ? SettingsNotice(text: "Notifications for Sphyrna are off in System Settings, so no banner will appear.",
                             buttonTitle: "Open System Settings")
            : nil
    }

    public static func loginItem(_ status: LoginItemStatus) -> SettingsNotice? {
        status == .requiresApproval
            ? SettingsNotice(text: "Allow Sphyrna in System Settings → General → Login Items.",
                             buttonTitle: "Open Login Items")
            : nil
    }
}

/// What the app knows about the system's side of Settings → General, and the calls the rows make.
/// The app installs the closures and keeps the two values current; the release flavor talks to the
/// system, an evidence run to recording fakes. Read the status again whenever Settings shows.
@MainActor @Observable
public final class SystemIntegration {
    public internal(set) var notificationAuthorization: NotificationAuthorization = .notDetermined
    public internal(set) var loginItemStatus: LoginItemStatus = .notRegistered

    @ObservationIgnored public var refresh: () -> Void = {}
    @ObservationIgnored public var setLoginItem: (Bool) -> Void = { _ in }
    @ObservationIgnored public var openNotificationSettings: () -> Void = {}
    @ObservationIgnored public var openLoginItems: () -> Void = {}

    public init() {}

    public func update(notifications: NotificationAuthorization? = nil, loginItem: LoginItemStatus? = nil) {
        if let notifications, notifications != notificationAuthorization { notificationAuthorization = notifications }
        if let loginItem, loginItem != loginItemStatus { loginItemStatus = loginItem }
    }
}
