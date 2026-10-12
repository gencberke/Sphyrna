import Foundation

/// One entry of the list the UI shows (D-40): a request waiting for the user, one the user
/// approved that is starting or failed to start, or a notice that the ticket already has a session.
public struct OpenSessionRequest: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Waits for Open Session / Deny.
        case open
        /// "<ticket> already has a session": Show Session / Dismiss. Nothing was or will be started.
        case exists
    }

    public enum Phase: Equatable, Sendable {
        case waiting
        /// Approved; the session is being started.
        case starting
        /// Approved, but the start failed. The request is spent (it never runs twice); dismiss it.
        case failed(String)
    }

    public let id: UUID
    /// The card the asking agent runs in (after `/clear`, the card the run is on now).
    public let requesterID: UUID
    public let requesterTitle: String?
    public let projectID: UUID
    public let projectName: String
    public let title: String
    public let ticketKey: String?
    public let message: String
    public let receivedAt: Date
    public internal(set) var kind: Kind
    public internal(set) var phase: Phase
    /// `.exists` only: the session that already belongs to the ticket.
    public internal(set) var existingSessionID: UUID?
    public internal(set) var existingTitle: String?

    public init(
        id: UUID = UUID(), requesterID: UUID, requesterTitle: String? = nil, projectID: UUID,
        projectName: String, title: String, ticketKey: String? = nil, message: String,
        receivedAt: Date = Date(), kind: Kind = .open, phase: Phase = .waiting,
        existingSessionID: UUID? = nil, existingTitle: String? = nil
    ) {
        self.id = id
        self.requesterID = requesterID
        self.requesterTitle = requesterTitle
        self.projectID = projectID
        self.projectName = projectName
        self.title = title
        self.ticketKey = ticketKey
        self.message = message
        self.receivedAt = receivedAt
        self.kind = kind
        self.phase = phase
        self.existingSessionID = existingSessionID
        self.existingTitle = existingTitle
    }

    /// An open request the user has not decided on yet, or has approved and is starting.
    var isUndecided: Bool {
        guard kind == .open else { return false }
        switch phase {
        case .waiting, .starting: return true
        case .failed: return false
        }
    }

    /// A notice or a failed request: nothing waits on it any more.
    var isSpent: Bool {
        if kind == .exists { return true }
        if case .failed = phase { return true }
        return false
    }
}

public enum OpenSessionApproval: Equatable, Sendable {
    case started(UUID)
    /// The ticket got a session between the request and the approval; nothing was started.
    case exists(UUID)
}

public enum OpenSessionError: Error, CustomStringConvertible, Equatable, Sendable {
    case unknownRequest(UUID)
    /// The request is not waiting (already starting, failed, or a notice).
    case notWaiting(UUID)
    case shuttingDown

    public var description: String {
        switch self {
        case .unknownRequest: "That request is no longer in Loom"
        case .notWaiting: "That request is not waiting for an answer"
        case .shuttingDown: "Loom is quitting; no new work is accepted"
        }
    }
}

/// What the start path needs to open the approved session.
struct OpenSessionSpec: Sendable {
    let requesterID: UUID
    let projectID: UUID
    let title: String
    let ticketKey: String?
    let message: String
}

