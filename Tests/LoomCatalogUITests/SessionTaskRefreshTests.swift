import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport

/// An update re-reads the shown task rows in place: the rows, their "Load more" pages and an open detail stay while the read
/// runs, and a parent picked up while the subscription is idle is read.
@MainActor
struct SessionTaskRefreshTests {
    actor Source {
        var values: [UUID: [SessionTaskProjection]] = [:]
        var requests = 0
        var continuation: AsyncStream<UInt64>.Continuation?
        var gate: CheckedContinuation<Void, Never>?
        var isHeld = false
        var entered = false
        var eventGate: CheckedContinuation<Void, Never>?
        var holdingEvent = false
        var enteredEvent = false

        func set(_ items: [SessionTaskProjection], parent: UUID) { values[parent] = items.sorted { $0.id.uuidString < $1.id.uuidString } }
        func hold() { isHeld = true; entered = false }
        func release() { gate?.resume(); gate = nil; isHeld = false }
        func heldInRead() -> Bool { entered }
        func requestCount() -> Int { requests }
        func holdEvent() { holdingEvent = true }
        func releaseEvent() { eventGate?.resume(); eventGate = nil; holdingEvent = false }
        func eventEntered() -> Bool { enteredEvent }
        func signal(_ value: UInt64) { continuation?.yield(value) }
        func stream() -> AsyncStream<UInt64> {
            let pair = AsyncStream<UInt64>.makeStream(bufferingPolicy: .bufferingNewest(1))
            continuation = pair.continuation
            return pair.stream
        }
        func page(_ parent: UUID, _ after: UUID?, _ limit: Int) async -> SessionTaskUIBridge.Page {
            requests += 1
            if isHeld {
                entered = true
                await withCheckedContinuation { gate = $0 }
            }
            let items = values[parent, default: []].filter { after == nil || $0.id.uuidString > after!.uuidString }
            let page = Array(items.prefix(limit))
            return SessionTaskUIBridge.Page(items: page, next: items.count > limit ? page.last?.id : nil)
        }
        func latest(_ task: UUID, _ limit: Int) async -> [SessionTaskEvent] {
            if holdingEvent {
                enteredEvent = true
                await withCheckedContinuation { eventGate = $0 }
            }
            return [SessionTaskEvent(id: UUID(), taskID: task, roundID: UUID(), nativeTurnID: nil, execution: nil,
                                     kind: .completed, payload: "Result", occurredAt: Date())]
        }
    }

    private func bridge(_ source: Source) -> SessionTaskUIBridge {
        SessionTaskUIBridge(projections: { parent, after, limit in await source.page(parent, after, limit) },
                            updates: { await source.stream() }, latestEvents: { task, limit in await source.latest(task, limit) })
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }

    private func task(parent: UUID, id: UUID, model: String? = nil, revision: Int64 = 1) -> SessionTaskProjection {
        let binding = SessionTaskBinding(sessionID: parent, nativeSessionID: "native", managedRunID: UUID(), generation: UUID())
        return SessionTaskProjection(id: id, parentSessionID: parent, childSessionID: id, harness: .codex,
            childName: "Reviewer", requestedChoices: HarnessLaunchChoices(harness: .codex, model: "gpt-example"),
            effectiveModel: model, effectiveEffort: nil, effectiveMode: nil, parentBinding: binding, childBinding: nil,
            lifecycle: .active, expiresAt: Date(timeIntervalSince1970: 0), childInputLimit: 3, parentWakeLimit: 6,
            childInputsUsed: 1, parentWakesUsed: 0, parentWakesConsumed: 0, uncertainChildEffects: 0,
            uncertainWakeEffects: 0, authorityEpoch: 0, activeRoundID: nil, pendingRoundID: nil,
            currentAttentionID: nil, nextOrdinal: 2, revision: revision)
    }

    @Test func rowsStayWhileAnUpdateIsRead() async throws {
        let source = Source(), state = SessionTaskUIState(), parent = uuid(1)
        let ids = [uuid(10), uuid(11)]
        await source.set(ids.map { task(parent: parent, id: $0) }, parent: parent)
        state.configure(bridge(source))
        let page = state.acquire(parent)
        defer { state.release(page); Task { await source.release() } }
        await waitFor("the first page") { page.didLoad && page.items.count == 2 }
        await source.set([task(parent: parent, id: ids[0], model: "new", revision: 2), task(parent: parent, id: ids[1])],
                         parent: parent)
        await source.hold()
        await source.signal(1)
        await waitFor("the update's read to start") { await source.heldInRead() }
        #expect(page.items.map(\.id) == ids && page.didLoad, "the rows stay while their update is read")
        await source.release()
        await waitFor("the updated row") { page.items.first?.effectiveModel == "new" }
        #expect(page.items.map(\.id) == ids)
    }

