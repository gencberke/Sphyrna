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

/// What the request card shows for one request, as plain values (the view only draws them). Kept apart from the view so each
/// kind and phase can be checked without a window. The card reads as the session it will become (FB6-24): its requester, the
/// title, the harness, model, effort, mode and project in one mono line, then the first three lines of the message.
struct OpenRequestBoxContent: Equatable {
    enum Action: Hashable { case deny, openSession, dismiss }

    /// A "preview" of the first message: this many lines, shown before "Show full message".
    static let previewLineLimit = 3
    /// A single very long line is cut here in the preview (the full text is one click away).
    static let previewCharacterLimit = 480

    let heading = "Open a new session?"
    /// "from <requester>", in mono on the heading's trailing side.
    let requester: String
    /// "1 of 3" when several requests wait, oldest first; nil for one.
    let counter: String?
    /// The title of the session that will open.
    let title: String
    let harnessName: String
    let provider: ManagedSession.Provider?
    /// The choices the session starts with, as the user reads them: a missing choice is Sphyrna's default.
    let model: String
    let effort: String
    let mode: String
    let projectName: String
    /// The first lines of the message.
    let preview: String
    /// More message than the preview shows: "Show full message" is offered.
    let hasMore: Bool
    let message: String
    /// "Opening…" while the approved session starts; the view draws a spinner in the accent button's place instead.
    let status: String?
    /// The approved session is starting: the buttons are disabled and the spinner takes the accent button's place.
    let showsSpinner: Bool
    let failure: String?
    let actions: [Action]
    /// The buttons are shown but cannot be pressed (the session is starting).
    let actionsDisabled: Bool

    /// `position` and `count` are the card's place among the requests of this session, oldest first. The coordinator
    /// has already resolved the mode; nil model and effort mean the harness's own defaults.
    init(_ request: OpenSessionRequest, position: Int = 1, count: Int = 1) {
        requester = "from " + (request.requesterTitle ?? SessionOrigin.unknownRequester)
        counter = count > 1 ? "\(position) of \(count)" : nil
        title = request.title
        let descriptor = HarnessCatalogue.descriptor(for: request.choices.harness)
        harnessName = descriptor?.displayName ?? request.choices.harness.rawValue
        provider = descriptor?.provider
        model = request.choices.model.map { request.choices.claudeChoices != nil ? ModelCatalog.claudeTitle(of: $0) : $0 }
            ?? "Default model"
        effort = request.choices.effort ?? "Default effort"
        mode = request.choices.mode?.title ?? descriptor?.defaultMode?.title ?? "Default mode"
        projectName = request.projectName
        let split = Self.preview(of: request.message)
        preview = split.text
        hasMore = split.truncated
        message = request.message
        switch request.phase {
        case .waiting:
            status = nil
            showsSpinner = false
            failure = nil
            actions = [.deny, .openSession]
            actionsDisabled = false
        case .starting:
            status = "Opening…"
            showsSpinner = true
            failure = nil
            actions = [.deny, .openSession]
            actionsDisabled = true
        case let .failed(text):
            status = nil
            showsSpinner = false
            failure = text
            actions = [.dismiss]
            actionsDisabled = false
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

/// One answered request, folded to a one-line notice for `LoomTheme.OpenRequest.foldLinger`: "Opened: <title>" with a way to
/// the new session, or "Denied: <title>". A dismissed failure just goes: there is nothing to report.
struct OpenRequestFold: Identifiable, Equatable {
    enum Outcome: Equatable { case opened, denied }

    /// The answered request's id.
    let id: UUID
    let outcome: Outcome
    let title: String
    /// The session whose agent asked: the opened session is found by its origin and title.
    let requesterID: UUID

    var text: String {
        switch outcome {
        case .opened: "Opened: " + title
        case .denied: "Denied: " + title
        }
    }

    var showsGoToSession: Bool { outcome == .opened }
}

extension OpenSessionRequest {
    /// The requester's card needs the user: a request nobody answered, or one that failed to
    /// start (its box stays until dismissed). A request that is starting does not.
    var needsUser: Bool {
        switch phase {
        case .waiting, .failed: return true
        case .starting: return false
        }
    }

    /// What answering this request folds to (FB6-24): an approved request was starting and is now gone, so its session
    /// exists; a request that left while it still waited was denied. A failed request that was dismissed folds to nothing.
    var answeredFold: OpenRequestFold.Outcome? {
        switch phase {
        case .waiting: return .denied
        case .starting: return .opened
        case .failed: return nil
        }
    }
}

/// What acceptance evidence records about the requests of agents to open a session (`--evidence`
/// snapshot, `openRequests`). A library seam like `IndicatorEvidence`: it only reads. Title and
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
                "phase": phase, "title": redacted ? "" : request.title,
                "project": request.projectID.uuidString, "failure": failure,
            ] as [String: Any]
        }
    }
}
