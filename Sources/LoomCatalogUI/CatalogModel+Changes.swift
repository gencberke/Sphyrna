import Foundation
import LoomChat
import LoomCore

/// The Changes tab on the model (V20): what it reads, when, and how its comments go to Claude.
///
/// Nothing reads while the tab is closed and nothing polls. `changesTrigger` is nil unless the selected session's
/// inspector is open on Changes, or on Overview of a session whose edits are read (the Overview lists the last turn's files);
/// the inspector's `.task(id:)` runs `runChangesRead()` when it becomes non-nil and again when the scope changes or a turn
/// ends (`noteChangesWorking`). The turn scopes read the session's transcript on disk (`EditScan`); the branch scope asks git
/// (`GitChanges`) for a file list, and for one file's diff when it is shown.
extension CatalogModel {
    // MARK: When it reads

    private func isChangesTabOpen(on sessionID: UUID) -> Bool {
        selectedSessionID == sessionID && inspector.isOpen(for: sessionID) && inspector.tab == .changes
    }

    /// The Overview is open on the session and lists the last turn's files, which are the Changes tab's own last-turn read
    /// (the same state, so the tab finds them when it opens).
    private func isOverviewReadingEdits(on sessionID: UUID) -> Bool {
        guard selectedSessionID == sessionID, inspector.isOpen(for: sessionID), shownInspectorTab == .overview,
              let provider = changesRow(sessionID)?.record.session.provider else { return false }
        return capabilities(of: provider).readsTranscript
    }

    /// What the tab reads for now, or nil while it is closed. The Overview reads the last turn whatever scope the tab shows.
    var changesTrigger: ChangesTrigger? {
        guard let id = selectedSessionID else { return nil }
        if isChangesTabOpen(on: id) {
            let session = changes.session(for: id)
            return ChangesTrigger(session: id, scope: session.scope, revision: session.revision)
        }
        guard isOverviewReadingEdits(on: id) else { return nil }
        return ChangesTrigger(session: id, scope: .lastTurn, revision: changes.session(for: id).revision)
    }

    /// The tab's count: the files of the current scope, once it was read.
    func changesFileCount(for sessionID: UUID?) -> Int? {
        guard let sessionID, let data = changes.session(for: sessionID).currentState.data, !data.files.isEmpty else { return nil }
        return data.files.count
    }

    /// The session's indicator changed while its Changes tab is mounted (the tab's view calls this). A turn that waits on a
    /// card is still the turn: only a change that leaves both working and waiting is its end.
    func noteChangesIndicator(_ indicator: SessionIndicator, for sessionID: UUID) {
        noteChangesWorking(indicator.keepsATurnGoing, for: sessionID)
    }

    /// A turn ended (or began) in a session whose Changes tab shows: the next read is due. Called with whether a turn is going;
    /// a tab that is closed reads nothing now and reads again when it opens.
    func noteChangesWorking(_ working: Bool, for sessionID: UUID) {
        let session = changes.session(for: sessionID)
        defer { session.wasWorking = working }
        guard session.wasWorking == true, !working, isChangesTabOpen(on: sessionID) || isOverviewReadingEdits(on: sessionID)
        else { return }
        session.bumpRevision()
    }

    func setChangesScope(_ scope: ChangesScope, for sessionID: UUID) {
        let session = changes.session(for: sessionID)
        guard session.scope != scope else { return }
        session.scope = scope
        session.composing = nil
        session.composingText = ""
    }

    /// The changed-files card's "Open in Changes": the inspector opens on the tab with the scope of the card.
    func openChanges(_ scope: ChangesScope, for sessionID: UUID) {
        setChangesScope(scope, for: sessionID)
        selectInspectorTab(.changes)
        setInspector(open: true, for: sessionID)
    }

    private func changesRow(_ sessionID: UUID) -> SessionRowModel? {
        selectedRow?.id == sessionID ? selectedRow : rowModels[sessionID]
    }

    // MARK: Reads

    /// Reads the current scope. Does nothing unless the trigger it was started for is still the current one when it
    /// ends: a tab closed, a scope or a session changed meanwhile.
    func runChangesRead() async {
        guard let trigger = changesTrigger else { return }
        switch trigger.scope {
        case .lastTurn: await readEdits(trigger, scan: .lastTurn)
        case .wholeSession: await readEdits(trigger, scan: .wholeSession)
        case .branch: await readBranch(trigger)
        }
    }

