import Foundation
import Testing
@testable import SwiftTerm

private final class FrameDeliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [FrameDriverSignal.Sink] = []

    func enqueue(_ sink: @escaping FrameDriverSignal.Sink) {
        lock.withLock { pending.append(sink) }
    }

    var count: Int { lock.withLock { pending.count } }

    @MainActor func drain() {
        while let sink = lock.withLock({ pending.isEmpty ? nil : pending.removeFirst() }) {
            sink()
        }
    }
}

@MainActor
@Suite(.serialized)
struct FrameDriverTests {
    @Test func runningDirtyWorkWaitsForCadenceAndParkedWorkWakes() {
        let deliveries = FrameDeliveries()
        let signal = FrameDriverSignal { deliveries.enqueue($0) }
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source, signal: signal)
        var frames = 0
        driver.onTick = { frames += 1 }
        driver.markDirty()
        #expect(deliveries.count == 1)
        deliveries.drain()
        #expect(source.isRunning)
        #expect(frames == 1)

        for _ in 0..<100 { driver.markDirty() }
        #expect(deliveries.count == 0)
        #expect(frames == 1)
        source.tick()
        #expect(frames == 2)
        for _ in 0..<FrameDriver.idleTickLimit { source.tick() }
        #expect(!source.isRunning)
        driver.nowUptimeNs = { UInt64.max / 2 }
        driver.markDirty()
        #expect(deliveries.count == 1)
        deliveries.drain()
        #expect(source.isRunning)
        #expect(frames == 3)
        driver.shutdown()
        deliveries.drain()
    }

    @Test func dirtyPublicationBetweenLastConsumptionAndPauseIsDelivered() {
        let deliveries = FrameDeliveries()
        let signal = FrameDriverSignal { deliveries.enqueue($0) }
        var consumed: FrameDriverSignal.Events = []
        signal.configure { [weak signal] in
            if let signal { consumed.formUnion(signal.takePendingEvents()) }
        }
        signal.setCadenceActive(true)
        #expect(signal.takePendingEvents().isEmpty)
        signal.markDirty()
        #expect(deliveries.count == 0)
        signal.setCadenceActive(false)
        #expect(deliveries.count == 1)
        deliveries.drain()
        #expect(consumed == [.dirty])
        signal.markDirty()
        #expect(deliveries.count == 1)
        deliveries.drain()
    }

    @Test func hiddenShowImmediateDisplayTickAndShutdownKeepTheirDelivery() {
        let deliveries = FrameDeliveries()
        let signal = FrameDriverSignal { deliveries.enqueue($0) }
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source, signal: signal)
        var frames = 0
        driver.onTick = { frames += 1 }
        driver.markDirty()
        deliveries.drain()
        driver.markDirty()
        driver.setVisibilityOnMain(visible: false)
        #expect(!source.isRunning)
        #expect(deliveries.count == 0)
        #expect(frames == 1)
        driver.nowUptimeNs = { UInt64.max / 2 }
        driver.setVisibilityOnMain(visible: true)
        #expect(source.isRunning)
        #expect(frames == 2)
        driver.requestImmediateTick()
        #expect(deliveries.count == 1)
        deliveries.drain()
        #expect(frames == 3)
        driver.markDirty()
        signal.publishDisplayLinkTick()
        #expect(deliveries.count == 1)
        deliveries.drain()
        #expect(frames == 4)
        driver.markDirty()
        signal.requestShutdown()
        #expect(deliveries.count == 1)
        deliveries.drain()
        #expect(!source.isRunning)
        driver.markDirty()
        #expect(deliveries.count == 0)
        source.tick()
        #expect(frames == 4)
    }

    @Test func detachReattachAndDirtyDuringFrameKeepPendingWork() {
        let deliveries = FrameDeliveries()
        let signal = FrameDriverSignal { deliveries.enqueue($0) }
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source, signal: signal)
        var frames = 0
        driver.onTick = {
            frames += 1
            if frames == 1 { driver.markDirty() }
        }
        driver.markDirty()
        deliveries.drain()
        #expect(frames == 1)
        #expect(deliveries.count == 0)
        source.tick()
        #expect(frames == 2)
        driver.setWindowAttachedOnMain(false)
        driver.markDirty()
        deliveries.drain()
        #expect(!source.isRunning)
        #expect(frames == 2)
        driver.nowUptimeNs = { UInt64.max / 2 }
        driver.setWindowAttachedOnMain(true)
        #expect(source.isRunning)
        #expect(frames == 3)
        driver.shutdown()
        deliveries.drain()
    }

    @Test func suspendedDirtyEventsAreRetainedWithoutMainActorWork() {
        let deliveries = FrameDeliveries()
        let signal = FrameDriverSignal { deliveries.enqueue($0) }
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source, signal: signal)
        var frames = 0
        driver.onTick = { frames += 1 }
        driver.markDirty()
        deliveries.drain()
        #expect(frames == 1)

        driver.setVisibilityOnMain(visible: false)
        for _ in 0..<1_000 { driver.markDirty() }
        #expect(deliveries.count == 0)
        #expect(!source.isRunning)
        #expect(frames == 1)

        driver.nowUptimeNs = { UInt64.max / 2 }
        driver.setVisibilityOnMain(visible: true)
        #expect(deliveries.count == 0)
        #expect(frames == 2)
        #expect(source.isRunning)
        source.tick()
        #expect(frames == 2)
        driver.shutdown()
        deliveries.drain()
    }

    @Test func suspendedImmediateAndShutdownEventsStillDeliver() {
        let deliveries = FrameDeliveries()
        let signal = FrameDriverSignal { deliveries.enqueue($0) }
        let source = ManualTickSource()
        let driver = FrameDriver(tickSource: source, signal: signal)
        var frames = 0
        driver.onTick = { frames += 1 }
        driver.setVisibilityOnMain(visible: false)
        driver.markDirty()
        driver.requestImmediateTick()
        #expect(deliveries.count == 1)
        deliveries.drain()
        #expect(frames == 1)
        driver.markDirty()
        signal.requestShutdown()
        #expect(deliveries.count == 1)
        deliveries.drain()
        #expect(!source.isRunning)
    }
}
