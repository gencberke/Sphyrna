import Darwin
import Foundation

/// Unix-socket plumbing shared by the one-way hook server and the request/response control
/// server: one rule for the socket directory, the path limit and the file mode.
enum LocalSocket {
    /// A listening, non-blocking, close-on-exec socket at `path`, mode 0600, inside an
    /// owner-only directory (created when missing). The caller owns the descriptor and
    /// unlinks the path when it stops.
    static func listen(at path: String) throws -> Int32 {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  let permissions = try FileManager.default.attributesOfItem(
                    atPath: parent.path
                  )[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o077 == 0 else {
                throw ClaudeHookTransportError.invalidConfiguration(
                    "socket directory must exist with owner-only permissions"
                )
            }
        } else {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var existing = stat()
        guard lstat(path, &existing) != 0, errno == ENOENT else {
            throw ClaudeHookTransportError.invalidConfiguration("socket path already exists")
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ClaudeHookTransportError.system(operation: "socket", code: errno)
        }
        do {
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw ClaudeHookTransportError.system(operation: "fcntl", code: errno)
            }
            var address = try unixAddress(path: path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else {
                throw ClaudeHookTransportError.system(operation: "bind", code: errno)
            }
            guard chmod(path, 0o600) == 0 else {
                throw ClaudeHookTransportError.system(operation: "chmod", code: errno)
            }
            guard Darwin.listen(descriptor, 16) == 0 else {
                throw ClaudeHookTransportError.system(operation: "listen", code: errno)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            unlink(path)
            throw error
        }
    }

    /// A connected, non-blocking client socket (SIGPIPE off).
    static func connect(path: String, timeout: TimeInterval) throws -> Int32 {
        var address = try unixAddress(path: path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ClaudeHookTransportError.system(operation: "socket", code: errno)
        }
        do {
            try prepare(descriptor)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result < 0 {
                guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else {
                    throw ClaudeHookTransportError.system(operation: "connect", code: errno)
                }
                try wait(
                    descriptor: descriptor, events: Int16(POLLOUT),
                    deadline: ProcessInfo.processInfo.systemUptime + timeout, operation: "connect"
                )
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: socketError))
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                    throw ClaudeHookTransportError.system(operation: "connect status", code: errno)
                }
                guard socketError == 0 else {
                    throw ClaudeHookTransportError.system(operation: "connect", code: socketError)
                }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Non-blocking, close-on-exec, no SIGPIPE: the state every control socket runs in.
    static func prepare(_ descriptor: Int32) throws {
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            throw ClaudeHookTransportError.system(operation: "SO_NOSIGPIPE", code: errno)
        }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ClaudeHookTransportError.system(operation: "fcntl", code: errno)
        }
    }

    static func wait(descriptor: Int32, events: Int16, deadline: TimeInterval,
                     operation: String) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ClaudeHookTransportError.timeout(operation) }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(min(remaining * 1_000, 500)))
            if result > 0 {
                // POLLHUP with readable data still has bytes to drain: only POLLIN decides.
                if item.revents & events != 0 { return }
                // A hung-up reader still gets its answer from recv (0 bytes = end of stream).
                if events == Int16(POLLIN), item.revents & Int16(POLLHUP) != 0 { return }
                guard item.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)) == 0 else {
                    throw ClaudeHookTransportError.system(operation: operation, code: ECONNRESET)
                }
            } else if result < 0, errno != EINTR {
                throw ClaudeHookTransportError.system(operation: operation, code: errno)
            }
        }
    }

    /// Writes everything before the deadline.
    static func writeAll(_ data: Data, to descriptor: Int32, deadline: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                try wait(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline,
                         operation: "write")
            } else {
                throw ClaudeHookTransportError.system(operation: "write", code: errno)
            }
        }
    }

    /// Reads until the peer closes its sending side. More than `limit` bytes is
    /// `messageTooLarge`; no end before the deadline is a timeout.
    static func readToEnd(from descriptor: Int32, limit: Int, deadline: TimeInterval) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count > 0 {
                guard data.count + count <= limit else { throw ClaudeHookTransportError.messageTooLarge }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                try wait(descriptor: descriptor, events: Int16(POLLIN), deadline: deadline,
                         operation: "read")
            } else {
                throw ClaudeHookTransportError.system(operation: "read", code: errno)
            }
        }
    }
}
