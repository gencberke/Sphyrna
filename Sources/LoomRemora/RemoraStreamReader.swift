import Foundation
import LoomChat

/// Reads the child's stdout (stream-json, `--include-partial-messages`) for one call: text deltas out as they come
/// (thinking dropped), then the result. Judges the end by `is_error` and `terminal_reason`, never by `subtype`: a refused
/// pack and a failed login are `subtype: "success"` with `is_error: true` (S10, S1).
struct RemoraStreamReader {
    enum Outcome: Equatable {
        case answer(RemoraAnswer)
        case failure(RemoraFailure)
    }

    private var decoder = StreamJSONDecoder()
    private var splitter = AnswerSplitter()
    private let known: Set<String>
    private var shown = ""
    private var sawTextDelta = false
    private var refusalSeen = false
    private var assistantError: String?
    private var assistantText = ""
    private(set) var model: String?
    private(set) var costUSD: Double?
    private(set) var outcome: Outcome?

    init(knownSessionIDs: Set<String>) { known = knownSessionIDs }

    /// The next piece of stdout. Returns the visible text pieces it settled; `outcome` is set once the result is read
    /// (frames after it are ignored).
    mutating func feed(_ chunk: Data) -> [String] {
        var pieces: [String] = []
        for frame in decoder.feed(chunk) {
            guard outcome == nil, case let .message(message) = frame else { continue }
            handle(message, into: &pieces)
        }
        return pieces
    }

    private mutating func handle(_ message: StreamMessage, into pieces: inout [String]) {
        switch message {
        case let .systemInit(start):
            model = start.model ?? model
        case let .streamEvent(event) where event.parentToolUseID == nil:
            switch event.event {
            case let .blockDelta(_, .text(text)):
                sawTextDelta = true
                emit(splitter.feed(text), into: &pieces)
            case let .messageDelta(stopReason, _):
                if stopReason == "refusal" { refusalSeen = true }
            default: break
            }
        case let .assistant(reply) where reply.parentToolUseID == nil:
            assistantError = reply.error ?? assistantError
            if reply.error == nil, !reply.isSynthetic {
                for case let .text(text) in reply.content { assistantText += text }
            }
            model = reply.isSynthetic ? model : (reply.model ?? model)
        case let .result(result):
            finish(with: result, into: &pieces)
        default:
            break
        }
    }

    private mutating func emit(_ piece: String, into pieces: inout [String]) {
        guard !piece.isEmpty else { return }
        shown += piece
        pieces.append(piece)
    }

    private mutating func finish(with result: TurnResult, into pieces: inout [String]) {
        costUSD = result.totalCostUSD
        let tokens = RemoraTokenUsage(result.usage)
        let failed = result.isError || (result.terminalReason.map { $0 != "completed" } ?? false)
        if failed {
            outcome = .failure(RemoraFailure(kind: failureKind(result), detail: failureDetail(result), usage: tokens))
            return
        }
        // No partial messages came (a very short answer, or a build that does not send them): the whole text is the delta.
        if !sawTextDelta {
            let whole = assistantText.isEmpty ? (result.result ?? "") : assistantText
            emit(splitter.feed(whole), into: &pieces)
        }
        emit(splitter.finish(), into: &pieces)
        var answer = RemoraAnswer(
            text: shown.trimmingCharacters(in: .whitespacesAndNewlines), cited: [], chips: [], drafts: [], proposedFacts: [],
            block: .missing, model: model, usage: tokens, costUSD: result.totalCostUSD, duration: .zero)
        if let blockText = splitter.block {
            if let block = RemoraBlock.parse(blockText, knownSessionIDs: known) {
                answer.block = .valid
                answer.cited = block.cited
                answer.chips = block.chips
                answer.drafts = block.drafts
                answer.proposedFacts = block.facts
            } else {
                answer.block = .invalid
            }
        }
        outcome = .answer(answer)
    }

    private func failureKind(_ result: TurnResult) -> RemoraFailure.Kind {
        if refusalSeen || result.stopReason == "refusal" { return .refused }
        switch assistantError {
        case "authentication_failed"?: return .notLoggedIn
        case "rate_limit"?, "billing_error"?: return .rateLimited
        default: break
        }
        if result.apiErrorStatus == 429 { return .rateLimited }
        if result.apiErrorStatus == 401 || result.result?.hasPrefix("Not logged in") == true { return .notLoggedIn }
        return .apiError
    }

    /// Claude's own error line (an API error text), cut short; never the pack or the answer.
    private func failureDetail(_ result: TurnResult) -> String {
        let line = result.errors.first ?? result.result ?? ""
        return String(line.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(200) ?? "")
    }
}
