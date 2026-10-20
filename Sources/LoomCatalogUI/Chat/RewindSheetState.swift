import Foundation
import LoomChat
import Observation
import SwiftUI

// What the Rewind files sheet (V21) holds and says. The dry run, the marks and the confirm are `CatalogModel+Rewind.swift`;
// the sheet itself is `RewindSheetView.swift`. Everything here is plain data and wording, so the rules are tested without a
// window.

/// One file of the sheet: its path as the user reads it (relative to the working folder) and its warning, if any.
struct RewindSheetFile: Equatable, Identifiable {
    var path: String
    var displayPath: String
    var mark: RewindFileMark?

    var id: String { path }
}

/// What a dry run found, as the sheet shows it.
struct RewindSheetContent: Equatable {
    var files: [RewindSheetFile]
    var insertions: Int
    var deletions: Int
    /// The message is the newest turn's: nothing but Undo brings this turn's file changes back.
    var newestTurn: Bool
    var copy: ChatRewindStore.CopyVerdict

    init(preview: RewindPreview, marks: [String: RewindFileMark], workingDirectory: String?, newestTurn: Bool) {
        files = preview.files.map {
            RewindSheetFile(path: $0, displayPath: EditScan.shorten($0, workingDirectory: workingDirectory), mark: marks[$0])
        }
        insertions = preview.insertions
        deletions = preview.deletions
        self.newestTurn = newestTurn
        copy = preview.copy
    }

    /// Rewind is on when something would change and Loom can keep its copy: Loom never rewinds without one.
    var canConfirm: Bool { !files.isEmpty && RewindCopy.canKeep(copy) }

    /// "+12 −3" over the whole set (the CLI gives totals, not counts per file).
    var totals: String { "+\(insertions) \u{2212}\(deletions)" }
}

enum RewindCopy {
    static let title = "Rewind files to before this message?"
    static let honestLabel = "Restores the files Claude changed with its file tools to how they were before this message. "
        + "Changes made by shell commands and subagents stay. Loom keeps a copy of these files, so you can undo this."
    static let newestTurnNote = "This turn\u{2019}s file changes can only come back through Undo."
    static let nothingToChange = "No files would change."
    static let tooLarge = "These files are too large to keep a copy for Undo"
    static let cannotCopy = "Loom cannot keep a copy of some of these files, so it does not rewind them"

    static func canKeep(_ verdict: ChatRewindStore.CopyVerdict) -> Bool {
        if case .ok = verdict { true } else { false }
    }

    /// What stands in the sheet when Loom cannot keep the copy; nil when it can.
    static func copyProblem(_ verdict: ChatRewindStore.CopyVerdict) -> String? {
        switch verdict {
        case .ok: nil
        case .tooLarge: tooLarge
        case .cannotCopy: cannotCopy
        }
    }

    /// What a refusal or a failure says, for the sheet and for Undo.
    static func message(for error: ChatRewindError) -> String {
        switch error {
        case let .notAvailable(availability): availability.reason ?? "Rewind is not available now"
        case let .cannot(cannot): cannot.text
        case .nothingToChange: nothingToChange
        case .tooLarge: tooLarge
        case .cannotCopy: cannotCopy
        case .copyFailed: "Loom could not keep a copy of these files, so nothing was rewound"
        case let .failed(text): "Claude could not rewind the files, and nothing changed. \(text)"
        case .noAnswer: "Claude did not answer the rewind, so some files may have changed. Undo on the marker puts back the copy Loom kept."
        case .undoUnavailable: "Undo is no longer available"
        case let .changedSince(files): "These files changed since the rewind: \(files.joined(separator: ", "))"
        case let .undoFailed(text): "Undo did not finish. \(text)"
        }
    }
}

/// The open sheet. Held by the model, like the delete confirmation, so the sheet needs no view state.
@MainActor @Observable
final class RewindSheetState: Identifiable {
    enum Phase: Equatable {
        /// The dry run is being made.
        case loading
        case ready(RewindSheetContent)
        /// The CLI has no checkpoint for the message, or the session is not at its prompt: the text says why.
        case cannot(String)
        /// The rewind was refused or failed: the text says why. Cancel only.
        case failed(String)
        /// The rewind runs.
        case rewinding
    }

    nonisolated let id = UUID()
    /// The message's first words (the marker names it).
    let title: String
    let userMessageID: String
    let driver: ChatSessionDriver
    var phase: Phase = .loading

    init(title: String, userMessageID: String, driver: ChatSessionDriver) {
        self.title = title
        self.userMessageID = userMessageID
        self.driver = driver
    }

    var content: RewindSheetContent? { if case let .ready(content) = phase { content } else { nil } }

    var canConfirm: Bool { content?.canConfirm ?? false }

    /// Cancel works until the rewind runs: a rewind under way is not cut short.
    var canCancel: Bool { phase != .rewinding }
}

/// Undo had files that changed since the rewind: the alert names them and asks before it overwrites.
struct RewindUndoPrompt: Identifiable {
    let id = UUID()
    let rewindID: String
    let driver: ChatSessionDriver
    /// As the user reads them (relative to the working folder).
    let files: [String]
    let directory: String?
}

/// The keys of the sheet: Esc cancels, and Return does nothing (it never confirms a rewind).
enum RewindSheetKeys {
    enum Reaction: Equatable {
        case cancel
        /// The key is taken and nothing happens.
        case swallow
        case ignore
    }

    static func reaction(to key: KeyEquivalent) -> Reaction {
        switch key {
        case .escape: .cancel
        case .return: .swallow
        default: .ignore
        }
    }
}

@MainActor @Observable
final class RewindState {
    var sheet: RewindSheetState?
    var undoPrompt: RewindUndoPrompt?
}
