import Foundation

/// A small app-owned discovery entry, installed only on a conversation's own
/// Codex server. The complete command help remains on demand.
enum SessionTaskSkill {
    static let name = "sphyrna"
    static let content = """
        ---
        name: sphyrna
        description: This session runs inside Sphyrna. Delegate tasks or send approved messages between sessions. Run "$SPHYRNA_CLI" task --help or send --help for details.
        ---

        # Sphyrna task channel

        Run `"$SPHYRNA_CLI" task --help` for the current commands. A child reports a
        completed, failed, or needs-input result explicitly. After reporting
        needs-input, finish the current turn so the parent can reply safely.
        Native tool approvals always belong to the user.

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
