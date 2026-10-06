import Darwin
import Foundation

/// Where Claude's own files live for one launch profile. Pure: every input is
/// passed in and nothing here reads the process environment or the disk.
///
/// The rule mirrors the launcher (`SessionRuntime.claudeProfile` and
/// `launchClaude`): an explicit profile directory (`ProviderToolchain
/// .profileDirectory`, set by `--claude-config`) wins, else `CLAUDE_CONFIG_DIR`
/// from the resolved terminal environment, else `~/.claude`. `~/.config/claude`
/// is never consulted. An empty or relative `CLAUDE_CONFIG_DIR` cannot be
/// resolved without the CLI's own working directory and falls through to home.
public struct ClaudeProfileLayout: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case explicitProfile
        case environment
        case homeDefault
    }

    /// Real path (symlinks resolved) when the directory exists, the registry reader's stance.
    public let configDirectory: URL
    public let source: Source

    public var projectsDirectory: URL { configDirectory.appendingPathComponent("projects", isDirectory: true) }

    public init(profileDirectory: URL?, environment: [String: String], home: URL) {
        let chosen: URL
        if let profileDirectory {
            chosen = profileDirectory
            source = .explicitProfile
        } else if let value = environment["CLAUDE_CONFIG_DIR"], value.hasPrefix("/") {
            chosen = URL(fileURLWithPath: value, isDirectory: true)
            source = .environment
        } else {
            chosen = home.appendingPathComponent(".claude", isDirectory: true)
            source = .homeDefault
        }
        // realpath, not resolvingSymlinksInPath: the latter strips /private, and the index keys
        // files by path, so every caller must see one spelling.
        if let resolved = realpath(chosen.path, nil) {
            configDirectory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
        } else {
            configDirectory = chosen.resolvingSymlinksInPath()
        }
    }

    public init(toolchain: ProviderToolchain, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(profileDirectory: toolchain.profileDirectory, environment: toolchain.environment, home: home)
    }
}
