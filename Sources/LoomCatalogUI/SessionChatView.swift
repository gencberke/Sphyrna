import Foundation
import LoomChat
import LoomCore
import SwiftUI

/// When the chat view of a session must be made again (V13 route). The view reads a transcript that may not exist yet:
/// a terminal session has none until its first prompt, and the view keeps what it found for as long as it lives. While it
/// shows its fallback, a new run or a change of the session's status is the moment a transcript may have appeared, so the
/// key moves on and the view looks again. Once the transcript shows, nothing re-keys: a running view follows its file
/// by itself, and scrolling and folds stay where they are.
struct ChatRouteKey: Equatable {
    private(set) var epoch = 0
    private var runID: UUID?
    private var indicator: SessionIndicator?

    /// Takes the session's run and status as they are now. Returns whether the key moved.
    @discardableResult
    mutating func update(runID: UUID?, indicator: SessionIndicator, onFallback: Bool) -> Bool {
        defer {
            self.runID = runID
            self.indicator = indicator
        }
        guard onFallback, self.indicator != nil, runID != self.runID || indicator != self.indicator else { return false }
        epoch += 1
        return true
    }
}

extension CatalogModel {
    /// Sets the one Claude config directory the app reads transcripts from (the profile layout's, known at launch):
    /// the Chat view looks below it, and so does the palette's session text search. Both follow it at once.
    public func setClaudeConfigDirectory(_ directory: URL?) {
        guard directory != claudeConfigDirectory else { return }
        claudeConfigDirectory = directory
        palette.transcriptsDirectory = directory?.appendingPathComponent("projects", isDirectory: true)
    }

    /// A subagent card in the chat was clicked: the inspector opens on Agents, on that subagent when the tab's list has it:
    /// the live state's, or a stopped session's folder list once it was read (the card knows only the id of its Agent call
    /// until the stream's `task_started` names the agent, and `agent_id` = `task_id` is the join).
    func openAgents(for agentID: String?, in sessionID: UUID) {
        if let agentID, listedSubagent(agentID, in: sessionID) != nil {
            openSubagent(agentID, in: sessionID)
            return
        }
        selectInspectorTab(.agents)
        setInspectorOpen(true, for: sessionID)
    }
}

/// The read-only Chat view of the selected session: its transcript below the profile's config directory, with today's
/// ended screen or record as the fallback when none resolves (D-54).
struct SessionChatView: View {
    let model: CatalogModel
    let row: SessionRowModel

    @State private var key = ChatRouteKey()
    @State private var onFallback = false

    /// The id Claude gave the session, from the live state first (a new session learns it from its first hook).
    private var claudeSessionID: String? {
        guard model.capabilities(of: row.record.session.provider).readsTranscript else { return nil }
        let id = row.live?.conversationID ?? row.record.session.providerConversationID
        return id?.isEmpty == false ? id : nil
    }

    var body: some View {
        let indicator = row.indicator
        VStack(spacing: 0) {
            // A question the provider asked stays answerable while the chat is shown; Return never approves it.
            RequestList(model: model, row: row, returnApproves: false)
            // A stopped session the Chat face owns has its composer instead: sending resumes it (V19).
            if Self.showsNotRunning(isRunning: model.isRunning(row)), !model.showsStoppedLiveChat(row) {
                EndedScreenNotice(model: model, row: row, showsDetails: false)
            }
            content(indicator: indicator)
        }
        .onChange(of: row.live?.runID, initial: true) { _, _ in noteState(indicator) }
        .onChange(of: indicator) { _, value in noteState(value) }
    }

    /// "This session is not running" belongs only to a session without a run: a Chat-face (pipe) run has no terminal
    /// and is running all the same.
    nonisolated static func showsNotRunning(isRunning: Bool) -> Bool { !isRunning }

    @ViewBuilder
    private func content(indicator: SessionIndicator) -> some View {
        // A Chat-face run: the driver's live model, not the transcript (V16). So is a stopped session the Chat face owns
        // (V19): the driver is stopped, and its composer resumes the session.
        if model.runEndpoint(of: row) == .pipe || model.showsStoppedLiveChat(row),
           let driver = model.liveChatDriverForDisplay(of: row),
           let feed = model.liveChatFeed(for: driver, card: row.id, conversationID: claudeSessionID,
                                         workingDirectory: row.record.session.workingDirectory) {
            LiveChatView(feed: feed, composer: model.liveChatComposer(for: driver, row: row, feed: feed),
                         onOpenSubagent: { [model, sessionID = row.id] agentID, _ in
                model.openAgents(for: agentID, in: sessionID)
            }, onOpenChanges: { [model, sessionID = row.id] newest in
                model.openChanges(newest ? .lastTurn : .wholeSession, for: sessionID)
            }, onContinueInTerminal: model.canContinue(in: .terminal, row: row)
                ? { [model, sessionID = row.id] in model.switchToTerminal(sessionID: sessionID) } : nil,
               continueUnavailableReason: model.continueUnavailableReason(in: .terminal, row: row),
               quickQuestion: model.quick.panel(for: row.id, driver: driver),
               pinned: { maxHeight in PinnedCardsView(cards: feed.cards, maxHeight: maxHeight) })
            .id(ObjectIdentifier(feed))
            .onChange(of: row.record.session.workingDirectory) { _, value in feed.setWorkingDirectory(value) }
        } else {
            // A run that ended shows its transcript; the card a dead process cut off (and the line of a cancelled one) stays above the bottom edge.
            transcript(indicator: indicator)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    EndedRunCards(model: model, sessionID: row.id, conversationID: claudeSessionID,
                                  workingDirectory: row.record.session.workingDirectory)
                }
        }
    }

    @ViewBuilder
    private func transcript(indicator: SessionIndicator) -> some View {
        // Read here, so the view follows the folder: a row shown before it is known switches once it is.
        if let id = claudeSessionID, let directory = model.claudeConfigDirectory {
            ChatTranscriptView(
                sessionID: id, configDirectory: directory, workingDirectory: row.record.session.workingDirectory,
                isWorking: indicator == .working,
                onOpenSubagent: { [model, sessionID = row.id] agentID, _ in model.openAgents(for: agentID, in: sessionID) },
                onOpenChanges: { [model, sessionID = row.id] newest in
                    model.openChanges(newest ? .lastTurn : .wholeSession, for: sessionID)
                },
                fallback: { fallback })
                .id(ChatViewIdentity(session: row.id, claudeID: id, epoch: key.epoch, directory: directory))
        } else {
            fallback
        }
    }

    private var fallback: some View {
        ChatFallback(model: model, row: row)
            .onAppear { onFallback = true }
            .onDisappear { onFallback = false }
    }

    private func noteState(_ indicator: SessionIndicator) {
        key.update(runID: row.live?.runID, indicator: indicator, onFallback: onFallback)
    }
}

private struct ChatViewIdentity: Hashable {
    let session: UUID
    let claudeID: String
    let epoch: Int
    let directory: URL
}

/// What the chat draws when no transcript resolves: the kept last screen of the run that ended, else the session's
/// record (the same panels the Terminal face shows for a session that is not running).
private struct ChatFallback: View {
    let model: CatalogModel
    let row: SessionRowModel

    var body: some View {
        if let screen = model.endedScreen(for: row.id) {
            EndedScreenView(snapshot: screen, fontSize: model.terminalFontSize)
        } else {
            ConversationDetail(model: model, row: row, inChat: true)
        }
    }
}
