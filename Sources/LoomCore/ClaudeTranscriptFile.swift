import Darwin
import Foundation

/// Opens `path` read-only, never through a final link, and only a regular file of this user. The caller closes the
/// descriptor. The one place both transcript kinds (subagent and main session) get their descriptors.
func openOwnRegularFile(_ path: String) -> Int32? {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
        close(descriptor)
        return nil
    }
    return descriptor
}

/// A main-session transcript that passed the location rules: `<profile>/projects/<folder>/<session id>.jsonl`, with its
/// real path inside the profile's `projects` folder. Nothing is open yet.
public struct ClaudeTranscriptFile: Equatable, Sendable {
    /// The path with symlinks resolved.
    public let path: String
    public let sessionID: String

    func openDescriptor() -> Int32? { openOwnRegularFile(path) }
}

/// Where a session's transcript is. The path can come from a hook payload (`transcript_path`) or be searched by the
/// session id, so it is checked here, right before anything opens it: the id is a plain identifier, the file is
/// `projects/<folder>/<id>.jsonl`, and after `realpath` it lies inside the profile's `projects` folder.
public enum ClaudeTranscriptLocator {
    /// The session's transcript under a Claude config directory (`CLAUDE_CONFIG_DIR`, or `~/.claude` for the default
    /// profile). `workingDirectory` is looked at first (Claude names the folder after it); otherwise every project
    /// folder is searched by name and the most recently modified file wins.
    public static func locate(sessionID: String, configDirectory: URL, workingDirectory: String? = nil) -> ClaudeTranscriptFile? {
        locate(sessionID: sessionID, projectsDirectory: configDirectory.appendingPathComponent("projects", isDirectory: true),
               workingDirectory: workingDirectory)
    }

    public static func locate(sessionID: String, projectsDirectory: URL, workingDirectory: String? = nil) -> ClaudeTranscriptFile? {
        guard isPlainIdentifier(sessionID) else { return nil }
        if let workingDirectory {
            let candidate = projectsDirectory.appendingPathComponent(folderName(forWorkingDirectory: workingDirectory), isDirectory: true)
                .appendingPathComponent(sessionID + ".jsonl")
            if let found = resolve(path: candidate.path, sessionID: sessionID, projectsDirectory: projectsDirectory) { return found }
        }
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return folders.map { $0.appendingPathComponent(sessionID + ".jsonl") }
            .filter { manager.fileExists(atPath: $0.path) }
            .sorted { modified($0) > modified($1) }
            .lazy.compactMap { resolve(path: $0.path, sessionID: sessionID, projectsDirectory: projectsDirectory) }
            .first
    }

    /// Checks a path someone else named (a hook payload's `transcript_path`).
    public static func resolve(path: String, sessionID: String, projectsDirectory: URL) -> ClaudeTranscriptFile? {
        guard isPlainIdentifier(sessionID), path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        guard let projects = realpath(projectsDirectory.path, nil) else { return nil }
        defer { free(projects) }
        let real = String(cString: resolved)
        let prefix = String(cString: projects) + "/"
        guard real.hasPrefix(prefix) else { return nil }
        let parts = real.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[1] == "\(sessionID).jsonl" else { return nil }
        return ClaudeTranscriptFile(path: real, sessionID: sessionID)
    }

    /// Claude's folder name for a working directory: every character that is not a letter or digit becomes `-`.
    static func folderName(forWorkingDirectory path: String) -> String {
        String(path.unicodeScalars.map { scalar in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        })
    }

    private static func isPlainIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" }
    }
}
