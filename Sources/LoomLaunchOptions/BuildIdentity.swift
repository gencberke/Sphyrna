import Foundation

/// Which build this is, derived once from the bundle identifier. The one owner
/// of "is this the production app" and of every identity-derived name; pure
/// value logic so both identities are testable without launching AppKit.
public struct BuildIdentity: Equatable, Sendable {
    /// The daily-use `Loom.app`. Every other identifier (the dev package,
    /// tests, a bare executable) is a development build.
    public static let productionBundleIdentifier = "local.loom.desktop"

    public let isProduction: Bool

    public init(bundleIdentifier: String?) {
        isProduction = bundleIdentifier == Self.productionBundleIdentifier
    }

    /// Folder under `~/Library/Application Support`.
    public var dataDirectoryName: String { isProduction ? "Loom" : "Loom-Dev" }

    /// Folder under the home directory for run-host and hook sockets.
    public var socketDirectoryName: String { isProduction ? ".loom" : ".loom-dev" }

    /// Evidence command channel (dev acceptance tooling only; a normal launch
    /// never subscribes). Scripts compute the same name, so it is one fixed
    /// string for both identities.
    public var commandChannelPrefix: String { "local.loom.desktop.dev.command." }

    /// Provider raw values a user may start. Codex is compiled and paused
    /// (D-14, D-28): absent from the production app, present in development.
    /// Raw strings keep this target free of dependencies.
    public var startableProviders: [String] { isProduction ? ["claude"] : ["claude", "codex"] }
}