    private func readEdits(_ trigger: ChangesTrigger, scan: EditScan.Scope) async {
        let session = changes.session(for: trigger.session)
        guard let row = changesRow(trigger.session) else { return }
        guard capabilities(of: row.record.session.provider).readsTranscript else {
            session.setState(.off("Claude's file edits are read from Claude sessions"), for: trigger.scope)
            return
        }
        var result = EditScanResult.empty
        let directory = row.record.session.workingDirectory
        if let conversation = row.live?.conversationID ?? row.record.session.providerConversationID, !conversation.isEmpty,
           let config = claudeConfigDirectory {
            if session.state(trigger.scope).data == nil { session.setState(.loading, for: trigger.scope) }
            result = await changes.reader.editScan(
                ChangesReader.Transcript(sessionID: conversation, configDirectory: config, workingDirectory: directory), scan)
            guard changesTrigger == trigger else { return }
        }
        var files: [ChangesFile] = []
        var hunks: [String: [DiffHunk]] = [:]
        for file in result.files {
            let shown = file.hunks
            hunks[file.path] = shown
            files.append(ChangesFile(
                id: file.path, displayPath: EditScan.shorten(file.path, workingDirectory: directory), absolutePath: file.path,
                added: file.added, removed: file.removed,
                isTooLarge: shown.reduce(0) { $0 + $1.lines.count } > LoomTheme.Changes.maxDiffLines))
        }
        session.setState(.ready(ChangesScopeData(files: files, hunks: hunks, truncated: result.truncated)), for: trigger.scope)
        selectFirstFileIfNeeded(session, scope: trigger.scope)
    }

    private func readBranch(_ trigger: ChangesTrigger) async {
        let session = changes.session(for: trigger.session)
        guard let row = changesRow(trigger.session) else { return }
        let directory = row.record.session.workingDirectory
        guard !directory.isEmpty else {
            session.setState(.off("Not a Git repository"), for: .branch)
            return
        }
        if session.state(.branch).data == nil { session.setState(.loading, for: .branch) }
        let state = await changes.reader.gitList(directory)
        guard changesTrigger == trigger else { return }
        switch state {
        case .notARepository: session.setState(.off("Not a Git repository"), for: .branch)
        case .noBaseBranch: session.setState(.off("No base branch found"), for: .branch)
        case .timedOut: session.setState(.timedOut, for: .branch)
        case let .failed(message): session.setState(.failed(message), for: .branch)
        case let .list(list):
            let files = list.files.map { file in
                ChangesFile(id: file.path, displayPath: file.path, absolutePath: list.absolutePath(of: file),
                            added: file.added, removed: file.removed, isBinary: file.isBinary, isTooLarge: file.isTooLarge)
            }
            session.resetGitDiffs()
            session.setState(.ready(ChangesScopeData(files: files, omittedFiles: list.omittedFiles, baseName: list.baseName,
                                                     onBase: list.onBase, list: list)), for: .branch)
            selectFirstFileIfNeeded(session, scope: .branch)
            if let selected = session.selected[.branch] { loadGitDiff(selected, in: trigger.session) }
        }
    }

    /// The open file stays when the new read still has it; otherwise the first of the list, in the order the list shows.
    private func selectFirstFileIfNeeded(_ session: SessionChanges, scope: ChangesScope) {
        guard let data = session.state(scope).data else { return }
        if let current = session.selected[scope], data.files.contains(where: { $0.id == current }) { return }
        session.select(ChangesTree.lines(of: data.files).compactMap(\.file).first?.id, in: scope)
    }

    /// The user opened a file of the list.
    func selectChangesFile(_ fileID: String, in sessionID: UUID) {
        let session = changes.session(for: sessionID)
        session.select(fileID, in: session.scope)
        if session.scope == .branch { loadGitDiff(fileID, in: sessionID) }
    }

    private func loadGitDiff(_ fileID: String, in sessionID: UUID) {
        let session = changes.session(for: sessionID)
        guard isChangesTabOpen(on: sessionID), session.scope == .branch, let list = session.state(.branch).data?.list,
              let file = list.files.first(where: { $0.path == fileID }), session.gitDiffs[fileID] == nil else { return }
        session.setGitDiff(.loading, for: fileID)
        let generation = session.branchGeneration
        let read = changes.reader.gitDiff
        Task { [weak self, weak session] in
            let diff = await read(file, list)
            guard let self, let session, session.branchGeneration == generation, isChangesTabOpen(on: sessionID) else { return }
            switch diff {
            case let .hunks(hunks): session.setGitDiff(.hunks(hunks), for: fileID)
            case .binary: session.setGitDiff(.binary, for: fileID)
            case .tooLarge: session.setGitDiff(.tooLarge, for: fileID)
            case .timedOut: session.setGitDiff(.timedOut, for: fileID)
            case let .failed(message): session.setGitDiff(.failed(message), for: fileID)
            }
        }
    }

    /// "Try again" on a read that timed out or failed: the scope reads again.
    func retryChanges(for sessionID: UUID) {
        let session = changes.session(for: sessionID)
        session.setState(.idle, for: session.scope)
        session.bumpRevision()
    }

    /// "Try again" on one branch file's diff.
    func retryChangesFile(_ fileID: String, in sessionID: UUID) {
        changes.session(for: sessionID).setGitDiff(nil, for: fileID)
        loadGitDiff(fileID, in: sessionID)
    }

    // MARK: Comments

