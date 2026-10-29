import Darwin
import Foundation
import Testing
import LoomTestSupport
@testable import LoomCoreTestRigs

/// A fake-provider process in chat mode, for the `stream` scenario only: it keeps every record with the time it arrived.
private final class StreamRig: @unchecked Sendable {
    typealias Record = [String: Any]

    let root: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var records: [(time: Date, record: Record)] = []

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-stream-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-fake-provider")
        process.arguments = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
            "--session-id", UUID().uuidString.lowercased(),
        ]
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": config.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            ingest(data)
        }
        try process.run()
    }

    private func ingest(_ data: Data) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if let object = (try? JSONSerialization.jsonObject(with: line)) as? Record { records.append((now, object)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
    }

    func send(_ object: Record) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
    }

    func user(_ text: String) {
        send(["type": "user", "message": ["role": "user", "content": text], "parent_tool_use_id": NSNull(),
              "uuid": UUID().uuidString.lowercased(), "origin": ["kind": "human"]])
    }

    func interrupt() {
        send(["type": "control_request", "request_id": "int-1", "request": ["subtype": "interrupt"]])
    }

    func all() -> [(time: Date, record: Record)] { lock.withLock { records } }

    func waitForResult(timeout: TimeInterval) async throws -> Record {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = all().first(where: { $0.record["type"] as? String == "result" }) { return found.record }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw StreamRigTimeout()
    }

    func waitForDeltas(_ count: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.deltas(all()).count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw StreamRigTimeout()
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        output.fileHandleForReading.readabilityHandler = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// The text deltas, in order, with their arrival times.
    static func deltas(_ records: [(time: Date, record: Record)]) -> [(time: Date, text: String)] {
        records.compactMap { entry in
            guard entry.record["type"] as? String == "stream_event",
                  let event = entry.record["event"] as? Record, event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? Record, delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return (entry.time, text)
        }
    }

    static func blocks(_ record: Record) -> [Record] {
        ((record["message"] as? Record)?["content"] as? [Record]) ?? []
    }
}

private struct StreamRigTimeout: Error {}

/// The `stream` scenario (`/scenario stream <seconds> <characters per second>`): the load the Release B evaluation streams
/// into Chat. Short runs here; the 60 s rate check is part of the harness evidence.
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct FakeProviderStreamTests {
    @Test(arguments: [(6.0, 600), (4.0, 6000)])
    func theStreamHoldsItsRateAndEndsWithANormalResult(seconds: Double, rate: Int) async throws {
        let rig = try StreamRig()
        defer { rig.stop() }
        rig.user("/scenario stream \(seconds) \(rate)")
        let result = try await rig.waitForResult(timeout: seconds + 15)
        let records = rig.all()
        let deltas = StreamRig.deltas(records)
        let characters = deltas.reduce(0) { $0 + $1.text.count }
        let expected = Int(seconds * Double(rate))
        // The count is exact up to a closing code fence; the pace is the clock's: first delta to last within 5 % (plus a tick).
        #expect(characters >= expected && characters <= expected + 8)
        let span = try #require(deltas.last).time.timeIntervalSince(try #require(deltas.first).time)
        #expect(span >= seconds * 0.95 - 0.1 && span <= seconds * 1.05 + 0.1, "span \(span) for \(seconds) s")
        #expect(deltas.count >= Int(seconds * 20)) // a delta per 20 ms tick, at most one fewer per block end and tool call
        #expect(result["subtype"] as? String == "success" && result["is_error"] as? Bool == false)
        #expect(result["terminal_reason"] as? String == "completed")
    }

    @Test func theTextIsMarkdownWithCodeBlocksAndToolCallsAndItsFinalRecordsMatchTheDeltas() async throws {
        let rig = try StreamRig()
        defer { rig.stop() }
        rig.user("/scenario stream 8 600")
        _ = try await rig.waitForResult(timeout: 25)
        let records = rig.all().map(\.record)
        let streamed = StreamRig.deltas(rig.all()).map(\.text).joined()
        let assistants = records.filter { $0["type"] as? String == "assistant" }
        let texts = assistants.flatMap(StreamRig.blocks).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        #expect(texts.joined() == streamed)
        #expect(!texts.contains { $0.hasPrefix("\n") || $0.hasSuffix("\n\n") })
        // Whole Markdown: every message closes its code fences.
        #expect(texts.allSatisfy { $0.components(separatedBy: "```").count % 2 == 1 })
        #expect(texts.contains { $0.contains("```") } && texts.contains { $0.contains("\n\n") })
        let uses = assistants.flatMap(StreamRig.blocks).filter { $0["type"] as? String == "tool_use" }
        let results = records.filter { $0["type"] as? String == "user" && $0["isReplay"] == nil }
            .flatMap(StreamRig.blocks).filter { $0["type"] as? String == "tool_result" }
        #expect(uses.count >= 2)
        #expect(Set(uses.compactMap { $0["id"] as? String }) == Set(results.compactMap { $0["tool_use_id"] as? String }))
        // A message's text block comes before its tool call, in one API message.
        let first = try #require(assistants.first { StreamRig.blocks($0).contains { $0["type"] as? String == "tool_use" } })
        let message = try #require(first["message"] as? [String: Any])
        #expect(message["stop_reason"] as? String == "tool_use")
    }

    @Test func theSequenceIsTheSameEveryRun() async throws {
        var runs: [String] = []
        for _ in 0..<2 {
            let rig = try StreamRig()
            defer { rig.stop() }
            rig.user("/scenario stream 2 6000")
            _ = try await rig.waitForResult(timeout: 15)
            runs.append(StreamRig.deltas(rig.all()).map(\.text).joined())
        }
        #expect(runs[0].count >= 12_000 && runs[0] == runs[1])
    }

    @Test func anInterruptEndsTheStreamWithinATickAndKeepsTheTextSoFar() async throws {
        let rig = try StreamRig()
        defer { rig.stop() }
        rig.user("/scenario stream 60 600")
        try await rig.waitForDeltas(10, timeout: 10)
        let before = Date()
        rig.interrupt()
        let result = try await rig.waitForResult(timeout: 5)
        #expect(Date().timeIntervalSince(before) < 2)
        #expect(result["subtype"] as? String == "error_during_execution")
        let aborted = rig.all().map(\.record).filter { ($0["aborted"] as? Bool) == true }
        #expect(aborted.count == 1)
    }
}
