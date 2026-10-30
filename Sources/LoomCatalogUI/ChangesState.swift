import Foundation
import LoomChat
import LoomCore
import Observation

// What the inspector's Changes tab (V20) holds per session: the scope it shows, what each scope read, the open file,
// the comment drafts and the state of a send. Nothing here reads a file or runs a program; the reads are
// `CatalogModel+Changes.swift`, and they happen only while the tab is open.

/// What the tab compares: recorded edits of the last turn or of the whole session, or the branch against its base.
enum ChangesScope: String, CaseIterable, Hashable, Sendable {
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

/// How a file of a scope differs from before it: the list's status letter (M, A, D, R; DESIGN §13 File list).
enum ChangesFileStatus: String, Equatable, Sendable, CaseIterable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"

    /// The letter the list draws.
    var letter: String { rawValue }

    /// What VoiceOver reads in its place.
    var word: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        }
    }

    /// Claude's edits: a file the scope created is added; the edit tools do not delete files, so the rest are modified.
    static func edit(isCreate: Bool) -> Self { isCreate ? .added : .modified }

    /// Git's list: an untracked file is added, a rename keeps its letter, and a tracked file that lost every line is deleted.
    static func branch(_ status: GitChangeStatus, added: Int, removed: Int) -> Self {
        switch status {
        case .renamed: .renamed
        case .untracked: .added
        case .modified: added == 0 && removed > 0 ? .deleted : .modified
        }
    }
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
    /// The list's letter: modified, added, deleted or renamed.
    var status: ChangesFileStatus = .modified
    /// The path before a rename (branch scope only): the list reads "old → new".
    var oldPath: String?
}

/// What a scope read.
struct ChangesScopeData: Equatable, Sendable {
    var files: [ChangesFile]
    /// The hunks of each file (edit scopes; a branch file's diff is read when it is shown).
    var hunks: [String: [DiffHunk]] = [:]
    /// The byte bound ended the edit scan before the scope was complete.
    var truncated = false
    /// Some records may be missing, including gaps other than the byte bound, so the missing coverage is not necessarily older edits.
    var partial = false
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

/// The footer's wording: "2 comments in 2 files".
enum ChangesFooterText {
    static func summary(comments: Int, files: Int) -> String {
        "\(comments) comment\(comments == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
    }
}

enum ChangesSendStatus: Equatable, Sendable {
    case idle
    case sending
    /// In a terminal session's mailbox, waiting for its Ready edge and its `inbox` ("Sent · waiting for <title> to be ready").
    case sent(UUID, title: String)
    /// The terminal session read the comments.
    case delivered
    /// The terminal session read the message, which left out (or cut) `notSent` comments to stay within 16 KiB; they stay.
    case deliveredInPart(notSent: Int)
    case failed(String)

    /// A send is under way or waits to be read: Send is off until it ends.
    var holdsSend: Bool {
        switch self {
        case .sending, .sent: true
        case .idle, .delivered, .deliveredInPart, .failed: false
        }
    }

    /// The footer's line under the buttons, nil when it has none.
    var line: String? {
        switch self {
        case let .sent(_, title): "Sent · waiting for \(title) to be ready"
        case .delivered: "Delivered"
        case let .deliveredInPart(count):
            "Delivered · \(count) comment\(count == 1 ? " was" : "s were") not sent: a message holds at most 16 KiB"
        case let .failed(message): message
        case .idle, .sending: nil
        }
    }
}

/// The tab's holder for one session. In memory only: drafts are not kept across a relaunch.
@MainActor @Observable
final class SessionChanges {
    @ObservationIgnored private weak var owner: ChangesState?
    @ObservationIgnored private let sessionID: UUID
    @ObservationIgnored private var codexSourceGeneration: UInt64?
    /// Only the current token may install a file result; old physical reads retain their own owner slot until they return.
    @ObservationIgnored private var fileReadTokens: [String: UUID] = [:]
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
    /// The live terminal run the runtime said takes messages; Send is shown for that run only.
    var messageRun: UUID?
    /// Follows the last terminal send until it was read.
    @ObservationIgnored var deliveryWatch: Task<Void, Never>?
    /// A turn ended while the tab was open: reads again.
    private(set) var revision = 0

    @ObservationIgnored var wasWorking: Bool?
    /// Moves with every branch list, so a diff read for an older list is dropped.
    @ObservationIgnored private(set) var branchGeneration = 0

    init(owner: ChangesState? = nil, sessionID: UUID = UUID()) {
        self.owner = owner
        self.sessionID = sessionID
    }

