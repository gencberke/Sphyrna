import Foundation
import LoomChat
import LoomCore
import Observation

// The Agents tab of a session with no live run (V23). Loom learned of a live run's subagents from the hooks (the ledger); a
// stopped session has no run, so its list is read from the session's own folder, once each time the tab opens on it (and
// when the session changes). Nothing reads while the tab is closed, and nothing polls.

/// What the tab reads for: the selected session, and the conversation its folder is named after. Nil while the tab is
/// closed or the session runs, which is when nothing reads (`CatalogModel.agentsTrigger`).
struct AgentsTrigger: Equatable, Sendable {
    var session: UUID
    var conversationID: String
}

/// The read, as a seam so a test counts it and the app wires the real one.
struct StoppedAgentsReader: Sendable {
    struct Request: Sendable {
        var conversationID: String
        var configDirectory: URL
        var workingDirectory: String?
    }

    var read: @Sendable (Request) async -> [SubagentRecord]

    /// Locates the session's transcript below the config directory it was given (never another profile's), lists
    /// `<session>/subagents` from its folder, and marks as interrupted the entries whose Agent call has no result in the
    /// transcript. A blocking read on its own task, off the main actor.
    static let live = StoppedAgentsReader { request in
        await Task.detached(priority: .userInitiated) {
            guard let main = ClaudeTranscriptLocator.locate(
                sessionID: request.conversationID, configDirectory: request.configDirectory,
                workingDirectory: request.workingDirectory) else { return [] }
            let folder = URL(fileURLWithPath: main.path).deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
            let entries = SubagentFolderReader.read(folder: folder)
            let unanswered = AgentCallScan.scan(file: main, wanting: Set(entries.compactMap(\.toolUseID))).unanswered
            return entries.map { entry in
                var record = entry.record
                record.wasInterrupted = entry.toolUseID.map(unanswered.contains) ?? false
                return record
            }
        }.value
    }
}

/// The holder on `CatalogModel`: the last list read for each session that was looked at, a few sessions at most.
@MainActor @Observable
final class StoppedAgentsState {
    struct List: Equatable {
        var conversationID: String
        var records: [SubagentRecord]
    }

    static let maximumSessions = 8

    private(set) var lists: [UUID: List] = [:]
    @ObservationIgnored private var order: [UUID] = []
    @ObservationIgnored var reader = StoppedAgentsReader.live

    init() {}

    /// The list read for this conversation of the session; nil before the first read (and for another conversation).
    func records(for session: UUID, conversationID: String?) -> [SubagentRecord]? {
        guard let list = lists[session], list.conversationID == conversationID else { return nil }
        return list.records
    }

    func store(_ records: [SubagentRecord], for session: UUID, conversationID: String) {
        lists[session] = List(conversationID: conversationID, records: records)
        order.removeAll { $0 == session }
        order.append(session)
        while order.count > Self.maximumSessions { lists[order.removeFirst()] = nil }
    }
}

extension CatalogModel {
    /// What the Agents tab reads for now, or nil while it is closed, the session runs, or there is nothing to read from.
    var agentsTrigger: AgentsTrigger? {
        guard let row = selectedRow, inspector.isOpen(for: row.id), shownInspectorTab == .agents,
              row.record.session.provider == .claude, claudeConfigDirectory != nil, row.live?.runID == nil, !isRunning(row),
              let conversation = row.live?.conversationID ?? row.record.session.providerConversationID,
              !conversation.isEmpty else { return nil }
        return AgentsTrigger(session: row.id, conversationID: conversation)
    }

    /// Reads the selected stopped session's folder. Does nothing unless the trigger it was started for is still the
    /// current one when it ends: the tab closed, the session changed or started a run meanwhile.
    func runAgentsRead() async {
        guard let trigger = agentsTrigger, let row = selectedRow, let config = claudeConfigDirectory else { return }
        let request = StoppedAgentsReader.Request(
            conversationID: trigger.conversationID, configDirectory: config, workingDirectory: row.record.session.workingDirectory)
        let records = await stoppedAgents.reader.read(request)
        guard agentsTrigger == trigger else { return }
        stoppedAgents.store(records, for: trigger.session, conversationID: trigger.conversationID)
    }

    /// The subagents the Agents tab lists for a session: the live run's (the hooks' ledger), else the folder's list of a
    /// stopped Claude session; nil while that list was not read yet. A session whose folder no read can reach has an empty
    /// list at once, so the tab never waits for a read that does not come.
    func agentRecords(for row: SessionRowModel) -> [SubagentRecord]? {
        if row.live?.runID != nil || isRunning(row) { return row.live?.subagents ?? [] }
        guard agentsFolderIsReadable(row) else { return [] }
        let conversation = row.live?.conversationID ?? row.record.session.providerConversationID
        return stoppedAgents.records(for: row.id, conversationID: conversation)
    }

    /// A session with no run can list its folder: a Claude session whose conversation Loom knows, under the profile the app
    /// reads (none when its layout was refused).
    func agentsFolderIsReadable(_ row: SessionRowModel) -> Bool {
        guard row.record.session.provider == .claude, claudeConfigDirectory != nil else { return false }
        let conversation = row.live?.conversationID ?? row.record.session.providerConversationID
        return conversation?.isEmpty == false
    }
}
