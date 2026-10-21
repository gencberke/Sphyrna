import AppKit
import Foundation
import LoomChat
import LoomCore

/// What Put in Draft will do for a session (DESIGN §20 Tiles, D-64): leave the line in an empty Chat composer, or copy it.
enum RemoraDraftPlan: Equatable {
    /// The session's Chat composer, or its saved draft, is empty: the line goes there.
    case place
    /// The composer (or the saved draft) has text: it keeps it, and the line is copied.
    case copyHasDraft
    /// A terminal session has no draft: the line is copied.
    case copyTerminal
}

/// What Put in Draft did.
enum RemoraDraftResult: Equatable {
    case placed
    case copiedHasDraft
    case copiedTerminal
    /// The draft could not be written; the line was copied.
    case copiedNotSaved
}

/// Where a session's draft lives and how to reach it: the live composer when a view made one, else the saved draft file. Plain
/// closures, so the rule is tested without a model. It never sends: nothing here reaches a driver.
struct RemoraDraftTarget {
    var sessionID: UUID
    /// The session shows its Chat composer (a Chat run, or a stopped session the Chat face resumes).
    var opensInChat: Bool
    /// The live composer: whether it holds text or attachments, and the way to set its text. Nil without one.
    var composerHasContent: (() -> Bool)?
    var setComposerText: ((String) -> Void)?
    /// The saved drafts, for a session with no live composer.
    var drafts: ChatDraftStore?
}

/// Put in Draft's rule. Pure over a target.
enum RemoraPutInDraft {
    static func plan(_ target: RemoraDraftTarget) -> RemoraDraftPlan {
        guard target.opensInChat else { return .copyTerminal }
        if let hasContent = target.composerHasContent {
            return hasContent() ? .copyHasDraft : .place
        }
        guard let drafts = target.drafts else { return .copyTerminal }
        // A draft that cannot be read is kept as it is (the store sets it aside); it counts as one.
        let saved: ChatDraft?
        do { saved = try drafts.load(sessionID: target.sessionID) } catch { return .copyHasDraft }
        guard let saved else { return .place }
        return saved.isEmpty ? .place : .copyHasDraft
    }

    /// Does what `plan` says. A line is never sent: it goes to a composer's text or a draft file, or to the pasteboard.
    @discardableResult
    static func perform(_ target: RemoraDraftTarget, line: String, copy: (String) -> Void) -> RemoraDraftResult {
        switch plan(target) {
        case .copyTerminal:
            copy(line)
            return .copiedTerminal
        case .copyHasDraft:
            copy(line)
            return .copiedHasDraft
        case .place:
            if let setComposerText = target.setComposerText, target.composerHasContent != nil {
                setComposerText(line)
                return .placed
            }
            guard let drafts = target.drafts else {
                copy(line)
                return .copiedNotSaved
            }
            do {
                try drafts.save(ChatDraft(text: line), sessionID: target.sessionID)
                return .placed
            } catch {
                copy(line)
                return .copiedNotSaved
            }
        }
    }

    /// The general pasteboard.
    static func copyToPasteboard(_ line: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }
}

extension CatalogModel {
    /// Whether the session shows its Chat composer: a run drives it through the pipe, or it is stopped and the Chat face
    /// resumes it (`DetailRoute`'s own rule, from the record when no row is loaded).
    func remoraSessionOpensInChat(_ record: CatalogSession) -> Bool {
        let id = record.session.id
        if let row = rowModels[id] {
            if let endpoint = runEndpoint(of: row) { return endpoint == .pipe }
            return showsStoppedLiveChat(row)
        }
        if let live = liveStates[id], live.runID != nil { return live.runEndpoint == .pipe }
        let identity = liveStates[id]?.conversationID ?? record.session.providerConversationID
        return facePolicy.showsStructuredFaceWhenStopped(capabilities(of: record.session.provider)) && identity?.isEmpty == false
    }

    func remoraDraftTarget(for record: CatalogSession) -> RemoraDraftTarget {
        let id = record.session.id
        let composer = composer(of: id)
        return RemoraDraftTarget(
            sessionID: id, opensInChat: remoraSessionOpensInChat(record),
            composerHasContent: composer.map { composer in { composer.hasContent || !composer.currentText().allSatisfy(\.isWhitespace) } },
            setComposerText: composer.map { composer in { composer.setText($0) } },
            drafts: chatSessions?.draftStore)
    }

    /// What Put in Draft would do for this session now (the hover popover's first line).
    func remoraDraftPlan(for record: CatalogSession) -> RemoraDraftPlan { RemoraPutInDraft.plan(remoraDraftTarget(for: record)) }

    /// Put in Draft: the line goes to the session's empty Chat composer, or is copied. Never sends.
    @discardableResult
    func putRemoraLineInDraft(_ line: String, record: CatalogSession,
                              copy: (String) -> Void = RemoraPutInDraft.copyToPasteboard) -> RemoraDraftResult {
        RemoraPutInDraft.perform(remoraDraftTarget(for: record), line: line, copy: copy)
    }
}
