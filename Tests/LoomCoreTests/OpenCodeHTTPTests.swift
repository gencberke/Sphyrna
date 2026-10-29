import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

/// A numeric loopback peer in the test process, with no provider executable.
private final class OpenCodeHTTPFixture: @unchecked Sendable {
    let fd: Int32
    let url: URL
    private let lock = NSLock()
    private var received = false
    var receivedRequest: Bool { lock.withLock { received } }

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw OpenCodeError.unavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0, listen(listener, 2) == 0 else { Darwin.close(listener); throw OpenCodeError.unavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        guard result == 0 else { Darwin.close(listener); throw OpenCodeError.unavailable }
        fd = listener
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/api/test")!
    }
    deinit { Darwin.close(fd) }

    /// One connection, served on a thread of its own: its `poll` waits must not hold a thread of the cooperative pool, which the
    /// tests' clients need. `delay` holds the answer back after the request is read.
    func serve(parts: [String], expectedBody: Int = 0, waitForClose: Bool = false, delay: TimeInterval = 0) -> Task<Data, any Error> {
        Task { try await onOwnThread("loom.test.opencode-peer") { try self.serveBlocking(parts: parts, expectedBody: expectedBody,
                                                                                   waitForClose: waitForClose, delay: delay) } }
    }

    private func serveBlocking(parts: [String], expectedBody: Int, waitForClose: Bool, delay: TimeInterval) throws -> Data {
        var item = pollfd(fd: self.fd, events: Int16(POLLIN), revents: 0)
        guard poll(&item, 1, 5000) > 0 else { throw OpenCodeError.timeout }
        let peer = accept(self.fd, nil, nil)
        guard peer >= 0 else { throw OpenCodeError.unavailable }
        defer { Darwin.close(peer) }
        var yes: Int32 = 1
        _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var request = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            var ready = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 5000) > 0 else { throw OpenCodeError.timeout }
            let count = Darwin.recv(peer, &chunk, chunk.count, 0)
            if count == 0 { return Data(request) }
            guard count > 0 else { throw OpenCodeError.unavailable }
            request += chunk.prefix(count)
            guard request.count <= 32 * 1024 else { throw OpenCodeError.responseTooLarge }
            if let end = Data(request).range(of: Data("\r\n\r\n".utf8)), request.count >= end.upperBound + expectedBody { break }
        }
        self.lock.withLock { self.received = true }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if waitForClose {
            var ready = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 5000) > 0, Darwin.recv(peer, &chunk, chunk.count, 0) == 0 else { throw OpenCodeError.timeout }
        } else {
            for part in parts {
                let bytes = Array(part.utf8)
                var offset = 0
                while offset < bytes.count {
                    let count = bytes.withUnsafeBytes { Darwin.send(peer, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
                    guard count > 0 else { throw OpenCodeError.unavailable }
                    offset += count
                }
            }
        }
        return Data(request)
    }
}

@Suite struct OpenCodeHTTPTests {
    private func request(_ server: OpenCodeHTTPFixture, body: String = "") -> URLRequest {
        var request = URLRequest(url: server.url)
        request.httpMethod = body.isEmpty ? "GET" : "POST"
        request.setValue("Basic Zml4dHVyZQ==", forHTTPHeaderField: "Authorization")
        request.httpBody = body.isEmpty ? nil : Data(body.utf8)
        return request
    }

    @Test func wrongBirthIsRejectedBeforeAnySecretOrBodyByte() async throws {
        let server = try OpenCodeHTTPFixture()
        let peer = server.serve(parts: ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"], expectedBody: 6)
        let current = try #require(ProcessTable.record(pid: getpid())).identity
        let wrong = ProcessIdentity(pid: current.pid, startSeconds: current.startSeconds + 1,
                                    startMicroseconds: current.startMicroseconds)
        await #expect(throws: OpenCodeError.unverifiedServer) {
            _ = try await OpenCodeHTTP.request(request(server, body: "secret"), leader: wrong, timeout: 3, lease: .init())
        }
        #expect(try await peer.value.isEmpty)
    }

