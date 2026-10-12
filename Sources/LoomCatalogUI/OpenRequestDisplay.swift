import Foundation
import LoomCore

/// Where a session came from (D-39, D-40): the session whose agent asked Loom to open it.
/// The card's meta row shows "from <requester>" in place of the branch only when both sessions
/// are on the same branch (the branch then says nothing new); otherwise the branch stays and the
/// origin moves to the tooltip.
public struct SessionOrigin: Equatable, Sendable {
    /// What the card calls the requester when it no longer exists or cannot be read.
    public static let unknownRequester = "another session"

    /// The requester's title, or "another session".
    public let requester: String
    public let isKnown: Bool
    /// Both sessions are on the same (known) branch: the origin takes the branch's place on the card.
    public let replacesBranch: Bool

    /// `requesterTitle == nil`: the requester no longer exists. Its branch is then unknown, so the
    /// card keeps its own branch and the origin is only in the tooltip.
    public init(requesterTitle: String?, requesterBranch: GitBranch?, ownBranch: GitBranch) {
        isKnown = requesterTitle != nil
        requester = requesterTitle ?? Self.unknownRequester
        replacesBranch = requesterTitle != nil && requesterBranch == ownBranch
    }

    /// The meta row text beside the arrow glyph.
    public var cardLabel: String { "from " + requester }
    public var tooltip: String { "Opened by " + requester }
    /// The value of the detail view's "Opened by" row.
    public var factValue: String { isKnown ? requester : "Another session" }
    public var accessibilityPhrase: String { "opened by " + requester }
}

/// What the request box shows for one request, as plain values (the view only draws them). Kept
/// apart from the view so each kind and phase can be checked without a window.
struct OpenRequestBoxContent: Equatable {
    enum Action: Equatable { case deny, openSession, dismiss, showSession }

    /// A "preview" of the first message: this many lines, shown before "Show full message".
    static let previewLineLimit = 4
    /// A single very long line is cut here in the preview (the full text is one click away).
    static let previewCharacterLimit = 480

    struct Line: Equatable {
        let label: String
        let value: String
    }

    let heading: String
    /// Project, title and ticket of an open request; empty for a notice.
    let lines: [Line]
    /// The first lines of the message; empty for a notice.
    let preview: String
    /// More message than the preview shows: "Show full message" is offered.
    let hasMore: Bool
    let message: String
    /// "Opening…" while the approved session starts.
    let status: String?
    let failure: String?
    let actions: [Action]
    /// The buttons are shown but cannot be pressed (the session is starting).
    let actionsDisabled: Bool
    /// An orange callout needing a decision; the "already has a session" notice is neutral.
    let needsDecision: Bool

    init(_ request: OpenSessionRequest) {
        switch request.kind {
        case .exists:
            let ticket = request.ticketKey ?? "This ticket"
            let existing = request.existingTitle.flatMap { $0.isEmpty ? nil : $0 }
            heading = existing.map { "\(ticket) already has a session: \($0)" } ?? "\(ticket) already has a session"
            lines = []
            preview = ""
            hasMore = false
            message = ""
            status = nil
            failure = nil
            actions = request.existingSessionID == nil ? [.dismiss] : [.showSession, .dismiss]
            actionsDisabled = false
            needsDecision = false
        case .open:
            heading = "Open a new session?"
            var rows = [Line(label: "Project", value: request.projectName), Line(label: "Title", value: request.title)]
            if let ticket = request.ticketKey { rows.append(Line(label: "Ticket", value: ticket)) }
            lines = rows
            let split = Self.preview(of: request.message)
            preview = split.text
            hasMore = split.truncated
            message = request.message
            needsDecision = true
            switch request.phase {
            case .waiting:
                status = nil
                failure = nil
                actions = [.deny, .openSession]
                actionsDisabled = false
            case .starting:
                status = "Opening…"
                failure = nil
                actions = [.deny, .openSession]
                actionsDisabled = true
            case let .failed(text):
                status = nil
                failure = text
                actions = [.dismiss]
                actionsDisabled = false
            }
        }
    }

    /// The first `previewLineLimit` lines, and whether anything (more lines, or a cut line) is left.
    static func preview(of message: String) -> (text: String, truncated: Bool) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: previewLineLimit, omittingEmptySubsequences: false)
        var truncated = lines.count > previewLineLimit
        var text = lines.prefix(previewLineLimit).joined(separator: "\n")
        if text.count > previewCharacterLimit {
            text = String(text.prefix(previewCharacterLimit))
            truncated = true
        }
        return (text, truncated)
    }
}

extension OpenSessionRequest {
    /// The requester's card needs the user: an open request nobody answered, or one that failed to
    /// start (its box stays until dismissed). A request that is starting, and a notice, do not.
    var needsUser: Bool {
        guard kind == .open else { return false }
        switch phase {
        case .waiting, .failed: return true
        case .starting: return false
        }
    }
}

/// What acceptance evidence records about the requests of agents to open a session (`--evidence`
/// snapshot, `openRequests`). A library seam like `IndicatorEvidence`: it only reads. Title, ticket and
/// failure text are empty when the evidence is redacted (real providers).
public enum OpenRequestEvidence {
    public static func rows(_ requests: [OpenSessionRequest], redacted: Bool) -> [[String: Any]] {
        requests.map { request in
            let phase: String
            var failure = ""
            switch request.phase {
            case .waiting: phase = "waiting"
            case .starting: phase = "starting"
            case let .failed(text):
                phase = "failed"
                failure = redacted ? "" : text
            }
            return [
                "id": request.id.uuidString, "requester": request.requesterID.uuidString,
                "kind": request.kind == .open ? "open" : "exists", "phase": phase,
                "title": redacted ? "" : request.title, "ticket": redacted ? "" : (request.ticketKey ?? ""),
                "project": request.projectID.uuidString, "failure": failure,
                "existingSession": request.existingSessionID?.uuidString ?? "",
            ] as [String: Any]
        }
    }
}
