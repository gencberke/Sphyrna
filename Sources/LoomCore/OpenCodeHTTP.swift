import Darwin
import Foundation

/// Closing a client revokes every in-flight request. The descriptor belongs to
/// the request's worker and is closed only by that worker, avoiding FD reuse races.
final class OpenCodeHTTPLease: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    func revoke() { lock.withLock { revoked = true } }
    var isRevoked: Bool { lock.withLock { revoked } }
    func withWritePermit<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard !revoked else { throw OpenCodeError.closed }
            return try body()
        }
    }
}

/// One request per connection to the app-owned numeric loopback server. This
/// path never uses a proxy, follows a redirect, retries, or logs provider bytes.
/// The credential and body are written only after the connected port's listener
/// has been witnessed in the exact born process.
enum OpenCodeHTTP {
    static let bodyLimit = 256 * 1024
    static let requestLimit = 64 * 1024
    static let headerLimit = 16 * 1024
    private static let rawLimit = 1024 * 1024

    static func request(_ request: URLRequest, leader: ProcessIdentity, timeout: TimeInterval,
                        lease: OpenCodeHTTPLease) async throws -> (Data, HTTPURLResponse) {
        let cancellation = OpenCodeHTTPLease()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let worker = Task.detached(priority: .userInitiated) {
                try perform(request, leader: leader, timeout: timeout, lease: lease, cancellation: cancellation)
            }
            return try await worker.value
        } onCancel: { cancellation.revoke() }
    }

    private static func perform(_ request: URLRequest, leader: ProcessIdentity, timeout: TimeInterval,
                                lease: OpenCodeHTTPLease, cancellation: OpenCodeHTTPLease) throws -> (Data, HTTPURLResponse) {
        guard timeout.isFinite, timeout > 0, timeout <= 30,
              let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let method = request.httpMethod, method == "GET" || method == "POST",
              let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Basic "), authorization.utf8.count <= 512,
              authorization.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }) else { throw OpenCodeError.invalidTarget }
        let body = request.httpBody ?? Data()
        guard body.count <= requestLimit else { throw OpenCodeError.responseTooLarge }
        let path = (parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath)
            + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        guard path.utf8.count <= 4096, !path.contains("\r"), !path.contains("\n") else { throw OpenCodeError.invalidTarget }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try check(lease, cancellation)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OpenCodeError.unavailable }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw OpenCodeError.unavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else { throw OpenCodeError.unavailable }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline, lease: lease, cancellation: cancellation)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw OpenCodeError.unavailable }
        }
        try check(lease, cancellation)
        guard OpenCodeListenerOwnership.owns(leader: leader, port: UInt16(port)) else { throw OpenCodeError.unverifiedServer }
        try check(lease, cancellation)
        let headers = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: \(authorization)\r\nAccept: application/json\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var outgoing = Data(headers.utf8)
        outgoing.append(body)
        try write(outgoing, fd: fd, deadline: deadline, lease: lease, cancellation: cancellation)
        let result = try read(fd: fd, url: url, deadline: deadline, lease: lease, cancellation: cancellation)
        try check(lease, cancellation)
        guard OpenCodeListenerOwnership.owns(leader: leader, port: UInt16(port)) else { throw OpenCodeError.unverifiedServer }
        return result
    }

    private static func check(_ lease: OpenCodeHTTPLease, _ cancellation: OpenCodeHTTPLease) throws {
        if cancellation.isRevoked || Task.isCancelled { throw CancellationError() }
        if lease.isRevoked { throw OpenCodeError.closed }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval,
                             lease: OpenCodeHTTPLease, cancellation: OpenCodeHTTPLease) throws {
        while true {
            try check(lease, cancellation)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw OpenCodeError.timeout }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(100, max(1, remaining * 1000))))
            if result > 0 {
                guard item.revents & Int16(POLLNVAL) == 0 else { throw OpenCodeError.unavailable }
                return
            }
            if result < 0 && errno != EINTR { throw OpenCodeError.unavailable }
        }
    }

    private static func write(_ data: Data, fd: Int32, deadline: TimeInterval,
                              lease: OpenCodeHTTPLease, cancellation: OpenCodeHTTPLease) throws {
        var offset = 0
        while offset < data.count {
            try check(lease, cancellation)
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw OpenCodeError.timeout }
            let count: Int
            do {
                count = try cancellation.withWritePermit {
                    try lease.withWritePermit {
                        data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
                    }
                }
            } catch {
                if cancellation.isRevoked { throw CancellationError() }
                throw error
            }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline, lease: lease, cancellation: cancellation)
            } else { throw OpenCodeError.unavailable }
        }
    }

    private enum Framing {
        case length(Int), chunked, untilClose
    }

    private static func read(fd: Int32, url: URL, deadline: TimeInterval,
                             lease: OpenCodeHTTPLease, cancellation: OpenCodeHTTPLease) throws -> (Data, HTTPURLResponse) {
        var header = [UInt8]()
        var framing: Framing?
        var response: HTTPURLResponse?
        var body = Data()
        var chunks = ChunkDecoder()
        var rawBytes = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            try check(lease, cancellation)
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw OpenCodeError.timeout }
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try wait(fd, events: Int16(POLLIN), deadline: deadline, lease: lease, cancellation: cancellation)
                    continue
                }
                throw OpenCodeError.unavailable
            }
            if count == 0 {
                guard let response, case .untilClose = framing else { throw OpenCodeError.invalidResponse }
                return (body, response)
            }
            rawBytes += count
            guard rawBytes <= rawLimit else { throw OpenCodeError.responseTooLarge }
            var incoming = Array(buffer.prefix(count))
            if framing == nil {
                header.append(contentsOf: incoming)
                if let end = separator(in: header) {
                    guard end <= headerLimit else { throw OpenCodeError.responseTooLarge }
                    let parsed = try parseHeader(Array(header[..<end]), url: url)
                    framing = parsed.0
                    response = parsed.1
                    incoming = Array(header.dropFirst(end + 4))
                    header.removeAll(keepingCapacity: false)
                } else {
                    guard header.count <= headerLimit + 3 else { throw OpenCodeError.responseTooLarge }
                    continue
                }
            }
            guard let framing, let response else { throw OpenCodeError.invalidResponse }
            switch framing {
            case let .length(length):
                guard body.count + incoming.count <= length else { throw OpenCodeError.invalidResponse }
                body.append(contentsOf: incoming)
                if body.count == length { return (body, response) }
            case .chunked:
                if try chunks.append(incoming) { return (chunks.output, response) }
            case .untilClose:
                guard body.count + incoming.count <= bodyLimit else { throw OpenCodeError.responseTooLarge }
                body.append(contentsOf: incoming)
            }
        }
    }

    private static func separator(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        return (0...(bytes.count - 4)).first { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10 }
    }

    private static func parseHeader(_ bytes: [UInt8], url: URL) throws -> (Framing, HTTPURLResponse) {
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw OpenCodeError.invalidResponse }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw OpenCodeError.invalidResponse }
        let status = first.split(separator: " ", omittingEmptySubsequences: true)
        guard status.count >= 2, (status[0] == "HTTP/1.1" || status[0] == "HTTP/1.0"),
              let code = Int(status[1]), (100...599).contains(code) else { throw OpenCodeError.invalidResponse }
        guard (200...299).contains(code) else { throw OpenCodeError.httpStatus(code) }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw OpenCodeError.invalidResponse }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard fields[name] == nil else { throw OpenCodeError.invalidResponse }
            fields[name] = value
        }
        let framing: Framing
        if let transfer = fields["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", fields["content-length"] == nil else { throw OpenCodeError.invalidResponse }
            framing = .chunked
        } else if let raw = fields["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                  let size = Int(raw), size >= 0, size <= bodyLimit else { throw OpenCodeError.responseTooLarge }
            framing = .length(size)
        } else { framing = .untilClose }
        guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: String(status[0]), headerFields: fields) else {
            throw OpenCodeError.invalidResponse
        }
        return (framing, response)
    }

    private struct ChunkDecoder {
        enum State { case size, data(Int), trailers }
        var state: State = .size
        var bytes: [UInt8] = []
        var cursor = 0
        var output = Data()
        var count = 0
        var trailerBytes = 0

        mutating func append(_ incoming: [UInt8]) throws -> Bool {
            if cursor > 0 { bytes.removeFirst(cursor); cursor = 0 }
            guard bytes.count + incoming.count <= OpenCodeHTTP.bodyLimit + OpenCodeHTTP.headerLimit else {
                throw OpenCodeError.responseTooLarge
            }
            bytes.append(contentsOf: incoming)
            while true {
                switch state {
                case .size:
                    guard let end = lineEnd() else {
                        if bytes.count - cursor > 128 { throw OpenCodeError.invalidResponse }
                        return false
                    }
                    let line = bytes[cursor..<end]
                    guard line.count <= 128 else { throw OpenCodeError.invalidResponse }
                    let digits = line.prefix { $0 != 59 }
                    guard !digits.isEmpty, digits.count <= 8,
                          digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                          let size = Int(String(decoding: digits, as: UTF8.self), radix: 16),
                          size <= OpenCodeHTTP.bodyLimit - output.count else { throw OpenCodeError.responseTooLarge }
                    count += 1
                    guard count <= 4096 else { throw OpenCodeError.responseTooLarge }
                    cursor = end + 2
                    state = size == 0 ? .trailers : .data(size)
                case let .data(size):
                    guard bytes.count - cursor >= size + 2 else { return false }
                    guard bytes[cursor + size] == 13, bytes[cursor + size + 1] == 10 else { throw OpenCodeError.invalidResponse }
                    output.append(contentsOf: bytes[cursor..<(cursor + size)])
                    cursor += size + 2
                    state = .size
                case .trailers:
                    guard let end = lineEnd() else {
                        guard trailerBytes + bytes.count - cursor <= OpenCodeHTTP.headerLimit else { throw OpenCodeError.responseTooLarge }
                        return false
                    }
                    trailerBytes += end - cursor + 2
                    guard trailerBytes <= OpenCodeHTTP.headerLimit else { throw OpenCodeError.responseTooLarge }
                    if end == cursor { cursor += 2; return true }
                    guard bytes[cursor..<end].contains(58) else { throw OpenCodeError.invalidResponse }
                    cursor = end + 2
                }
            }
        }

        private func lineEnd() -> Int? {
            guard bytes.count - cursor >= 2 else { return nil }
            return (cursor..<(bytes.count - 1)).first { bytes[$0] == 13 && bytes[$0 + 1] == 10 }
        }
    }
}
