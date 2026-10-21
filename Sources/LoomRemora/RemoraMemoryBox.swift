import Foundation
import LoomCore
import Synchronization

/// The thread-safe holder of Remora's memory (`<data root>/remora/`), opened when first needed. A deletion that
/// `SessionRuntime.start()` recovers can reach the forgetter before any UI or main-actor object exists, so neither the
/// forgetter nor the memory's opening may need the main actor: both go through this box. Making the box reads nothing; the
/// memory's folders, journal fold and usage file are touched when `memory()` first runs.
final class RemoraMemoryBox: Sendable {
    private struct State {
        var memory: RemoraMemory?
        var note: RemoraDurableNote
    }

    let directory: URL
    private let timeZone: TimeZone
    private let clock: @Sendable () -> Date
    private let state: Mutex<State>

    init(directory: URL, note: RemoraDurableNote, timeZone: TimeZone, clock: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.timeZone = timeZone
        self.clock = clock
        state = Mutex(State(memory: nil, note: note))
    }

    /// The memory when it is already open; nil otherwise.
    var openMemory: RemoraMemory? { state.withLock { $0.memory } }

    var isOpen: Bool { openMemory != nil }

    /// The memory, opened now when it was not.
    func memory() throws -> RemoraMemory {
        try state.withLock { state in
            if let memory = state.memory { return memory }
            let memory = try RemoraMemory(directory: directory, timeZone: timeZone, clock: clock, durableNote: state.note)
            state.memory = memory
            return memory
        }
    }

    /// The same, off the caller's actor (the first call lists and folds the journal's folder).
    @concurrent func open() async throws -> RemoraMemory { try memory() }

    /// `Remora.md` moved: the memory (open now or opened later) reads this note. Returns the open memory, which the caller
    /// tells.
    func use(note: RemoraDurableNote) -> RemoraMemory? {
        state.withLock { state in
            state.note = note
            return state.memory
        }
    }
}

/// Registers with the deletion flow: when a session is permanently deleted, its journal lines and note items go. It holds
/// only the box, so it is `Sendable`, runs off the main actor, and opens the memory on demand when a recovered deletion
/// arrives first. A forgetter that throws keeps the deletion pending, so a memory that cannot be opened throws. With no
/// `remora/` folder at all (Remora was never used) there is nothing to forget and nothing is made.
struct RemoraHostForgetter: ConversationForgetting {
    let box: RemoraMemoryBox

    func forget(sessionID: UUID, providerIDs: [String]) async throws {
        guard box.isOpen || FileManager.default.fileExists(atPath: box.directory.path) else { return }
        try await box.open().forget(session: sessionID)
    }
}
