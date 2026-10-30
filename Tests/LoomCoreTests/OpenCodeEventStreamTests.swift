import Darwin
import Foundation
import Testing
@testable import LoomCore
@testable import LoomCoreTestRigs
import LoomTestSupport

private final class EventPeer: @unchecked Sendable {
    let listener: Int32
    let serverURL: URL
    private let lock = NSLock()
    private var peer: Int32 = -1
    private var request = Data()
    private var didRead = false
    var received: Data { lock.withLock { request } }
    var receivedRequest: Bool { lock.withLock { didRead } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OpenCodeError.unavailable }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0, listen(fd, 1) == 0 else { Darwin.close(fd); throw OpenCodeError.unavailable }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &addr, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }) == 0 else { Darwin.close(fd); throw OpenCodeError.unavailable }
        listener = fd
        serverURL = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: addr.sin_port))")!
    }
    deinit { Darwin.close(listener) }

    func serve(initial: [Data] = [], respond: Bool = true) -> Task<Data, any Error> {
        Task.detached {
            var ready = pollfd(fd: self.listener, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 5000) > 0 else { throw OpenCodeError.timeout }
            let fd = accept(self.listener, nil, nil)
            guard fd >= 0 else { throw OpenCodeError.unavailable }
            defer {
                self.lock.withLock { self.peer = -1 }
                Darwin.close(fd)
            }
            var yes: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
            self.lock.withLock { self.peer = fd }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var request = Data()
            while true {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 5000) > 0 else { throw OpenCodeError.timeout }
                let n = Darwin.recv(fd, &buffer, buffer.count, 0)
                if n == 0 { return request }
                guard n > 0 else { throw OpenCodeError.unavailable }
                request.append(contentsOf: buffer.prefix(n))
                guard request.count <= 16 * 1024 else { throw OpenCodeError.responseTooLarge }
                if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            }
            self.lock.withLock { self.request = request; self.didRead = true }
            if respond {
                for part in initial { try self.send(part) }
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 5000) > 0 else { throw OpenCodeError.timeout }
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            guard n == 0 else { throw OpenCodeError.invalidResponse }
            return request
        }
    }

    func send(_ data: Data) throws {
        try lock.withLock {
            guard peer >= 0 else { throw OpenCodeError.closed }
            var offset = 0
            while offset < data.count {
                let n = data.withUnsafeBytes { Darwin.send(peer, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
                guard n > 0 else { throw OpenCodeError.closed }
                offset += n
            }
        }
    }
}

private final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _connected = 0
    private var _disconnected = 0
    private var _events: [OpenCodeEvent] = []
    var connected: Int { lock.withLock { _connected } }
    var disconnected: Int { lock.withLock { _disconnected } }
    var events: [OpenCodeEvent] { lock.withLock { _events } }
    func connect() { lock.withLock { _connected += 1 } }
    func receive(_ event: OpenCodeEvent) -> Bool { lock.withLock { _events.append(event); return true } }
    func disconnect() { lock.withLock { _disconnected += 1 } }
}

/// Holds the stream's own read queue inside the event callback until `release()`, so a close has to wait for it.
private final class BlockingEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = ActorFreezeGate()
    private var began = 0
    private var finished = 0
    var callbackEntered: Bool { gate.entered }
    var starts: Int { lock.withLock { began } }
    var completions: Int { lock.withLock { finished } }
    func receive(_ event: OpenCodeEvent) -> Bool {
        gate.hold()
        return true
    }
    func markStart() { lock.withLock { began += 1 } }
    func markFinished() { lock.withLock { finished += 1 } }
    func release() { gate.release() }
}

@Suite(.serialized) struct OpenCodeEventStreamTests {
    private let connected = Data("data: {\"id\":\"evt_1\",\"type\":\"server.connected\",\"data\":{}}\n\n".utf8)
    private func chunk(_ bytes: Data) -> Data {
        var value = Data(String(bytes.count, radix: 16).utf8)
        value.append(Data("\r\n".utf8))
        value.append(bytes)
        value.append(Data("\r\n".utf8))
        return value
    }
    private func owner() throws -> ProcessIdentity { try #require(ProcessTable.record(pid: getpid())).identity }

    @Test func wrongBornListenerReceivesNoAuthorization() async throws {
        let peer = try EventPeer()
        let server = peer.serve()
        let real = try owner()
        let wrong = ProcessIdentity(pid: real.pid, startSeconds: real.startSeconds + 1,
                                    startMicroseconds: real.startMicroseconds)
        let sink = EventSink()
        await #expect(throws: OpenCodeError.unverifiedServer) {
            _ = try await OpenCodeEventStream.open(serverURL: peer.serverURL, password: "fixture-secret",
                                                   owner: wrong, timeout: 3,
                                                   onConnected: { sink.connect() },
                                                   onEvent: { sink.receive($0) },
                                                   onDisconnect: { sink.disconnect() })
        }
        #expect(try await server.value.isEmpty)
        #expect(sink.connected == 0)
    }

