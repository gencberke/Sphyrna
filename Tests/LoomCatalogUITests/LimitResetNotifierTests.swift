import AppKit
import Foundation
import SwiftUI
import Testing
import Synchronization
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

@MainActor
@Suite struct LimitResetNotifierTests {
    private let now = Date(timeIntervalSince1970: 1_791_600_000)

    private final class Scheduler: LimitResetScheduling {
        var scheduled: [LimitResetNotice] = []
        var cancelled: [String] = []
        var allCancelled = 0
        func scheduleReset(_ notice: LimitResetNotice) async -> Bool { scheduled.append(notice); return true }
        func cancelResets(_ identifiers: [String]) { cancelled.append(contentsOf: identifiers) }
        func cancelAllResets() { allCancelled += 1 }
    }

    private final class SlowScheduler: LimitResetScheduling {
        var pending: CheckedContinuation<Bool, Never>?
        var added: LimitResetNotice?
        var cancelled: [String] = []
        func scheduleReset(_ notice: LimitResetNotice) async -> Bool {
            added = notice
            return await withCheckedContinuation { pending = $0 }
        }
        func cancelResets(_ identifiers: [String]) { cancelled.append(contentsOf: identifiers) }
        func cancelAllResets() {}
    }

    private final class ReplacingScheduler: LimitResetScheduling {
        var notices: [LimitResetNotice] = []
        var pending: [String: CheckedContinuation<Bool, Never>] = [:]
        var cancelled: [String] = []
        func scheduleReset(_ notice: LimitResetNotice) async -> Bool {
            notices.append(notice)
            return await withCheckedContinuation { pending[notice.identifier] = $0 }
        }
        func cancelResets(_ identifiers: [String]) { cancelled.append(contentsOf: identifiers) }
        func cancelAllResets() {}
    }

    private func signal(id: UUID, reset: Date) -> ClaudeLimitResetSignal {
        ClaudeLimitResetSignal(sessionID: id, nativeSessionID: UUID().uuidString, runID: UUID(), promptID: UUID(),
                               windowID: "five_hour", resetsAt: reset)
    }

    private func reading(reset: Date, account: HarnessAccount? = .subscription(email: "person@example.invalid", plan: "max")) -> HarnessReading {
        HarnessReading(provider: .claude, account: account, windows: [HarnessLimitWindow(id: "five_hour", name: "5-hour",
            durationMinutes: 300, usedPercent: 100, resetsAt: reset)], readAt: now)
    }

    @Test func aRevokedObservationCannotSurviveAsynchronousScheduling() async throws {
        let scheduler = SlowScheduler(), validity = Mutex(true)
        var opened: [UUID] = []
        let notifier = LimitResetNotifier(scheduler: scheduler) { opened.append($0) }
        notifier.setEnabled(true)
        let reset = now.addingTimeInterval(3_600)
        let signal = signal(id: UUID(), reset: reset), reading = reading(reset: reset)
        let pending = Task { await notifier.receive(signal, reading: reading, accountRevision: 1,
            authorization: .authorized, now: now, isCurrent: { validity.withLock { $0 } }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while scheduler.pending == nil, ContinuousClock.now < deadline { await Task.yield() }
        let notice = try #require(scheduler.added)
        validity.withLock { $0 = false }
        scheduler.pending?.resume(returning: true)
        await pending.value
        #expect(scheduler.cancelled.contains(notice.identifier))
        notifier.activate(identifier: notice.identifier)
        #expect(opened.isEmpty)
    }

    @Test func resetPreferenceDefaultsOffAndSurvivesRelaunchWithoutChangingOtherPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-reset-pref-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("preferences.json"))
        let integration = SystemIntegration()
        integration.attach(preferences: preferences)
        #expect(!integration.notifyLimitResets && !integration.notifyLongTurns)
        var changes = 0
        integration.onNotifyLimitResetsChange = { changes += 1 }
        integration.setNotifyLimitResets(true)
        integration.setNotifyLimitResets(true)
        let relaunched = SystemIntegration()
        relaunched.attach(preferences: UIPreferencesStore(url: preferences.url))
        #expect(changes == 1 && relaunched.notifyLimitResets && !relaunched.notifyLongTurns)
    }

