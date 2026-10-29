import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// What both halves of `ComposerMentionTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ComposerMentionShared {
    @MainActor struct Fixture {
        let rig: LiveRig
        let host: ChatSessionHost
        let driver: ChatSessionDriver
        let composer: ChatComposerModel
        let id: UUID
        var store: ChatDraftStore { host.draftStore }
    }

    /// The sessions the composer may mention, as the catalog would answer.
    @MainActor
    static let login = ComposerMention(id: UUID(), title: "Fix the login bug", provider: .claude)

    @MainActor
    static let docs = ComposerMention(id: UUID(), title: "Write the docs", provider: .claude)
}

/// `ComposerMentionTests`'s fixtures, for both halves of the suite.
@MainActor protocol ComposerMentionFixtures {}

extension ComposerMentionFixtures {
    typealias Fixture = ComposerMentionShared.Fixture

    func make(started: Bool = false, id: UUID = UUID(), rig existing: LiveRig? = nil,
                      mentions: [ComposerMention] = [ComposerMentionShared.login, ComposerMentionShared.docs], texts: [UUID: String]? = nil) async throws -> Fixture {
        let rig = if let existing { existing } else { try await LiveRig.make() }
        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root, driverForgotten: { _ in })
        let driver = started ? try await host.startNewSession(projectID: nil, sessionID: id, draft: nil) : host.driver(for: id)
        var environment = ComposerEnvironment()
        environment.draftDelay = .milliseconds(40)
        environment.mentionDebounce = .milliseconds(10)
        let known = Dictionary(uniqueKeysWithValues: mentions.map { ($0.id, $0) })
        environment.mentionTarget = { known[$0] }
        let texts = texts ?? Dictionary(uniqueKeysWithValues: mentions.map { ($0.id, "[Another session, \"\($0.title)\"]") })
        environment.sessionMention = { texts[$0] }
        environment.sessionCandidates = {
            mentions.map { ComposerSessionCandidate(id: $0.id, title: $0.title, project: "Web", lastActivity: Date()) }
        }
        let composer = ChatComposerModel(driver: driver, card: id, drafts: host.draftStore, environment: environment)
        composer.start()
        await composer.refresh()
        await composer.attachmentsRestored()
        return Fixture(rig: rig, host: host, driver: driver, composer: composer, id: id)
    }

    func waitUntil(_ seconds: Double = 12, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// A real text view of the composer, never shown: its drop handling is called as a drag would call it. The view holds its
    /// coordinator weakly, so the caller keeps the coordinator.
    func textView(for composer: ChatComposerModel) -> (view: ComposerTextEditor.ComposerTextView, keep: AnyObject) {
        let editor = ComposerTextEditor(host: composer, height: .constant(60), minimumHeight: 60, maximumHeight: 220)
        let coordinator = editor.makeCoordinator()
        let view = ComposerTextEditor.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.coordinator = coordinator
        view.delegate = coordinator
        coordinator.textView = view
        composer.editorAttached(view)
        return (view, coordinator)
    }

    func pasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("loom-mention-test-\(UUID())")) }

    func working(_ fixture: Fixture) async -> Bool {
        await waitUntil { await fixture.composer.refresh(); return fixture.composer.state.turnRunning }
    }
}
