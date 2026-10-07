import Foundation
import Observation
import Testing
import LoomCore
@testable import LoomCatalogUI

/// U5: the relative-time tick, the persisted window frame, and the start busy state
/// (the busy state against a delayed toolchain is in `ConversationControllerTests`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DailyUsePolishTests {
    final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        func read() -> Date { lock.withLock { date } }
        func set(_ value: Date) { lock.withLock { date = value } }
    }

    /// Stands in for "sleep until": records each requested date, waits until released,
    /// and ends with `CancellationError` when the ticking task is cancelled.
    final class TickGate: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: CheckedContinuation<Void, any Error>?
        private var cancelledFlag = false
        private var dates: [Date] = []
        var requested: [Date] { lock.withLock { dates } }
        var cancelled: Bool { lock.withLock { cancelledFlag } }

        func sleep(until date: Date) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let wasCancelled = lock.withLock { () -> Bool in
                        dates.append(date)
                        if cancelledFlag { return true }
                        pending = continuation
                        return false
                    }
                    if wasCancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                    cancelledFlag = true
                    defer { pending = nil }
                    return pending
                }
                continuation?.resume(throwing: CancellationError())
            }
        }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                defer { pending = nil }
                return pending
            }
            continuation?.resume()
        }
    }

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func makeModel(preferencesAt url: URL? = nil) -> (CatalogModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-polish-\(UUID())")
        let file = url ?? root.appendingPathComponent("ui-preferences.json")
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: UIPreferencesStore(url: file))
        return (model, root)
    }

    private func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day,
                                                   hour: hour, minute: minute, second: second))!
    }

    // MARK: Item 1: the tick

    @Test func nowTicksOncePerMinuteOnlyWhileTheWindowIsActive() async throws {
        let (model, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ClockBox(local(6, 10, 10, 0, 30))
        let gate = TickGate()
        model.currentDate = clock.read
        model.sleepUntil = { try await gate.sleep(until: $0) }

        // Hidden or inactive: no timer at all.
        try await Task.sleep(for: .milliseconds(60))
        #expect(gate.requested.isEmpty)

        model.setWindowActive(true)
        #expect(await waitUntil { gate.requested.count == 1 })
        #expect(gate.requested == [local(6, 10, 10, 1)], "aligned to the next minute boundary")
        #expect(model.now == local(6, 10, 10, 0, 30), "activation catches up once; the tick has not fired yet")

        clock.set(local(6, 10, 10, 1))
        gate.release()
        #expect(await waitUntil { gate.requested.count == 2 })
        #expect(model.now == local(6, 10, 10, 1))
        #expect(gate.requested.last == local(6, 10, 10, 2))

        // Nothing is written between ticks, however long the wait.
        let flag = ChangeFlag()
        withObservationTracking { _ = model.now } onChange: { flag.raise() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(flag.isRaised == false)

        // Deactivation cancels the timer; later minutes change nothing.
        model.setWindowActive(false)
        #expect(await waitUntil { gate.cancelled })
        clock.set(local(6, 10, 10, 2))
        gate.release()
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.now == local(6, 10, 10, 1))
        #expect(gate.requested.count == 2)

        // Activating again catches up at once and restarts the aligned tick.
        let reactivated = TickGate()
        model.sleepUntil = { try await reactivated.sleep(until: $0) }
        clock.set(local(6, 10, 10, 2, 20))
        model.setWindowActive(true)
        #expect(model.now == local(6, 10, 10, 2, 20))
        #expect(await waitUntil { reactivated.requested == [local(6, 10, 10, 3)] })
        model.stop()
        #expect(await waitUntil { reactivated.cancelled }, "stopping the model ends the tick")
    }

    final class ChangeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    @Test func midnightRegroupsTheDayHeadings() async throws {
        let (model, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let calendar = Calendar.current
        let clock = ClockBox(local(6, 10, 23, 59, 30))
        let gate = TickGate()
        model.currentDate = clock.read
        model.sleepUntil = { try await gate.sleep(until: $0) }
        model.setWindowActive(true)
        #expect(await waitUntil { gate.requested.count == 1 })
        #expect(gate.requested == [local(6, 11, 0, 0)])

        let usedYesterdayEvening = calendar.startOfDay(for: local(6, 10, 22, 0))
        #expect(DayGrouping.title(for: usedYesterdayEvening, now: model.now, calendar: calendar) == "Today")
        clock.set(local(6, 11, 0, 0))
        gate.release()
        #expect(await waitUntil { model.now == local(6, 11, 0, 0) })
        #expect(DayGrouping.title(for: usedYesterdayEvening, now: model.now, calendar: calendar) == "Yesterday")
        model.stop()
    }

    // MARK: Item 2: the window frame

    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1079)

    @Test func aSavedFrameThatFitsAScreenIsRestored() {
        let frame = WindowFrame(x: 120, y: 80, width: 1000, height: 700)
        #expect(frame.restorable(onScreens: [screen]) == frame.rect)
        let onSecond = WindowFrame(x: 2000, y: 100, width: 900, height: 600)
        let second = CGRect(x: 1728, y: 0, width: 1920, height: 1080)
        #expect(onSecond.restorable(onScreens: [screen, second]) == onSecond.rect)
    }

    @Test func aSavedFrameThatNoLongerFitsAnyScreenFallsBackToTheDefault() {
        // The screen it was on is gone.
        #expect(WindowFrame(x: 2000, y: 100, width: 900, height: 600).restorable(onScreens: [screen]) == nil)
        // Mostly off screen.
        #expect(WindowFrame(x: 1500, y: 100, width: 900, height: 600).restorable(onScreens: [screen]) == nil)
        // Title bar above the visible area.
        #expect(WindowFrame(x: 100, y: 900, width: 900, height: 600).restorable(onScreens: [screen]) == nil)
        // Smaller than the minimum window, or not a number.
        #expect(WindowFrame(x: 100, y: 100, width: 500, height: 300).restorable(onScreens: [screen]) == nil)
        #expect(WindowFrame(x: .nan, y: 100, width: 900, height: 600).restorable(onScreens: [screen]) == nil)
        #expect(WindowFrame(x: 100, y: 100, width: 900, height: 600).restorable(onScreens: []) == nil)
    }

    @Test func theFrameIsSavedInThePreferencesFileAfterTheDebounceAndAtFlush() async throws {
        let (model, root) = makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("ui-preferences.json")
        model.preferenceWriteDelay = .milliseconds(30)
        #expect(model.preferencesSnapshot.windowFrame == nil)

        // A burst of moves writes once, after the burst.
        for step in 0..<20 { model.setWindowFrame(CGRect(x: 100 + step, y: 100, width: 1000, height: 700)) }
        #expect(!FileManager.default.fileExists(atPath: url.path), "nothing is written per move")
        await model.settle()
        let saved = UIPreferencesStore(url: url)
        #expect(saved.current.windowFrame == WindowFrame(x: 119, y: 100, width: 1000, height: 700))

        // The same frame again writes nothing; a pending change is written at flush (Quit).
        model.setWindowFrame(CGRect(x: 119, y: 100, width: 1000, height: 700))
        await model.settle()
        model.preferenceWriteDelay = .seconds(30)
        model.setWindowFrame(CGRect(x: 300, y: 120, width: 1100, height: 720))
        model.flushPreferences()
        #expect(UIPreferencesStore(url: url).current.windowFrame == WindowFrame(x: 300, y: 120, width: 1100, height: 720))
    }

    @Test func aMissingOrUnreadableFrameDecodesToNoFrame() throws {
        let none = try JSONDecoder().decode(UIPreferences.self, from: Data("{}".utf8))
        #expect(none.windowFrame == nil)
        let broken = try JSONDecoder().decode(UIPreferences.self, from: Data(#"{"windowFrame":{"x":"a"}}"#.utf8))
        #expect(broken.windowFrame == nil)
        let tiny = try JSONDecoder().decode(
            UIPreferences.self, from: Data(#"{"windowFrame":{"x":1,"y":1,"width":10,"height":10}}"#.utf8))
        #expect(tiny.windowFrame == nil)
    }
}
