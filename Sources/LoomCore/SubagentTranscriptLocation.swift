import Darwin
import Foundation

/// A subagent's transcript that passed the location rules: its real path, which lies inside the profile's
/// `projects` folder and has the shape Claude writes. Nothing is open yet; `openDescriptor()` opens it.
public struct SubagentTranscriptFile: Equatable, Sendable {
    /// The path with symlinks resolved.
    public let path: String
    public let agentID: String

    /// Opens the file read-only, never through a final link, and only a regular file of this user.
    /// The caller closes the descriptor.
    func openDescriptor() -> Int32? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            close(descriptor)
            return nil
        }
        return descriptor
    }
}

/// Where a subagent's transcript may be read from (FB4-5). The path comes from a hook payload and the
/// `meta.json` beside the file, so it is checked again here, right before anything opens it:
/// - the id is one of Claude's (`SubagentMeta.isValidAgentID`);
/// - the file is `…/subagents/agent-<id>.jsonl` or `…/subagents/workflows/<run>/agent-<id>.jsonl`;
/// - after `realpath` it lies inside the profile's `projects` folder, so a link or `..` cannot lead out.
public enum SubagentTranscriptLocation {
    public static func resolve(path: String, agentID: String, projectsDirectory: URL) -> SubagentTranscriptFile? {
        guard SubagentMeta.isValidAgentID(agentID), path.hasPrefix("/"),
              let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        guard let projects = realpath(projectsDirectory.path, nil) else { return nil }
        defer { free(projects) }
        let real = String(cString: resolved)
        guard real.hasPrefix(String(cString: projects) + "/") else { return nil }
        let parts = real.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[parts.count - 1] == "agent-\(agentID).jsonl" else { return nil }
        let folder = parts[parts.count - 2]
        let inSubagents = folder == "subagents"
        let inWorkflow = parts.count >= 5 && parts[parts.count - 3] == "workflows" && parts[parts.count - 4] == "subagents"
        guard inSubagents || inWorkflow else { return nil }
        return SubagentTranscriptFile(path: real, agentID: agentID)
    }
}
