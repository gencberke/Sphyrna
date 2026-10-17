import Foundation

/// The latest main-thread assistant message of one session, as the usage index holds it: what the
/// context ring reads. It comes from the index's own database (an indexed lookup); no transcript
/// is opened for it.
public struct SessionContextSample: Equatable, Sendable {
    /// The model id as the transcript wrote it.
    public var model: String
    public var timestamp: Date
    public var tokens: UsageTokens

    public init(model: String, timestamp: Date, tokens: UsageTokens) {
        self.model = model
        self.timestamp = timestamp
        self.tokens = tokens
    }

    /// What the model read on its last turn: fresh input plus both cache classes. Output is left out,
    /// the way Claude Code's own context figure leaves it out (it counts on the next turn's input).
    public var contextTokens: Int64 { tokens.input + tokens.cacheWrite + tokens.cacheRead }
}

/// One session's context at a glance: tokens always, a share only when the model's window is known.
public struct ContextUsage: Equatable, Sendable {
    public var tokens: Int64
    /// The model's context window in tokens; nil while unknown.
    public var window: Int64?
    public var model: String

    public init(tokens: Int64, window: Int64?, model: String) {
        self.tokens = max(tokens, 0)
        self.window = window.flatMap { $0 > 0 ? $0 : nil }
        self.model = model
    }

    public init(sample: SessionContextSample, window: Int64?) {
        self.init(tokens: sample.contextTokens, window: window, model: sample.model)
    }

    /// Tokens over the window, 0...1; nil when the window is unknown (no percentage is guessed).
    public var fraction: Double? {
        guard let window else { return nil }
        return min(max(Double(tokens) / Double(window), 0), 1)
    }

    /// A whole percent, 0...100, rounded; nil with `fraction`.
    public var percent: Int? { fraction.map { Int(($0 * 100).rounded()) } }
}
