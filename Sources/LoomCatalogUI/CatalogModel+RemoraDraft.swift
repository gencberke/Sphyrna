import AppKit
import Foundation
import LoomChat
import LoomCore

/// What Draft Brief's landing did (DESIGN §8 Remora's brief): the brief always becomes a draft's text, unsent, and never takes the
/// place of what the user wrote. Home's Put in Draft has its own rule (`RemoraHomeDraft`, D-95).
enum RemoraDraftResult: Equatable {
    /// The draft was empty, or still held Remora's last brief untouched: the brief is its text now.
    case placed
    /// The draft held the user's text: it keeps it, and the brief went into a new draft of the same project, which the page shows.
    case placedInNewDraft
}

/// The general pasteboard, for a line Home's Put in Draft can only copy.
enum RemoraPasteboard {
    static func copy(_ line: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }
}

// MARK: Home's Put in Draft

/// Why Home cannot place a line in a session's composer (D-95): its button reads Copy to Clipboard and says why.
enum RemoraCopyReason: Equatable {
    /// The session runs in the terminal, which has no composer Sphyrna fills.
    case terminal
    /// A Codex session, which Sphyrna cannot open yet.
    case codex
}

/// What Home's Put in Draft will do for a session (DESIGN §20 Tiles, D-95).
enum RemoraHomeDraftPlan: Equatable {
    /// The line goes to the session's composer (or its saved draft), and the session opens.
    case place
    /// The line can only be copied.
    case copy(RemoraCopyReason)
}

/// What Home's Put in Draft did.
enum RemoraHomeDraftResult: Equatable {
    /// The line is in the composer (or the saved draft the composer restores from), unsent, and the session was opened.
    case placed
    /// The session's composer cannot be filled: the line was copied.
    case copied(RemoraCopyReason)
    /// The saved draft could not be read or written: it was left as it is, and the line was copied.
    case copiedNotSaved
}

/// A session as Home's Put in Draft reaches it: its live composer when a view made one, else its saved draft, and the way to open
/// it. Plain closures, so the rule is tested without a model. It never sends: nothing here reaches a driver.
struct RemoraHomeDraftTarget {
    var sessionID: UUID
    /// Nil when Sphyrna fills the session's composer; else why the line is copied.
    var copyReason: RemoraCopyReason?
    /// The live composer's text and the way to set it. Nil without one.
    var composerText: (() -> String)?
    var setComposerText: ((String) -> Void)?
    /// Asks the live composer for the keyboard (a composer that is not on screen yet takes it when it appears).
    var focusComposer: (() -> Void)?
    /// The saved drafts, for a session with no live composer.
    var drafts: ChatDraftStore?
    /// Opens the session the way its sidebar row does.
    var open: () -> Void
}

/// Home's Put in Draft (D-95): the line goes below whatever the composer holds and the session opens with its composer focused;
/// where no composer can be filled, the line is copied. Pure over a target.
enum RemoraHomeDraft {
    static func plan(_ target: RemoraHomeDraftTarget) -> RemoraHomeDraftPlan {
        target.copyReason.map(RemoraHomeDraftPlan.copy) ?? .place
    }

    /// `text` with `line` after it: a blank text gives the line alone, any other gets a blank line and then the line, below the text
    /// as it was. The user's text is never changed or reordered.
    static func appending(_ line: String, to text: String) -> String {
        if text.allSatisfy(\.isWhitespace) { return line }
        if text.hasSuffix("\n\n") { return text + line }
        return text + (text.hasSuffix("\n") ? "\n" : "\n\n") + line
    }

    /// Does what `plan` says. A line is never sent: it goes to a composer's text or a draft file, or to the pasteboard.
    @discardableResult
    static func perform(_ target: RemoraHomeDraftTarget, line: String, copy: (String) -> Void) -> RemoraHomeDraftResult {
        if let reason = target.copyReason {
            copy(line)
            return .copied(reason)
        }
        if let composerText = target.composerText, let setComposerText = target.setComposerText {
            setComposerText(appending(line, to: composerText()))
        } else {
            guard let drafts = target.drafts else {
                copy(line)
                return .copiedNotSaved
            }
            do {
                // A draft that cannot be read is set aside by the store and left alone here.
                var draft = try drafts.load(sessionID: target.sessionID) ?? ChatDraft()
                draft.text = appending(line, to: draft.text)
                draft.updatedAt = Date()
                try drafts.save(draft, sessionID: target.sessionID)
            } catch {
                copy(line)
                return .copiedNotSaved
            }
        }
        target.open()
        target.focusComposer?()
        return .placed
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

    /// Home's Put in Draft target: the live composer, else the saved drafts; opening selects the session as its sidebar row does.
    func remoraHomeDraftTarget(for record: CatalogSession) -> RemoraHomeDraftTarget {
        let id = record.session.id
        let composer = composer(of: id)
        return RemoraHomeDraftTarget(
            sessionID: id, copyReason: remoraCopyReason(for: record),
            composerText: composer.map { composer in { composer.currentText() } },
            setComposerText: composer.map { composer in { composer.setText($0) } },
            focusComposer: composer.map { composer in { composer.focusComposer() } },
            drafts: chatSessions?.draftStore,
            open: { [weak self] in self?.select(id) })
    }

    /// Why Home's Put in Draft can only copy the line for this session; nil when its composer is filled.
    func remoraCopyReason(for record: CatalogSession) -> RemoraCopyReason? {
        guard !remoraSessionOpensInChat(record) else { return nil }
        return record.session.provider == .codex ? .codex : .terminal
    }

    /// What Home's Put in Draft would do for this session now (its label and the hover popover's first line). Reads no file.
    func remoraHomeDraftPlan(for record: CatalogSession) -> RemoraHomeDraftPlan {
        remoraCopyReason(for: record).map(RemoraHomeDraftPlan.copy) ?? .place
    }

    /// Home's Put in Draft: the line goes to the session's composer and the session opens, or the line is copied. Never sends.
    @discardableResult
    func putRemoraLineInDraft(_ line: String, record: CatalogSession,
                              copy: (String) -> Void = RemoraPasteboard.copy) -> RemoraHomeDraftResult {
        RemoraHomeDraft.perform(remoraHomeDraftTarget(for: record), line: line, copy: copy)
    }
}