    func state(_ scope: ChangesScope) -> ChangesScopeState {
        if scope.isEdits, let generation = codexSourceGeneration,
           let owner, generation != owner.codexSourceGeneration { return .idle }
        owner?.touch(.scope(sessionID, scope))
        return states[scope] ?? .idle
    }
    var currentState: ChangesScopeState { state(scope) }

    func setState(_ state: ChangesScopeState, for scope: ChangesScope) {
        let key = ChangesPayloadCache.Key.scope(sessionID, scope)
        if states[scope] == state { owner?.touch(key); return }
        let next = owner?.admit(state, key: key) ?? state
        if case .idle = next {
            if states[scope] != nil { states[scope] = nil }
        } else if states[scope] != next {
            states[scope] = next
        }
    }

    /// Stale Codex turn results are hidden immediately by `state`; release their bytes when this session is read again.
    func prepareCodexRead() {
        let generation = owner?.codexSourceGeneration ?? 0
        guard codexSourceGeneration != generation else { return }
        owner?.remove(.scope(sessionID, .lastTurn))
        owner?.remove(.scope(sessionID, .wholeSession))
        states[.lastTurn] = nil
        states[.wholeSession] = nil
        codexSourceGeneration = generation
    }

    func select(_ id: String?, in scope: ChangesScope) {
        if scope == .branch, let id { owner?.touch(.diff(sessionID, id)) }
        guard selected[scope] != id else { return }
        selected[scope] = id
    }

    func setGitDiff(_ diff: ChangesFileDiff?, for id: String) {
        if diff == nil { fileReadTokens[id] = nil }
        let key = ChangesPayloadCache.Key.diff(sessionID, id)
        if gitDiffs[id] == diff { owner?.touch(key); return }
        let next = owner?.admit(diff, key: key, fileID: id) ?? diff
        guard gitDiffs[id] != next else { return }
        gitDiffs[id] = next
    }

    /// A new branch list: the diffs read for the old one are gone.
    func resetGitDiffs() {
        branchGeneration += 1
        fileReadTokens.removeAll()
        owner?.removeDiffs(for: sessionID)
        if !gitDiffs.isEmpty { gitDiffs = [:] }
    }

    /// Starts at most one current request for a file; a busy result uses the existing explicit Retry path.
    func beginGitDiffRead(for id: String) -> UUID? {
        guard gitDiffs[id] == nil, let owner else { return nil }
        guard let token = owner.reserveFileRead(session: sessionID, file: id) else {
            setGitDiff(.failed("Other files are still being read. Try again."), for: id)
            return nil
        }
        fileReadTokens[id] = token
        setGitDiff(.loading, for: id)
        return token
    }

    func isCurrentFileRead(_ token: UUID, for id: String) -> Bool { fileReadTokens[id] == token }

    func finishGitDiffRead(_ token: UUID, for id: String) {
        guard fileReadTokens[id] == token else { return }
        fileReadTokens[id] = nil
        if gitDiffs[id] == .loading { setGitDiff(nil, for: id) }
    }

