import Foundation
import LoomChat
import LoomCore
import Observation

// What the inspector's Changes tab (V20) holds per session: the scope it shows, what each scope read, the open file,
// the comment drafts and the state of a send. Nothing here reads a file or runs a program; the reads are
// `CatalogModel+Changes.swift`, and they happen only while the tab is open.

/// What the tab compares: Claude's edits of the last turn or of the whole session, or the branch against its base.
enum ChangesScope: String, CaseIterable, Sendable {
    case lastTurn
    case wholeSession
    case branch

    var title: String {
        switch self {
        case .lastTurn: "Last turn"
        case .wholeSession: "Whole session"
        case .branch: "Branch"
        }
    }

    var isEdits: Bool { self != .branch }
}

/// One file of a scope, as the list and the message name it.
struct ChangesFile: Equatable, Identifiable, Sendable {
    /// Unique within the scope: the absolute path of an edit, the repository path of a branch file.
    let id: String
    /// Relative to the session's folder (edits) or the repository (branch): what the list shows and the message names.
    var displayPath: String
    var absolutePath: String
    var added: Int
    var removed: Int
    var isBinary = false
    var isTooLarge = false
}

/// What a scope read.
struct ChangesScopeData: Equatable, Sendable {
    var files: [ChangesFile]
    /// The hunks of each file (edit scopes; a branch file's diff is read when it is shown).
    var hunks: [String: [DiffHunk]] = [:]
    /// The byte bound ended the edit scan before the scope was complete.
    var truncated = false
    /// Branch files past the reader's cap.
    var omittedFiles = 0
    /// The branch scope's base ("main") and whether the session is on it (then the files are the uncommitted changes).
    var baseName: String?
    var onBase = false
    var list: GitChangeList?
}

enum ChangesScopeState: Equatable, Sendable {
    /// Not read yet.
    case idle
    case loading
    case ready(ChangesScopeData)
    /// The scope cannot be shown here, with the reason ("Not a Git repository").
    case off(String)
    case timedOut
    case failed(String)

    var data: ChangesScopeData? {
        if case let .ready(data) = self { data } else { nil }
    }
}

/// One file's diff in the branch scope.
enum ChangesFileDiff: Equatable, Sendable {
    case loading
    case hunks([DiffHunk])
    case binary
    case tooLarge
    case timedOut
    case failed(String)
}

/// Where a comment sits: the file, the line (the new side's number, the old side's for a removed line) and the line's
/// text. A line is found again after a re-read by these three, so a comment stays with its line when other lines move.
struct ChangeAnchor: Hashable, Sendable {
    var fileID: String
    var line: Int?
    var removed: Bool
    var text: String
}

struct ChangeComment: Equatable, Identifiable, Sendable {
    let id: UUID
    var anchor: ChangeAnchor
    /// The path the message names.
    var displayPath: String
    var text: String
}

/// The text one send carries: every comment of a scope as one plain-text message.
enum ChangesMessage {
    /// "Comments on the changes (<scope name>):", then one block per comment: `path:line`, the line quoted, the comment.
    /// `comments` come in the order they should read; a line without a number (a notebook cell) names the file alone.
    static func text(scopeName: String, comments: [ChangeComment]) -> String {
        let blocks = comments.map { comment -> String in
            let place = comment.anchor.line.map { "\(comment.displayPath):\($0)" } ?? comment.displayPath
            return "\(place)\n> \(comment.anchor.text)\n\(comment.text)"
        }
        return (["Comments on the changes (\(scopeName)):"] + blocks).joined(separator: "\n\n")
    }
}

/// The footer's wording: "2 comments in 2 files".
enum ChangesFooterText {
    static func summary(comments: Int, files: Int) -> String {
        "\(comments) comment\(comments == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
    }
}

enum ChangesSendStatus: Equatable, Sendable {
    case idle
    case sending
    case failed(String)
}

/// The tab's holder for one session. In memory only: drafts are not kept across a relaunch.
@MainActor @Observable
final class SessionChanges {
    var scope: ChangesScope = .lastTurn
    private(set) var states: [ChangesScope: ChangesScopeState] = [:]
    private(set) var selected: [ChangesScope: String] = [:]
    /// The branch files' diffs, by file id; reset with every new list.
    private(set) var gitDiffs: [String: ChangesFileDiff] = [:]
    private(set) var drafts: [ChangesScope: [ChangeComment]] = [:]
    /// The comment box that is open, and what it holds.
    var composing: ChangeAnchor?
    var composingText = ""
    var sendStatus: ChangesSendStatus = .idle
    /// A turn ended while the tab was open: reads again.
    private(set) var revision = 0

