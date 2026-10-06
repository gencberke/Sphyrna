import CryptoKit
import Foundation

/// The app's command-line options, parsed once. Pure value logic so the data
/// root and evidence rules can be tested without launching AppKit.
public struct LaunchOptions: Equatable, Sendable {
    public enum DataRoot: Equatable, Sendable {
        case root(URL)
        /// The catalog must not be opened; nothing may fall back to the default root.
        case refused(String)
    }

    public let arguments: [String]

    public init(arguments: [String]) { self.arguments = arguments }

    public func contains(_ flag: String) -> Bool { arguments.contains(flag) }

    public func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Acceptance run directory (`--evidence <dir>`); nil for a normal launch.
    public var evidenceDirectory: String? { value(after: "--evidence") }
    public var isEvidence: Bool { evidenceDirectory != nil }

    /// Evidence mode never touches the default root: `--data-root` if given,
    /// else `<evidence>/data`. `--data-root` alone, or a flag without its
    /// value, refuses the catalog instead of silently using the default root.
    public func resolveDataRoot(defaultRoot: URL) -> DataRoot {
        let wantsEvidence = contains("--evidence"), wantsRoot = contains("--data-root")
        if wantsEvidence, evidenceDirectory == nil {
            return .refused("--evidence needs a directory. Loom did not open its catalog.")
        }
        if wantsRoot, value(after: "--data-root") == nil {
            return .refused("--data-root needs a directory. Loom did not open its catalog.")
        }
        guard let evidence = evidenceDirectory else {
            if wantsRoot {
                return .refused("--data-root is only valid together with --evidence. Loom did not open its catalog.")
            }
            return .root(defaultRoot)
        }
        if let path = value(after: "--data-root") { return .root(URL(fileURLWithPath: path, isDirectory: true)) }
        return .root(URL(fileURLWithPath: evidence, isDirectory: true).appendingPathComponent("data", isDirectory: true))
    }

    /// Per-instance command channel: the distributed notification name carries a
    /// hash of the evidence directory's real path, so concurrent evidence
    /// instances (and normal launches, which never subscribe) cannot hear each
    /// other. Scripts compute the same name with `loom_command_channel`.
    public static let commandChannelPrefix = "local.loom.desktop.dev.command."

    public static func commandChannel(evidenceDirectory: String) -> String {
        var resolved = URL(fileURLWithPath: evidenceDirectory).standardizedFileURL.path
        if let real = realpath(evidenceDirectory, nil) {
            resolved = String(cString: real)
            free(real)
        }
        let digest = SHA256.hash(data: Data(resolved.utf8))
        return commandChannelPrefix + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }
}
