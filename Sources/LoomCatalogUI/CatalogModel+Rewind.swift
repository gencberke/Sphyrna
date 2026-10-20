import Foundation
import LoomChat
import LoomCore

/// Rewind files (V21) on the model: the sheet's dry run with the "changed outside Claude" marks, the confirm, and the Undo on
/// the rewind's marker. The driver owns the rule (a live session at its prompt), the copy and the CLI call; this file reads
/// Claude's own edits for the marks and turns the driver's answers into the sheet and its messages.
extension CatalogModel {
    // MARK: The sheet

    /// "Rewind files to before this message" on a user row: opens the sheet and runs the dry run. `rowID` is the row of the
    /// stream's joined model (the history's records and the live run's messages alike).
    func requestRewind(driver: ChatSessionDriver, card: UUID, feed: LiveChatFeed?, rowID: String) {
        guard rewinds.sheet == nil, let feed,
              let entry = feed.presentation.model.entries.first(where: { $0.id == rowID }),
              ChatRewindAction.offers(entry), case let .user(prompt) = entry.body else { return }
        let newest = RewindMessagePlace.isNewestPrompt(rowID, in: feed.presentation.model.entries)
        let directory = feed.workingDirectory
        let sheet = RewindSheetState(title: RewindMarker.title(from: prompt.text), userMessageID: rowID, driver: driver)
        rewinds.sheet = sheet
        Task { [weak self, weak sheet] in
            let uuid = await driver.messageUUID(ofRow: rowID)
            let phase: RewindSheetState.Phase
            do {
                let preview = try await driver.rewindPreview(userMessageID: uuid)
                let scan = await self?.rewindEditScan(card: card) ?? .empty
                let marks = await Self.rewindMarks(for: preview.files, scan: scan)
                phase = .ready(RewindSheetContent(preview: preview, marks: marks, workingDirectory: directory, newestTurn: newest))
            } catch let error as ChatRewindError {
                phase = .cannot(RewindCopy.message(for: error))
            } catch {
                phase = .cannot("Loom could not check what a rewind would change")
            }
            guard let sheet, self?.rewinds.sheet === sheet else { return }
            sheet.phase = phase
        }
    }

    func cancelRewind() {
        guard let sheet = rewinds.sheet, sheet.canCancel else { return }
        rewinds.sheet = nil
    }

    /// The sheet's "Rewind files". The driver checks the rule again and keeps its copy before the CLI is called.
    func confirmRewind() async {
        guard let sheet = rewinds.sheet, sheet.canConfirm else { return }
        sheet.phase = .rewinding
        let driver = sheet.driver
        let uuid = await driver.messageUUID(ofRow: sheet.userMessageID)
        do {
            try await driver.rewindFiles(userMessageID: uuid, messageTitle: sheet.title)
            if rewinds.sheet === sheet { rewinds.sheet = nil }
        } catch let error as ChatRewindError {
            sheet.phase = .failed(RewindCopy.message(for: error))
        } catch {
            sheet.phase = .failed("The files were not rewound")
        }
    }

    // MARK: Marks

    /// Claude's own edits of the whole session, from its transcript (V20's scan); empty where the transcript cannot be found.
    private func rewindEditScan(card: UUID) async -> EditScanResult {
        guard let row = rowModels[card] ?? selectedRow.flatMap({ $0.id == card ? $0 : nil }),
              let conversation = row.live?.conversationID ?? row.record.session.providerConversationID, !conversation.isEmpty,
              let config = claudeConfigDirectory else { return .empty }
        return await changes.reader.editScan(
            ChangesReader.Transcript(sessionID: conversation, configDirectory: config,
                                     workingDirectory: row.record.session.workingDirectory), .wholeSession)
    }

    /// Reads the files' states off the main actor and compares them with Claude's last edits.
    nonisolated private static func rewindMarks(for files: [String], scan: EditScanResult) async -> [String: RewindFileMark] {
        await Task.detached {
            RewindOutsideChange.marks(files: files, scan: scan) { path in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                    return RewindOutsideChange.FileState(exists: false)
                }
                return RewindOutsideChange.FileState(exists: true, modified: attributes[.modificationDate] as? Date)
            }
        }.value
    }

    // MARK: Undo

    /// Undo on the rewind's marker. Files changed since the rewind are named first and overwritten only when the user says so.
    func undoRewind(driver: ChatSessionDriver, rewindID: String, directory: String?, overwritingChanged: Bool = false) {
        Task { [weak self] in
            do {
                try await driver.undoRewind(rewindID: rewindID, overwritingChanged: overwritingChanged)
            } catch ChatRewindError.changedSince(let files) {
                let shown = files.map { EditScan.shorten($0, workingDirectory: directory) }
                self?.rewinds.undoPrompt = RewindUndoPrompt(rewindID: rewindID, driver: driver, files: shown, directory: directory)
            } catch let error as ChatRewindError {
                self?.reportFailure(RewindCopy.message(for: error))
            } catch {
                self?.reportFailure("Undo did not finish")
            }
        }
    }

    func cancelUndoPrompt() { rewinds.undoPrompt = nil }

    /// The alert's "Overwrite and Undo".
    func confirmUndoOverwrite() {
        guard let prompt = rewinds.undoPrompt else { return }
        rewinds.undoPrompt = nil
        undoRewind(driver: prompt.driver, rewindID: prompt.rewindID, directory: prompt.directory, overwritingChanged: true)
    }
}

enum RewindMessagePlace {
    /// Whether the row is the newest user prompt of the stream: a rewind to it loses the newest turn's file changes for good
    /// (S8 Q4), except through Undo.
    static func isNewestPrompt(_ rowID: String, in entries: [ChatEntry]) -> Bool {
        entries.last(where: ChatRewindAction.offers)?.id == rowID
    }
}
