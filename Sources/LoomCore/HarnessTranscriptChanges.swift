import Darwin
import Foundation

public struct CodexRecordedChange: Equatable, Sendable {
    public enum Kind: Sendable { case added, modified, deleted }
    public let path: String
    public let oldPath: String?
    public let kind: Kind
    public let hunks: [DiffHunk]
}

public struct CodexChangesResult: Equatable, Sendable {
    public var changes: [CodexRecordedChange]
    /// A bound, unknown shape, missing turn cwd, or a path outside the workspace omitted part of the read.
    public var partial: Bool
    public var eventsSeen: Int
}

/// Reads only persisted, successful structured file changes; shell output is never interpreted as an edit.
public enum CodexChangesReader {
    public enum Scope: Sendable { case lastTurn, wholeSession }
    private struct Event {
        var id: String
        var turnID: String?
        var changes: [CodexRecordedChange]
    }
    private enum Parsed { case ignored, unknown, event(Event) }
    private static let byteLimit = 64 * 1024 * 1024
    private static let pageBytes = 256 * 1024
    private static let lineLimit = 1024 * 1024
    private static let pendingLimit = 256
    private static let changesLimit = 1_000
    private static let retainedByteLimit = 2 * 1024 * 1024
    private static let eventLimit = 4_096
    private static let turnMarker = Data("\"turn_context\"".utf8)
    private static let eventMarker = Data("\"event_msg\"".utf8)
    private static let responseMarker = Data("\"response_item\"".utf8)
    private static let patchMarker = Data("\"patch_apply_end\"".utf8)
    private static let itemMarker = Data("\"item_completed\"".utf8)
    private static let messageMarker = Data("\"message\"".utf8)
    private static let userMarker = Data("\"user\"".utf8)

