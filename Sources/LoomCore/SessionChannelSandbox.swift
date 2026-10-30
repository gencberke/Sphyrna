import Foundation

/// Whether a session's own harness lets its agent reach Sphyrna's session channel (`"$SPHYRNA_CLI"` task, send, inbox).
///
/// Codex runs the commands its agent starts inside its macOS seatbelt sandbox. Every mode Sphyrna starts Codex in sandboxes
/// it with the network off (`CodexLaunchSettings`: Ask before edits is `read-only`, Accept edits is `workspace-write` with
/// `sandbox_workspace_write.network_access=false`; a start without a mode takes Ask before edits). That policy has no
/// outbound rule for Unix sockets, so the helper's connect is denied and the channel is unreachable from such a session.
/// Codex 0.164 allows named Unix sockets only together with its managed network proxy (`permissions.<profile>.network`),
/// which opens a network path; Sphyrna does not use it. Claude sessions are not affected.
public enum SessionChannelSandbox {
    /// The plain reason every surface gives.
    public static let codexReason = "Codex's sandbox in this mode blocks Sphyrna's session channel"

    /// The reason a session of `harness` in `mode` cannot use the channel; nil when it can. A nil mode is the mode a
    /// start without one takes.
    public static func blockedReason(harness: HarnessID, mode: HarnessMode?) -> String? {
        guard let descriptor = HarnessCatalogue.descriptor(for: harness), let block = descriptor.sessionChannelBlocked,
              let effective = mode ?? descriptor.defaultMode, block.modes.contains(effective) else { return nil }
        return block.reason
    }

    /// What the helper says when a sandbox denied its connect (a seatbelt denial is `EPERM`), instead of a bare
    /// connection error. Codex marks a sandboxed command with the network off by `CODEX_SANDBOX_NETWORK_DISABLED=1`.
    static func helperConnectFailure(_ error: Error, environment: [String: String]) -> String? {
        guard case let ClaudeHookTransportError.system(operation, code) = error,
              operation == "connect" || operation == "socket", code == EPERM || code == EACCES else { return nil }
        let reason = environment["CODEX_SANDBOX_NETWORK_DISABLED"] == "1"
            ? codexReason : "A sandbox blocks Sphyrna's session channel"
        return "error: \(reason); its connection to Sphyrna was denied (\(String(cString: strerror(code))))"
    }
}

extension SessionRuntime {
    /// `SessionChannelSandbox.blockedReason` for a stored session, by its harness and recorded mode. A session the catalog
    /// does not know yet has no reason here; the callers' own guards refuse it.
    func sessionChannelBlockedReason(sessionID: UUID) async -> String? {
        guard let record = try? await catalog.session(id: sessionID) else { return nil }
        let mode = (try? await catalog.launchChoices(sessionID: sessionID)).flatMap { HarnessMode.fromStored($0.permissionMode) }
        return configuration.sessionChannelBlock(record.session.harnessID, mode)
    }
}
