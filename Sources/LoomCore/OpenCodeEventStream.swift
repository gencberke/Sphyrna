import Darwin
import Foundation

/// One authenticated, volatile native feed. One serial queue owns the
/// nonblocking numeric-loopback socket and readiness callbacks. There is no
/// proxy, reconnect, timer or polling during the subscribed lifetime.
final class OpenCodeEventStream: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sphyrna.opencode.events")
    private let owner: ProcessIdentity
    private let port: UInt16
    private var authorization: String
    private let onConnected: @Sendable () -> Void
    private let onEvent: @Sendable (OpenCodeEvent) -> Bool
    private let onDisconnect: @Sendable () -> Void
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var ready = false
    private var closed = false
    private var connected = false
    private var witnessed = false
    private var fd: Int32 = -1
    private var outbound = Data()
    private var written = 0
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var deadline: DispatchSourceTimer?
    private var wire = OpenCodeEventWire()
    private var decoder = OpenCodeEventDecoder()

    private init(serverURL: URL, password: String, owner: ProcessIdentity,
                 onConnected: @escaping @Sendable () -> Void,
                 onEvent: @escaping @Sendable (OpenCodeEvent) -> Bool,
                 onDisconnect: @escaping @Sendable () -> Void) throws {
        guard OpenCodeLaunchProfile.validServerURL(serverURL),
              OpenCodeLaunchProfile.validPassword(password),
              let number = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)?.port else {
            throw OpenCodeError.invalidTarget
        }
        self.port = UInt16(number)
        self.owner = owner
        self.authorization = Data("opencode:\(password)".utf8).base64EncodedString()
        self.onConnected = onConnected
        self.onEvent = onEvent
        self.onDisconnect = onDisconnect
    }

    static func open(serverURL: URL, password: String, owner: ProcessIdentity, timeout: TimeInterval = 5,
                     onConnected: @escaping @Sendable () -> Void,
                     onEvent: @escaping @Sendable (OpenCodeEvent) -> Bool,
                     onDisconnect: @escaping @Sendable () -> Void) async throws -> OpenCodeEventStream {
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw OpenCodeError.invalidTarget }
        let stream = try OpenCodeEventStream(serverURL: serverURL, password: password, owner: owner,
                                             onConnected: onConnected, onEvent: onEvent, onDisconnect: onDisconnect)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                stream.queue.async { stream.start(timeout: timeout, continuation: continuation) }
            }
            try Task.checkCancellation()
            return stream
        } onCancel: { stream.cancel() }
    }

    func close() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                finish(OpenCodeError.closed)
                continuation.resume()
            }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        queue.async { [self] in finish(CancellationError()) }
    }

    private func start(timeout: TimeInterval, continuation: CheckedContinuation<Void, any Error>) {
        guard !closed, !lock.withLock({ cancelled }) else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        started = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(OpenCodeError.timeout) }
        deadline = timer
        timer.resume()

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { finish(OpenCodeError.unavailable); return }
        fd = socketFD
        var yes: Int32 = 1
        let flags = fcntl(socketFD, F_GETFL)
        guard flags >= 0,
              setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
              fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(socketFD, F_SETFD, FD_CLOEXEC) == 0 else { finish(OpenCodeError.unavailable); return }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { connected = true }
        else if errno != EINPROGRESS && errno != EAGAIN && errno != EINTR {
            finish(OpenCodeError.unavailable); return
        }
        let source = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.writeReady() }
        writeSource = source
        source.resume()
    }

    private func writeReady() {
        guard !closed, fd >= 0, writeSource != nil else { return }
        if !connected {
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                finish(OpenCodeError.unavailable); return
            }
            connected = true
        }
        if !witnessed {
            guard OpenCodeListenerOwnership.owns(leader: owner, port: port) else {
                finish(OpenCodeError.unverifiedServer); return
            }
            witnessed = true
            let types = [
                "session.created", "session.deleted", "session.inbox.enqueued",
                "session.inbox.delivered", "session.inbox.cancelled",
                "session.execution.started", "session.execution.succeeded",
                "session.execution.failed", "session.execution.interrupted"
            ]
            let query = types.map { "types=\($0)" }.joined(separator: "&")
            let headers = "GET /api/event?\(query) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Basic \(authorization)\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n"
            outbound = Data(headers.utf8)
            authorization = ""
        }
        while written < outbound.count {
            let count = lock.withLock { () -> Int in
                guard !cancelled else { return -2 }
                return outbound.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: written), outbound.count - written, 0) }
            }
            if count == -2 { finish(CancellationError()); return }
            if count > 0 { written += count; continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            finish(OpenCodeError.unavailable); return
        }
        outbound.removeAll(keepingCapacity: false)
        writeSource?.cancel()
        writeSource = nil
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readReady() }
        readSource = source
        source.resume()
    }

    private func readReady() {
        guard !closed, fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        // Leave the queue regularly even if a peer continually writes.
        for _ in 0..<16 {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count == 0 { finish(OpenCodeError.unavailable); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish(OpenCodeError.unavailable); return
            }
            guard OpenCodeListenerOwnership.owns(leader: owner, port: port) else {
                finish(OpenCodeError.unverifiedServer); return
            }
            do {
                let frames = try wire.feed(Data(buffer.prefix(count)))
                for bytes in frames {
                    for event in try decoder.feed(bytes) {
                        if !ready {
                            guard event.type == "server.connected", event.sessionID == nil,
                                  event.sequence == nil, event.inboxID == nil else {
                                throw OpenCodeError.invalidResponse
                            }
                            ready = true
                            deadline?.cancel()
                            deadline = nil
                            onConnected()
                            continuation?.resume()
                            continuation = nil
                        } else {
                            guard event.type != "server.connected", onEvent(event) else {
                                throw OpenCodeError.invalidResponse
                            }
                        }
                    }
                }
                if wire.ended { finish(OpenCodeError.unavailable); return }
            } catch { finish(error); return }
        }
    }

    private func finish(_ error: any Error) {
        guard !closed else { return }
        closed = true
        if started { onDisconnect() }
        deadline?.cancel()
        deadline = nil
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        outbound.removeAll(keepingCapacity: false)
        authorization = ""
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }

    deinit {
        deadline?.cancel()
        readSource?.cancel()
        writeSource?.cancel()
        if fd >= 0 { Darwin.close(fd) }
    }
}

