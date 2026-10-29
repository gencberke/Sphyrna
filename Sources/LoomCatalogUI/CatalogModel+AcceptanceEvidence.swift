import Foundation
import LoomCore

/// Inert seams for the development flavor's acceptance commands (DEVELOPMENT §5: `draft-choice`, `changes-scope`,
/// `changes-comment`, `changes-send`, `changes-state`). Nothing in the app calls them; each one makes the same model call a
/// click on the draft's chips or in the Changes tab makes, and the report holds ids, counts and state words only.
extension CatalogModel {
    /// The draft's model chip (a catalogue entry of any harness, so it can switch the draft's harness), its effort and its mode
    /// segment, as a click on each sets them. `nil` leaves that choice alone. Returns the choices the draft now resolves.
    @discardableResult
    public func setDraftChoicesForEvidence(harness: HarnessID, model: String?, effort: String?, mode: String?,
                                           projectID: UUID?) -> HarnessLaunchChoices {
        if let model {
            if let entry = modelCatalog.validationModels(for: harness).first(where: { $0.id == model }) {
                setDraftModel(entry, projectID: projectID)
            } else {
                setDraftModel(.value(model), projectID: projectID)
            }
        }
        if let effort { setDraftEffort(.value(effort), projectID: projectID) }
        if let mode { setDraftMode(.value(mode), projectID: projectID) }
        return draftStartChoices(projectID: projectID)
    }

    /// The Changes tab's scope menu.
    @discardableResult
    public func setChangesScopeForEvidence(_ raw: String, for sessionID: UUID) -> Bool {
        guard let scope = ChangesScope(rawValue: raw) else { return false }
        setChangesScope(scope, for: sessionID)
        return true
    }

    /// A click on the `fileIndex`-th file of the current scope (in list order), then on the first line of its diff that takes a
    /// comment, typing `text` and Save. False when the scope has no such file or the file's diff has no commentable line yet
    /// (a branch file's diff is read when it is shown: call again once it arrived).
    public func addChangeCommentForEvidence(fileIndex: Int, text: String, in sessionID: UUID) -> Bool {
        let session = changes.session(for: sessionID)
        guard let data = session.currentState.data else { return false }
        let files = ChangesTree.lines(of: data.files).compactMap(\.file)
        guard files.indices.contains(fileIndex) else { return false }
        let file = files[fileIndex]
        if session.selected[session.scope] != file.id { selectChangesFile(file.id, in: sessionID) }
        var hunks = data.hunks[file.id]
        if session.scope == .branch, case let .hunks(read)? = session.gitDiffs[file.id] { hunks = read }
        guard let hunks,let anchor = ChangesDiffLayout.items(of: hunks, fileID: file.id).compactMap(\.anchor).first
        else { return false }
        beginChangeComment(at: anchor, in: sessionID)
        changes.session(for: sessionID).composingText = text
        saveChangeComment(in: sessionID)
        return true
    }

    /// The footer's Send.
    public func sendChangeCommentsForEvidence(_ sessionID: UUID) async { await sendChangeComments(for: sessionID) }

    /// The tab's state for a report: the scope and its read, how many files and comments, which files carry comments (by list
    /// index), the send's state word and whether the footer offers Send. No path, line or comment text.
    public func changesStateForEvidence(_ sessionID: UUID) -> [String: Any] {
        let session = changes.session(for: sessionID)
        let files = ChangesTree.lines(of: session.currentState.data?.files ?? []).compactMap(\.file)
        let comments = session.comments(in: session.scope)
        let read: String = switch session.currentState {
        case .idle: "idle"
        case .loading: "loading"
        case .ready: "ready"
        case .off: "off"
        case .timedOut: "timedOut"
        case .failed: "failed"
        }
        let status: String = switch session.sendStatus {
        case .idle: "idle"
        case .sending: "sending"
        case .sent: "sent"
        case .delivered: "delivered"
        case .failed: "failed"
        }
        var sentID: Any = NSNull()
        if case let .sent(id, _) = session.sendStatus { sentID = id.uuidString }
        let availability: String = switch changesSendAvailability(for: sessionID) {
        case .ready: "chat"
        case .terminal: "terminal"
        case .unavailable: "unavailable"
        }
        return [
            "sessionID": sessionID.uuidString, "scope": session.scope.rawValue, "read": read,
            "fileCount": files.count, "selectedFileIndex": files.firstIndex { $0.id == session.selected[session.scope] } ?? -1,
            "commentCount": comments.count,
            "commentFileIndexes": Array(Set(comments.compactMap { c in files.firstIndex { $0.id == c.anchor.fileID } })).sorted(),
            "commentIDs": comments.map(\.id.uuidString),
            "sendStatus": status, "sentMessageID": sentID, "availability": availability,
            "sendOffered": changesSendTitle(for: sessionID) != nil,
            "messageRun": session.messageRun?.uuidString ?? NSNull(),
        ]
    }
}
