import AppKit
import LoomCatalogUI
import LoomCore
import UserNotifications

/// The long-turn banner (opt-in): a title, the project as its subtitle, no sound, and one Open action. The session id is the
/// request identifier, so Open and a click on the banner both reach `NotificationService.onActivate`.
@MainActor
protocol FinishedTurnNotifying: AnyObject {
    func postFinished(_ notice: LongTurnWatch.Notice)
    func cancelQueuedFinished()
}

extension FinishedTurnNotifying {
    func cancelQueuedFinished() {}
}

extension UserNotificationService: FinishedTurnNotifying {
    func postFinished(_ notice: LongTurnWatch.Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        if let subtitle = notice.subtitle { content.subtitle = subtitle }
        content.categoryIdentifier = LongTurnWatch.categoryIdentifier
        content.interruptionLevel = .active
        let generation = finishedGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.registerNotificationCategories()
            guard self.finishedGeneration == generation else { return }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id.uuidString, content: content, trigger: nil)) { error in
                if let error { LoomLog.error(.lifecycle, "A long-turn banner could not be posted (\(LoomLog.category(of: error)))") }
            }
        }
    }

    func cancelQueuedFinished() { finishedGeneration &+= 1 }
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
    private var resetAccountRevision: UInt64 = 0
    let resetNotifier: LimitResetNotifier?
    /// Whether Loom is the active app; evidence replaces it.
    var isAppActive: () -> Bool = { NSApp.isActive }

    init(model: CatalogModel, service: any NotificationService) {
        self.model = model
        self.service = service
        if let scheduler = service as? any LimitResetScheduling {
            resetNotifier = LimitResetNotifier(scheduler: scheduler) { [weak service] id in service?.onActivate?(id) }
        } else {
            resetNotifier = nil
        }
    }

    /// At launch: banners an earlier run left behind go, and the permission is asked for once when the
    /// setting is on and the system has not been asked yet.
    func start() {
        service.removeAll()
        resetNotifier?.setEnabled(model.integration.notifyLimitResets)
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
        guard model.integration.notifyLongTurns else {
            (service as? any FinishedTurnNotifying)?.cancelQueuedFinished()
            return
        }
        Task {
            if await service.authorization() == .notDetermined { await requestAuthorization() }
            await refreshAuthorization()
        }
    }

    /// The owner wires a typed signal only after the authenticated hook and bounded transcript read agree.
    func verifiedLimitReached(_ signal: ClaudeLimitResetSignal) {
        guard let resetNotifier, let reading = model.usage?.readings[.claude] else { return }
        let authorization = model.integration.notificationAuthorization
        let revision = resetAccountRevision
        Task { [weak self] in
            guard let self, self.resetAccountRevision == revision, self.model.usage?.readings[.claude] == reading,
                  self.model.integration.notifyLimitResets else { return }
            await resetNotifier.receive(signal, reading: reading, accountRevision: revision,
                                        authorization: authorization, now: Date())
        }
    }

    func limitReadingChanged(previous: HarnessReading?, current: HarnessReading?) {
        if let before = previous?.account, let after = current?.account, before != after {
            resetAccountRevision &+= 1
            resetNotifier?.accountChanged()
        }
        resetNotifier?.readingChanged(current, now: Date())
    }

    func limitResetPreferenceChanged() { resetNotifier?.setEnabled(model.integration.notifyLimitResets) }

    func sessionDeleted(_ id: UUID) { resetNotifier?.sessionDeleted(id) }

    /// Settings → Notify switch. Off takes every banner back; on asks for permission once.
    func preferenceChanged() {
        if !model.notifyApprovals {
            service.remove(ids: Array(approvals))
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
    func stop() {
        (service as? any FinishedTurnNotifying)?.cancelQueuedFinished()
        resetNotifier?.setEnabled(false)
        service.removeAll()
    }
}