/// Incremental HTTP/1.1 framing for a long-lived event body. Only headers and
/// chunk framing are buffered; event payload size is bounded by the SSE decoder.
private struct OpenCodeEventWire {
    private enum Mode { case header, identity, chunkSize, chunkBody(Int), chunkEnd, trailers }
    private var mode = Mode.header
    private var bytes = [UInt8]()
    private var trailerBytes = 0
    private(set) var ended = false

    mutating func feed(_ input: Data) throws -> [Data] {
        guard !ended else { throw OpenCodeError.invalidResponse }
        bytes.append(contentsOf: input)
        var output: [Data] = []
        while !bytes.isEmpty {
            switch mode {
            case .header:
                guard let end = separator() else {
                    guard bytes.count <= OpenCodeHTTP.headerLimit + 3 else { throw OpenCodeError.responseTooLarge }
                    return output
                }
                guard end <= OpenCodeHTTP.headerLimit else { throw OpenCodeError.responseTooLarge }
                let header = Array(bytes[..<end])
                bytes.removeFirst(end + 4)
                mode = try parseHeader(header)
            case .identity:
                output.append(Data(bytes))
                bytes.removeAll(keepingCapacity: true)
            case .chunkSize:
                guard let end = lineEnd() else {
                    guard bytes.count <= 128 else { throw OpenCodeError.invalidResponse }
                    return output
                }
                guard end <= 128 else { throw OpenCodeError.invalidResponse }
                let digits = bytes[..<end].prefix { $0 != 59 }
                guard !digits.isEmpty, digits.count <= 8,
                      digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let size = Int(String(decoding: digits, as: UTF8.self), radix: 16),
                      size <= 256 * 1024 else { throw OpenCodeError.responseTooLarge }
                bytes.removeFirst(end + 2)
                mode = size == 0 ? .trailers : .chunkBody(size)
            case let .chunkBody(remaining):
                let count = min(remaining, bytes.count)
                output.append(Data(bytes.prefix(count)))
                bytes.removeFirst(count)
                mode = count == remaining ? .chunkEnd : .chunkBody(remaining - count)
            case .chunkEnd:
                guard bytes.count >= 2 else { return output }
                guard bytes[0] == 13, bytes[1] == 10 else { throw OpenCodeError.invalidResponse }
                bytes.removeFirst(2)
                mode = .chunkSize
            case .trailers:
                guard let end = lineEnd() else {
                    guard trailerBytes + bytes.count <= OpenCodeHTTP.headerLimit else { throw OpenCodeError.responseTooLarge }
                    return output
                }
                trailerBytes += end + 2
                guard trailerBytes <= OpenCodeHTTP.headerLimit else { throw OpenCodeError.responseTooLarge }
                if end == 0 {
                    bytes.removeFirst(2)
                    guard bytes.isEmpty else { throw OpenCodeError.invalidResponse }
                    ended = true
                    return output
                }
                guard bytes[..<end].contains(58) else { throw OpenCodeError.invalidResponse }
                bytes.removeFirst(end + 2)
            }
        }
        return output
    }

    private func parseHeader(_ data: [UInt8]) throws -> Mode {
        guard let text = String(bytes: data, encoding: .utf8) else { throw OpenCodeError.invalidResponse }
        let lines = text.components(separatedBy: "\r\n")
        let status = (lines.first ?? "").split(separator: " ")
        guard status.count >= 2, status[0] == "HTTP/1.1", status[1] == "200" else {
            throw OpenCodeError.unverifiedServer
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw OpenCodeError.invalidResponse }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { throw OpenCodeError.invalidResponse }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["content-type"]?.lowercased().split(separator: ";").first == "text/event-stream",
              headers["content-length"] == nil else { throw OpenCodeError.invalidResponse }
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked" else { throw OpenCodeError.invalidResponse }
            return .chunkSize
        }
        return .identity
    }

    private func separator() -> Int? {
        guard bytes.count >= 4 else { return nil }
        return (0...(bytes.count - 4)).first { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10 }
    }
    private func lineEnd() -> Int? {
        guard bytes.count >= 2 else { return nil }
        return (0..<(bytes.count - 1)).first { bytes[$0] == 13 && bytes[$0 + 1] == 10 }
    }
}
