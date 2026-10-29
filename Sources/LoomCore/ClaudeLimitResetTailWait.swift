import Darwin
import Dispatch
import Foundation

extension ClaudeLimitResetSignalReader {
    /// Native transcript insertion is queued independently of StopFailure.
    /// Subscribe before reading, then retry only actual file events, for at most
    /// five seconds/eight bounded reads. There is no repeating timer.
    static func waitForSignal(_ context: ClaudeLimitResetContext, timeout: TimeInterval = 5,
                              onRead: (@Sendable () -> Void)? = nil) async -> ClaudeLimitResetSignal? {
        guard UUID(uuidString: context.nativeSessionID) != nil, context.configDirectory.isFileURL,
              context.configDirectory.path.hasPrefix("/"), context.workingDirectory.hasPrefix("/"),
              timeout.isFinite, timeout > 0, timeout <= 5 else { return nil }
        let events = ClaudeLimitResetFileEvents(context: context, timeout: timeout)
        let result: ClaudeLimitResetSignal? = await withTaskCancellationHandler {
            events.start()
            var reads = 0
            for await _ in events.changes {
                guard !Task.isCancelled, reads < 8 else { break }
                reads += 1
                let signal = await read(context)
                onRead?()
                if let signal { return Optional(signal) }
            }
            return nil as ClaudeLimitResetSignal?
        } onCancel: { events.stop() }
        await events.stopAndWait()
        return result
    }
}

private final class ClaudeLimitResetFileEvents: @unchecked Sendable {
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "loom.claude.limit-tail", qos: .utility)
    private let file: URL
    private let config: URL
    private let timeout: TimeInterval
    private let closed = DispatchGroup()
    // Confined to queue; every source owns and closes its own descriptor.
    private var stopped = false
    private var started = false
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var deadline: DispatchWorkItem?

    init(context: ClaudeLimitResetContext, timeout: TimeInterval) {
        config = context.configDirectory
        file = config.appendingPathComponent("projects")
            .appendingPathComponent(ClaudeTranscriptLocator.folderName(forWorkingDirectory: context.workingDirectory))
            .appendingPathComponent(context.nativeSessionID + ".jsonl")
        self.timeout = timeout
        (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func start() {
        queue.async { [self] in
            guard !started, !stopped else { return }
            started = true
            attach()
            let work = DispatchWorkItem { [weak self] in self?.tearDown() }
            deadline = work
            queue.asyncAfter(deadline: .now() + timeout, execute: work)
            continuation.yield(())
        }
    }

    func stop() { queue.async { [self] in tearDown() } }

    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                tearDown()
                closed.notify(queue: queue) { continuation.resume() }
            }
        }
    }

    private func tearDown() {
        guard !stopped else { return }
        stopped = true
        deadline?.cancel(); deadline = nil
        sources.values.forEach { $0.cancel() }; sources.removeAll()
        continuation.finish()
    }

    private func attach() {
        guard !stopped else { return }
        // Watch the closest existing directory within this profile until the
        // exact file appears. Never watch HOME or scan directory contents.
        var directory = file.deletingLastPathComponent()
        while directory.path != config.path, !Self.directoryExists(directory.path) {
            directory.deleteLastPathComponent()
        }
        let paths = Set([file.path, directory.path])
        for (path, source) in sources where !paths.contains(path) { source.cancel(); sources[path] = nil }
        for path in paths where sources[path] == nil {
            let fd = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            closed.enter()
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete, .revoke], queue: queue)
            source.setCancelHandler { [closed] in close(fd); closed.leave() }
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source, !stopped else { return }
                if !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                    sources[path] = nil; source.cancel()
                }
                attach()
                continuation.yield(())
            }
            sources[path] = source
            source.resume()
        }
    }

    private static func directoryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
