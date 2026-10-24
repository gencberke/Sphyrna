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

/// Long-turn notifications (opt-in): the sessions whose turn just finished after at least 30 s while they were not on screen (Sphyrna
/// not the active app, or another session shown). A turn runs while the session works or waits for an approval in the middle of it;
/// it finishes when the session is at its prompt again. A turn that ends in a request waiting for the user posts nothing: the
/// needs-approval banner speaks for it. The watch follows the attention candidates on each menu bar change and keeps no timer.
@MainActor
public final class LongTurnWatch {
    public static let minimumTurn: TimeInterval = 30
    /// The notification's category and its one action: Open brings Sphyrna forward on the session, as a click on the banner does.
    public static let categoryIdentifier = "loom-turn-finished"
    public static let openActionIdentifier = "open"
    public static let openActionTitle = "Open"

    public struct Notice: Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let subtitle: String?
    }

    /// When each running turn was first seen.
    private var started: [UUID: Date] = [:]

    public init() {}

    /// "<session title> finished".
    public static func title(session: String) -> String { "\(session) finished" }

    /// What the notifier posts after a menu bar change: one notice per long turn that just finished off screen, with the switch on.
    public func finishedTurns(in model: CatalogModel, appIsActive: Bool, now: Date = Date()) -> [Notice] {
        finishedTurns(model.attentionCandidates(), enabled: model.integration.notifyLongTurns, appIsActive: appIsActive,
                      shown: model.selectedSessionID, now: now).compactMap { id in
            model.titleAndProject(of: id).map { Notice(id: id, title: Self.title(session: $0.title), subtitle: $0.project) }
        }
    }

    /// The decision itself. Turns are followed with the switch off too, so turning it on mid-turn counts the whole turn.
    func finishedTurns(_ candidates: [AttentionCandidate], enabled: Bool, appIsActive: Bool, shown: UUID?, now: Date) -> [UUID] {
        var finished: [UUID] = []
        var seen = Set<UUID>()
        for candidate in candidates {
            let id = candidate.id
            seen.insert(id)
            switch candidate.indicator {
            case .working, .waitingForApproval:
                if started[id] == nil { started[id] = now }
            case .unviewedCompletion, .ready:
                guard let start = started.removeValue(forKey: id) else { continue }
                let onScreen = appIsActive && shown == id
                if enabled, !onScreen, now.timeIntervalSince(start) >= Self.minimumTurn { finished.append(id) }
            default:
                started[id] = nil // waiting for the user, failed, stopped: no finished turn
            }
        }
        started = started.filter { seen.contains($0.key) }
        return finished.sorted { $0.uuidString < $1.uuidString }
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

    /// Settings → General → Keep Mac awake. Kept in the preferences file the app hands over (`attach(preferences:)`).
    public internal(set) var keepAwake: KeepAwakeSetting = .off
    /// Settings → General → Notify when a long turn finishes (opt-in), kept beside Keep Mac awake.
    public internal(set) var notifyLongTurns = false

    @ObservationIgnored public var refresh: () -> Void = {}
    @ObservationIgnored public var setLoginItem: (Bool) -> Void = { _ in }
    @ObservationIgnored public var openNotificationSettings: () -> Void = {}
    @ObservationIgnored public var openLoginItems: () -> Void = {}
    /// Keep Mac awake changed; the app reads `keepAwake`.
    @ObservationIgnored public var onKeepAwakeChange: () -> Void = {}
    /// Notify when a long turn finishes changed; the app reads `notifyLongTurns`.
    @ObservationIgnored public var onNotifyLongTurnsChange: () -> Void = {}
    @ObservationIgnored private var preferences: UIPreferencesStore?

    public init() {}

    /// The preferences file the model writes: this card's options that are not the model's are read from it and written to it, beside
    /// the other General switches. Before it is attached they keep their defaults and are not written.
    public func attach(preferences: UIPreferencesStore) {
        self.preferences = preferences
        keepAwake = preferences.current.keepAwake
        notifyLongTurns = preferences.current.notifyLongTurns
    }

    public func setNotifyLongTurns(_ on: Bool) {
        guard on != notifyLongTurns else { return }
        notifyLongTurns = on
        persist { $0.notifyLongTurns = on }
        onNotifyLongTurnsChange()
    }

    public func setKeepAwake(_ setting: KeepAwakeSetting) {
        guard setting != keepAwake else { return }
        keepAwake = setting
        persist { $0.keepAwake = setting }
        onKeepAwakeChange()
    }

    private func persist(_ change: (inout UIPreferences) -> Void) {
        do { try preferences?.update(change) }
        catch { LoomLog.error(.lifecycle, "Preferences could not be saved (\(LoomLog.category(of: error)))") }
    }

    public func update(notifications: NotificationAuthorization? = nil, loginItem: LoginItemStatus? = nil) {
        if let notifications, notifications != notificationAuthorization { notificationAuthorization = notifications }
        if let loginItem, loginItem != loginItemStatus { loginItemStatus = loginItem }
    }
}