    @Test func actualSettingsSwitchPersistsAndExplainsItsRunningAppBoundary() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-reset-settings-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = UIPreferencesStore(url: root.appendingPathComponent("preferences.json"))
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: preferences)
        model.integration.attach(preferences: preferences)
        let host = NSHostingController(rootView: SystemSettingsCard(model: model, integration: model.integration)
            .frame(width: 650, height: 900))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 650, height: 900))
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let elements = accessibilityElements(in: host.view)
        let toggle = try #require(elements.first { InkAX.label($0) == "Notify when a limit resets" })
        #expect(elements.contains { (InkAX.value($0) ?? InkAX.label($0)).contains("Sphyrna must be running") })
        #expect(!model.integration.notifyLimitResets)
        #expect(toggle.accessibilityPerformPress?() == true)
        #expect(model.integration.notifyLimitResets && preferences.current.notifyLimitResets)
        #expect(model.integration.notificationAuthorization == .notDetermined)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func explicitMatchingSignalSchedulesOnceAndContinueSelectsItsSession() async throws {
        let scheduler = Scheduler(), id = UUID(), reset = now.addingTimeInterval(3_600)
        var continued: [UUID] = []
        let notifier = LimitResetNotifier(scheduler: scheduler) { continued.append($0) }
        let signal = signal(id: id, reset: reset)
        await notifier.receive(signal, reading: reading(reset: reset), accountRevision: 1, authorization: .authorized, now: now)
        #expect(scheduler.scheduled.isEmpty, "the setting starts off")
        notifier.setEnabled(true)
        await notifier.receive(signal, reading: reading(reset: reset), accountRevision: 1, authorization: .notDetermined, now: now)
        #expect(scheduler.scheduled.isEmpty, "a reset notice does not request a notification grant")
        await notifier.receive(signal, reading: reading(reset: reset), accountRevision: 1, authorization: .authorized, now: now)
        await notifier.receive(signal, reading: reading(reset: reset), accountRevision: 1, authorization: .authorized, now: now)
        let notice = try #require(scheduler.scheduled.first)
        #expect(scheduler.scheduled.count == 1 && notice.sessionID == id && notice.resetsAt == reset)
        #expect(notice.windowName == "5-hour")
        notifier.activate(identifier: "unrelated")
        notifier.activate(identifier: notice.identifier)
        #expect(continued == [id])
    }

    @Test func mismatchedWindowsAndUnknownAccountNeverSchedule() async {
        let scheduler = Scheduler(), id = UUID(), reset = now.addingTimeInterval(3_600)
        let notifier = LimitResetNotifier(scheduler: scheduler) { _ in }
        notifier.setEnabled(true)
        await notifier.receive(signal(id: id, reset: reset), reading: reading(reset: reset.addingTimeInterval(600)),
                               accountRevision: 1, authorization: .authorized, now: now)
        await notifier.receive(signal(id: id, reset: reset), reading: reading(reset: reset, account: nil),
                               accountRevision: 1, authorization: .authorized, now: now)
        await notifier.receive(signal(id: id, reset: reset),
                               reading: reading(reset: reset, account: .subscription(email: nil, plan: "max")),
                               accountRevision: 1, authorization: .authorized, now: now)
        await notifier.receive(signal(id: id, reset: now), reading: reading(reset: now),
                               accountRevision: 1, authorization: .authorized, now: now)
        #expect(scheduler.scheduled.isEmpty)
    }

    @Test func obsoleteResetAccountDeletionAndDisablingCancelPendingNotices() async throws {
        let scheduler = Scheduler(), first = UUID(), second = UUID(), reset = now.addingTimeInterval(3_600)
        var continued: [UUID] = []
        let notifier = LimitResetNotifier(scheduler: scheduler) { continued.append($0) }
        notifier.setEnabled(true)
        await notifier.receive(signal(id: first, reset: reset), reading: reading(reset: reset),
                               accountRevision: 1, authorization: .authorized, now: now)
        let old = try #require(scheduler.scheduled.last)
        notifier.readingChanged(reading(reset: reset.addingTimeInterval(300)), now: now)
        #expect(scheduler.cancelled.contains(old.identifier))
        await notifier.receive(signal(id: first, reset: reset), reading: reading(reset: reset),
                               accountRevision: 1, authorization: .authorized, now: now)
        let replacement = try #require(scheduler.scheduled.last)
        notifier.sessionDeleted(first)
        #expect(replacement.identifier != old.identifier && scheduler.cancelled.contains(replacement.identifier))
        notifier.activate(identifier: replacement.identifier)
        #expect(continued.isEmpty, "a late click after deletion cannot select the deleted session")
        await notifier.receive(signal(id: second, reset: reset), reading: reading(reset: reset),
                               accountRevision: 1, authorization: .authorized, now: now)
        let other = try #require(scheduler.scheduled.last)
        notifier.accountChanged()
        #expect(scheduler.allCancelled >= 1)
        notifier.activate(identifier: other.identifier)
        #expect(continued.isEmpty, "a late click after account change cannot reopen a stale notice")
        notifier.setEnabled(false)
        #expect(scheduler.allCancelled >= 2)
    }

    @Test func disablingWhileTheSystemSchedulesCannotLeaveAnOldNoticeBehind() async throws {
        let scheduler = SlowScheduler(), id = UUID(), reset = now.addingTimeInterval(3_600)
        let notifier = LimitResetNotifier(scheduler: scheduler) { _ in }
        notifier.setEnabled(true)
        let event = signal(id: id, reset: reset), snapshot = reading(reset: reset), timestamp = now
        let task = Task { await notifier.receive(event, reading: snapshot, accountRevision: 1,
                                                  authorization: .authorized, now: timestamp) }
        for _ in 0..<100 where scheduler.pending == nil { await Task.yield() }
        let notice = try #require(scheduler.added)
        let pending = try #require(scheduler.pending)
        notifier.setEnabled(false)
        pending.resume(returning: true)
        await task.value
        #expect(scheduler.cancelled.contains(notice.identifier))
    }

    @Test func anOldSchedulingCompletionCannotCancelAReplacement() async throws {
        let scheduler = ReplacingScheduler(), id = UUID(), reset = now.addingTimeInterval(3_600)
        var continued: [UUID] = []
        let notifier = LimitResetNotifier(scheduler: scheduler) { continued.append($0) }
        notifier.setEnabled(true)
        let event = signal(id: id, reset: reset), snapshot = reading(reset: reset), timestamp = now
        let first = Task { await notifier.receive(event, reading: snapshot, accountRevision: 1,
                                                   authorization: .authorized, now: timestamp) }
        for _ in 0..<100 where scheduler.notices.count < 1 { await Task.yield() }
        let old = try #require(scheduler.notices.first)
        notifier.setEnabled(false)
        notifier.setEnabled(true)
        let second = Task { await notifier.receive(event, reading: snapshot, accountRevision: 1,
                                                    authorization: .authorized, now: timestamp) }
        for _ in 0..<100 where scheduler.notices.count < 2 { await Task.yield() }
        let replacement = try #require(scheduler.notices.last)
        #expect(old.identifier != replacement.identifier)
        let newCompletion = try #require(scheduler.pending[replacement.identifier])
        let oldCompletion = try #require(scheduler.pending[old.identifier])
        newCompletion.resume(returning: true)
        await second.value
        oldCompletion.resume(returning: true)
        await first.value
        #expect(scheduler.cancelled.contains(old.identifier) && !scheduler.cancelled.contains(replacement.identifier))
        notifier.activate(identifier: replacement.identifier)
        #expect(continued == [id])
    }

    @Test func expiredNoticesCannotExhaustTheBoundedPendingSet() async {
        let scheduler = Scheduler(), reset = now.addingTimeInterval(3_600)
        let notifier = LimitResetNotifier(scheduler: scheduler) { _ in }
        notifier.setEnabled(true)
        for _ in 0..<128 {
            await notifier.receive(signal(id: UUID(), reset: reset), reading: reading(reset: reset),
                                   accountRevision: 1, authorization: .authorized, now: now)
        }
        #expect(scheduler.scheduled.count == 128)
        let later = reset.addingTimeInterval(1), nextReset = later.addingTimeInterval(3_600)
        await notifier.receive(signal(id: UUID(), reset: nextReset), reading: reading(reset: nextReset),
                               accountRevision: 1, authorization: .authorized, now: later)
        #expect(scheduler.scheduled.count == 129, "expired entries must not block a new notification")
    }

    @Test func anObservedAccountSwitchCancelsThePendingReset() async throws {
        let scheduler = Scheduler(), reset = now.addingTimeInterval(3_600), id = UUID()
        let notifier = LimitResetNotifier(scheduler: scheduler) { _ in }
        notifier.setEnabled(true)
        let first = reading(reset: reset)
        let second = reading(reset: reset, account: .subscription(email: "other@example.invalid", plan: "max"))
        let source = UsageHarnessTests.Scripted([
            HarnessProbeAnswer(account: first.account, windows: first.windows),
            HarnessProbeAnswer(account: second.account, windows: second.windows),
        ])
        let connections = HarnessConnections()
        let clock = TestClock(now)
        let probe = HarnessProbe(connections: connections, sources: [.claude: source], clock: { clock.now })
        let usage = UsageModel(index: FakeUsageIndex(), clock: { clock.now })
        usage.attachHarness(probe: probe, connections: connections)
        let timestamp = now
        usage.onClaudeReadingChange = { old, new in
            if let before = old?.account, let after = new?.account, before != after { notifier.accountChanged() }
            notifier.readingChanged(new, now: timestamp)
        }
        await usage.checkStatusLimits(of: .claude)
        let current = try #require(usage.readings[.claude])
        await notifier.receive(signal(id: id, reset: reset), reading: current, accountRevision: 1,
                               authorization: .authorized, now: now)
        #expect(scheduler.scheduled.count == 1)
        await usage.checkStatusLimits(of: .claude)
        #expect(usage.readings[.claude]?.account == second.account && scheduler.allCancelled >= 1)
        #expect(source.asks == 2)
    }

    @Test func aNewUnknownAccountRevisionCancelsEvenWhenItCannotSchedule() async {
        let scheduler = Scheduler(), id = UUID(), reset = now.addingTimeInterval(3_600)
        let notifier = LimitResetNotifier(scheduler: scheduler) { _ in }
        notifier.setEnabled(true)
        let event = signal(id: id, reset: reset)
        await notifier.receive(event, reading: reading(reset: reset), accountRevision: 1, authorization: .authorized, now: now)
        #expect(scheduler.scheduled.count == 1)
        await notifier.receive(event, reading: reading(reset: reset, account: nil), accountRevision: 2,
                               authorization: .authorized, now: now)
        #expect(scheduler.allCancelled >= 1 && scheduler.scheduled.count == 1)
    }
}
