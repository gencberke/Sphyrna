import Darwin
import Foundation

/// A fresh, app-owned additional workspace contains public discovery only.
/// Native hooks inherit launch-local credentials; none are written here.
enum AgySessionDiscovery {
    static let hookEvents = ["SessionStart", "PreInvocation", "PostInvocation", "PreToolUse", "PostToolUse", "Stop"]
    static let skill = """
        ---
        name: sphyrna
        description: This session runs inside Sphyrna. Run "$SPHYRNA_CLI" --help for session commands.
        ---

        # Sphyrna session commands

        Use `"$SPHYRNA_CLI" sessions` to list session metadata and `"$SPHYRNA_CLI" open --help` to request an approved session.
        """

    static func install(in directory: URL, helper: URL) throws -> URL {
        guard directory.isFileURL, helper.isFileURL, directory.path.hasPrefix("/"),
              helper.path.hasPrefix("/"), !directory.path.contains("\0"), !helper.path.contains("\0") else {
            throw AgyLaunchError.invalidTarget
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              FileManager.default.isExecutableFile(atPath: helper.path) else { throw AgyLaunchError.invalidTarget }
        // A carrier is immutable for one run. Refuse an existing native folder
        // rather than replacing a project or another run's resources.
        let agents = directory.appendingPathComponent(".agents", isDirectory: true)
        guard mkdir(agents.path, 0o700) == 0 else { throw AgyLaunchError.invalidTarget }
        let skill = agents.appendingPathComponent("skills/sphyrna", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try write(Data(Self.skill.utf8), to: skill.appendingPathComponent("SKILL.md"))
        let quotedHelper = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let events = Dictionary(uniqueKeysWithValues: hookEvents.map { event in
            (event, [["type": "command", "command": "\(quotedHelper) agy-hook \(event)", "timeout": 5] as [String: Any]])
        })
        let data = try JSONSerialization.data(withJSONObject: ["sphyrna-owned-channel": events], options: [.sortedKeys])
        try write(data, to: agents.appendingPathComponent("hooks.json"))
        return directory
    }

    private static func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: .withoutOverwriting)
        guard chmod(file.path, 0o600) == 0 else { throw AgyLaunchError.invalidTarget }
    }
}
