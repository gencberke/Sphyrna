import Foundation

public enum ProviderResumePlanner {
    public static func claude(
        session: ManagedSession, capabilities: ProviderCapabilities,
        config: URL, environment: [String: String],
        hooks: ClaudeHookLaunchConfiguration? = nil
    ) throws -> ProviderLaunchProfile {
        guard session.provider == .claude,
              let conversationID = session.providerConversationID,
              !conversationID.isEmpty else {
            throw LoomError.message("Claude session has no provider session identity")
        }
        return try .claude(
            route: .resume(conversationID), capabilities: capabilities,
            config: config, environment: environment, hooks: hooks
        )
    }

    public static func codex(
        session: ManagedSession, socketPath: String,
        capabilities: ProviderCapabilities, home: URL,
        environment: [String: String]
    ) throws -> ProviderLaunchProfile {
        guard session.provider == .codex,
              let conversationID = session.providerConversationID,
              !conversationID.isEmpty else {
            throw LoomError.message("Codex session has no provider session identity")
        }
        return try .codex(
            route: .remote(socket: socketPath, threadID: conversationID, workingDirectory: session.workingDirectory),
            capabilities: capabilities, home: home, environment: environment
        )
    }
}

/// Converts only explicit provider-history diagnostics to the typed product
/// error. Unknown exits remain unknown; they must never silently fall back to a
/// new conversation.
public enum ProviderResumeDiagnostics {
    public static func error(
        provider: ManagedSession.Provider, conversationID: String,
        output: String, exitStatus: Int32
    ) -> (any Error)? {
        guard exitStatus != 0 else { return nil }
        let normalized = output.lowercased()
        let unavailable: Bool
        switch provider {
        case .claude:
            unavailable = normalized.contains("no conversation found")
                || normalized.contains("session not found")
                || normalized.contains("cannot resume")
        case .codex:
            unavailable = normalized.contains("thread not found")
                || normalized.contains("rollout not found")
                || normalized.contains("conversation not found")
                || normalized.contains("no saved session found")
        case .synthetic:
            unavailable = false
        }
        if unavailable {
            return LoomError.providerHistoryUnavailable(
                provider: provider, conversationID: conversationID
            )
        }
        return LoomError.message(
            "\(provider.rawValue) resume exited with status \(exitStatus)"
        )
    }
}
