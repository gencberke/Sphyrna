import CryptoKit
import Darwin
import Foundation

/// Synchronous, bounded transport for local app-server probes, not a production RPC client.
@MainActor
final class ProbeRPCClient {
    enum Failure: Error, CustomStringConvertible {
        case system(String, Int32)
        case protocolViolation(String)
        case timeout(String)
        case closed

        var description: String {
            switch self {
            case let .system(operation, code): return "Probe RPC \(operation): \(String(cString: strerror(code)))"
            case let .protocolViolation(reason): return "Probe RPC protocol: \(reason)"
            case let .timeout(operation): return "Probe RPC timed out during \(operation)"
            case .closed: return "Probe RPC connection closed"
            }
        }
    }

    private var descriptor: Int32 = -1
    private let limit = 16 * 1024 * 1024
    private var input: [UInt8] = []
    private var fragments: [UInt8]? = nil
    private var closed = false

    init(socketPath: String) throws {
        var address = sockaddr_un()
        let path = Array(socketPath.utf8)
        guard !path.contains(0), path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw Failure.protocolViolation("Unix socket path is too long or contains NUL")
        }
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.system("socket", errno) }
        do {
            var enabled: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                             socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
                throw Failure.system("SO_NOSIGPIPE", errno)
            }
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw Failure.system("fcntl", errno)
            }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                destination.copyBytes(from: path + [0])
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result < 0 {
                guard errno == EINPROGRESS || errno == EAGAIN || errno == EINTR else {
                    throw Failure.system("connect", errno)
                }
                try wait(for: Int16(POLLOUT), deadline: deadline, operation: "connect")
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout.size(ofValue: socketError))
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                    throw Failure.system("connect status", errno)
                }
                guard socketError == 0 else { throw Failure.system("connect", socketError) }
            }
            try upgrade(deadline: deadline)
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

    func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= limit else { throw Failure.protocolViolation("outgoing message exceeds 16 MiB") }
        try sendFrame(opcode: 1, payload: Array(data))
    }

    func drain() throws -> [[String: Any]] {
        guard !closed else { throw Failure.closed }
        var messages: [[String: Any]] = []
        var received = 0
        while true {
            try parseFrames(into: &messages)
            if closed { break }
            // Bound work per call even when a producer continuously fills the socket.
            if received >= limit { break }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count > 0 {
                guard input.count + count <= limit + 14 else {
                    throw Failure.protocolViolation("receive buffer exceeds 16 MiB")
                }
                input.append(contentsOf: bytes.prefix(count))
                received += count
            } else if count == 0 {
                closed = true
                guard input.isEmpty, fragments == nil else {
                    throw Failure.protocolViolation("connection ended during a message")
                }
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                throw Failure.system("read", errno)
            }
        }
        if closed && messages.isEmpty { throw Failure.closed }
        return messages
    }

    private func upgrade(deadline: TimeInterval) throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        try write(Array(request.utf8), deadline: deadline)
        let separator: [UInt8] = [13, 10, 13, 10]
        while true {
            if let end = input.indices.first(where: { index in
                index + 4 <= input.count && Array(input[index..<(index + 4)]) == separator
            }) {
                guard let header = String(bytes: input.prefix(end), encoding: .utf8) else {
                    throw Failure.protocolViolation("invalid upgrade headers")
                }
                input.removeFirst(end + 4)
                let lines = header.components(separatedBy: "\r\n")
                let status = lines[0].split(separator: " ")
                guard status.count >= 2, status[0] == "HTTP/1.1", status[1] == "101" else {
                    throw Failure.protocolViolation("WebSocket upgrade rejected: \(lines[0])")
                }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else {
                        throw Failure.protocolViolation("malformed upgrade header")
                    }
                    let name = line[..<colon].lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    headers[name] = headers[name].map { $0 + "," + value } ?? value
                }
                let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                let connection = headers["connection", default: ""].lowercased().split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard headers["sec-websocket-accept"] == expected,
                      headers["upgrade"]?.lowercased() == "websocket", connection.contains("upgrade"),
                      headers["sec-websocket-extensions"] == nil, headers["sec-websocket-protocol"] == nil else {
                    throw Failure.protocolViolation("invalid WebSocket upgrade response")
                }
                return
            }
            guard input.count < 65_536 else { throw Failure.protocolViolation("upgrade headers exceed 64 KiB") }
            try wait(for: Int16(POLLIN), deadline: deadline, operation: "WebSocket upgrade")
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count > 0 { input.append(contentsOf: bytes.prefix(count)) }
            else if count == 0 { throw Failure.closed }
            else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw Failure.system("upgrade read", errno)
            }
        }
    }

    private func parseFrames(into messages: inout [[String: Any]]) throws {
        while input.count >= 2 {
            let final = input[0] & 0x80 != 0
            let opcode = input[0] & 0x0f
            guard input[0] & 0x70 == 0, input[1] & 0x80 == 0 else {
                throw Failure.protocolViolation("reserved bits or masked server frame")
            }
            var length = UInt64(input[1] & 0x7f)
            var offset = 2
            if length == 126 || length == 127 {
                let byteCount = length == 126 ? 2 : 8
                guard input.count >= offset + byteCount else { return }
                length = input[offset..<(offset + byteCount)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard (byteCount == 2 && length >= 126) || (byteCount == 8 && length >= 65_536) else {
                    throw Failure.protocolViolation("noncanonical frame length")
                }
                offset += byteCount
            }
            guard length <= limit else { throw Failure.protocolViolation("frame exceeds 16 MiB") }
            if opcode >= 8 && (!final || length > 125) {
                throw Failure.protocolViolation("invalid control frame")
            }
            guard input.count >= offset + Int(length) else { return }
            let payload = Array(input[offset..<(offset + Int(length))])
            input.removeFirst(offset + Int(length))
            switch opcode {
            case 0:
                guard fragments != nil else { throw Failure.protocolViolation("unexpected continuation") }
                guard fragments!.count + payload.count <= limit else {
                    throw Failure.protocolViolation("fragmented message exceeds 16 MiB")
                }
                fragments!.append(contentsOf: payload)
                if final {
                    let complete = fragments!
                    fragments = nil
                    messages.append(try decode(complete))
                }
            case 1:
                guard fragments == nil else { throw Failure.protocolViolation("text frame during fragmented message") }
                if final { messages.append(try decode(payload)) }
                else { fragments = payload }
            case 8:
                guard payload.count != 1 else { throw Failure.protocolViolation("invalid close payload") }
                try sendFrame(opcode: 8, payload: payload)
                closed = true
                return
            case 9: try sendFrame(opcode: 10, payload: payload)
            case 10: break
            default: throw Failure.protocolViolation("unsupported opcode \(opcode)")
            }
        }
    }

    private func decode(_ payload: [UInt8]) throws -> [String: Any] {
        guard String(bytes: payload, encoding: .utf8) != nil else {
            throw Failure.protocolViolation("text message is not UTF-8")
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else {
            throw Failure.protocolViolation("expected JSON object")
        }
        return object
    }

    private func sendFrame(opcode: UInt8, payload: [UInt8]) throws {
        guard !closed else { throw Failure.closed }
        var frame: [UInt8] = [0x80 | opcode]
        if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
        else if payload.count <= 65_535 {
            frame += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> shift) & 0xff))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame += mask
        frame += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        try write(frame, deadline: ProcessInfo.processInfo.systemUptime + 5)
    }

    private func write(_ bytes: [UInt8], deadline: TimeInterval) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes {
                Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
            }
            if count > 0 { offset += count }
            else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                try wait(for: Int16(POLLOUT), deadline: deadline, operation: "write")
            } else { throw Failure.system("write", count == 0 ? EPIPE : errno) }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure.timeout("write") }
        }
    }

    private func wait(for events: Int16, deadline: TimeInterval, operation: String) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.timeout(operation) }
            var descriptor = pollfd(fd: self.descriptor, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 5000)))
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL) == 0 else {
                    throw Failure.system("poll", EBADF)
                }
                return
            }
            if result < 0 && errno != EINTR { throw Failure.system("poll", errno) }
        }
    }
}
