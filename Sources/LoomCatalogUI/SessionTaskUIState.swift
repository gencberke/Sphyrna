import Foundation
import LoomCore
import Observation
import SwiftUI

/// The application supplies only trusted-user reads. No UI path starts or sends to a provider.
public struct SessionTaskUIBridge: Sendable {
    public struct Page: Sendable {
        public let items: [SessionTaskProjection]
        public let next: UUID?

        public init(items: [SessionTaskProjection], next: UUID?) {
            self.items = items
            self.next = next
        }
    }

    public let projections: @Sendable (_ parent: UUID, _ after: UUID?, _ limit: Int) async throws -> Page
    public let updates: @Sendable () async -> AsyncStream<UInt64>
    public let latestEvents: @Sendable (_ task: UUID, _ limit: Int) async throws -> [SessionTaskEvent]

    public init(projections: @escaping @Sendable (UUID, UUID?, Int) async throws -> Page,
                updates: @escaping @Sendable () async -> AsyncStream<UInt64>,
                latestEvents: @escaping @Sendable (UUID, Int) async throws -> [SessionTaskEvent]) {
        self.projections = projections
        self.updates = updates
        self.latestEvents = latestEvents
    }
}

/// One visible parent's metadata; reading one parent never observes another parent's changes.
@MainActor @Observable
final class SessionTaskParentUI {
    let id: UUID
    fileprivate(set) var items: [SessionTaskProjection] = []
    fileprivate(set) var next: UUID?
    fileprivate(set) var isLoading = false
    fileprivate(set) var didLoad = false
    fileprivate(set) var unavailable = false
    fileprivate(set) var limited = false
    fileprivate(set) var incomplete = false
    @ObservationIgnored fileprivate var references = 1
    @ObservationIgnored fileprivate var isTracked = true
    /// A read from the first page that replaces `items` only when it ends, so the shown rows stay through an update.
    @ObservationIgnored fileprivate var pass: Pass? = Pass()
    @ObservationIgnored fileprivate var wantsMore = false

    fileprivate struct Pass {
        /// How many rows the pass reads again (those shown when it starts, at least a page); nil until its first page.
        var target: Int?
        var items: [SessionTaskProjection] = []
        var next: UUID?
        var incomplete = false
        /// An update arrived after the pass began: another pass follows it.
        var again = false
    }

    fileprivate var wantsPage: Bool { pass != nil || wantsMore }

    init(id: UUID) { self.id = id }
}

/// Bounded, interest-driven metadata only. Event payloads are returned solely to an open task detail.
@MainActor @Observable
final class SessionTaskUIState {
    static let maximumParents = 32
    static let maximumTasks = 128
    static let pageSize = 50
    static let eventLimit = 10
    static let eventByteLimit = 16 * 1024

    struct EventBatch {
        let events: [SessionTaskEvent]
        let partial: Bool
    }
    enum EventRead {
        case unavailable, failed, ready(EventBatch)
    }

    private(set) var sourceGeneration: UInt64 = 0
    private(set) var revision: UInt64 = 0
    @ObservationIgnored private var bridge: SessionTaskUIBridge?
    @ObservationIgnored private var parents: [UUID: SessionTaskParentUI] = [:]
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored private var subscription: Task<Void, Never>?
    @ObservationIgnored private var load: Task<Void, Never>?
    @ObservationIgnored private var loadToken: UUID?
    @ObservationIgnored private var loadingParent: UUID?
    /// The parent read last; the next read starts after it, so frequent updates cannot starve later parents.
    @ObservationIgnored private var served: UUID?
    @ObservationIgnored private var subscribed = false

    deinit {
        subscription?.cancel()
        load?.cancel()
    }

    var cachedTaskCount: Int { parents.values.reduce(0) { $0 + $1.items.count } }
    var activeParentCount: Int { parents.count }

    func configure(_ bridge: SessionTaskUIBridge?) {
        sourceGeneration &+= 1
        revision &+= 1
        self.bridge = bridge
        cancelWork()
        for parent in parents.values { reset(parent) }
        startUpdatesIfNeeded()
    }

    func acquire(_ id: UUID) -> SessionTaskParentUI {
        if let parent = parents[id] {
            parent.references += 1
            return parent
        }
        let parent = SessionTaskParentUI(id: id)
        guard parents.count < Self.maximumParents else {
            parent.isTracked = false
            parent.unavailable = true
            return parent
        }
        parents[id] = parent
        order.append(id)
        reset(parent)
        startUpdatesIfNeeded()
        drain()
        return parent
    }

    func release(_ parent: SessionTaskParentUI) {
        guard parent.isTracked, parents[parent.id] === parent else { return }
        parent.references -= 1
        guard parent.references == 0 else { return }
        parents[parent.id] = nil
        order.removeAll { $0 == parent.id }
        if loadingParent == parent.id { cancelLoad() }
        if parents.isEmpty { cancelWork() } else { drain() }
    }