    /// Opens the comment box under a line (with the saved comment of that line, when there is one).
    func beginChangeComment(at anchor: ChangeAnchor, in sessionID: UUID) {
        let session = changes.session(for: sessionID)
        session.composing = anchor
        session.composingText = session.comment(at: anchor, in: session.scope)?.text ?? ""
    }

    func cancelChangeComment(in sessionID: UUID) {
        let session = changes.session(for: sessionID)
        session.composing = nil
        session.composingText = ""
    }

    /// Saves the open box's text on its line; an empty text removes the line's comment.
    func saveChangeComment(in sessionID: UUID) {
        let session = changes.session(for: sessionID)
        guard let anchor = session.composing else { return }
        let text = session.composingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            session.removeComment(at: anchor, in: session.scope)
        } else if let file = session.currentState.data?.files.first(where: { $0.id == anchor.fileID }) {
            session.saveComment(text, at: anchor, displayPath: file.displayPath, in: session.scope)
        }
        session.composing = nil
        session.composingText = ""
    }

    func removeChangeComment(at anchor: ChangeAnchor, in sessionID: UUID) {
        let session = changes.session(for: sessionID)
        session.removeComment(at: anchor, in: session.scope)
        if session.composing == anchor { cancelChangeComment(in: sessionID) }
    }

    func discardChangeComments(in sessionID: UUID) {
        let session = changes.session(for: sessionID)
        session.discardComments(in: session.scope)
        session.sendStatus = .idle
    }

    /// The current scope's comments in the order they read: by file as the list shows them, then by line.
    func orderedChangeComments(for sessionID: UUID) -> [ChangeComment] {
        let session = changes.session(for: sessionID)
        let order = ChangesTree.lines(of: session.currentState.data?.files ?? []).compactMap(\.file).map(\.id)
        func rank(_ comment: ChangeComment) -> Int { order.firstIndex(of: comment.anchor.fileID) ?? order.count }
        let indexed = session.comments(in: session.scope).enumerated()
        return indexed.sorted { a, b in
            let (left, right) = (rank(a.element), rank(b.element))
            if left != right { return left < right }
            let (lineA, lineB) = (a.element.anchor.line ?? Int.max, b.element.anchor.line ?? Int.max)
            return lineA != lineB ? lineA < lineB : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Sending

    enum ChangesSendAvailability: Equatable {
        case ready
        /// The session is not in the Chat face, so there is no message to send to.
        case notChat
    }

    /// Comments go to Claude as a message in the session's Chat: a live Chat session, or a stopped one that the Chat
    /// face owns (the send resumes it, as the stopped composer does). A terminal-face session shows the diffs only.
    func changesSendAvailability(for sessionID: UUID) -> ChangesSendAvailability {
        guard let row = changesRow(sessionID), capabilities(of: row.record.session.provider).structuredFace else { return .notChat }
        return liveChatDriver(for: sessionID) != nil || showsStoppedLiveChat(row) ? .ready : .notChat
    }

    /// The scope as the message names it: "Last turn", "Whole session", "Branch vs main".
    func changesScopeName(for sessionID: UUID) -> String {
        let session = changes.session(for: sessionID)
        guard session.scope == .branch, let base = session.state(.branch).data?.baseName else { return session.scope.title }
        return "Branch vs \(base)"
    }

    /// Sends the current scope's comments as one message, the way the composer's Return does (`.next`). Comments clear
    /// once the send was accepted; a refused send keeps them.
    func sendChangeComments(for sessionID: UUID) async {
        let session = changes.session(for: sessionID)
        let comments = orderedChangeComments(for: sessionID)
        guard !comments.isEmpty, session.sendStatus != .sending, changesSendAvailability(for: sessionID) == .ready else { return }
        let scope = session.scope
        let text = ChangesMessage.text(scopeName: changesScopeName(for: sessionID), comments: comments)
        session.sendStatus = .sending
        do {
            if let send = changes.sendOverride {
                try await send(text, sessionID)
            } else {
                _ = try await sendChatMessage(text, to: sessionID)
            }
            session.discardComments(in: scope)
            session.sendStatus = .idle
        } catch {
            session.sendStatus = .failed(Self.userMessage(for: error, context: "The comments could not be sent"))
        }
    }
}

/// The file list as a tree: folders first, single-child folders merged, as the changed-files card draws it.
enum ChangesTree {
    struct Line: Equatable {
        var depth: Int
        var name: String
        var isFolder: Bool
        var added: Int
        var removed: Int
        var file: ChangesFile?
    }

    static func lines(of files: [ChangesFile]) -> [Line] {
        var byPath: [String: ChangesFile] = [:]
        for file in files where byPath[file.displayPath] == nil { byPath[file.displayPath] = file }
        let tree = ChatWork.tree(of: files.map { ChangedFile(path: $0.displayPath, added: $0.added, removed: $0.removed) })
        return tree.map { line in
            Line(depth: line.depth, name: line.name, isFolder: line.isFolder, added: line.added, removed: line.removed,
                 file: line.path.flatMap { byPath[$0] })
        }
    }
}
