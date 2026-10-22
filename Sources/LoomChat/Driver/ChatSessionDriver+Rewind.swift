import Foundation
import LoomCore

// Rewind files (V21), on the driver: a dry run for the confirmation sheet, the real rewind with Loom's own copy kept first,
// and Undo from that copy. Spike S8 has the wire: `rewind_files` takes the uuid Loom put on its own user line, restores only
// the files Claude's Write, Edit and NotebookEdit touched, overwrites the user's own edits to them without a word, and is
// accepted (to the model's confusion) in the middle of a turn. So Loom offers it only at the prompt, and never calls the CLI
// before the files it will touch are copied.

/// Whether a files rewind can be asked for now. The rule is one: a live session at its prompt (the phase is `ready`, no turn
/// runs, no request waits, no handover holds it, no rewind is under way).
public enum RewindAvailability: Equatable, Sendable {
    case available
    /// A turn runs, a card waits, the child starts or stops, a handover or another rewind holds the session.
    case notIdle
    /// No process: the user resumes the session first (a rewind never resumes one by itself).
    case stopped

    /// Why the action is off; nil when it is on.
    public var reason: String? {
        switch self {
        case .available: nil
        case .notIdle: "Rewind works while the session waits for you"
        case .stopped: "Resume the session to rewind its files"
        }
    }

    public static func of(phase: ChatDriverPhase, turnRunning: Bool, requestCount: Int, handoverHolds: Bool,
                          rewinding: Bool) -> RewindAvailability {
        switch phase {
        case .stopped, .failed: return .stopped
        case .starting, .working, .needsYou, .stopping: return .notIdle
        case .ready: break
        }
        return turnRunning || requestCount > 0 || handoverHolds || rewinding ? .notIdle : .available
    }
}

/// Why the CLI cannot rewind to a message.
public enum RewindCannot: Equatable, Sendable {
    /// The message was sent before checkpointing was on, or from the terminal face: "No file checkpoint for this message".
    case noCheckpoint
    /// The run was started without the checkpointing switch: "File rewinding is off for this run".
    case notEnabled
    /// Anything else the CLI said.
    case other(String)

    init(cliText: String?) {
        let text = cliText ?? ""
        if text.contains("No file checkpoint") { self = .noCheckpoint } else if text.contains("not enabled") { self = .notEnabled } else {
            self = .other(text)
        }
    }

    public var text: String {
        switch self {
        case .noCheckpoint: "No file checkpoint for this message"
        case .notEnabled: "File rewinding is off for this run"
        case let .other(text): text.isEmpty ? "Claude cannot rewind to this message" : text
        }
    }
}

public enum ChatRewindError: Error, Equatable, Sendable {
    /// The session is not at its prompt (or has no process).
    case notAvailable(RewindAvailability)
    case cannot(RewindCannot)
    /// The dry run lists no file: nothing would change.
    case nothingToChange
    /// Loom keeps a copy before it rewinds; the files are over its bounds, or one cannot be copied. Nothing was rewound.
    case tooLarge
    case cannotCopy([String])
    /// The copy could not be written (the text says what the system said). Nothing was rewound.
    case copyFailed(String)
    /// The CLI answered an error frame: nothing changed.
    case failed(String)
    /// The CLI did not answer the rewind (a timeout, the process ended): files may have changed. Loom kept its copy, and the
    /// marker offers Undo from it.
    case noAnswer
    /// Undo is not offered: not the session's newest rewind, a message was sent after it, or it was undone already.
    case undoUnavailable
    /// Undo would overwrite files changed since the rewind (named); `overwritingChanged: true` goes on.
    case changedSince([String])
    /// The copy is missing or changed, or the restore failed.
    case undoFailed(String)
}

/// What a dry run found: the files the rewind would change, with the CLI's totals, and whether Loom can keep a copy of them.
public struct RewindPreview: Equatable, Sendable {
    public var userMessageID: String
    /// Absolute paths, in the CLI's order.
    public var files: [String]
    public var insertions: Int
    public var deletions: Int
    public var copy: ChatRewindStore.CopyVerdict

    public var canKeepCopy: Bool { if case .ok = copy { true } else { false } }
}

public struct RewindResult: Equatable, Sendable {
    public var rewindID: String
    public var files: [String]
    public var insertions: Int
    public var deletions: Int
}

public struct RewindUndoResult: Equatable, Sendable {
    public var restored: [String]
    public var trashed: [String]
}

/// The session's newest rewind, while it can still be undone. Its copies exist while `undoOpen`.
struct RewindRecord: Equatable, Sendable {
    var rewindID: String
    /// The card the copies are kept under (a `/clear` moves the driver to another one).
    var card: UUID
    /// The marker's row.
    var entryID: String
    var undoOpen: Bool
}