    func loadMore(_ parent: SessionTaskParentUI) {
        guard parent.isTracked, parents[parent.id] === parent, parent.didLoad, parent.next != nil,
              !parent.isLoading else { return }
        parent.wantsMore = true
        parent.limited = false
        drain()
    }

    func task(_ id: UUID, in parentID: UUID) -> SessionTaskProjection? {
        parents[parentID]?.items.first { $0.id == id }
    }

    /// A shown task's read is stale only when that task's own revision changed; a task not shown, at any update.
    func readEvents(for taskID: UUID) async -> EventRead {
        guard let bridge else { return .unavailable }
        let generation = sourceGeneration
        let requestedRevision = revision
        let taskRevision = shownRevision(of: taskID)
        func current() -> Bool {
            !Task.isCancelled && generation == sourceGeneration && taskRevision == shownRevision(of: taskID)
                && (taskRevision != nil || requestedRevision == revision)
        }
        do {
            let received = try await bridge.latestEvents(taskID, Self.eventLimit)
            guard current() else { return .unavailable }
            let latest = received.suffix(Self.eventLimit)
            let safe = latest.filter { $0.taskID == taskID && $0.payload.utf8.count <= Self.eventByteLimit }
            return .ready(EventBatch(events: Array(safe), partial: received.count > Self.eventLimit || safe.count != latest.count))
        } catch {
            guard current() else { return .unavailable }
            return .failed
        }
    }

    private func shownRevision(of taskID: UUID) -> Int64? {
        for parent in parents.values {
            if let task = parent.items.first(where: { $0.id == taskID }) { return task.revision }
        }
        return nil
    }

    private func reset(_ parent: SessionTaskParentUI) {
        parent.items = []
        parent.next = nil
        parent.isLoading = false
        parent.didLoad = false
        parent.unavailable = bridge == nil
        parent.limited = false
        parent.incomplete = false
        parent.pass = .init()
        parent.wantsMore = false
    }

    /// An update keeps the shown rows and reads them again; a pass already under way is followed by one more.
    private func markStale(_ parent: SessionTaskParentUI) {
        if parent.pass == nil { parent.pass = .init() } else if parent.pass?.target != nil { parent.pass?.again = true }
    }

    /// Subscribe before the first page so an update during the read is not lost.
    private func startUpdatesIfNeeded() {
        guard subscription == nil, !parents.isEmpty, let bridge else { return }
        let generation = sourceGeneration
        subscription = Task { [weak self] in
            let stream = await bridge.updates()
            guard !Task.isCancelled, self?.sourceGeneration == generation else { return }
            self?.subscribed = true
            self?.drain()
            for await _ in stream {
                guard !Task.isCancelled, let self, self.sourceGeneration == generation else { return }
                self.revision &+= 1
                for parent in self.parents.values { self.markStale(parent) }
                self.drain()
            }
            if !Task.isCancelled, let self, self.sourceGeneration == generation {
                self.subscribed = false
                for parent in self.parents.values { parent.incomplete = true }
            }
        }
    }

