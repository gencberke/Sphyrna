import Foundation

// File checkpoints of the fake CLI (V21), after what spike S8 saw of Claude Code 2.1.300:
//   - checkpoints exist only with CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true (LOOM_FAKE_CHAT_CHECKPOINTS=off turns them
//     off whatever the environment says); without them `rewind_files` answers "File rewinding is not enabled.";
//   - a user message that starts a turn gets a snapshot of every file the Write and Edit tools touched so far;
//   - a file becomes tracked the first time Write or Edit touches it, with its content before that touch;
//   - a rewind to a message puts every tracked file back to its snapshot of that message (a file tracked later: to its
//     original content), deletes a file that did not exist then, and touches nothing else (Bash and subagents are not tracked);
//   - a message with no snapshot (an assistant uuid, an unknown one, one sent before checkpoints were on) has no checkpoint;
//   - the dry run counts lines added and removed over the whole set and changes nothing; a real run answers `skippedLinks`.
//   - LOOM_FAKE_CHAT_CHECKPOINTS=fail: a real rewind answers an error frame and changes nothing.
//   - LOOM_FAKE_CHAT_CHECKPOINTS=die: a real rewind restores the files and the process exits without an answer.

final class ChatCheckpoints {
    enum Mode { case on, off, failingRewind, dyingRewind }

    let mode: Mode
    private var tracked: [String] = []
    private var originals: [String: Data?] = [:]
    private var snapshots: [String: [String: Data?]] = [:]

    init(environment: [String: String]) {
        let switched = environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"] == "true"
        switch environment["LOOM_FAKE_CHAT_CHECKPOINTS"] {
        case "off": mode = .off
        case "fail": mode = switched ? .failingRewind : .off
        case "die": mode = switched ? .dyingRewind : .off
        default: mode = switched ? .on : .off
        }
    }

    var isEnabled: Bool { mode != .off }

    /// A user message starts a turn: what the tracked files hold now is the state "before this message".
    func messageStarted(_ uuid: String) {
        guard isEnabled else { return }
        snapshots[uuid] = Dictionary(uniqueKeysWithValues: tracked.map { ($0, Self.read($0)) })
    }

    /// A Write or Edit is about to change `path`.
    func willChange(_ path: String) {
        guard isEnabled, originals[path] == nil else { return }
        originals[path] = .some(Self.read(path))
        tracked.append(path)
    }

    enum Answer {
        case cannot(String)
        case files([String], insertions: Int, deletions: Int)
    }

    /// What a rewind to before `uuid` would change, now.
    func plan(_ uuid: String) -> Answer {
        guard isEnabled else { return .cannot("File rewinding is not enabled.") }
        guard let snapshot = snapshots[uuid] else { return .cannot("No file checkpoint found for this message.") }
        var files: [String] = []
        var insertions = 0, deletions = 0
        for path in tracked {
            let wanted = target(of: path, in: snapshot)
            let now = Self.read(path)
            guard wanted != now else { continue }
            files.append(path)
            let (added, removed) = Self.lineChanges(from: now, to: wanted)
            insertions += added
            deletions += removed
        }
        return .files(files, insertions: insertions, deletions: deletions)
    }

    /// Puts the tracked files back to before `uuid`.
    func rewind(_ uuid: String) {
        guard let snapshot = snapshots[uuid] else { return }
        for path in tracked {
            let wanted = target(of: path, in: snapshot)
            if let wanted {
                try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                         withIntermediateDirectories: true)
                try? wanted.write(to: URL(fileURLWithPath: path))
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// A file's content before the message: its snapshot of the message, else what it held when first tracked.
    private func target(of path: String, in snapshot: [String: Data?]) -> Data? {
        if let inSnapshot = snapshot[path] { return inSnapshot }
        if let original = originals[path] { return original }
        return nil
    }

    private static func read(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    /// Lines of `new` not in `old` and the other way round (a replaced line is one of each); a missing file has no lines.
    private static func lineChanges(from old: Data?, to new: Data?) -> (added: Int, removed: Int) {
        func lines(_ data: Data?) -> [String] {
            guard let data, !data.isEmpty else { return [] }
            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            return lines
        }
        let difference = lines(new).difference(from: lines(old))
        var added = 0, removed = 0
        for change in difference {
            switch change {
            case .insert: added += 1
            case .remove: removed += 1
            }
        }
        return (added, removed)
    }
}

extension ChatEngine {
    /// `rewind_files`: the dry run answers inside a success, a real run answers `skippedLinks`, and a refusal of a real run is
    /// an error frame (S8 Q1).
    func rewindFiles(id: String, body: ChatObject) {
        let uuid = body["user_message_id"] as? String ?? ""
        let dryRun = body["dry_run"] as? Bool ?? false
        switch checkpoints.plan(uuid) {
        case let .cannot(text):
            send(dryRun ? wire.controlSuccess(id, wire.rewindFilesCannot(text)) : wire.controlError(id, text))
        case let .files(files, insertions, deletions):
            if dryRun {
                send(wire.controlSuccess(id, wire.rewindFilesDryRun(files: files, insertions: insertions, deletions: deletions)))
            } else if checkpoints.mode == .failingRewind {
                send(wire.controlError(id, "The files could not be restored."))
            } else if checkpoints.mode == .dyingRewind {
                checkpoints.rewind(uuid)
                exit(1)
            } else {
                checkpoints.rewind(uuid)
                send(wire.controlSuccess(id, wire.rewindFilesDone()))
            }
        }
    }
}
