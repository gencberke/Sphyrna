import Foundation
import LoomCore

/// Reloadable Changes payloads only. `ChangesState` owns and mutates it on MainActor; user text never enters it.
struct ChangesPayloadCache {
    static let maximumEntries = 64
    static let maximumBytes = 16 * 1_024 * 1_024
    /// Reserve one small slot for an explicit failure when active reads pin the rest of the budget.
    static let maximumRegularBytes = maximumBytes - 16 * 1_024

    enum Key: Hashable {
        case scope(UUID, ChangesScope)
        case diff(UUID, String)

        var sessionID: UUID {
            switch self {
            case let .scope(id, _), let .diff(id, _): id
            }
        }
    }

    private struct Entry {
        var bytes: Int
        var age: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0

    mutating func touch(_ key: Key) {
        guard var entry = entries[key] else { return }
        clock &+= 1
        entry.age = clock
        entries[key] = entry
    }

    mutating func remove(_ key: Key) {
        if let removed = entries.removeValue(forKey: key) { bytes -= removed.bytes }
    }

    mutating func removeSession(_ id: UUID) {
        for key in entries.keys.filter({ $0.sessionID == id }) { remove(key) }
    }

    mutating func removeDiffs(_ id: UUID) {
        for key in entries.keys.filter({ $0.sessionID == id }) {
            if case .diff = key { remove(key) }
        }
    }

    /// The returned victims are already removed. If protected entries leave no room, nothing changes.
    mutating func insert(_ key: Key, bytes size: Int, fallback: Bool = false, protected: (Key) -> Bool) -> [Key]? {
        let byteLimit = fallback ? Self.maximumBytes : Self.maximumRegularBytes
        let entryLimit = fallback ? Self.maximumEntries : Self.maximumEntries - 1
        guard size <= byteLimit else { return nil }
        var proposed = self
        proposed.remove(key)
        proposed.clock &+= 1
        proposed.entries[key] = Entry(bytes: size, age: proposed.clock)
        proposed.bytes += size
        var victims: [Key] = []
        while proposed.entries.count > entryLimit || proposed.bytes > byteLimit {
            guard let victim = proposed.entries.filter({ $0.key != key && !protected($0.key) })
                .min(by: { $0.value.age < $1.value.age })?.key else { return nil }
            proposed.remove(victim)
            victims.append(victim)
        }
        self = proposed
        return victims
    }

    /// Conservative retained-size estimate; stop as soon as the budget is exceeded.
    static func estimate(_ state: ChangesScopeState) -> Int? {
        var meter = Meter()
        switch state {
        case .idle, .loading: return nil
        case let .ready(data):
            meter.add(256)
            meter.add(data.baseName)
            for file in data.files {
                meter.add(128)
                meter.add(file.id); meter.add(file.displayPath); meter.add(file.absolutePath); meter.add(file.oldPath)
                if meter.exceeded { return meter.bytes }
            }
            for (path, hunks) in data.hunks {
                meter.add(96); meter.add(path)
                if meter.exceeded { return meter.bytes }
                for hunk in hunks {
                    meter.add(hunk)
                    if meter.exceeded { return meter.bytes }
                }
            }
            if let list = data.list {
                meter.add(128); meter.add(list.root); meter.add(list.baseName); meter.add(list.compareTo)
                for file in list.files {
                    meter.add(96); meter.add(file.path); meter.add(file.oldPath)
                    if meter.exceeded { return meter.bytes }
                }
            }
        case let .off(reason), let .failed(reason): meter.add(128); meter.add(reason)
        case .timedOut: meter.add(128)
        }
        return meter.bytes
    }

    static func estimate(_ diff: ChangesFileDiff, id: String) -> Int? {
        var meter = Meter()
        meter.add(128); meter.add(id)
        switch diff {
        case .loading: return nil
        case let .hunks(hunks):
            for hunk in hunks {
                meter.add(hunk)
                if meter.exceeded { return meter.bytes }
            }
        case let .failed(reason): meter.add(reason)
        case .binary, .tooLarge, .timedOut: break
        }
        return meter.bytes
    }

    private struct Meter {
        private(set) var bytes = 0
        var exceeded: Bool { bytes > ChangesPayloadCache.maximumBytes }

        mutating func add(_ count: Int) {
            guard !exceeded else { return }
            let remaining = ChangesPayloadCache.maximumBytes - bytes
            bytes = count > remaining ? ChangesPayloadCache.maximumBytes + 1 : bytes + count
        }

        mutating func add(_ text: String?) {
            guard let text, !exceeded else { return }
            add(32)
            if !exceeded { add(text.utf8.count) }
        }

        mutating func add(_ hunk: DiffHunk) {
            add(96)
            for line in hunk.lines {
                add(line)
                if exceeded { return }
            }
        }
    }
}
