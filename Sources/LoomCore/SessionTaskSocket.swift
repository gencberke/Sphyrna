import Darwin
import Foundation

/// A separate launch-local task endpoint. Its handler authenticates every
/// request against a live run; this socket has no app-wide bearer token.
final class SessionTaskSocket: @unchecked Sendable {
    typealias Handler = @Sendable (Data) async -> Data
    private let path: String
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "dev.loom.task.accept", qos: .userInitiated)
    private let serveQueue = DispatchQueue(label: "dev.loom.task.serve", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var stopped = false
    private var connections: [Int32: Task<Void, Never>?] = [:]
    private static let maximumConnections = 32
    private static let requestBytes = 128 * 1024

    init(path: String, handler: @escaping Handler) throws {
        self.path = path
        self.handler = handler
        let fd = try LocalSocket.listen(at: path)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else {
            Darwin.close(fd)
            throw ClaudeHookTransportError.invalidConfiguration("task socket identity is not verified")
        }
        let device = info.st_dev, inode = info.st_ino
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptAvailable(fd) }
        source.setCancelHandler {
            Darwin.close(fd)
            var current = stat()
            if lstat(path, &current) == 0, current.st_uid == geteuid(),
               current.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
               current.st_dev == device, current.st_ino == inode { unlink(path) }
        }
        self.source = source
        source.resume()
    }

    deinit { stop() }

    func stop() {
        let value: (DispatchSourceRead?, [Task<Void, Never>]) = lock.withLock {
            guard !stopped else { return (nil, []) }
            stopped = true
            // Keep the lock until shutdown so a finishing connection cannot
            // close and recycle its descriptor between our snapshot and use.
            for fd in connections.keys { _ = Darwin.shutdown(fd, SHUT_RDWR) }
            let value = (source, connections.values.compactMap { $0 })
            source = nil
            return value
        }
        value.0?.cancel()
        for task in value.1 { task.cancel() }
    }

    private func acceptAvailable(_ fd: Int32) {
        while !lock.withLock({ stopped }) {
            let connection = Darwin.accept(fd, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            let admitted = lock.withLock {
                guard !stopped, connections.count < Self.maximumConnections else { return false }
                connections[connection] = .some(nil)
                return true
            }
            guard admitted, (try? LocalSocket.prepare(connection)) != nil else {
                if admitted { lock.withLock { connections.removeValue(forKey: connection) } }
                Darwin.close(connection)
                continue
            }
            serveQueue.async { [self] in receive(connection) }
        }
    }

    private func receive(_ fd: Int32) {
        let request: Data
        do {
            request = try LocalSocket.readToEnd(from: fd, limit: Self.requestBytes,
                deadline: ProcessInfo.processInfo.systemUptime + 5)
        } catch { finish(fd, nil); return }
        let task = Task { [self] in
            let response = await handler(request)
            finish(fd, Task.isCancelled ? nil : response)
        }
        let cancel = lock.withLock {
            guard !stopped, connections.keys.contains(fd) else { return true }
            connections[fd] = task
            return false
        }
        if cancel { task.cancel() }
    }

    private func finish(_ fd: Int32, _ data: Data?) {
        // Removing first prevents stop from touching a recycled descriptor.
        let owned = lock.withLock { connections.removeValue(forKey: fd) != nil }
        guard owned else { return }
        if let data, data.count <= SessionTaskWireLimits.replyBytes {
            try? LocalSocket.writeAll(data, to: fd, deadline: ProcessInfo.processInfo.systemUptime + 2)
        }
        Darwin.close(fd)
    }
}