extension ChatSessionDriver {
    // MARK: The rule

    /// Whether a rewind can be asked for now (the composer state carries it for the rows).
    public func rewindAvailability() -> RewindAvailability {
        RewindAvailability.of(phase: phase, turnRunning: turnRunning, requestCount: requests.count,
                              handoverHolds: handover.isHolding, rewinding: rewindBusy)
    }

    /// The same rule without this driver's own rewind in flight: the real call checks it again after its copy.
    private func idleBlock() -> RewindAvailability {
        RewindAvailability.of(phase: phase, turnRunning: turnRunning, requestCount: requests.count,
                              handoverHolds: handover.isHolding, rewinding: false)
    }

    private func setRewindBusy(_ busy: Bool) {
        rewindBusy = busy
        changed()
    }

    private func idleChannel() throws -> ControlChannel {
        let availability = rewindAvailability()
        guard availability == .available else { throw ChatRewindError.notAvailable(availability) }
        guard let current = run else { throw ChatRewindError.notAvailable(.stopped) }
        return current.channel
    }

    /// The uuid the CLI knows a row's message by, which `rewind_files` names: the row's own id, or the one "Read now" sent the
    /// message again under. A row of the transcript's history is named by its record's uuid, which is its id.
    public func messageUUID(ofRow rowID: String) -> String { model.sentUUID(ofRow: rowID) }

    // MARK: Preview

    /// The dry run: what a rewind to before this message would change. It changes nothing. Throws `cannot` when the CLI has
    /// no checkpoint for the message.
    public func rewindPreview(userMessageID: String) async throws -> RewindPreview {
        let channel = try idleChannel()
        let dry = try await dryRun(userMessageID, on: channel)
        let copy = rewindStore?.verdict(for: dry.files) ?? .cannotCopy([])
        return RewindPreview(userMessageID: userMessageID, files: dry.files, insertions: dry.insertions, deletions: dry.deletions,
                             copy: copy)
    }

    private func dryRun(_ userMessageID: String, on channel: ControlChannel)
        async throws -> (files: [String], insertions: Int, deletions: Int) {
        let reply: ControlReply
        do {
            reply = try await channel.request(.rewindFiles(userMessageID: userMessageID, dryRun: true))
        } catch let ControlError.rejected(_, message) {
            throw ChatRewindError.cannot(RewindCannot(cliText: message))
        } catch {
            throw ChatRewindError.failed(LoomLog.category(of: error))
        }
        guard reply.canRewind == true else { throw ChatRewindError.cannot(RewindCannot(cliText: reply.rewindError)) }
        return (reply.filesChanged, reply.insertions ?? 0, reply.deletions ?? 0)
    }

    // MARK: Rewind

    /// The real rewind. The order is the safety:
    /// 1. the rule is checked, and a fresh dry run names the files (the sheet's list may be old);
    /// 2. every listed file that exists is copied, with a manifest, and the rule is checked again;
    /// 3. only then the CLI is called;
    /// 4. the files as the rewind left them are recorded, and the stream gets its marker.
    /// A refusal at any step before 3 changes nothing. An error frame from the CLI changes nothing either, and the copy is
    /// dropped. An answer that never came (a timeout, the process ended) may have left files changed: the copy stays, and the
    /// marker is placed with Undo all the same, so the copy Loom kept is within the user's reach.
    @discardableResult
    public func rewindFiles(userMessageID: String, messageTitle: String = "") async throws -> RewindResult {
        let channel = try idleChannel()
        guard let store = rewindStore else { throw ChatRewindError.cannotCopy([]) }
        setRewindBusy(true)
        defer { setRewindBusy(false) }
        let card = sessionID
        let dry = try await dryRun(userMessageID, on: channel)
        guard !dry.files.isEmpty else { throw ChatRewindError.nothingToChange }
        let manifest: ChatRewindManifest
        do {
            manifest = try await Task.detached { try store.begin(sessionID: card, userMessageID: userMessageID, paths: dry.files) }.value
        } catch ChatRewindStoreError.tooLarge {
            throw ChatRewindError.tooLarge
        } catch let ChatRewindStoreError.cannotCopy(files) {
            throw ChatRewindError.cannotCopy(files)
        } catch {
            throw ChatRewindError.copyFailed(LoomLog.category(of: error))
        }
        // The phase can change while the copy is written: a turn that began, a card, a handover, the child's end.
        let block = idleBlock()
        guard block == .available, run?.channel === channel else {
            store.discard(sessionID: card, rewindID: manifest.rewindID)
            throw ChatRewindError.notAvailable(block == .available ? .notIdle : block)
        }
        do {
            let reply = try await channel.request(.rewindFiles(userMessageID: userMessageID, dryRun: false), timeout: .seconds(60))
            if reply.canRewind == false {
                store.discard(sessionID: card, rewindID: manifest.rewindID)
                throw ChatRewindError.cannot(RewindCannot(cliText: reply.rewindError))
            }
        } catch let ControlError.rejected(_, message) {
            // An error frame: the CLI changed nothing, so the copy is of no use.
            store.discard(sessionID: card, rewindID: manifest.rewindID)
            throw ChatRewindError.failed(message)
        } catch let error as ChatRewindError {
            throw error
        } catch {
            LoomLog.error(.lifecycle, "A files rewind was not answered (\(LoomLog.category(of: error))); Sphyrna kept its copy")
            // What the files hold now is what Undo compares against later.
            _ = try? await Task.detached { try store.finish(sessionID: card, rewindID: manifest.rewindID) }.value
            placeRewindMarker(rewindID: manifest.rewindID, card: card, title: messageTitle)
            journal?.record("chat.rewind_unanswered", ["files": .int(dry.files.count)])
            throw ChatRewindError.noAnswer
        }
        do {
            _ = try await Task.detached { try store.finish(sessionID: card, rewindID: manifest.rewindID) }.value
        } catch {
            LoomLog.error(.lifecycle, "The files a rewind left could not be recorded (\(LoomLog.category(of: error)))")
        }
        placeRewindMarker(rewindID: manifest.rewindID, card: card, title: messageTitle)
        journal?.record("chat.rewound", ["files": .int(dry.files.count), "insertions": .int(dry.insertions),
                                         "deletions": .int(dry.deletions)])
        return RewindResult(rewindID: manifest.rewindID, files: dry.files, insertions: dry.insertions, deletions: dry.deletions)
    }