    @Test func fragmentedChunkedFeedIsQuietUntilMoreDataAndClosesItsOwnStream() async throws {
        let peer = try EventPeer()
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        let framed = chunk(connected)
        let server = peer.serve(initial: [header.prefix(17), header.dropFirst(17), framed.prefix(9), framed.dropFirst(9)])
        let sink = EventSink()
        let stream = try await OpenCodeEventStream.open(serverURL: peer.serverURL, password: "fixture-secret",
                                                        owner: owner(), timeout: 3,
                                                        onConnected: { sink.connect() },
                                                        onEvent: { sink.receive($0) },
                                                        onDisconnect: { sink.disconnect() })
        let request = String(decoding: peer.received, as: UTF8.self)
        #expect(request.contains("GET /api/event?"))
        #expect(request.contains("Authorization: Basic "))
        #expect(request.contains("types=config.updated"))
        #expect(request.contains("types=plugin.updated"))
        #expect(sink.connected == 1)
        let event = Data("data: {\"id\":\"evt_2\",\"type\":\"session.created\",\"data\":{\"sessionID\":\"ses_one\"},\"durable\":{\"aggregateID\":\"ses_one\",\"seq\":1,\"version\":1}}\n\n".utf8)
        let frame = chunk(event)
        try peer.send(frame.prefix(11))
        try peer.send(frame.dropFirst(11))
        #expect(await SessionRuntimeRig.waitUntil(2) { sink.events.count == 1 })
        #expect(sink.events.first?.sessionID == "ses_one")
        let changed = Data("data: {\"id\":\"evt_3\",\"type\":\"config.updated\",\"data\":{}}\n\n".utf8)
        try peer.send(chunk(changed))
        #expect(await SessionRuntimeRig.waitUntil(2) { sink.events.count == 2 })
        #expect(sink.events.last?.type == "config.updated")
        try peer.send(chunk(Data(": heartbeat\n\n".utf8)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(sink.events.count == 2)
        await stream.close()
        _ = try await server.value
        #expect(sink.disconnected == 1)
        #expect(sink.events.count == 2)
    }

    @Test func oversizeFrameDisconnectsAndCancellationClosesPendingHandshake() async throws {
        let peer = try EventPeer()
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
        let server = peer.serve(initial: [header, connected])
        let sink = EventSink()
        let stream = try await OpenCodeEventStream.open(serverURL: peer.serverURL, password: "fixture-secret",
                                                        owner: owner(), timeout: 3,
                                                        onConnected: { sink.connect() },
                                                        onEvent: { sink.receive($0) },
                                                        onDisconnect: { sink.disconnect() })
        try peer.send(Data(repeating: 65, count: 65_537))
        #expect(await SessionRuntimeRig.waitUntil(2) { sink.disconnected == 1 })
        _ = try await server.value
        await stream.close()
        #expect(sink.disconnected == 1)

        let pendingPeer = try EventPeer()
        let pendingServer = pendingPeer.serve(respond: false)
        let pendingSink = EventSink()
        let starting = Task {
            try await OpenCodeEventStream.open(serverURL: pendingPeer.serverURL, password: "fixture-secret",
                                               owner: owner(), timeout: 4,
                                               onConnected: { pendingSink.connect() },
                                               onEvent: { pendingSink.receive($0) },
                                               onDisconnect: { pendingSink.disconnect() })
        }
        #expect(await SessionRuntimeRig.waitUntil(2) { pendingPeer.receivedRequest })
        starting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await starting.value }
        _ = try await pendingServer.value
        #expect(pendingSink.connected == 0)
        #expect(pendingSink.disconnected == 1)
    }
    @Test func closingOneStreamCannotCloseOrUpdateAnotherGeneration() async throws {
        let firstPeer = try EventPeer()
        let secondPeer = try EventPeer()
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
        let firstServer = firstPeer.serve(initial: [header, connected])
        let first = EventSink(), second = EventSink()
        let leader = try owner()
        let stream1 = try await OpenCodeEventStream.open(serverURL: firstPeer.serverURL, password: "fixture-secret",
                                                         owner: leader, timeout: 3,
                                                         onConnected: { first.connect() },
                                                         onEvent: { first.receive($0) },
                                                         onDisconnect: { first.disconnect() })
        await stream1.close()
        _ = try await firstServer.value
        let secondServer = secondPeer.serve(initial: [header, connected])
        let stream2 = try await OpenCodeEventStream.open(serverURL: secondPeer.serverURL, password: "fixture-secret",
                                                         owner: leader, timeout: 3,
                                                         onConnected: { second.connect() },
                                                         onEvent: { second.receive($0) },
                                                         onDisconnect: { second.disconnect() })
        let frame = Data("data: {\"id\":\"evt_2\",\"type\":\"session.created\",\"data\":{\"sessionID\":\"ses_two\"},\"durable\":{\"aggregateID\":\"ses_two\",\"seq\":1,\"version\":1}}\n\n".utf8)
        try secondPeer.send(frame)
        #expect(await SessionRuntimeRig.waitUntil(2) { second.events.count == 1 })
        #expect(first.events.isEmpty)
        #expect(first.disconnected == 1)
        #expect(second.disconnected == 0)
        await stream2.close()
        _ = try await secondServer.value
        #expect(second.disconnected == 1)
    }

    @Test func alreadyCancelledSubscriptionDoesNotConnect() async throws {
        let peer = try EventPeer()
        let leader = try owner()
        let sink = EventSink()
        let opening = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OpenCodeEventStream.open(serverURL: peer.serverURL, password: "fixture-secret",
                                                       owner: leader, timeout: 3,
                                                       onConnected: { sink.connect() },
                                                       onEvent: { sink.receive($0) },
                                                       onDisconnect: { sink.disconnect() })
        }
        await #expect(throws: CancellationError.self) { _ = try await opening.value }
        var pending = pollfd(fd: peer.listener, events: Int16(POLLIN), revents: 0)
        #expect(poll(&pending, 1, 0) == 0)
        #expect(sink.connected == 0)
    }

