import CoreServices
import Darwin
import Dispatch
import Foundation
import Synchronization

/// What changed under a profile's `projects` folder since the last callback.
public struct UsageTranscriptChange: Equatable, Sendable {
    /// Transcripts that were created, written or renamed.
    public var paths: [URL]
    /// The kernel lost or merged events (or the folder itself moved): only a full scan is sure to see everything.
    public var needsFullScan: Bool

    public init(paths: [URL], needsFullScan: Bool) {
        self.paths = paths
        self.needsFullScan = needsFullScan
    }
}

/// One FSEvents stream over `<profile>/projects`, so the usage numbers follow the transcripts Claude
/// writes (Loom's sessions, plain terminal sessions and subagents alike) instead of waiting for an
/// event Loom happens to know about. The kernel coalesces; there is no timer and no polling, and an
/// idle profile costs nothing. Events for anything that is not a transcript are dropped here.
public final class UsageTranscriptWatcher: @unchecked Sendable {
    private let directory: URL
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "loom.usage.watcher", qos: .utility)
    private let handler: @Sendable (UsageTranscriptChange) -> Void
    private let stream = Mutex<FSEventStreamRef?>(nil)
    /// The path the stream reports under (real path, symlinks resolved).
    private let reportedPrefix: String

    /// - Parameters:
    ///   - directory: the profile's `projects` folder (it may not exist yet; creating it is seen).
    ///   - latency: how long the kernel may merge events before delivering them.
    ///   - handler: called on a private queue.
    public init(directory: URL, latency: TimeInterval = 1, handler: @escaping @Sendable (UsageTranscriptChange) -> Void) {
        let resolved = realpath(directory.path, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        self.directory = URL(fileURLWithPath: resolved ?? directory.path, isDirectory: true)
        self.latency = latency
        self.handler = handler
        reportedPrefix = self.directory.path
    }

    deinit { stop() }

    /// Starts the stream; false when the system refused it. Calling it twice keeps the first stream.
    @discardableResult
    public func start() -> Bool {
        stream.withLock { current in
            guard current == nil else { return true }
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, count, paths, flags, _ in
                    guard let info else { return }
                    let watcher = Unmanaged<UsageTranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
                    let list = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []
                    watcher.deliver(paths: list, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
                },
                &context, [directory.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else { return false }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            current = created
            return true
        }
    }

    /// Stops the stream; no callback runs after this returns.
    public func stop() {
        let finished = stream.withLock { current -> FSEventStreamRef? in
            defer { current = nil }
            return current
        }
        guard let finished else { return }
        FSEventStreamStop(finished)
        FSEventStreamInvalidate(finished)
        FSEventStreamRelease(finished)
        queue.sync {} // a callback already running has finished
    }

    private static let lostEvents = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
    private static let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
    private static let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)

    private func deliver(paths: [String], flags: [FSEventStreamEventFlags]) {
        var changed: [URL] = []
        var seen = Set<String>()
        var full = false
        for (path, flag) in zip(paths, flags) {
            if flag & Self.lostEvents != 0 { full = true }
            guard flag & Self.file != 0, flag & Self.removed == 0, Self.isTranscript(path, under: reportedPrefix),
                  seen.insert(path).inserted else { continue }
            changed.append(URL(fileURLWithPath: path))
        }
        guard full || !changed.isEmpty else { return }
        handler(UsageTranscriptChange(paths: changed, needsFullScan: full))
    }

    /// A transcript file the index would read: `.jsonl`, not in a skipped folder, inside the watched folder.
    static func isTranscript(_ path: String, under prefix: String) -> Bool {
        guard path.hasPrefix(prefix + "/") else { return false }
        let relative = path.dropFirst(prefix.count + 1).split(separator: "/").map(String.init)
        guard let name = relative.last, UsageTranscriptWalker.isTranscriptName(name) else { return false }
        return !relative.dropLast().contains { UsageTranscriptWalker.skippedDirectories.contains($0) }
    }
}