/// Keeps the requests of agents until the user decides (contract section 7: nothing starts
/// without an approval call). Requests live in memory only. Each request has at most one waiting
/// client; after `replyDelay` that client is told `pending` and the request stays, so a later
/// approval still opens the session.
actor OpenSessionCoordinator {
    typealias Authorize = @Sendable (_ sessionID: UUID, _ runID: UUID) async -> UUID?
    typealias IsRunning = @Sendable (_ sessionID: UUID) async -> Bool

    private struct Entry {
        var request: OpenSessionRequest
        var waiter: CheckedContinuation<OpenSessionReply, Never>?
        var timeout: Task<Void, Never>?
    }

    static let maximumEntries = 64
    static let maximumWaiting = 32

    private let catalog: SessionCatalog
    private let authorize: Authorize
    private let isRunning: IsRunning
    private let replyDelay: TimeInterval
    private var entries: [Entry] = []
    private var subscribers: [UUID: AsyncStream<[OpenSessionRequest]>.Continuation] = [:]
    private var shutDown = false

    init(catalog: SessionCatalog, authorize: @escaping Authorize, isRunning: @escaping IsRunning,
         replyDelay: TimeInterval = OpenSessionLimits.serverReplyDelay) {
        self.catalog = catalog
        self.authorize = authorize
        self.isRunning = isRunning
        self.replyDelay = replyDelay
    }

    // MARK: List for the UI

    func snapshot() -> [OpenSessionRequest] { entries.map(\.request) }

    /// The current list first, then the whole list after every change.
    func updates() -> AsyncStream<[OpenSessionRequest]> {
        let (stream, continuation) = AsyncStream<[OpenSessionRequest]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        continuation.yield(snapshot())
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func publish() {
        let list = snapshot()
        for continuation in subscribers.values { continuation.yield(list) }
    }

    // MARK: From the agent

    func submit(_ call: OpenSessionCall) async -> OpenSessionReply {
        guard !shutDown else { return Self.unavailable("Loom is quitting") }
        guard let requesterID = await authorize(call.sessionID, call.managedRunID) else {
            return Self.unavailable("this process is not part of a live Loom session")
        }
        let input: OpenSessionInput
        do {
            input = try OpenSessionInput.validated(
                title: call.title, ticketKey: call.ticketKey, project: call.project, message: call.message
            )
        } catch {
            return OpenSessionReply(status: .invalid, detail: String(describing: error))
        }

        let project: CatalogProject
        let requesterTitle: String?
        do {
            let requester = try await catalog.session(id: requesterID)
            requesterTitle = requester?.title
            switch try await resolveProject(input.project, requester: requester) {
            case let .success(found): project = found
            case let .failure(rejection):
                return OpenSessionReply(status: .invalid, detail: rejection.reason)
            }
            // Nothing is started for a ticket that has a session, so no approval is needed: say so
            // at once, and show the user why nothing is opening.
            if let ticket = input.ticketKey,
               let existing = try await catalog.session(projectID: project.id, ticket: ticket, excluding: requesterID) {
                let running = await isRunning(existing.session.id)
                noteExisting(existing, input: input, requesterID: requesterID,
                             requesterTitle: requesterTitle, project: project)
                return Self.existsReply(existing, ticket: ticket, running: running)
            }
        } catch {
            return OpenSessionReply(status: .invalid, detail: "Loom could not read its catalog: \(error)")
        }

        // Checked after the last suspension so two requests of one session cannot both pass.
        guard !shutDown else { return Self.unavailable("Loom is quitting") }
        guard !entries.contains(where: {
            $0.request.requesterID == requesterID && $0.request.isUndecided
        }) else {
            return OpenSessionReply(status: .invalid, detail: "a request from this session is already waiting")
        }
        guard entries.filter({ $0.request.isUndecided }).count < Self.maximumWaiting else {
            return OpenSessionReply(status: .invalid, detail: "too many requests are waiting in Loom")
        }
        let id = UUID()
        let request = OpenSessionRequest(
            id: id, requesterID: requesterID, requesterTitle: requesterTitle, projectID: project.id,
            projectName: project.name, title: input.title, ticketKey: input.ticketKey,
            message: input.message, receivedAt: Date(), kind: .open, phase: .waiting
        )
        return await withCheckedContinuation { continuation in
            let timeout = Task { [replyDelay] in
                try? await Task.sleep(for: .seconds(replyDelay))
                guard !Task.isCancelled else { return }
                await self.resolveWaiter(id, OpenSessionReply(status: .pending))
            }
            entries.append(Entry(request: request, waiter: continuation, timeout: timeout))
            trimEntries()
            publish()
        }
    }

    private func resolveProject(
        _ requested: String?, requester: CatalogSession?
    ) async throws -> Result<CatalogProject, OpenSessionRejection> {
        let projects = try await catalog.projects()
        guard let requested else {
            guard let projectID = requester?.projectID,
                  let own = projects.first(where: { $0.id == projectID }) else {
                return .failure(OpenSessionRejection(
                    "this session is not in a Loom project; name one with --project"
                ))
            }
            return .success(own)
        }
        let standardized = URL(fileURLWithPath: requested).standardizedFileURL
            .resolvingSymlinksInPath().path
        let matches = projects.filter {
            $0.name == requested || $0.path == requested
                || (requested.hasPrefix("/") && $0.path == standardized)
        }
        switch matches.count {
        case 1: return .success(matches[0])
        case 0:
            let known = projects.prefix(10).map(\.name).joined(separator: ", ")
            return .failure(OpenSessionRejection(
                "no Loom project is named or located at \"\(requested)\"; Loom projects: \(known.isEmpty ? "none" : known)"
            ))
        default:
            return .failure(OpenSessionRejection(
                "more than one Loom project matches \"\(requested)\"; use the project's full path"
            ))
        }
    }

    private static func unavailable(_ detail: String) -> OpenSessionReply {
        OpenSessionReply(status: .unavailable, detail: detail)
    }

    private static func existsReply(_ existing: CatalogSession, ticket: String, running: Bool) -> OpenSessionReply {
        OpenSessionReply(
            status: .exists, sessionID: existing.session.id,
            title: existing.title ?? ticket, running: running
        )
    }

    /// One notice per asking session and existing session, replaced by a newer one.
    private func noteExisting(
        _ existing: CatalogSession, input: OpenSessionInput, requesterID: UUID,
        requesterTitle: String?, project: CatalogProject
    ) {
        guard !shutDown else { return }
        entries.removeAll {
            $0.request.kind == .exists && $0.request.requesterID == requesterID
                && $0.request.existingSessionID == existing.session.id
        }
        var notice = OpenSessionRequest(
            id: UUID(), requesterID: requesterID, requesterTitle: requesterTitle, projectID: project.id,
            projectName: project.name, title: input.title, ticketKey: input.ticketKey,
            message: input.message, receivedAt: Date(), kind: .exists, phase: .waiting
        )
        notice.existingSessionID = existing.session.id
        notice.existingTitle = existing.title
        entries.append(Entry(request: notice))
        trimEntries()
        publish()
    }

    /// A bounded list: the oldest notice or failed request goes first, then the oldest request.
    private func trimEntries() {
        while entries.count > Self.maximumEntries {
            let index = entries.firstIndex { $0.request.isSpent } ?? 0
            let removed = entries.remove(at: index)
            removed.timeout?.cancel()
            removed.waiter?.resume(returning: OpenSessionReply(status: .denied))
        }
    }

    private func resolveWaiter(_ id: UUID, _ reply: OpenSessionReply) {
        guard let index = entries.firstIndex(where: { $0.request.id == id }),
              let waiter = entries[index].waiter else { return }
        entries[index].waiter = nil
        entries[index].timeout?.cancel()
        entries[index].timeout = nil
        waiter.resume(returning: reply)
    }

    // MARK: From the user

    /// Starts the approved session through `start`, which returns the new session's id. The
    /// waiting client (if its wait has not run out) is answered with what happened.
    func approve(
        _ id: UUID, start: @Sendable (OpenSessionSpec) async throws -> UUID
    ) async throws -> OpenSessionApproval {
        guard !shutDown else { throw OpenSessionError.shuttingDown }
        guard let index = entries.firstIndex(where: { $0.request.id == id }) else {
            throw OpenSessionError.unknownRequest(id)
        }
        let request = entries[index].request
        guard request.kind == .open, request.phase == .waiting else { throw OpenSessionError.notWaiting(id) }
        setPhase(.starting, of: id)

        // The ticket may have got a session since the request arrived (another request, the user).
        if let ticket = request.ticketKey,
           let existing = try? await catalog.session(projectID: request.projectID, ticket: ticket, excluding: request.requesterID) {
            let running = await isRunning(existing.session.id)
            resolveWaiter(id, Self.existsReply(existing, ticket: ticket, running: running))
            if let at = entries.firstIndex(where: { $0.request.id == id }) {
                entries[at].request.kind = .exists
                entries[at].request.phase = .waiting
                entries[at].request.existingSessionID = existing.session.id
                entries[at].request.existingTitle = existing.title
            }
            publish()
            return .exists(existing.session.id)
        }

        do {
            let sessionID = try await start(OpenSessionSpec(
                requesterID: request.requesterID, projectID: request.projectID, title: request.title,
                ticketKey: request.ticketKey, message: request.message
            ))
            resolveWaiter(id, OpenSessionReply(status: .started, sessionID: sessionID, title: request.title))
            remove(id)
            return .started(sessionID)
        } catch let error as SessionRuntimeError {
            if case .alreadyStarting = error {
                // Another start of this project was in flight: nothing was created, ask again.
                setPhase(.waiting, of: id)
                throw error
            }
            fail(id, error)
            throw error
        } catch {
            fail(id, error)
            throw error
        }
    }

    private func fail(_ id: UUID, _ error: any Error) {
        let text = String(describing: error)
        setPhase(.failed(text), of: id)
        resolveWaiter(id, OpenSessionReply(status: .failed, detail: text))
    }

    private func setPhase(_ phase: OpenSessionRequest.Phase, of id: UUID) {
        guard let index = entries.firstIndex(where: { $0.request.id == id }) else { return }
        entries[index].request.phase = phase
        publish()
    }

    private func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.request.id == id }) else { return }
        entries[index].timeout?.cancel()
        entries.remove(at: index)
        publish()
    }

    /// Nothing is started; the waiting client (if any) is told `denied`.
    func deny(_ id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.request.id == id }) else {
            throw OpenSessionError.unknownRequest(id)
        }
        let request = entries[index].request
        guard request.kind == .open, request.phase == .waiting else { throw OpenSessionError.notWaiting(id) }
        resolveWaiter(id, OpenSessionReply(status: .denied))
        remove(id)
    }

    /// Removes a notice or a failed request; a request still waiting counts as denied.
    func dismiss(_ id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.request.id == id }) else {
            throw OpenSessionError.unknownRequest(id)
        }
        if entries[index].request.phase == .starting { throw OpenSessionError.notWaiting(id) }
        resolveWaiter(id, OpenSessionReply(status: .denied))
        remove(id)
    }

    /// Quit: every waiting client is told Loom is going away and the list is cleared.
    func shutdown() {
        guard !shutDown else { return }
        shutDown = true
        let pending = entries
        entries.removeAll()
        for entry in pending {
            entry.timeout?.cancel()
            entry.waiter?.resume(returning: Self.unavailable("Loom is quitting"))
        }
        publish()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }
}
