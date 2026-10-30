import Foundation

/// A small app-owned discovery entry, installed only on a conversation's own
/// Codex server. The complete command help remains on demand.
enum SessionTaskSkill {
    static let name = "sphyrna"
    /// Every mode Sphyrna starts Codex in sandboxes it with the network off (`SessionChannelSandbox`), so this entry
    /// names the channel only to say it is blocked; it advertises no task, send or inbox command a session cannot run.
    static let content = """
        ---
        name: sphyrna
        description: This session runs inside Sphyrna. \(SessionChannelSandbox.codexReason), so Sphyrna's task and message commands are not available here.
        ---

        # Sphyrna session channel

        \(SessionChannelSandbox.codexReason): the sandbox denies the helper's
        connection to Sphyrna, so tasks, messages and the inbox are not available
        in this session. Native tool approvals always belong to the user.

        """

    static func install(in dataRoot: URL) throws -> URL {
        let root = dataRoot.appendingPathComponent("channel-skills", isDirectory: true)
        let file = root.appendingPathComponent("sphyrna/SKILL.md")
        let data = Data(content.utf8)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
        return root.standardizedFileURL
    }
}

/// `available` means the owned server listed the enabled metadata. Native
/// skill selection and its model-facing budget remain under the provider's control.
public enum SessionTaskDiscovery: String, Sendable {
    case available, unavailable
}
