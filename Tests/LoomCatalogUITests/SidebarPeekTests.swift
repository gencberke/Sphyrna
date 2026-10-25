import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// Peek: a sidebar row's tooltip tells the session's last ask and the first line of its last answer. The reader works on fixture
/// transcripts in temporary folders, the model's answer for a session without a transcript is asked of the model, and no view
/// or hover is involved.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SidebarPeekTests {
    // MARK: Fixtures

    private struct Fixture {
        let root: URL
        let config: URL
        let folder: String

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-peek-\(UUID())", isDirectory: true)
            config = root.appendingPathComponent("claude-config", isDirectory: true)
            let work = root.appendingPathComponent("app", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            folder = work.path
        }

        func transcript(_ conversation: String, lines: [String]) throws {
            let name = ClaudeTranscriptLocator.folderName(forWorkingDirectory: folder)
            let file = config.appendingPathComponent("projects/\(name)/\(conversation).jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        }

        func peek(_ conversation: String) -> ProjectLastLine.Peek? {
            ProjectLastLine.readPeek(sessionID: conversation, configDirectory: config, workingDirectory: folder)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func json(_ object: Any) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    private static func ask(_ text: String) -> String {
        json(["type": "user", "message": ["role": "user", "content": text]])
    }

    private static func answer(_ text: String, sidechain: Bool = false) -> String {
        json(["type": "assistant", "isSidechain": sidechain,
              "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }

    private static let toolUse = #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
    private static let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
    private static let meta = #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>remember</system-reminder>"}}"#
    private static let commandOutput = #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Compacted</local-command-stdout>"}}"#

    // MARK: The reader

    @Test func theLastAskAndTheAnswerAfterItAreFoundAndWhatIsNotTypedIsSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.transcript("c1", lines: [
            Self.ask("first question"), Self.answer("An older answer."),
            Self.ask("fix the build\nand run the tests"), Self.toolUse, Self.toolResult,
            Self.answer("## Fixed it\nThe build passes."), Self.toolResult, Self.meta, Self.commandOutput,
            Self.answer("a side answer", sidechain: true), Self.toolUse,
        ])
        #expect(fixture.peek("c1") == ProjectLastLine.Peek(ask: "fix the build", answer: "Fixed it"))
    }

    @Test func aTranscriptWithNoAskOrNoAnswerLeavesThatLineOut() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.transcript("ask-only", lines: [Self.ask("hello"), Self.toolUse])
        try fixture.transcript("answer-only", lines: [Self.answer("Hi there."), Self.toolResult, Self.meta])
        try fixture.transcript("neither", lines: [Self.toolResult, Self.meta, Self.commandOutput, Self.toolUse])
        // The last ask has no answer yet: the answer of the turn before is not shown with it.
        try fixture.transcript("working", lines: [Self.ask("one"), Self.answer("Done one."), Self.ask("two"), Self.toolUse])
        #expect(fixture.peek("ask-only") == ProjectLastLine.Peek(ask: "hello", answer: nil))
        #expect(fixture.peek("answer-only") == ProjectLastLine.Peek(ask: nil, answer: "Hi there."))
        #expect(fixture.peek("neither") == ProjectLastLine.Peek())
        #expect(fixture.peek("working") == ProjectLastLine.Peek(ask: "two", answer: nil))
        #expect(fixture.peek("missing") == nil, "no transcript is not a peek")
        #expect(ProjectLastLine.readPeek(sessionID: "ask-only", configDirectory: fixture.config, workingDirectory: "/elsewhere") == nil,
                "only the working directory's own project folder is looked in")
    }

    @Test func theReadStaysInsideItsByteBounds() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let filler = (0..<300).map { _ in Self.answer(String(repeating: "x", count: 900), sidechain: true) }
        // The ask is further back than `maxPages` pages of `pageBytes`: it is not read.
        try fixture.transcript("far", lines: [Self.ask("too far back"), Self.answer("Early.")] + filler + [Self.answer("Late.")])
        let far = fixture.peek("far")
        #expect(filler.joined().utf8.count > ProjectLastLine.pageBytes * ProjectLastLine.maxPages)
        #expect(far == ProjectLastLine.Peek(ask: nil, answer: "Late."))
        // A line over `maxLineBytes` is not read: the answer behind it is the last one that can be.
        let huge = Self.answer(String(repeating: "y", count: ProjectLastLine.maxLineBytes + 1_000))
        try fixture.transcript("huge", lines: [Self.ask("small ask"), Self.answer("Small answer."), huge])
        #expect(fixture.peek("huge") == ProjectLastLine.Peek(ask: "small ask", answer: "Small answer."))
    }

    @Test func eachLineIsCutAtTheLengthOfTheProjectPage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let long = String(repeating: "a", count: 400)
        try fixture.transcript("long", lines: [Self.ask(long), Self.answer(long)])
        let peek = try #require(fixture.peek("long"))
        #expect(peek.ask?.count == ProjectLastLine.maxLength && peek.ask?.hasSuffix("\u{2026}") == true)
        #expect(peek.answer?.count == ProjectLastLine.maxLength && peek.answer?.hasSuffix("\u{2026}") == true)
        // The project page's reader is as it was.
        #expect(ProjectLastLine.read(sessionID: "long", configDirectory: fixture.config, workingDirectory: fixture.folder) == peek.answer)
    }

    // MARK: The tooltip

    @Test func theTooltipIsTheAskAndTheAnswerOnTwoLines() {
        typealias Peek = ProjectLastLine.Peek
        #expect(SidebarPeekStore.tooltip(for: Peek(ask: "fix it", answer: "Fixed.")) == "You: fix it\nClaude: Fixed.")
        #expect(SidebarPeekStore.tooltip(for: Peek(ask: "fix it", answer: nil)) == "You: fix it")
        #expect(SidebarPeekStore.tooltip(for: Peek(ask: nil, answer: "Fixed.")) == "Claude: Fixed.")
        #expect(SidebarPeekStore.tooltip(for: Peek()) == nil)
        let long = String(repeating: "b", count: 500)
        let line = ProjectLastLine.firstLine(of: long)
        #expect(SidebarPeekStore.tooltip(for: Peek(ask: line, answer: nil))?.count == "You: ".count + ProjectLastLine.maxLength)
    }

    // MARK: Which sessions, and when it reads

    private func record(_ provider: ManagedSession.Provider, conversation: String?, folder: String, activity: Date = Date())
        -> CatalogSession {
        CatalogSession(session: ManagedSession(provider: provider, providerConversationID: conversation, workingDirectory: folder),
                       title: "t", createdAt: activity, lastUsedAt: activity, lifecycle: .idle, pinned: false)
    }

    private func model(_ fixture: Fixture) throws -> CatalogModel {
        let model = CatalogModel(
            catalog: try SessionCatalog(url: fixture.root.appendingPathComponent("catalog.sqlite3")), events: SessionEventHub(),
            preferences: UIPreferencesStore(url: fixture.root.appendingPathComponent("ui-preferences.json")))
        model.claudeConfigDirectory = fixture.config
        return model
    }

    @Test func aSessionWithoutATranscriptGetsNoPeek() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.transcript("conv", lines: [Self.ask("hello"), Self.answer("Hi.")])
        let model = try model(fixture)
        defer { model.stop() }
        let claude = record(.claude, conversation: "conv", folder: fixture.folder)
        #expect(model.peekTarget(for: claude) != nil)
        let others = [record(.codex, conversation: "conv", folder: fixture.folder),
                      record(.claude, conversation: nil, folder: fixture.folder),
                      record(.claude, conversation: "", folder: fixture.folder)]
        for other in others { #expect(model.peekTarget(for: other) == nil) }
        model.claudeConfigDirectory = nil
        #expect(model.peekTarget(for: claude) == nil, "no profile to look in")
        model.claudeConfigDirectory = fixture.config

        let store = SidebarPeekStore()
        for other in others { await store.load(other, model: model) }
        #expect(store.reads == 0 && store.entries.isEmpty)
        for other in others { #expect(store.tooltip(for: other.session.id) == nil) }
    }

    @Test func aPeekIsReadOnceUntilTheSessionsActivityChangesAndNeverForAPointerThatLeft() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.transcript("conv", lines: [Self.ask("hello"), Self.answer("Hi.")])
        let model = try model(fixture)
        defer { model.stop() }
        let store = SidebarPeekStore()
        let first = record(.claude, conversation: "conv", folder: fixture.folder, activity: Date(timeIntervalSince1970: 1_000))
        await store.load(first, model: model)
        #expect(store.reads == 1)
        #expect(store.tooltip(for: first.session.id) == "You: hello\nClaude: Hi.")
        await store.load(first, model: model)
        #expect(store.reads == 1, "kept for the same activity")

        // The session did more: the next hover reads again.
        try fixture.transcript("conv", lines: [Self.ask("hello"), Self.answer("Hi."), Self.ask("again"), Self.answer("Again.")])
        let later = CatalogSession(session: first.session, title: "t", createdAt: first.createdAt, lastUsedAt: first.lastUsedAt,
                                   lifecycle: .idle, pinned: false, lastActivityAt: Date(timeIntervalSince1970: 2_000))
        await store.load(later, model: model)
        #expect(store.reads == 2)
        #expect(store.tooltip(for: first.session.id) == "You: again\nClaude: Again.")

        // A pointer that left before the read cancels it.
        let newest = CatalogSession(session: first.session, title: "t", createdAt: first.createdAt, lastUsedAt: first.lastUsedAt,
                                    lifecycle: .idle, pinned: false, lastActivityAt: Date(timeIntervalSince1970: 3_000))
        let hover = Task { await store.load(newest, model: model) }
        hover.cancel()
        await hover.value
        #expect(store.reads == 2)
        #expect(store.entries[first.session.id]?.activity == Date(timeIntervalSince1970: 2_000))
    }
}
