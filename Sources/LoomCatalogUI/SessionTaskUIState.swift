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
    @ObservationIgnored fileprivate var wantsPage = true
    @ObservationIgnored fileprivate var isTracked = true

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
        parent.wantsPage = true
        parent.limited = false
        drain()
    }

    func task(_ id: UUID, in parentID: UUID) -> SessionTaskProjection? {
        parents[parentID]?.items.first { $0.id == id }
    }

    func readEvents(for taskID: UUID) async -> EventRead {
        guard let bridge else { return .unavailable }
        let generation = sourceGeneration
        let requestedRevision = revision
        do {
            let received = try await bridge.latestEvents(taskID, Self.eventLimit)
            guard !Task.isCancelled, generation == sourceGeneration, requestedRevision == revision else { return .unavailable }
            let latest = received.suffix(Self.eventLimit)
            let safe = latest.filter { $0.taskID == taskID && $0.payload.utf8.count <= Self.eventByteLimit }
            return .ready(EventBatch(events: Array(safe), partial: received.count > Self.eventLimit || safe.count != latest.count))
        } catch {
            guard !Task.isCancelled, generation == sourceGeneration, requestedRevision == revision else { return .unavailable }
            return .failed
        }
    }

    private func reset(_ parent: SessionTaskParentUI) {
        parent.items = []
        parent.next = nil
        parent.isLoading = false
        parent.didLoad = false
        parent.unavailable = bridge == nil
        parent.limited = false
        parent.incomplete = false
        parent.wantsPage = true
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
                self.cancelLoad()
                for parent in self.parents.values { self.reset(parent) }
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
        guard let parent = order.compactMap({ parents[$0] }).first(where: { $0.wantsPage }) else { return }
        let room = Self.maximumTasks - cachedTaskCount
        guard room > 0 else {
            for parent in parents.values where parent.wantsPage { parent.limited = true }
            return
        }
        let limit = min(Self.pageSize, room)
        let cursor = parent.didLoad ? parent.next : nil
        guard !parent.didLoad || cursor != nil else { parent.wantsPage = false; drain(); return }
        parent.isLoading = true
        parent.limited = false
        parent.unavailable = false
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
            parent.isLoading = false
            parent.wantsPage = false
            switch result {
            case let .success(page):
                var seen = Set(parent.items.map(\.id))
                let valid = page.items.prefix(limit).filter { $0.parentSessionID == parent.id && seen.insert($0.id).inserted }
                parent.items.append(contentsOf: valid)
                parent.incomplete = parent.incomplete || page.items.count > limit || valid.count != page.items.count
                parent.next = page.next
                if let cursor, cursor == page.next { parent.next = nil; parent.incomplete = true }
                parent.didLoad = true
            case .failure:
                parent.unavailable = true
            }
        }
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
