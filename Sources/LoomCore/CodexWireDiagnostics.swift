import CoreFoundation
import CryptoKit
import Foundation

/// Explicitly opt-in, bounded metadata only. Never persists provider content or identifiers.
public final class CodexWireDiagnostics: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public let sequence: UInt64
        public let connection: String
        public let envelope: String
        public let method: String
        public let idType: String
        public let threadMatch: Bool?
        public let turnLabel: String?
        public var decode: String
        public var routing: String
    }
    public struct Snapshot: Codable, Sendable {
        public let entries: [Entry]
        public let dropped: Int
        public let invalidated: Bool
        public let failures: [String]
    }
    private let router = CodexSessionRouter()
    private let sessionID = UUID()
    private let runID = UUID()
    private let lock = NSLock()
    private let connection: String
    private let threadID: String
    private let capacity: Int
    private var sequence: UInt64 = 0
    private var entries: [Entry] = []
    private var dropped = 0
    private var failures: Set<String> = []
    public init(connection: String, threadID: String, capacity: Int = 256) {
        self.connection = connection == "A" ? "A" : "B"
        self.threadID = threadID
        self.capacity = min(4096, max(1, capacity))
    }
    private static let methods: Set<String> = [
        "thread/started", "thread/status/changed", "turn/started", "turn/completed",
        "serverRequest/resolved", "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval", "item/permissions/requestApproval", "item/tool/requestUserInput",
    ]
    @discardableResult public func observe(_ data: Data) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let method = object?["method"] as? String
        let id = object?["id"]
        let idType: String
        switch id {
        case nil: idType = "absent"
        case is NSNull: idType = "null"
        case is String: idType = "string"
        case let value as NSNumber: idType = CFGetTypeID(value) == CFBooleanGetTypeID() ? "boolean" : "number"
        default: idType = "other"
        }
        let params = object?["params"] as? [String: Any]
        let thread = params?["threadId"] as? String ?? (params?["thread"] as? [String: Any])?["id"] as? String
        let turn = params?["turnId"] as? String ?? (params?["turn"] as? [String: Any])?["id"] as? String
        let match = thread.map { $0 == threadID }
        let label = turn.map { Data(SHA256.hash(data: Data($0.utf8))).prefix(8).map { String(format: "%02x", $0) }.joined() }
        let envelope = object == nil ? "invalid" : method != nil ? (id == nil ? "notification" : "request") : id != nil ? "response" : "invalid"
        if entries.count == capacity { entries.removeFirst(); dropped += 1 }
        entries.append(Entry(sequence: sequence, connection: connection, envelope: envelope,
                             method: method.map { Self.methods.contains($0) ? $0 : "other" } ?? "absent",
                             idType: idType, threadMatch: match, turnLabel: label,
                             decode: "pending", routing: "pending"))
        return sequence
    }
    public func decoded(_ token: UInt64, outcome: String) {
        lock.lock(); defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.sequence == token }) else { return }
        entries[index].decode = ["response", "request", "event", "unknown-event", "failed"].contains(outcome) ? outcome : "failed"
        entries[index].routing = outcome == "response" ? "rpc" : outcome == "failed" ? "rejected" :
            "pending"
    }
    public func route(_ inbound: CodexAppServerInbound, token: UInt64) async {
        let binding = CodexRunBinding(sessionID: sessionID, managedRunID: runID, threadID: threadID, workingDirectory: "")
        await router.register(binding)
        let decision = await router.route(inbound)
        let label: String
        switch decision {
        case let .routed(value): label = value == binding ? "target-run" : "other-run"
        case .unmatched: label = "unmatched"
        case .ambiguous: label = "ambiguous"
        case .initialLaunchMatched: label = "initial-launch"
        case .newConversation: label = "new-conversation"
        }
        setRouting(token, label)
    }
    private func setRouting(_ token: UInt64, _ label: String) {
        lock.lock(); defer { lock.unlock() }
        if let index = entries.firstIndex(where: { $0.sequence == token }) { entries[index].routing = label }
    }
    public func invalidate(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        failures.insert(["disconnect", "timeout", "stream-drop", "protocol", "preparation"].contains(reason) ? reason : "protocol")
    }
    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(entries: entries, dropped: dropped, invalidated: dropped > 0 || !failures.isEmpty, failures: failures.sorted())
    }
}
