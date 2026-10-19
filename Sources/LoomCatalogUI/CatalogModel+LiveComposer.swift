import Foundation
import LoomChat
import LoomCore

/// The session's composer (V17) on the model: made by the first live view of a Chat session and kept by the host for as
/// long as it keeps the driver, so the text, attachments, history and menus outlive the view.
extension CatalogModel {
    func liveChatComposer(for driver: ChatSessionDriver, row: SessionRowModel, feed: LiveChatFeed) -> ChatComposerModel? {
        guard let host = chatSessions else { return nil }
        let id = row.id
        let drafts = host.draftStore
        let composer = host.attachment(for: driver) {
            ChatComposerModel(driver: driver, card: id, drafts: drafts, environment: composerEnvironment(feed: feed))
        }
        // The composer outlives a feed the host let go of, and its environment holds the feed it was made with weakly: every
        // view binds it to the feed it shows now (else the folder, history and the handover notice
        // would answer nothing after the feed was released), and the feed's pinned cards take the composer's text and keys.
        composer.environment = composerEnvironment(feed: feed)
        composer.attach(cards: feed.cards)
        return composer
    }

    /// What the composer asks of the app: the session's folder, its earlier messages, the other sessions and the context
    /// figure the usage index holds.
    private func composerEnvironment(feed: LiveChatFeed) -> ComposerEnvironment {
        var environment = ComposerEnvironment()
        environment.workingDirectory = { [weak feed] in feed?.workingDirectory }
        environment.historyTexts = { [weak feed] in feed?.userMessageTexts() ?? [] }
        environment.contextFallback = { [weak self, weak feed] in
            guard let self, let feed,
                  let conversation = (rowModels[feed.card]?.record ?? liveRecords[feed.card])?.session.providerConversationID
            else { return nil }
            return usage?.contexts[conversation]
        }
        environment.sessionCandidates = { [weak self, weak feed] in
            guard let self, let feed else { return [] }
            return paletteSessions().filter { $0.provider == .claude && $0.id != feed.card }.map {
                ComposerSessionCandidate(id: $0.id, title: $0.title, project: $0.project, lastActivity: $0.lastActivityAt)
            }
        }
        environment.sessionMention = { [weak self] id in self?.sessionMentionText(for: id) }
        environment.cycleView = { [weak feed] in feed?.presentation.cycleViewMode() }
        environment.handoverNotice = { [weak self, weak feed] in
            guard let self, let feed else { return nil }
            return composerHandoverNotice(of: feed.card)
        }
        return environment
    }

    /// The text that mentions another session: its title, the transcript's path and the first line of its last answer. The
    /// read is bounded (`ProjectLastLine`); a session without a transcript is mentioned by its title alone.
    func sessionMentionText(for id: UUID) -> String? {
        guard let record = rowModels[id]?.record ?? liveRecords[id] else { return nil }
        let title = record.displayTitle(projectName: projectName(for: record))
        var parts = ["Another session, \"\(title)\""]
        if let conversation = record.session.providerConversationID, let directory = claudeConfigDirectory {
            if let file = ClaudeTranscriptLocator.locate(sessionID: conversation, configDirectory: directory,
                                                         workingDirectory: record.session.workingDirectory) {
                parts.append("transcript \(file.path)")
            }
            if let answer = ProjectLastLine.read(sessionID: conversation, configDirectory: directory,
                                                 workingDirectory: record.session.workingDirectory) {
                parts.append("its last answer began: \(answer)")
            }
        }
        return "[" + parts.joined(separator: " \u{00B7} ") + "]"
    }

    /// Writes every composer's draft now (Quit).
    public func flushChatComposers() {
        for composer in chatSessions?.kept(ofType: ChatComposerModel.self) ?? [] { composer.flushDraft() }
    }
}

// MARK: Evidence

extension CatalogModel {
    /// The session's composer, when a live view made one.
    func composer(of sessionID: UUID) -> ChatComposerModel? {
        guard let driver = chatSessions?.existingDriver(for: sessionID) else { return nil }
        return chatSessions?.existingAttachment(for: driver)
    }

    /// Drives the composer as the user does and reports what it holds (kinds and counts; the evidence driver decides whether
    /// titles may be written). `command`: `focus`, `type` (the text goes in through the text view, `\n` is a new line),
    /// `clear`, `mode|model|effort` (a chip's choice), `ring` (`on|off`: the popover), `popover` (`mode|model|effort|off`: a picker's popover), `attach` (a file path), `paste` (a text of that many KB, as a paste), `state`.
    public func composerEvidence(session: UUID, command: String, argument: String) async -> [String: Any] {
        guard let composer = composer(of: session) else { return ["composer": false] }
        var applied: Bool?
        switch command {
        case "focus": composer.editor?.focus()
        case "type": composer.typeForEvidence(argument.replacingOccurrences(of: "\\n", with: "\n"))
        case "clear": composer.clearComposer()
        case "attach": composer.attach(fileURLs: [URL(fileURLWithPath: argument)])
        case "mode", "model", "effort":
            let task = command == "mode" ? composer.setMode(argument)
                : command == "model" ? composer.setModel(argument) : composer.setEffort(argument)
            let finished = ComposerFlag()
            Task { await task.value; finished.raise() }
            try? await Task.sleep(for: .milliseconds(1500))
            applied = finished.isRaised
        case "folder":
            // Evidence: the session's files are those of this folder (a session without a project works in the home
            // folder, which is not scanned).
            composer.environment.workingDirectory = { argument }
        case "ring": composer.ringPopoverOpen = argument != "off"
        case "popover":
            // The bar's pickers (D-63): `mode`, `model` or `effort` opens that popover and closes the others; `off` closes all.
            composer.ringPopoverOpen = false
            composer.modePopoverOpen = argument == "mode"
            composer.modelPopoverOpen = argument == "model"
            composer.effortPopoverOpen = argument == "effort"
        case "paste": composer.addPastedText(String(repeating: "pasted line of text\n", count: max(1, (Int(argument) ?? 1) * 52)))
        default: break
        }
        // The work started above (an image is prepared off the main thread) settles.
        try? await Task.sleep(for: .milliseconds(command == "attach" ? 800 : 200))
        var summary = composer.summary
        summary["composer"] = true
        if let applied { summary["changeFinished"] = applied }
        summary["menuTitles"] = composer.menu?.items.prefix(12).map(\.title) ?? []
        summary["editorAttached"] = composer.editor != nil
        return summary
    }
}

/// Whether a change a chip made has finished (evidence).
final class ComposerFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.lock(); raised = true; lock.unlock() }
    var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
}