    /// The marker after the rewind; the previous rewind's Undo is closed (only the newest is offered).
    private func placeRewindMarker(rewindID: String, card: UUID, title: String) {
        closeRewindUndo(to: .expired)
        let delta = model.appendMarker(.rewound(RewindMarker(rewindID: rewindID, title: title)), at: clock())
        newestRewind = RewindRecord(rewindID: rewindID, card: card, entryID: delta.inserted.first ?? "", undoOpen: true)
        note(delta)
    }

    /// The newest rewind's Undo is no longer offered: a message was sent, a newer rewind came, or it was undone. Its copies go
    /// with it (D-72): they exist only while Undo can be offered, and only this one rewind's are ever kept.
    func closeRewindUndo(to undo: RewindMarker.Undo) {
        guard var current = newestRewind, current.undoOpen else { return }
        current.undoOpen = false
        newestRewind = current
        rewindStore?.discard(sessionID: current.card, rewindID: current.rewindID)
        var delta = ModelDelta()
        model.updateEntry(current.entryID, delta: &delta) { body in
            if case var .marker(.rewound(marker)) = body {
                marker.undo = undo
                body = .marker(.rewound(marker))
            }
        }
        note(delta)
    }

    // MARK: Undo

    /// Puts back the files the newest rewind replaced: every copy is restored, a file the rewind brought back that did not
    /// exist before goes to the Trash. Files changed since the rewind are named first (`changedSince`) and overwritten only
    /// with `overwritingChanged`. Not while a turn runs or a card waits.
    @discardableResult
    public func undoRewind(rewindID: String, overwritingChanged: Bool = false) async throws -> RewindUndoResult {
        guard let current = newestRewind, current.rewindID == rewindID, current.undoOpen, let store = rewindStore else {
            throw ChatRewindError.undoUnavailable
        }
        guard !rewindBusy, !turnRunning, requests.isEmpty, !handover.isHolding else { throw ChatRewindError.notAvailable(.notIdle) }
        setRewindBusy(true)
        defer { setRewindBusy(false) }
        let card = current.card
        do {
            if !overwritingChanged {
                let changed = try await Task.detached { try store.changedSinceRewind(sessionID: card, rewindID: rewindID) }.value
                if !changed.isEmpty { throw ChatRewindError.changedSince(changed) }
            }
            let report = try await Task.detached { try store.restore(sessionID: card, rewindID: rewindID) }.value
            closeRewindUndo(to: .undone)
            journal?.record("chat.rewind_undone", ["restored": .int(report.restored.count), "trashed": .int(report.trashed.count)])
            return RewindUndoResult(restored: report.restored, trashed: report.trashed)
        } catch let error as ChatRewindError {
            throw error
        } catch let ChatRewindStoreError.damaged(text) {
            throw ChatRewindError.undoFailed(text)
        } catch {
            throw ChatRewindError.undoFailed(LoomLog.category(of: error))
        }
    }

    /// The newest rewind's id while its Undo is offered.
    public func openUndoRewindID() -> String? {
        newestRewind.flatMap { $0.undoOpen ? $0.rewindID : nil }
    }
}
