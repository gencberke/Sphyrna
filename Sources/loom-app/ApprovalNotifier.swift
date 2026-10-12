import AppKit
import LoomCatalogUI

/// Needs-approval banners (D-49, D-52). It hears the set of sessions at Needs approval whenever the menu
/// bar summary changes, asks `ApprovalNotificationPlanner` what to post and what to take back, and
/// carries that out through a `NotificationService`. It keeps no timer.
@MainActor
final class ApprovalNotifier {
    private let model: CatalogModel
    private let service: any NotificationService
    private var approvals = Set<UUID>()
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
            if model.notifyApprovals, await service.authorization() == .notDetermined { await requestAuthorization() }
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
            service.post(id: id, title: session.title, body: ApprovalNotificationPlanner.body(project: session.project))
        }
        if !plan.remove.isEmpty { service.remove(ids: plan.remove) }
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