    /// An evicted payload is re-read by the mounted task; drafts, selections and send state remain intact.
    fileprivate func evict(_ key: ChangesPayloadCache.Key) {
        switch key {
        case let .scope(_, scope):
            guard states[scope] != nil else { return }
            states[scope] = nil
            if scope == .branch { resetGitDiffs() }
            bumpRevision()
        case let .diff(_, file):
            gitDiffs[file] = nil
            if scope == .branch, selected[.branch] == file { bumpRevision() }
        }
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

    /// Removes the comments with these ids (a read terminal send), leaving any other in the scope.
    func removeComments(_ ids: Set<UUID>, in scope: ChangesScope) {
        drafts[scope]?.removeAll { ids.contains($0.id) }
        if drafts[scope]?.isEmpty == true { drafts[scope] = nil }
    }

    /// Removes the comments a read terminal send carried, each only while it still reads as sent (same line, same text):
    /// one edited since, written since, or left out of the message stays.
    func removeSentComments(_ sent: [ChangeComment], in scope: ChangesScope) {
        let ids = Set(drafts[scope]?.filter { draft in
            sent.contains { $0.id == draft.id && $0.anchor == draft.anchor && $0.text == draft.text }
        }.map(\.id) ?? [])
        removeComments(ids, in: scope)
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
    private struct FileRead {
        var session: UUID
        var file: String
    }
    private static let maximumFileReads = 8
    @ObservationIgnored private var sessions: [UUID: SessionChanges] = [:]
    @ObservationIgnored private var payloads = ChangesPayloadCache()
    @ObservationIgnored private var fileReads: [UUID: FileRead] = [:]
    @ObservationIgnored var reader = ChangesReader.unavailable
    /// Replaces the send path of a test; nil sends through the session's Chat driver.
    @ObservationIgnored var sendOverride: (@MainActor (String, UUID) async throws -> Void)?
    private(set) var codexSourceGeneration: UInt64 = 0

    init() {}

    func session(for id: UUID) -> SessionChanges {
        if let existing = sessions[id] { return existing }
        let made = SessionChanges(owner: self, sessionID: id)
        sessions[id] = made
        return made
    }

    func existing(_ id: UUID) -> SessionChanges? { sessions[id] }

    fileprivate func touch(_ key: ChangesPayloadCache.Key) { payloads.touch(key) }
    fileprivate func remove(_ key: ChangesPayloadCache.Key) { payloads.remove(key) }
    fileprivate func removeDiffs(for id: UUID) { payloads.removeDiffs(id) }

    fileprivate func reserveFileRead(session: UUID, file: String) -> UUID? {
        guard fileReads.count < Self.maximumFileReads else { return nil }
        let token = UUID()
        fileReads[token] = FileRead(session: session, file: file)
        return token
    }

    func finishFileRead(_ token: UUID) { fileReads[token] = nil }

    fileprivate func admit(_ state: ChangesScopeState, key: ChangesPayloadCache.Key) -> ChangesScopeState {
        guard let bytes = ChangesPayloadCache.estimate(state) else { payloads.remove(key); return state }
        if insert(key, bytes: bytes) { return state }
        let reason = bytes > ChangesPayloadCache.maximumRegularBytes
            ? "The changes are too large to keep here."
            : "Other files are still being read. Try again."
        let unavailable = ChangesScopeState.failed(reason)
        if let bytes = ChangesPayloadCache.estimate(unavailable) { _ = insert(key, bytes: bytes, fallback: true) }
        return unavailable
    }

    fileprivate func admit(_ diff: ChangesFileDiff?, key: ChangesPayloadCache.Key, fileID: String) -> ChangesFileDiff? {
        guard let diff, let bytes = ChangesPayloadCache.estimate(diff, id: fileID) else { payloads.remove(key); return diff }
        if insert(key, bytes: bytes) { return diff }
        let unavailable: ChangesFileDiff = bytes > ChangesPayloadCache.maximumRegularBytes
            ? .tooLarge : .failed("Other files are still being read. Try again.")
        if let bytes = ChangesPayloadCache.estimate(unavailable, id: fileID) { _ = insert(key, bytes: bytes, fallback: true) }
        return unavailable
    }

    private func insert(_ key: ChangesPayloadCache.Key, bytes: Int, fallback: Bool = false) -> Bool {
        var pinned: Set<ChangesPayloadCache.Key> = Set(fileReads.compactMap { token, read in
            guard sessions[read.session]?.isCurrentFileRead(token, for: read.file) == true else { return nil }
            return ChangesPayloadCache.Key.scope(read.session, .branch)
        })
        if case let .diff(id, _) = key { pinned.insert(.scope(id, .branch)) }
        guard let victims = payloads.insert(key, bytes: bytes, fallback: fallback, protected: pinned.contains) else { return false }
        for victim in victims { sessions[victim.sessionID]?.evict(victim) }
        return true
    }

    /// Invalidates only Codex turn reads, without walking retained sessions or disturbing drafts and branch state.
    func invalidateCodexReads(to generation: UInt64) { codexSourceGeneration = generation }

    /// The session was deleted: what it read, its open file and its comment drafts go.
    func forget(_ id: UUID) { payloads.removeSession(id); sessions[id] = nil }
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
    var codexScan: @Sendable (Transcript, EditScan.Scope) async -> CodexChangesResult? = { transcript, scope in
        await readCodex(transcript, scope: scope)
    }

    @concurrent
    private static func readCodex(_ transcript: Transcript, scope: EditScan.Scope) async -> CodexChangesResult? {
        guard !Task.isCancelled, let id = UUID(uuidString: transcript.sessionID)?.uuidString.lowercased(),
              let workspace = transcript.workingDirectory,
              let file = CodexRolloutLocator.locate(sessionIDs: [id], home: transcript.configDirectory).files[id] else { return nil }
        let kind: CodexChangesReader.Scope = scope == .lastTurn ? .lastTurn : .wholeSession
        return CodexChangesReader.scan(file: file, workspace: workspace, scope: kind)
    }

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
    var source: TranscriptSourceKey? = nil
}
