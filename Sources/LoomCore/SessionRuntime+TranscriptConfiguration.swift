import Foundation

extension SessionRuntime {
    /// The already resolved Codex profile, if a session resolved it. This never starts or probes a provider.
    public func cachedCodexTranscriptHome() -> URL? {
        cachedToolchain(for: .codex)?.profileDirectory
    }
}