    @Test func anotherParentsUpdateKeepsThisParentsRows() async throws {
        let source = Source(), state = SessionTaskUIState(), first = uuid(1), second = uuid(2)
        let kept = task(parent: first, id: uuid(10))
        await source.set([kept], parent: first)
        await source.set([task(parent: second, id: uuid(20))], parent: second)
        state.configure(bridge(source))
        let pages = [state.acquire(first), state.acquire(second)]
        defer { for page in pages { state.release(page) }; Task { await source.release() } }
        await waitFor("both parents read") { pages.allSatisfy { $0.didLoad && $0.items.count == 1 } }
        await source.set([task(parent: second, id: uuid(20), model: "new", revision: 2)], parent: second)
        await source.hold()
        await source.signal(1)
        await waitFor("the update's read to start") { await source.heldInRead() }
        #expect(pages[0].items == [kept] && pages[1].items.count == 1, "neither parent's rows clear for the read")
        await source.release()
        await waitFor("the other parent's update") { pages[1].items.first?.effectiveModel == "new" }
        #expect(pages[0].items == [kept])
    }

    @Test func loadedMorePagesSurviveAnUpdate() async throws {
        let source = Source(), state = SessionTaskUIState(), parent = uuid(1)
        let ids = (0..<70).map { uuid(100 + $0) }
        await source.set(ids.map { task(parent: parent, id: $0) }, parent: parent)
        state.configure(bridge(source))
        let page = state.acquire(parent)
        defer { state.release(page) }
        await waitFor("the first page") { page.didLoad && page.items.count == 50 }
        state.loadMore(page)
        await waitFor("the second page") { page.items.count == 70 && page.next == nil }
        // The change sits on the second page, so it shows only if the update reads both pages again.
        await source.set(ids.map { task(parent: parent, id: $0, model: $0 == ids[60] ? "new" : nil, revision: $0 == ids[60] ? 2 : 1) },
                         parent: parent)
        await source.signal(1)
        await waitFor("the second page's update") { page.items.first { $0.id == ids[60] }?.effectiveModel == "new" }
        #expect(page.items.map(\.id) == ids && page.next == nil, "the pages loaded before the update stay loaded")
    }

    @Test func anOpenDetailStaysThroughAnotherTasksUpdate() async throws {
        let source = Source(), state = SessionTaskUIState(), parent = uuid(1), open = uuid(10), other = uuid(11)
        await source.set([task(parent: parent, id: open), task(parent: parent, id: other)], parent: parent)
        state.configure(bridge(source))
        let page = state.acquire(parent)
        defer { state.release(page); Task { await source.releaseEvent(); await source.release() } }
        await waitFor("the first page") { page.didLoad && page.items.count == 2 }
        await source.holdEvent()
        let reading = Task { await state.readEvents(for: open) }
        await waitFor("the open task's reports read") { await source.eventEntered() }
        await source.set([task(parent: parent, id: open), task(parent: parent, id: other, model: "new", revision: 2)],
                         parent: parent)
        await source.hold()
        await source.signal(1)
        await waitFor("the update's read to start") { await source.heldInRead() }
        #expect(state.task(open, in: parent) != nil, "the open task stays while the update is read")
        await source.release()
        await waitFor("the other task's update") { page.items.first { $0.id == other }?.effectiveModel == "new" }
        #expect(state.task(open, in: parent)?.revision == 1)
        await source.releaseEvent()
        guard case let .ready(batch) = await reading.value else {
            Issue.record("another task's update must not discard the open task's reports"); return
        }
        #expect(batch.events.map(\.taskID) == [open])
    }

    @Test func aParentAcquiredWhileTheSubscriptionIsIdleIsRead() async throws {
        let source = Source(), state = SessionTaskUIState(), first = uuid(1), second = uuid(2)
        await source.set([task(parent: first, id: uuid(10))], parent: first)
        await source.set([task(parent: second, id: uuid(20)), task(parent: second, id: uuid(21))], parent: second)
        state.configure(bridge(source))
        let page = state.acquire(first)
        defer { state.release(page) }
        await waitFor("the first parent read") { page.didLoad }
        let later = state.acquire(second)
        defer { state.release(later) }
        await waitFor("the later parent read") { later.didLoad && later.items.count == 2 }
    }
}
