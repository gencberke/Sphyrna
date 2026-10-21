import Foundation
import Observation

/// What a session is going through right now, as the UI shows it: a start, a resume or a Stop that has not finished.
public enum ConversationBusy: Equatable, Sendable {
    case starting
    case resuming
    case stopping
}

/// A new-conversation request that is still starting (one per provider and project).
public struct StartKey: Hashable, Sendable {
    public let provider: ManagedSession.Provider
    public let projectID: UUID?
    public init(provider: ManagedSession.Provider, projectID: UUID?) {
        self.provider = provider
        self.projectID = projectID
    }
}

/// The transition state of every session's lifecycle: busy per session, the starts that have no finished card yet, and the
/// handovers under way.
/// `SessionService` is the only writer in the app; views read it (observed: a view that reads it redraws when it changes),
/// and a model with no service owns an object of its own, so its reads stay valid. The mutators are `package` for that
/// one reason: the service, and the model's test seams.
@MainActor @Observable
public final class SessionTransitions {
    public private(set) var busy: [UUID: ConversationBusy] = [:]
    /// Starts under way, one per provider and project: a second start of the same key is refused until the first ends.
    public private(set) var startingKeys: Set<StartKey> = []
    /// The starts that have no card yet (the toolchain is still resolving); a subset of `startingKeys`.
    public private(set) var preparingStarts: Set<StartKey> = []
    /// The Chat → terminal moves that wait or run (V19), by session.
    public private(set) var handovers: [UUID: Handover] = [:]

    public init() {}

    /// Claims the key; false when a start of the same key is under way.
    package func beginStart(_ key: StartKey) -> Bool {
        let inserted = startingKeys.insert(key).inserted
        if inserted { preparingStarts.insert(key) }
        return inserted
    }

    /// The card exists now (its own "Starting…" state takes over from the preparing notice).
    package func cardCreated(for key: StartKey) { preparingStarts.remove(key) }

    package func endStart(_ key: StartKey) {
        startingKeys.remove(key)
        preparingStarts.remove(key)
    }

    package func setBusy(_ id: UUID, _ value: ConversationBusy?) { busy[id] = value }

    package func setHandover(_ value: Handover?, for id: UUID) {
        if handovers[id] != value { handovers[id] = value }
    }
}
