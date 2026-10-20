import Darwin
import Foundation
@testable import LoomCore

/// One synthetic assistant line. Field names follow Claude Code's transcripts;
/// every value is made up. `output_tokens` is the last field of the line, so a
/// same-length edit of it lands inside the 64-byte tail guard.
struct UsageLine {
    var id = "msg_1"
    var request: String? = "req_1"
    var session = "sess-1"
    var model = "claude-haiku-4-5-20251001"
    var ts = "2026-10-05T10:00:00.000Z"
    var input = 10
    var output = 20
    var cw5: Int? = nil
    var cw1: Int? = nil
    var legacyCache: Int? = nil
    var cacheRead = 0
    var sidechain = false
    var speed: String? = "standard"
    var geo: String? = nil
    var web = 0
    var apiError = false
    var type = "assistant"
    var costUSD: Double? = nil

    var json: String {
        var usage = "\"input_tokens\":\(input)"
        if let legacyCache { usage += ",\"cache_creation_input_tokens\":\(legacyCache)" }
        else if cw5 != nil || cw1 != nil {
            usage += ",\"cache_creation_input_tokens\":\((cw5 ?? 0) + (cw1 ?? 0))"
            usage += ",\"cache_creation\":{\"ephemeral_5m_input_tokens\":\(cw5 ?? 0),\"ephemeral_1h_input_tokens\":\(cw1 ?? 0)}"
        }
        usage += ",\"cache_read_input_tokens\":\(cacheRead),\"service_tier\":\"standard\""
        if let speed { usage += ",\"speed\":\"\(speed)\"" }
        if let geo { usage += ",\"inference_geo\":\"\(geo)\"" }
        if web > 0 { usage += ",\"server_tool_use\":{\"web_search_requests\":\(web)}" }
        usage += ",\"output_tokens\":\(output)"
        var head = "{\"type\":\"\(type)\",\"timestamp\":\"\(ts)\""
        if let request { head += ",\"requestId\":\"\(request)\"" }
        head += ",\"sessionId\":\"\(session)\",\"isSidechain\":\(sidechain),\"isApiErrorMessage\":\(apiError)"
        if let costUSD { head += ",\"costUSD\":\(costUSD)" }
        return head + ",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"usage\":{\(usage)}}}"
    }
}

/// A throwaway Claude profile and index database under a temp directory.
final class UsageFixture {
    let root: URL
    var config: URL { root.appendingPathComponent("config", isDirectory: true) }
    var projects: URL { config.appendingPathComponent("projects", isDirectory: true) }
    var databaseURL: URL { root.appendingPathComponent("usage-index.sqlite3") }

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loom-usage-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(config.path, 0o700)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeIndex(
        coldStartWindow: TimeInterval = 90 * 86_400, clock: @escaping @Sendable () -> Date = { Date() },
        chunkBytes: Int? = nil, maximumLineBytes: Int? = nil, sideChats: (@Sendable () async -> Set<String>)? = nil
    ) -> ClaudeUsageIndex {
        let profile = ClaudeProfileLayout(profileDirectory: config, environment: [:], home: root)
        if let chunkBytes, let maximumLineBytes {
            return ClaudeUsageIndex(databaseURL: databaseURL, profile: profile, coldStartWindow: coldStartWindow,
                                    clock: clock, chunkBytes: chunkBytes, maximumLineBytes: maximumLineBytes)
        }
        return ClaudeUsageIndex(databaseURL: databaseURL, profile: profile, coldStartWindow: coldStartWindow, clock: clock,
                                sideChats: sideChats)
    }

    /// `projects/<project>/<session>.jsonl`
    func transcript(project: String = "-tmp-proj", session: String = "sess-1") -> URL {
        projects.appendingPathComponent(project, isDirectory: true).appendingPathComponent("\(session).jsonl")
    }

    /// `projects/<project>/<session>/subagents/agent-<agent>.jsonl`
    func subagent(project: String = "-tmp-proj", session: String = "sess-1", agent: String = "a1") -> URL {
        projects.appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("agent-\(agent).jsonl")
    }

    @discardableResult
    func write(_ lines: [String], to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.map { $0 + "\n" }.joined()).utf8).write(to: url)
        return url
    }

    @discardableResult
    func writeRaw(_ data: Data, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func append(_ lines: [String], to url: URL) throws {
        try append(Data((lines.map { $0 + "\n" }.joined()).utf8), to: url)
    }

    func size(of url: URL) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0)
    }

    static let utc = TimeZone(identifier: "UTC")!
    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }
    static let now = date("2026-10-07T12:00:00.000Z")
}

extension ClaudeUsageIndex {
    func all(now: Date = UsageFixture.now, timeZone: TimeZone = UsageFixture.utc) throws -> UsageSnapshot {
        try snapshot(range: .all, now: now, timeZone: timeZone)
    }
}
