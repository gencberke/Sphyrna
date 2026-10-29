import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

@MainActor
@Suite(.serialized)
struct SessionTaskStateTests {
    actor Source {
        enum ReadFailure: Error { case failed }
        struct Request: Sendable {
            let parent: UUID
            let after: UUID?
            let limit: Int
        }
        var values: [UUID: [SessionTaskProjection]] = [:]
        var requested: [Request] = []
        var order: [String] = []
        var events: [SessionTaskEvent] = []
        var eventsAsked: [UUID] = []
        var continuation: AsyncStream<UInt64>.Continuation?
        var gate: CheckedContinuation<Void, Never>?
        var isHeld = false
        var entered = false
        var eventGate: CheckedContinuation<Void, Never>?
        var holdingEvent = false
        var failEvent = false
        var enteredEvent = false
        var streamEnded = false

        func set(_ items: [SessionTaskProjection], parent: UUID) { values[parent] = items.sorted { $0.id.uuidString < $1.id.uuidString } }
        func setEvents(_ items: [SessionTaskEvent]) { events = items }
        func hold() { isHeld = true }
        func release() { gate?.resume(); gate = nil; isHeld = false }
        func snapshot() -> ([Request], [String], [UUID], Bool) { (requested, order, eventsAsked, entered) }
        func holdEvent(failing: Bool = false) { holdingEvent = true; failEvent = failing }
        func releaseEvent() { eventGate?.resume(); eventGate = nil; holdingEvent = false }
        func eventEntered() -> Bool { enteredEvent }
        func ended() -> Bool { streamEnded }
        func noteEnd() { streamEnded = true }
        func stream() -> AsyncStream<UInt64> {
            order.append("subscribe")
            let pair = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
            continuation = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in Task { await self?.noteEnd() } }
            return pair.stream
        }
        func page(_ parent: UUID, _ after: UUID?, _ limit: Int) async -> SessionTaskUIBridge.Page {
            requested.append(Request(parent: parent, after: after, limit: limit))
            order.append("page")
            if isHeld {
                entered = true
                await withCheckedContinuation { gate = $0 }
            }
            let items = values[parent, default: []].filter { after == nil || $0.id.uuidString > after!.uuidString }
            let page = Array(items.prefix(limit))
            return SessionTaskUIBridge.Page(items: page, next: items.count > limit ? page.last?.id : nil)
        }
        func latest(_ task: UUID, _ limit: Int) async throws -> [SessionTaskEvent] {
            eventsAsked.append(task)
            if holdingEvent {
                enteredEvent = true
                await withCheckedContinuation { eventGate = $0 }
            }
            if failEvent { throw ReadFailure.failed }
            return Array(events.suffix(limit))
        }
        func signal(_ value: UInt64) { continuation?.yield(value) }
    }

    private func bridge(_ source: Source) -> SessionTaskUIBridge {
        SessionTaskUIBridge(projections: { parent, after, limit in await source.page(parent, after, limit) },
                            updates: { await source.stream() }, latestEvents: { task, limit in try await source.latest(task, limit) })
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }

    private func task(parent: UUID, id: UUID, child: UUID? = nil) -> SessionTaskProjection {
        let binding = SessionTaskBinding(sessionID: parent, nativeSessionID: "native", managedRunID: UUID(), generation: UUID())
        return SessionTaskProjection(id: id, parentSessionID: parent, childSessionID: child ?? UUID(), harness: .codex,
            childName: "Reviewer", requestedChoices: HarnessLaunchChoices(harness: .codex, model: "gpt-example"),
            effectiveModel: nil, effectiveEffort: nil, effectiveMode: nil, parentBinding: binding, childBinding: nil,
            lifecycle: .active, expiresAt: Date(), childInputLimit: 3, parentWakeLimit: 6,
            childInputsUsed: 1, parentWakesUsed: 0, parentWakesConsumed: 0, uncertainChildEffects: 0,
            uncertainWakeEffects: 0, authorityEpoch: 0, activeRoundID: nil, pendingRoundID: nil,
            currentAttentionID: nil, nextOrdinal: 2, revision: 1)
    }

    private func wait(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func visibleParentsShareOneBoundAndResumeTheirExactCursor() async throws {
        let source = Source(), state = SessionTaskUIState()
        let parents = [uuid(1), uuid(2), uuid(3)]
        for (i, parent) in parents.enumerated() {
            await source.set((0..<50).map { task(parent: parent, id: uuid(1_000 + i * 100 + $0)) }, parent: parent)
        }
        state.configure(bridge(source))
        let pages = parents.map { state.acquire($0) }
        defer { for page in pages { state.release(page) } }
        #expect(await wait { pages.allSatisfy(\.didLoad) })
        #expect(pages.map(\.items.count) == [50, 50, 28])
        #expect(state.cachedTaskCount == 128 && state.activeParentCount == 3)
        let requests = await source.snapshot().0
        #expect(requests.map(\.limit) == [50, 50, 28])
        #expect(await source.snapshot().1.prefix(2) == ["subscribe", "page"])
        let cursor = try #require(pages[2].next)
        state.loadMore(pages[2])
        #expect(pages[2].limited && !pages[2].isLoading)
        state.release(pages[0])
        #expect(await wait { pages[2].items.count == 50 })
        #expect(await source.snapshot().0.last?.after == cursor)
        #expect(state.cachedTaskCount == 100 && pages[2].next == nil)
    }

    @Test func staleSourceCannotRestoreOldMetadataAfterReplacement() async throws {
        let old = Source(), fresh = Source(), state = SessionTaskUIState()
        let parent = UUID(), child = UUID(), id = UUID()
        var original = task(parent: parent, id: id, child: child)
        original.effectiveModel = "old"
        var updated = original
        updated.effectiveModel = "new"
        await old.set([original], parent: parent)
        await fresh.set([updated], parent: parent)
        await old.hold()
        state.configure(bridge(old))
        let page = state.acquire(parent)
        defer { state.release(page); Task { await old.release() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await old.snapshot().3) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await old.snapshot().3)
        let prior = state.sourceGeneration
        state.configure(bridge(fresh))
        #expect(state.sourceGeneration != prior && page.items.isEmpty)
        await old.release()
        #expect(await wait { page.items.first?.effectiveModel == "new" })
        #expect(page.items.first?.childSessionID == child)
        #expect(await fresh.snapshot().1.prefix(2) == ["subscribe", "page"])
    }

    @Test func onlyTheSelectedDetailReadsBoundedReportedEvents() async throws {
        let source = Source(), state = SessionTaskUIState(), id = UUID(), other = UUID(), round = UUID()
        let events = (0..<10).map { index in
            SessionTaskEvent(id: UUID(), taskID: id, roundID: round, nativeTurnID: nil, execution: nil,
                             kind: index == 9 ? .needsParentInput : .completed,
                             payload: index == 5 ? String(repeating: "x", count: 16_385) : "Report \(index)", occurredAt: Date())
        }
        await source.setEvents(events)
        state.configure(bridge(source))
        #expect(await source.snapshot().2.isEmpty)
        let read = await state.readEvents(for: id)
        guard case let .ready(batch) = read else { Issue.record("Events should be readable"); return }
        #expect(batch.events.count == 9 && batch.partial)
        #expect(batch.events.last?.kind == .needsParentInput)
        let asked = await source.snapshot().2
        #expect(asked == [id] && !asked.contains(other))
    }
    @Test func anOldEventReadCannotReappearAfterARevision() async throws {
        let source = Source(), state = SessionTaskUIState(), parent = UUID(), id = UUID()
        let event = SessionTaskEvent(id: UUID(), taskID: id, roundID: UUID(), nativeTurnID: nil, execution: nil,
                                     kind: .completed, payload: "Old result", occurredAt: Date())
        await source.setEvents([event])
        await source.holdEvent()
        state.configure(bridge(source))
        let page = state.acquire(parent)
        defer { state.release(page); Task { await source.releaseEvent() } }
        #expect(await wait { page.didLoad })
        let oldRevision = state.revision
        let pending = Task { await state.readEvents(for: id) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await source.eventEntered()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await source.eventEntered())
        await source.signal(1)
        #expect(await wait { state.revision != oldRevision })
        await source.releaseEvent()
        if case .unavailable = await pending.value {} else { Issue.record("A previous revision's report must not be returned") }
    }

    @Test func releasingTheStateCancelsItsUpdateStream() async throws {
        let source = Source()
        var state: SessionTaskUIState? = SessionTaskUIState()
        weak var weakState = state
        state?.configure(bridge(source))
        let page = try #require(state?.acquire(UUID()))
        #expect(await wait { page.didLoad })
        let deadline = ContinuousClock.now + .seconds(5)
        while (await source.snapshot().1).isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await source.snapshot().1.first == "subscribe")
        state = nil
        #expect(await wait { weakState == nil })
        let endedBy = ContinuousClock.now + .seconds(2)
        while !(await source.ended()) && ContinuousClock.now < endedBy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await source.ended(), "the update subscription must end with its UI owner")
    }

    @Test func visibleParentKeysAreBoundedEvenWithNoMetadata() {
        let state = SessionTaskUIState()
        let parents = (0...SessionTaskUIState.maximumParents).map { _ in state.acquire(UUID()) }
        #expect(state.activeParentCount == SessionTaskUIState.maximumParents)
        #expect(parents.last?.unavailable == true)
        for parent in parents { state.release(parent) }
        #expect(state.activeParentCount == 0)
    }

    @Test func aNewRoundKeepsTheSameChildAcrossObservedUpdates() async throws {
        let source = Source(), state = SessionTaskUIState(), parent = UUID(), id = UUID(), child = UUID()
        var first = task(parent: parent, id: id, child: child)
        first.activeRoundID = UUID()
        await source.set([first], parent: parent)
        state.configure(bridge(source))
        let page = state.acquire(parent)
        defer { state.release(page) }
        #expect(await wait { page.items.first?.activeRoundID == first.activeRoundID })
        var second = first
        second.activeRoundID = UUID()
        second.revision += 1
        await source.set([second], parent: parent)
        await source.signal(2)
        #expect(await wait { page.items.first?.activeRoundID == second.activeRoundID })
        #expect(page.items.first?.id == id && page.items.first?.childSessionID == child)
    }

    @Test func aFailedOldEventReadCannotAlterCurrentDetail() async throws {
        let source = Source(), state = SessionTaskUIState(), parent = UUID(), id = UUID()
        await source.holdEvent(failing: true)
        state.configure(bridge(source))
        let page = state.acquire(parent)
        defer { state.release(page); Task { await source.releaseEvent() } }
        #expect(await wait { page.didLoad })
        let oldRevision = state.revision
        let pending = Task { await state.readEvents(for: id) }
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await source.eventEntered()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await source.eventEntered())
        await source.signal(1)
        #expect(await wait { state.revision != oldRevision })
        await source.releaseEvent()
        if case .unavailable = await pending.value {} else { Issue.record("A previous revision's failure must not be returned") }
    }

}
