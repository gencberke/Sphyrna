import AppKit
import LoomCatalogUI
import LoomCore
import UserNotifications

/// The long-turn banner (opt-in): a title, the project as its subtitle, no sound, and one Open action. The session id is the
/// request identifier, so Open and a click on the banner both reach `NotificationService.onActivate`.
@MainActor
protocol FinishedTurnNotifying: AnyObject {
    func postFinished(_ notice: LongTurnWatch.Notice)
}

extension UserNotificationService: FinishedTurnNotifying {
    func postFinished(_ notice: LongTurnWatch.Notice) {
        let center = UNUserNotificationCenter.current()
        // Sphyrna's only category; setting it again replaces it with itself.
        let open = UNNotificationAction(identifier: LongTurnWatch.openActionIdentifier, title: LongTurnWatch.openActionTitle,
                                        options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: LongTurnWatch.categoryIdentifier, actions: [open],
                                                                 intentIdentifiers: [])])
        let content = UNMutableNotificationContent()
        content.title = notice.title
        if let subtitle = notice.subtitle { content.subtitle = subtitle }
        content.categoryIdentifier = LongTurnWatch.categoryIdentifier
        content.interruptionLevel = .active
        center.add(UNNotificationRequest(identifier: notice.id.uuidString, content: content, trigger: nil)) { error in
            if let error { LoomLog.error(.lifecycle, "A long-turn banner could not be posted (\(LoomLog.category(of: error)))") }
        }
    }
}

/// Needs-approval banners (D-49, D-52) and the opt-in long-turn banners. It hears the set of sessions at Needs approval whenever
/// the menu bar summary changes, asks `ApprovalNotificationPlanner` what to post and what to take back, asks `LongTurnWatch` which
/// long turns just finished, and carries that out through a `NotificationService`. It keeps no timer.
@MainActor
final class ApprovalNotifier {
    private let model: CatalogModel
    private let service: any NotificationService
    private var approvals = Set<UUID>()
    private let longTurns = LongTurnWatch()
    /// Whether Loom is the active app; evidence replaces it.
    var isAppActive: () -> Bool = { NSApp.isActive }

    init(model: CatalogModel, service: any NotificationService) {
        self.model = model
        self.service = service
    }

    /// At launch: banners an earlier run left behind go, and the permission is asked for once when the
    /// setting is on and the system has not been asked yet.
    func start() {
        service.removeAll()
        Task {
            if model.notifyApprovals || model.integration.notifyLongTurns, await service.authorization() == .notDetermined {
                await requestAuthorization()
            }
            await refreshAuthorization()
        }
    }

    /// The set of sessions at Needs approval changed.
    func approvalsChanged(_ current: Set<UUID>) {
        let plan = ApprovalNotificationPlanner.plan(previous: approvals, current: current,
                                                    appIsActive: isAppActive(), enabled: model.notifyApprovals)
        approvals = current
        for id in plan.post {
            guard let session = model.titleAndProject(of: id) else { continue }
            service.post(id: id, title: session.title, body: ApprovalNotificationPlanner.body(
                project: session.project, kind: model.firstWaitingRequestKind(of: id), harness: model.harnessName(of: id)))
        }
        if !plan.remove.isEmpty { service.remove(ids: plan.remove) }
    }

    /// A menu bar change: a long turn that just finished off screen gets its banner when the switch is on.
    func turnsChanged() {
        let notices = longTurns.finishedTurns(in: model, appIsActive: isAppActive())
        guard !notices.isEmpty, let poster = service as? any FinishedTurnNotifying else { return }
        for notice in notices { poster.postFinished(notice) }
    }

    /// Settings → Notify when a long turn finishes: on asks for permission once.
    func longTurnPreferenceChanged() {
        guard model.integration.notifyLongTurns else { return }
        Task {
            if await service.authorization() == .notDetermined { await requestAuthorization() }
            await refreshAuthorization()
        }
    }

    /// Settings → Notify switch. Off takes every banner back; on asks for permission once.
    func preferenceChanged() {
        if !model.notifyApprovals {
            service.removeAll()
        } else {
            Task {
                if await service.authorization() == .notDetermined { await requestAuthorization() }
                await refreshAuthorization()
            }
        }
    }

    func refreshAuthorization() async {
        model.integration.update(notifications: await service.authorization())
    }

    private func requestAuthorization() async {
        model.integration.update(notifications: await service.requestAuthorization())
    }

    /// At quit: nothing of Loom's stays in Notification Center.
    func stop() { service.removeAll() }
}