    @Test func framedRepliesAndCapsUseTheActualOwnedSocket() async throws {
        for response in [
            ["HTTP/1.1 200 OK\r\nContent-Len", "gth: 5\r\n\r\nhe", "llo"],
            ["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "2\r\nhe\r\n", "3\r\nllo\r\n0\r\n", "\r\n"],
        ] {
            let server = try OpenCodeHTTPFixture()
            let peer = server.serve(parts: response)
            let owner = try #require(ProcessTable.record(pid: getpid())).identity
            let (data, answer) = try await OpenCodeHTTP.request(request(server), leader: owner, timeout: 3, lease: .init())
            #expect(answer.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == "hello")
            let sent = String(decoding: try await peer.value, as: UTF8.self)
            #expect(sent.contains("Authorization: Basic Zml4dHVyZQ==\r\n"))
        }
        let server = try OpenCodeHTTPFixture()
        let peer = server.serve(parts: ["HTTP/1.1 200 OK\r\nContent-Length: 262145\r\n\r\n"])
        let owner = try #require(ProcessTable.record(pid: getpid())).identity
        await #expect(throws: OpenCodeError.responseTooLarge) {
            _ = try await OpenCodeHTTP.request(request(server), leader: owner, timeout: 3, lease: .init())
        }
        _ = try await peer.value
    }

    @Test func cancellationClosesItsOwnBlockedConnection() async throws {
        let server = try OpenCodeHTTPFixture()
        let peer = server.serve(parts: [], waitForClose: true)
        let owner = try #require(ProcessTable.record(pid: getpid())).identity
        let task = Task { try await OpenCodeHTTP.request(request(server), leader: owner, timeout: 5, lease: .init()) }
        #expect(await SessionRuntimeRig.waitUntil(2) { server.receivedRequest })
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!(try await peer.value).isEmpty)
    }
    @Test func alreadyCancelledRequestDoesNotConnectOrSend() async throws {
        let server = try OpenCodeHTTPFixture()
        let owner = try #require(ProcessTable.record(pid: getpid())).identity
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OpenCodeHTTP.request(request(server, body: "secret"), leader: owner, timeout: 3, lease: .init())
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        var pending = pollfd(fd: server.fd, events: Int16(POLLIN), revents: 0)
        let count = poll(&pending, 1, 0)
        if count > 0 {
            let peer = accept(server.fd, nil, nil)
            if peer >= 0 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let captured = Darwin.recv(peer, &bytes, bytes.count, MSG_DONTWAIT)
                #expect(captured <= 0)
                Darwin.close(peer)
            }
        }
        #expect(count == 0)
    }

    /// A request waits for its answer (`poll` against its deadline) on a thread of its own, not on the cooperative pool. On the
    /// pool, more slow answers than it has threads queued behind each other: the last requests started only when the first ended.
    @Test func slowAnswersRunTogetherOffTheCooperativePool() async throws {
        let owner = try #require(ProcessTable.record(pid: getpid())).identity
        let servers = try (0..<(ProcessInfo.processInfo.activeProcessorCount + 2)).map { _ in try OpenCodeHTTPFixture() }
        let peers = servers.map { $0.serve(parts: ["HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"], delay: 3) }
        let requests = servers.map { request($0) }
        let elapsed = try await ContinuousClock().measure {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for request in requests {
                    group.addTask { _ = try await OpenCodeHTTP.request(request, leader: owner, timeout: 10, lease: .init()) }
                }
                try await group.waitForAll()
            }
        }
        for peer in peers { _ = try await peer.value }
        #expect(elapsed < .seconds(4.5), "\(requests.count) answers held 3 s each took \(elapsed): they queued for pool threads")
    }
}