    @Test func concurrentClientCloseWaitsForTheOwnedStreamToClose() async throws {
        let peer = try EventPeer()
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
        let server = peer.serve(initial: [header, connected])
        let blocker = BlockingEventSink()
        defer { blocker.release() }
        let stream = try await OpenCodeEventStream.open(serverURL: peer.serverURL, password: "fixture-secret",
                                                        owner: owner(), timeout: 3,
                                                        onConnected: {}, onEvent: { blocker.receive($0) },
                                                        onDisconnect: {})
        let frame = Data("data: {\"id\":\"evt_2\",\"type\":\"session.created\",\"data\":{\"sessionID\":\"ses_one\"},\"durable\":{\"aggregateID\":\"ses_one\",\"seq\":1,\"version\":1}}\n\n".utf8)
        try peer.send(frame)
        #expect(await SessionRuntimeRig.waitUntil(2) { blocker.callbackEntered })
        let client = OpenCodeClient(base: peer.serverURL, password: "fixture-secret", eventStream: stream) { _ in
            throw OpenCodeError.unavailable
        }
        let one = Task {
            blocker.markStart()
            await client.close()
            blocker.markFinished()
        }
        let two = Task {
            blocker.markStart()
            await client.close()
            blocker.markFinished()
        }
        #expect(await SessionRuntimeRig.waitUntil(2) { blocker.starts == 2 })
        let finishedEarly = await SessionRuntimeRig.waitUntil(0.3) { blocker.completions > 0 }
        #expect(!finishedEarly)
        blocker.release()
        await one.value
        await two.value
        _ = try await server.value
        #expect(blocker.completions == 2)
    }

    @Test func failedSubscriptionCannotRestartWithARevokedRequestLease() async throws {
        let peer = try EventPeer()
        let leader = try owner()
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".utf8)
        let server = peer.serve(initial: [header, Data("data: not-json\n\n".utf8)])
        let base = peer.serverURL
        let client = OpenCodeClient(base: base, password: "fixture-secret", leader: leader) { request in
            let data = try JSONSerialization.data(withJSONObject: [
                "pid": leader.pid, "version": "2.2.0", "urls": [base.absoluteString],
                "paths": ["tmp": "/tmp/profile"]
            ])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        try await client.verify(pid: leader.pid, version: "2.2.0", temporaryDirectory: "/tmp/profile")
        await #expect(throws: OpenCodeError.invalidResponse) {
            _ = try await client.openLive(appSessionID: UUID(), runID: UUID(), timeout: 2)
        }
        _ = try await server.value
        await #expect(throws: OpenCodeError.closed) {
            _ = try await client.openLive(appSessionID: UUID(), runID: UUID(), timeout: 0.3)
        }
        var pending = pollfd(fd: peer.listener, events: Int16(POLLIN), revents: 0)
        let count = poll(&pending, 1, 0)
        if count > 0 {
            let fd = accept(peer.listener, nil, nil)
            if fd >= 0 { Darwin.close(fd) }
        }
        #expect(count == 0)
        await client.close()
    }

}
