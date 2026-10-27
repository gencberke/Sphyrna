import Foundation
import LoomCore
import Observation
import SwiftUI

/// Peek: what a session last did, in the tooltip of its sidebar row. The pointer must rest on the row (`SidebarPeekHover`), then
/// one bounded read of the end of the session's transcript runs off the main actor (`ProjectLastLine.readPeek`); the result is
/// kept per session and read again only when the session's last activity has changed since.
@MainActor @Observable
final class SidebarPeekStore {

    /// What a hover stays still for before anything is read, so a pointer that crosses rows (or a list that scrolls under it)
    /// reads nothing.
    static let restDelay = Duration.milliseconds(400)
    /// How many sessions are kept; the oldest read goes first.
    static let limit = 64

    struct Entry: Equatable {
        /// The session's `lastActivityAt` when it was read.
        var activity: Date
        var peek: ProjectLastLine.Peek
    }

    private(set) var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var order: [UUID] = []
    /// Reads that ran (tests).
    @ObservationIgnored private(set) var reads = 0

    /// The tooltip for a session: "You: <ask>" and, on the next line, "Claude: <answer>"; nil while nothing is known.
    func tooltip(for id: UUID) -> String? {
        entries[id].flatMap { Self.tooltip(for: $0.peek) }
    }

    static func tooltip(for peek: ProjectLastLine.Peek) -> String? {
        var lines: [String] = []
        if let ask = peek.ask { lines.append("You: " + ask) }
        if let answer = peek.answer { lines.append("Claude: " + answer) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Reads the session's peek unless the one kept is of its current activity. Cancelled with its caller (the pointer left).
    func load(_ record: CatalogSession, model: CatalogModel) async {
        let id = record.session.id
        guard let target = model.peekTarget(for: record), !Task.isCancelled,
              entries[id]?.activity != record.lastActivityAt else { return }
        reads += 1
        let activity = record.lastActivityAt
        let peek = await Self.read(target)
        guard !Task.isCancelled, let peek else { return }
        entries[id] = Entry(activity: activity, peek: peek)
        order.removeAll { $0 == id }
        order.append(id)
        if order.count > Self.limit { entries[order.removeFirst()] = nil }
    }

    @concurrent
    private static func read(_ target: CatalogModel.PeekTarget) async -> ProjectLastLine.Peek? {
        guard !Task.isCancelled else { return nil }
        return ProjectLastLine.readPeek(
            sessionID: target.conversation, configDirectory: target.configDirectory, workingDirectory: target.workingDirectory)
    }
}

extension CatalogModel {
    struct PeekTarget: Sendable {
        var conversation: String
        var configDirectory: URL
        var workingDirectory: String
    }

    /// Where a row's peek is read from: a session whose harness reads a transcript, with its conversation id, and the profile
    /// to look in. Nil for any other (a Codex session, one that never ran), whose row keeps its tooltip as it is.
    func peekTarget(for record: CatalogSession) -> PeekTarget? {
        guard capabilities(of: record.session.provider).readsTranscript,
              let conversation = record.session.providerConversationID, !conversation.isEmpty,
              let directory = claudeConfigDirectory else { return nil }
        return PeekTarget(conversation: conversation, configDirectory: directory, workingDirectory: record.session.workingDirectory)
    }
}

/// Gives a row the peek as its tooltip. The hover is state of this modifier alone, so the pointer entering or leaving does not
/// redraw the row. A pointer that rests (`SidebarPeekStore.restDelay`) starts the read; one that leaves cancels it. Parts of the
/// row with a tooltip of their own (the time, the reason, the branch) keep it.
struct SidebarPeekHover: ViewModifier {
    let record: CatalogSession
    let model: CatalogModel
    @State private var resting = false

    func body(content: Content) -> some View {
        // The app's one store is held by the model (`CatalogModel.sidebarPeek`), not by a shared instance.
        let store = model.sidebarPeek
        let canPeek = model.peekTarget(for: record) != nil
        content
            .help(canPeek ? store.tooltip(for: record.session.id) ?? "" : "")
            .onHover { resting = $0 && canPeek }
            .task(id: resting) {
                guard resting else { return }
                try? await Task.sleep(for: SidebarPeekStore.restDelay)
                guard !Task.isCancelled else { return }
                await store.load(record, model: model)
            }
    }
}
