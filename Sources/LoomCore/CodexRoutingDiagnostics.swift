import Foundation

/// A bounded, content-free record. Unknown metadata is classified, never copied.
public struct CodexRoutingDiagnostic: Codable, Sendable {
    public let sequence: UInt64
    public let event: String
    public let threadID: String?
    public let sessionIDs: [UUID]
    public let runIDs: [UUID]
    public let cwdMatch: Bool?
    public let ephemeral: Bool?
    public let source: String
    public let originator: String
    public let decision: String
}

public actor CodexRoutingDiagnostics {
    private var entries: [CodexRoutingDiagnostic] = []
    private var dropped = 0

    public init() {}

    public func record(_ entry: CodexRoutingDiagnostic) {
        if entries.count == 256 { entries.removeFirst(); dropped += 1 }
        entries.append(entry)
    }

    public struct Snapshot: Codable, Sendable {
        public let entries: [CodexRoutingDiagnostic]
        public let dropped: Int
    }

    public func snapshot() -> Snapshot { Snapshot(entries: entries, dropped: dropped) }
}

extension CodexThreadIdentity {
    // These are the interactive sources already supported by Loom's remote path.
    // Missing or unfamiliar metadata cannot authorize a persistent identity change.
    var isInteractiveConversation: Bool {
        ephemeral == false && (source == "cli" || source == "vscode")
    }

    var sourceClass: String {
        switch source {
        case nil: "missing"
        case "cli": "cli"
        case "vscode": "vscode"
        case "exec": "exec"
        default: "other"
        }
    }

    var originatorClass: String {
        switch originator {
        case nil: "missing"
        case "codex-tui": "codex-tui"
        case "loom": "loom"
        default: "other"
        }
    }
}
