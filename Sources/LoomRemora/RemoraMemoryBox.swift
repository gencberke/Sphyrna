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
    /// Serializes the kept brief's file (the host writes it on the main actor, the forgetter removes it off the main actor) and
    /// holds the sessions that were permanently deleted while this process ran, so a call that was running when the forgetter
    /// came cannot write their words afterwards. Not persisted: the ids are few and a new process starts with no call running.
    private let keptLock = Mutex<Set<UUID>>([])
    private let kept: RemoraKeptBriefFile

    init(directory: URL, note: RemoraDurableNote, timeZone: TimeZone, clock: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.timeZone = timeZone
        self.clock = clock
        state = Mutex(State(memory: nil, note: note))
        kept = RemoraKeptBriefFile(directory: directory)
    }

    /// The memory when it is already open; nil otherwise.
    var openMemory: RemoraMemory? { state.withLock { $0.memory } }

    var isOpen: Bool { openMemory != nil }

    /// The memory, opened now when it was not.
    func memory() throws -> RemoraMemory {
        try state.withLock { state in
            if let memory = state.memory { return memory }
            let memory = try RemoraMemory(directory: directory, timeZone: timeZone, clock: clock, durableNote: state.note,
                                          forgotten: forgottenSessions())
            state.memory = memory
            return memory
        }
    }

    /// The same, off the caller's actor (the first call lists and folds the journal's folder).
    @concurrent func open() async throws -> RemoraMemory { try memory() }

    // MARK: The day's brief

    /// Keeps `brief` as the day's (replacing the one before). A write that fails leaves the one before.
    /// A brief that names a session deleted in this process is not kept (a call that was running when the deletion came).
    func keep(_ brief: RemoraKeptBrief) {
        keptLock.withLock { forgotten in
            guard forgotten.isDisjoint(with: brief.sessionIDs) else { return }
            try? kept.write(brief)
        }
    }

    /// A session was permanently deleted: it is remembered for this process (`keep` refuses a brief that names it, and the
    /// memory is told through `forgottenSessions()`), and the kept brief that names it is removed. One step, before anything that
    /// can throw.
    func recordForgotten(_ session: UUID) {
        keptLock.withLock { forgotten in
            forgotten.insert(session)
            guard let brief = kept.read(), brief.sessionIDs.contains(session) else { return }
            kept.remove()
        }
    }

    func forgottenSessions() -> Set<UUID> { keptLock.withLock { $0 } }

    /// The kept brief when it belongs to the current day (it starts at `RemoraSchedule.dayStart`). One of an earlier day is
    /// removed, and nothing is returned. Reads one small file, never the memory.
    func keptBrief() -> RemoraKeptBrief? {
        keptLock.withLock { _ in
            guard let brief = kept.read() else { return nil }
            guard brief.startedAt >= RemoraSchedule.dayStart(containing: clock(), in: timeZone) else {
                kept.remove()
                return nil
            }
            return brief
        }
    }

    /// The same, off the caller's actor.
    @concurrent func readKeptBrief() async -> RemoraKeptBrief? { keptBrief() }

    /// Removes the kept brief when `matches` says so (a session it names was deleted, or a project it read from became
    /// excluded). Nothing is read when no file is there.
    func removeKeptBrief(where matches: (RemoraKeptBrief) -> Bool) {
        keptLock.withLock { _ in
            guard let brief = kept.read(), matches(brief) else { return }
            kept.remove()
        }
    }

    /// Removes the kept brief whatever it holds (Settings' Clear).
    func removeKeptBrief() {
        keptLock.withLock { _ in kept.remove() }
    }

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
/// `remora/` folder at all (Remora was never used) there is nothing to forget and nothing is made. The day's brief that names the session goes too.
struct RemoraHostForgetter: ConversationForgetting {
    let box: RemoraMemoryBox

    func forget(sessionID: UUID, providerIDs: [String]) async throws {
        // The session is recorded, and the day's brief that names it goes, before anything that can throw: a deletion that stays
        // pending must not leave its words on Home, and a call that is running must not write them afterwards (`keep`, and the
        // memory's `apply` once it is opened with the record).
        box.recordForgotten(sessionID)
        guard box.isOpen || FileManager.default.fileExists(atPath: box.directory.path) else { return }
        try await box.open().forget(session: sessionID)
    }
}