    public static func scan(file: CodexRolloutFile, workspace: String, scope: Scope) -> CodexChangesResult? {
        guard let root = canonicalExisting(workspace), let reader = CodexRolloutReader(file: file) else { return nil }
        defer { reader.close() }
        var pending: [String: [Event]] = [:]
        var seen: Set<String> = []
        var changes: [CodexRecordedChange] = []
        var partial = false
        var reachedStart = false
        var boundary = false
        var pages = 0
        var retainedBytes = 0
        func append(_ event: Event, cwd: String?) {
            for change in event.changes {
                guard changes.count < changesLimit else { partial = true; return }
                guard let path = scoped(change.path, cwd: cwd, root: root),
                      change.oldPath == nil || scoped(change.oldPath!, cwd: cwd, root: root) != nil else {
                    partial = true
                    continue
                }
                changes.append(CodexRecordedChange(path: path,
                    oldPath: change.oldPath.flatMap { scoped($0, cwd: cwd, root: root) }, kind: change.kind, hunks: change.hunks))
            }
        }
        scanning: while pages * pageBytes < byteLimit && !Task.isCancelled {
            let page = reader.readBackward(pageBytes: pageBytes, maximumLineBytes: lineLimit)
            pages += 1
            reachedStart = page.reachedStart
            for record in page.records.reversed() {
                guard let bytes = record.bytes else { partial = true; continue }
                let possibleTurn = bytes.range(of: turnMarker) != nil
                let possibleEvent = bytes.range(of: eventMarker) != nil
                    && (bytes.range(of: patchMarker) != nil || bytes.range(of: itemMarker) != nil)
                let possibleUser = bytes.range(of: responseMarker) != nil && bytes.range(of: messageMarker) != nil
                    && bytes.range(of: userMarker) != nil
                guard possibleTurn || possibleEvent || possibleUser else { continue }
                guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    partial = true
                    continue
                }
                if let turn = turnContext(object), let events = pending.removeValue(forKey: turn.id) {
                    for event in events { append(event, cwd: turn.cwd) }
                    if boundary && pending.isEmpty { break scanning }
                }
                if boundary { continue }
                if case .lastTurn = scope, CodexRolloutText.message(in: object)?.role == .user {
                    boundary = true
                    if pending.isEmpty { break scanning }
                    continue
                }
                switch parse(object) {
                case .ignored: break
                case .unknown: partial = true
                case let .event(event):
                    guard seen.count < eventLimit else { partial = true; break scanning }
                    guard seen.insert(event.id).inserted else { continue }
                    let size = event.changes.reduce(0) { total, change in
                        total + change.path.utf8.count + change.hunks.reduce(0) { n, hunk in
                            n + hunk.lines.reduce(0) { $0 + $1.utf8.count }
                        }
                    }
                    guard size <= retainedByteLimit - retainedBytes else { partial = true; continue }
                    retainedBytes += size
                    if event.changes.allSatisfy({ $0.path.hasPrefix("/") && ($0.oldPath?.hasPrefix("/") ?? true) }) {
                        append(event, cwd: nil)
                    } else if let turnID = event.turnID, !turnID.isEmpty {
                        guard pending.values.reduce(0, { $0 + $1.count }) < pendingLimit else { partial = true; break }
                        pending[turnID, default: []].append(event)
                    } else { partial = true }
                }
            }
            if page.reachedStart { break }
        }
        if !pending.isEmpty || Task.isCancelled || reader.skippedLongLine || (!reachedStart && !boundary) { partial = true }
        return CodexChangesResult(changes: Array(changes.reversed()), partial: partial, eventsSeen: seen.count)
    }

    private static func turnContext(_ object: [String: Any]) -> (id: String, cwd: String)? {
        guard object["type"] as? String == "turn_context", let payload = object["payload"] as? [String: Any],
              let id = payload["turn_id"] as? String, !id.isEmpty, let cwd = payload["cwd"] as? String else { return nil }
        return (id, cwd)
    }

    private static func parse(_ object: [String: Any]) -> Parsed {
        guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else { return .ignored }
        let id: String
        let rawChanges: [String: Any]
        switch type {
        case "patch_apply_end":
            guard payload["success"] as? Bool == true else { return .ignored }
            guard let call = payload["call_id"] as? String, !call.isEmpty,
                  let changes = payload["changes"] as? [String: Any] else { return .unknown }
            id = call
            rawChanges = changes
        case "item_completed":
            guard let item = payload["item"] as? [String: Any], item["type"] as? String == "FileChange" else { return .ignored }
            guard item["status"] as? String == "completed" else { return .ignored }
            guard let call = item["id"] as? String, !call.isEmpty,
                  let changes = item["changes"] as? [String: Any] else { return .unknown }
            id = call
            rawChanges = changes
        default: return .ignored
        }
        var result: [CodexRecordedChange] = []
        for (path, raw) in rawChanges.sorted(by: { $0.key < $1.key }) {
            guard !path.isEmpty, let change = raw as? [String: Any], let kind = change["type"] as? String else { return .unknown }
            switch kind {
            case "add", "delete":
                guard let content = change["content"] as? String else { return .unknown }
                var lines = content.components(separatedBy: "\n")
                if lines.last == "" { lines.removeLast() }
                let adding = kind == "add"
                let hunk = DiffHunk(oldStart: adding ? 0 : 1, oldLines: adding ? 0 : lines.count,
                                    newStart: adding ? 1 : 0, newLines: adding ? lines.count : 0,
                                    lines: lines.map { (adding ? "+" : "-") + $0 })
                result.append(CodexRecordedChange(path: path, oldPath: nil, kind: adding ? .added : .deleted, hunks: [hunk]))
            case "update":
                guard let diff = change["unified_diff"] as? String else { return .unknown }
                let parsed = UnifiedDiff.parse(diff)
                guard !parsed.hunks.isEmpty, !parsed.isBinary else { return .unknown }
                let move = change["move_path"] as? String
                if change["move_path"] != nil && !(change["move_path"] is NSNull) && (move == nil || move!.isEmpty) { return .unknown }
                result.append(CodexRecordedChange(path: move ?? path, oldPath: move == nil ? nil : path,
                                                   kind: .modified, hunks: parsed.hunks))
            default: return .unknown
            }
        }
        return .event(Event(id: id, turnID: payload["turn_id"] as? String, changes: result))
    }

    /// Resolve an existing path, or the nearest existing ancestor for a new/deleted path, before enforcing the workspace root.
    private static func scoped(_ path: String, cwd: String?, root: String) -> String? {
        guard !path.isEmpty else { return nil }
        let url: URL
        if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else {
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            url = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(path)
        }
        var part = url.standardizedFileURL
        var tail: [String] = []
        var resolved: String?
        for _ in 0..<64 {
            if let found = canonicalExisting(part.path) { resolved = found; break }
            let name = part.lastPathComponent
            guard !name.isEmpty, part.path != "/" else { break }
            tail.append(name)
            part.deleteLastPathComponent()
        }
        guard let resolved else { return nil }
        var result = URL(fileURLWithPath: resolved, isDirectory: true)
        for component in tail.reversed() { result.appendPathComponent(component) }
        let absolute = result.standardizedFileURL.path
        guard absolute != root, absolute.hasPrefix(root.hasSuffix("/") ? root : root + "/") else { return nil }
        return absolute
    }

    private static func canonicalExisting(_ path: String) -> String? {
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