    /// One page at a time bounds in-flight memory and prevents a burst of visible rows from racing the total cap.
    private func drain() {
        guard subscribed, load == nil, let bridge else { return }
        let tracked = order.compactMap { parents[$0] }
        let start = served.flatMap { id in tracked.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        for parent in tracked[start...] + tracked[..<start] where parent.wantsPage {
            if read(parent, bridge) { return }
        }
    }

    /// Starts the parent's next page; false when it has none to read now.
    private func read(_ parent: SessionTaskParentUI, _ bridge: SessionTaskUIBridge) -> Bool {
        var pass = parent.pass
        guard pass != nil || parent.next != nil else { parent.wantsMore = false; return false }
        // A pass replaces the parent's own rows, so they count as room for it.
        let room = Self.maximumTasks - cachedTaskCount + (pass.map { parent.items.count - $0.items.count } ?? 0)
        guard room > 0 else {
            if let pass, pass.target != nil { finish(parent, pass) } else { parent.limited = true }
            return false
        }
        let cursor: UUID?
        let limit: Int
        if var current = pass {
            cursor = current.target == nil ? nil : current.next
            let target = current.target ?? max(parent.items.count, Self.pageSize)
            current.target = target
            limit = min(Self.pageSize, room, target - current.items.count)
            pass = current
            parent.pass = current
        } else {
            cursor = parent.next
            limit = min(Self.pageSize, room)
        }
        let refreshing = pass != nil
        if !refreshing || !parent.didLoad {
            parent.isLoading = true
            parent.unavailable = false
        }
        parent.limited = false
        let generation = sourceGeneration
        let token = UUID()
        let parentID = parent.id
        loadToken = token
        loadingParent = parentID
        load = Task { [weak self, weak parent] in
            let result: Result<SessionTaskUIBridge.Page, Error>
            do { result = .success(try await bridge.projections(parentID, cursor, limit)) }
            catch { result = .failure(error) }
            guard let self, self.loadToken == token else { return }
            self.load = nil
            self.loadToken = nil
            self.loadingParent = nil
            defer { self.drain() }
            guard !Task.isCancelled, let parent, self.sourceGeneration == generation,
                  self.parents[parentID] === parent else { return }
            self.served = parentID
            parent.isLoading = false
            if refreshing { self.receivePass(result, parent, cursor: cursor, limit: limit) }
            else { self.receiveMore(result, parent, cursor: cursor, limit: limit) }
        }
        return true
    }

    private func receiveMore(_ result: Result<SessionTaskUIBridge.Page, Error>, _ parent: SessionTaskParentUI,
                             cursor: UUID?, limit: Int) {
        parent.wantsMore = false
        switch result {
        case let .success(page):
            var seen = Set(parent.items.map(\.id))
            let valid = page.items.prefix(limit).filter { $0.parentSessionID == parent.id && seen.insert($0.id).inserted }
            parent.items.append(contentsOf: valid)
            parent.incomplete = parent.incomplete || page.items.count > limit || valid.count != page.items.count
            parent.next = page.next
            if let cursor, cursor == page.next { parent.next = nil; parent.incomplete = true }
        case .failure:
            parent.unavailable = true
        }
    }

    private func receivePass(_ result: Result<SessionTaskUIBridge.Page, Error>, _ parent: SessionTaskParentUI,
                             cursor: UUID?, limit: Int) {
        guard var pass = parent.pass, let target = pass.target else { return }
        switch result {
        case let .success(page):
            var seen = Set(pass.items.map(\.id))
            let valid = page.items.prefix(limit).filter { $0.parentSessionID == parent.id && seen.insert($0.id).inserted }
            pass.items.append(contentsOf: valid)
            pass.incomplete = pass.incomplete || page.items.count > limit || valid.count != page.items.count
            pass.next = page.next
            if let cursor, cursor == page.next { pass.next = nil; pass.incomplete = true }
            if pass.next != nil, pass.items.count < target { parent.pass = pass } else { finish(parent, pass) }
        case .failure:
            // Rows already shown stay, marked as not all read; a parent never read is unavailable.
            parent.pass = pass.again ? SessionTaskParentUI.Pass() : nil
            if parent.didLoad { parent.incomplete = true } else { parent.unavailable = true }
        }
    }

    /// Assigns only what changed, so an update that changed nothing leaves the rows' observers alone.
    private func finish(_ parent: SessionTaskParentUI, _ pass: SessionTaskParentUI.Pass) {
        if parent.items != pass.items { parent.items = pass.items }
        if parent.next != pass.next { parent.next = pass.next }
        if parent.incomplete != pass.incomplete { parent.incomplete = pass.incomplete }
        if parent.unavailable { parent.unavailable = false }
        if !parent.didLoad { parent.didLoad = true }
        parent.pass = pass.again ? SessionTaskParentUI.Pass() : nil
    }

    /// Wait for a cancelled read to return before starting another, even if its loader ignores cancellation.
    private func cancelLoad() { load?.cancel() }

    private func cancelWork() {
        subscription?.cancel()
        subscription = nil
        subscribed = false
        cancelLoad()
    }
}

/// A parent is retained only while its real surface has visible interest in it.
struct SessionTaskInterest: ViewModifier {
    let state: SessionTaskUIState
    let parentID: UUID
    let active: Bool
    @Binding var parent: SessionTaskParentUI?

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, active in update(active) }
            .onChange(of: parentID) { _, _ in update(active, force: true) }
            .onDisappear { update(false) }
    }

    private func update(_ active: Bool, force: Bool = false) {
        if force || !active {
            if let parent { state.release(parent) }
            parent = nil
        }
        if active, parent == nil { parent = state.acquire(parentID) }
    }
}

extension CatalogModel {
    /// The application connects trusted-user reads after the runtime is ready.
    public func setSessionTaskUIBridge(_ bridge: SessionTaskUIBridge?) {
        sessionTasks.configure(bridge)
    }

    /// Show this exact owned child without starting, stopping or handing over its run.
    func openSessionTaskChild(_ taskID: UUID, parentID: UUID) {
        guard let task = sessionTasks.task(taskID, in: parentID) else { return }
        faces.choose(.terminal, for: task.childSessionID)
        select(task.childSessionID, revealInList: false)
    }
}