    @ObservationIgnored var wasWorking: Bool?
    /// Moves with every branch list, so a diff read for an older list is dropped.
    @ObservationIgnored private(set) var branchGeneration = 0

    func state(_ scope: ChangesScope) -> ChangesScopeState { states[scope] ?? .idle }
    var currentState: ChangesScopeState { state(scope) }

    func setState(_ state: ChangesScopeState, for scope: ChangesScope) {
        guard states[scope] != state else { return }
        states[scope] = state
    }

    func select(_ id: String?, in scope: ChangesScope) {
        guard selected[scope] != id else { return }
        selected[scope] = id
    }

    func setGitDiff(_ diff: ChangesFileDiff?, for id: String) {
        guard gitDiffs[id] != diff else { return }
        gitDiffs[id] = diff
    }

    /// A new branch list: the diffs read for the old one are gone.
    func resetGitDiffs() {
        branchGeneration += 1
        if !gitDiffs.isEmpty { gitDiffs = [:] }
    }

    func bumpRevision() { revision += 1 }

    // MARK: Comments

    func comments(in scope: ChangesScope) -> [ChangeComment] { drafts[scope] ?? [] }

    /// Saves the comment at `anchor`; a second comment on the same line replaces the first.
    func saveComment(_ text: String, at anchor: ChangeAnchor, displayPath: String, in scope: ChangesScope) {
        var list = drafts[scope] ?? []
        if let index = list.firstIndex(where: { $0.anchor == anchor }) {
            list[index].text = text
        } else {
            list.append(ChangeComment(id: UUID(), anchor: anchor, displayPath: displayPath, text: text))
        }
        drafts[scope] = list
    }

    func removeComment(at anchor: ChangeAnchor, in scope: ChangesScope) {
        drafts[scope]?.removeAll { $0.anchor == anchor }
    }

    func discardComments(in scope: ChangesScope) {
        drafts[scope] = nil
        composing = nil
        composingText = ""
    }

    func comment(at anchor: ChangeAnchor, in scope: ChangesScope) -> ChangeComment? {
        drafts[scope]?.first { $0.anchor == anchor }
    }
}

/// The holder on `CatalogModel`: one `SessionChanges` per session, and how the tab reads.
@MainActor @Observable
final class ChangesState {
    @ObservationIgnored private var sessions: [UUID: SessionChanges] = [:]
    @ObservationIgnored var reader = ChangesReader.unavailable
    /// Replaces the send path of a test; nil sends through the session's Chat driver.
    @ObservationIgnored var sendOverride: (@MainActor (String, UUID) async throws -> Void)?

    init() {}

    func session(for id: UUID) -> SessionChanges {
        if let existing = sessions[id] { return existing }
        let made = SessionChanges()
        sessions[id] = made
        return made
    }

    func existing(_ id: UUID) -> SessionChanges? { sessions[id] }

    /// The session was deleted: what it read, its open file and its comment drafts go.
    func forget(_ id: UUID) { sessions[id] = nil }
}

/// What the tab's reads are made of, so a test counts them and the app wires the real ones.
struct ChangesReader: Sendable {
    struct Transcript: Sendable {
        var sessionID: String
        var configDirectory: URL
        var workingDirectory: String?
    }

    var editScan: @Sendable (Transcript, EditScan.Scope) async -> EditScanResult
    var gitList: @Sendable (_ directory: String) async -> GitChangesState
    var gitDiff: @Sendable (GitChangeFile, GitChangeList) async -> GitFileDiff

    /// The scan runs on its own task off the main actor; git goes through `GitChanges` (nil: Git cannot be reached).
    static func live(git: GitChanges?) -> ChangesReader {
        ChangesReader(
            editScan: { transcript, scope in
                await Task.detached(priority: .userInitiated) {
                    guard let file = ClaudeTranscriptLocator.locate(
                        sessionID: transcript.sessionID, configDirectory: transcript.configDirectory,
                        workingDirectory: transcript.workingDirectory) else { return EditScanResult.empty }
                    return EditScan.scan(file: file, scope: scope)
                }.value
            },
            gitList: { directory in
                guard let git else { return .failed("Git is not available here") }
                return await git.list(directory: directory)
            },
            gitDiff: { file, list in
                guard let git else { return .failed("Git is not available here") }
                return await git.diff(of: file, in: list)
            })
    }

    static let unavailable = live(git: nil)
}

/// What the tab reads for: the selected session, its open scope and how many turns ended while it was open. Nil while
/// the tab is closed, which is when nothing reads.
struct ChangesTrigger: Equatable, Sendable {
    var session: UUID
    var scope: ChangesScope
    var revision: Int
}
