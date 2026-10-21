import Foundation

/// A finished answer: the visible text, the validated parts of its closing block, and what the call cost.
public struct RemoraAnswer: Equatable, Sendable {
    public enum BlockState: String, Sendable {
        /// The closing block was there and valid.
        case valid
        /// There was none (the answer is text only).
        case missing
        /// There was one and it could not be used: the fields below are empty, the text stands.
        case invalid
    }

    /// The answer as shown: the model's text without the closing block, trimmed.
    public var text: String
    public var cited: [String]
    public var chips: [RemoraChip]
    public var drafts: [RemoraDraft]
    public var proposedFacts: [String]
    /// A brief's rewritten project notes and its one-line summary of the day (empty and nil for a question or a block
    /// without them). `RemoraMemory.apply` is what uses them.
    public var notes: [RemoraNoteUpdate] = []
    public var summary: String?
    public var block: BlockState
    /// The model id from `system/init` (`claude-sonnet-5-5`).
    public var model: String?
    public var usage: RemoraTokenUsage
    public var costUSD: Double?
    /// From the start of the call to its result.
    public var duration: Duration
}
