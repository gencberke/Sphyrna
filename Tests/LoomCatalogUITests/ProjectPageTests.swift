import AppKit
import Foundation
import SQLite3
import SwiftUI
import Synchronization
import Testing
@testable import LoomCore
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// An index that answers project lookups from a fixed answer and records what it was asked.
final class ProjectUsageFakeIndex: UsageIndexing, @unchecked Sendable {
    private let state = Mutex<[[String]]>([])
    var answer = ProjectUsage(tokens: UsageTokens(input: 4_000_000, output: 800_000), estimatedCostUSD: 31, messageCount: 90, sessionCount: 2)
    /// The index cannot answer a project lookup.
    var fails = false
    struct Unreadable: Error {}
    var lookups: [[String]] { state.withLock { $0 } }

    func refreshAll() async throws -> UsageScanReport { UsageScanReport() }
    func snapshot(range: UsageRange, now: Date, timeZone: TimeZone) async throws -> UsageSnapshot {
        UsageSnapshotFactory.snapshot(range: range, now: now)
    }
    func projectUsage(sessions: [String], range: UsageRange, now: Date, timeZone: TimeZone) async throws -> ProjectUsage {
        state.withLock { $0.append(sessions) }
        if fails { throw Unreadable() }
        return answer
    }
}

/// V08: the project page. It reads when it opens and not before, every read is bounded, a row's last line
/// is read lazily from the end of its transcript, and a preset fills the draft and starts nothing. Files live
/// in temporary folders that each test removes; no process starts.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ProjectPageTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-project-page-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @MainActor
    final class Intents: NewSessionIntents {
        var starts = 0
        var sends = 0
        func start(provider: ManagedSession.Provider, projectID: UUID?) { starts += 1 }
        func resume(sessionID: UUID) {}
        func stop(sessionID: UUID) {}
        func answer(sessionID: UUID, requestID: String, accept: Bool) {}
        func viewed(sessionID: UUID) {}
        func terminalView(sessionID: UUID) -> NSView? { nil }
        func startSession(projectID: UUID?, launch: NewSessionLaunch, focus: NewSessionFocus,
                          outcome: @escaping @MainActor (NewSessionOutcome) -> Void) { sends += 1 }
    }

    private struct Rig {
        let root: URL
        let model: CatalogModel
        let intents: Intents
        let index: ProjectUsageFakeIndex
        let projectID: UUID
        let folder: URL
        let config: URL
        /// Newest first: recent, lastWeek, old, codex.
        let recent: CatalogSession
        let lastWeek: CatalogSession
        let old: CatalogSession
        let codex: CatalogSession
        let elsewhere: UUID
    }

    private func rig(root: URL) async throws -> Rig {
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let folder = root.appendingPathComponent("app", isDirectory: true)
        let otherFolder = root.appendingPathComponent("other", isDirectory: true)
        for directory in [folder, otherFolder] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let projectID = try await catalog.addProject(path: folder.path).project.id
        let otherID = try await catalog.addProject(path: otherFolder.path).project.id
        let now = Date()
        @discardableResult
        func insert(_ provider: ManagedSession.Provider, _ conversation: String, in project: UUID, _ directory: URL,
                    age: TimeInterval) async throws -> CatalogSession {
            let session = ManagedSession(provider: provider, providerConversationID: conversation, workingDirectory: directory.path)
            let used = now.addingTimeInterval(-age)
            try await catalog.insertSession(session, title: conversation, createdAt: used, lastUsedAt: used, lifecycle: .idle, projectID: project)
            return try #require(try await catalog.session(id: session.id))
        }
        let recent = try await insert(.claude, "conv-recent", in: projectID, folder, age: 3_600)
        let lastWeek = try await insert(.claude, "conv-week", in: projectID, folder, age: 3 * 86_400)
        let old = try await insert(.claude, "conv-old", in: projectID, folder, age: 30 * 86_400)
        let codex = try await insert(.codex, "conv-codex", in: projectID, folder, age: 2 * 3_600)
        let other = try await insert(.claude, "conv-other", in: otherID, otherFolder, age: 60)
        let intents = Intents()
        let model = CatalogModel(
            catalog: catalog, events: SessionEventHub(), preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        model.intents = intents
        let index = ProjectUsageFakeIndex()
        model.usage = UsageModel(index: index, clock: { now }, timeZone: TimeZone(identifier: "UTC")!,
                                 debounce: .milliseconds(20), activationCooldown: .zero)
        let config = root.appendingPathComponent("claude-config", isDirectory: true)
        model.claudeConfigDirectory = config
        await model.start()
        return Rig(root: root, model: model, intents: intents, index: index, projectID: projectID, folder: folder, config: config,
                   recent: recent, lastWeek: lastWeek, old: old, codex: codex, elsewhere: other.session.id)
    }

    private func transcript(_ rig: Rig, _ record: CatalogSession) -> URL {
        let name = ClaudeTranscriptLocator.folderName(forWorkingDirectory: record.session.workingDirectory)
        return rig.config.appendingPathComponent("projects/\(name)/\(record.session.providerConversationID ?? "").jsonl")
    }

    private static func assistant(_ text: String, sidechain: Bool = false) -> String {
        let escaped = String(data: (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data(), encoding: .utf8) ?? "[\"\"]"
        let body = String(escaped.dropFirst().dropLast())
        return #"{"type":"assistant","isSidechain":\#(sidechain),"message":{"role":"assistant","content":[{"type":"text","text":\#(body)}]}}"#
    }

    private static let toolOnly = #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
    private static let user = #"{"type":"user","message":{"role":"user","content":"go"}}"#

    // MARK: Reading only when the page opens

    @Test func nothingIsReadUntilThePageOpensAndEveryPartIsReadOnceWhenItDoes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }

        model.showProjectPage(rig.projectID)
        #expect(model.destination == .projectPage(rig.projectID))
        #expect(model.projectPage.reads == ProjectPageReads() && model.projectPage.records.isEmpty)
        #expect(rig.index.lookups.isEmpty)

        await model.openProjectPage(rig.projectID)
        let reads = model.projectPage.reads
        #expect(reads.sessionPages == 1 && reads.usageLookups == 1 && reads.gitReads == 1 && reads.instructionReads == 1)
        #expect(reads.transcriptTails == 0, "a last line waits for its row to be drawn")
        #expect(rig.index.lookups.count == 1)
    }

    @Test func closingThePageDropsWhatItReadAndLaterAsksReadNothing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        try write(Self.assistant("done"), to: transcript(rig, rig.recent))
        await model.openProjectPage(rig.projectID)
        #expect(!model.projectPage.records.isEmpty)

        model.closeProjectPage()
        #expect(model.projectPage.records.isEmpty && model.projectPage.projectID == nil && model.projectPage.usage == nil)
        await model.loadProjectLastLine(rig.recent)
        #expect(model.projectPage.reads.transcriptTails == 0 && model.projectPage.lastLines.isEmpty)
        model.loadMoreProjectSessions()
        #expect(model.projectPage.reads.sessionPages == 1, "no page is read while the page is closed")
    }

    @Test func aTaskCancelledBeforeItReadsPublishesNothing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        let task = Task { await model.openProjectPage(rig.projectID) }
        task.cancel()
        await task.value
        #expect(model.projectPage.records.isEmpty && model.projectPage.usage == nil)
        #expect(rig.index.lookups.isEmpty)
    }

    @Test func theListHoldsTheProjectsSessionsNewestActivityFirstAndNoOtherProjects() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await model.openProjectPage(rig.projectID)
        let ids = model.projectPage.records.map(\.session.id)
        #expect(ids == [rig.recent, rig.codex, rig.lastWeek, rig.old].map(\.session.id))
        #expect(!ids.contains(rig.elsewhere))
        #expect(!model.projectPage.hasMore)
    }

    // MARK: The week's usage

    @Test func theUsageLookupNamesTheClaudeSessionsOfTheWeekOnly() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await model.openProjectPage(rig.projectID)
        let asked = try #require(rig.index.lookups.first)
        // Not the 30-day-old session, not Codex, not another project's.
        #expect(Set(asked) == ["conv-recent", "conv-week"])
        #expect(model.projectPage.usage?.tokens.total == 4_800_000 && model.projectPage.usageLoad == .done)
        // The week's Codex session is said to be left out, by its harness's name, and nothing failed.
        #expect(model.projectPage.usageUncounted == ["Codex"] && !model.projectPage.usageFailed)
        #expect(model.projectPageEvidence()["usageUncounted"] as? [String] == ["Codex"])
        #expect(ProjectUsageText.notCounted(model.projectPage.usageUncounted) == "Codex sessions are not counted.")
    }

    @Test func aProjectWithNoUsageIndexShowsNoUsage() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.usage = nil
        await model.openProjectPage(rig.projectID)
        #expect(model.projectPage.usage == nil && model.projectPage.usageLoad == .done)
    }

    @Test func anIndexThatCannotAnswerIsSaidSoAndIsNotNoUsage() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        rig.index.fails = true
        await model.openProjectPage(rig.projectID)
        #expect(model.projectPage.usage == nil && model.projectPage.usageLoad == .done)
        #expect(model.projectPage.usageFailed, "the card says the usage could not be read")
        #expect(model.projectPageEvidence()["usageFailed"] as? Bool == true)

        // The page opened again over an index that answers: the failure is gone with the page that had it.
        rig.index.fails = false
        await model.openProjectPage(rig.projectID)
        #expect(!model.projectPage.usageFailed && model.projectPage.usage?.tokens.total == 4_800_000)
        // No index at all is another thing again: nothing failed.
        model.usage = nil
        await model.openProjectPage(rig.projectID)
        #expect(!model.projectPage.usageFailed && model.projectPage.usage == nil)
    }

    // MARK: Lazy last lines

    @Test func aRowsLastLineIsReadOnceFromItsTranscriptAndOnlyWhenAsked() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        try write([Self.user, Self.assistant("## Added 12 tests\nAll 214 pass."), Self.toolOnly].joined(separator: "\n") + "\n",
                  to: transcript(rig, rig.recent))
        await model.openProjectPage(rig.projectID)
        #expect(model.projectPage.lastLines.isEmpty && model.projectPage.reads.transcriptTails == 0)

        await model.loadProjectLastLine(rig.recent)
        #expect(model.projectPage.lastLines[rig.recent.session.id] == "Added 12 tests")
        #expect(model.projectPage.reads.transcriptTails == 1)

        await model.loadProjectLastLine(rig.recent)
        #expect(model.projectPage.reads.transcriptTails == 1, "a line already read is not read again")

        // A session with no transcript reads as having none, once; a Codex session has no Claude transcript.
        await model.loadProjectLastLine(rig.lastWeek)
        await model.loadProjectLastLine(rig.lastWeek)
        await model.loadProjectLastLine(rig.codex)
        #expect(model.projectPage.lastLines[rig.lastWeek.session.id] == "")
        #expect(model.projectPage.reads.transcriptTails == 2)
    }

    @Test func rowsAskedAtTheSameTimeAreReadOneAfterAnotherAndNotTwice() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        try write(Self.assistant("first") + "\n", to: transcript(rig, rig.recent))
        try write(Self.assistant("second") + "\n", to: transcript(rig, rig.lastWeek))
        await model.openProjectPage(rig.projectID)
        async let a: Void = model.loadProjectLastLine(rig.recent)
        async let b: Void = model.loadProjectLastLine(rig.recent)
        async let c: Void = model.loadProjectLastLine(rig.lastWeek)
        _ = await (a, b, c)
        #expect(model.projectPage.reads.transcriptTails == 2)
        #expect(model.projectPage.lastLines[rig.recent.session.id] == "first")
        #expect(model.projectPage.lastLines[rig.lastWeek.session.id] == "second")
        #expect(await model.projectPage.tails.reads == 2)
    }

    @Test func aLastLineIsTheReasonLoomHoldsElseTheTranscript() {
        let approval = StatusReason(.approval(tool: "Bash"), detail: "git push origin main")
        #expect(ProjectSessionLine.text(reason: approval, transcript: "old words") == "Asks to run: git push origin main")
        #expect(ProjectSessionLine.holdsLine(approval))

        let done = StatusReason(.turnDone, detail: "Rate limiter tests pass")
        #expect(ProjectSessionLine.text(reason: done, transcript: "stale") == "Rate limiter tests pass")

        // "Turn done" says less than the transcript's last answer.
        let bare = StatusReason(.turnDone)
        #expect(ProjectSessionLine.text(reason: bare, transcript: "Added 12 tests") == "Added 12 tests")
        #expect(!ProjectSessionLine.holdsLine(bare))
        #expect(ProjectSessionLine.text(reason: bare, transcript: nil) == nil)
        #expect(ProjectSessionLine.text(reason: nil, transcript: "") == nil)
        #expect(ProjectSessionLine.text(reason: nil, transcript: "kept") == "kept")
        let failed = StatusReason(.failure(category: "rate_limit"), detail: "Too many requests")
        #expect(ProjectSessionLine.text(reason: failed, transcript: "x") == "Failed: Too many requests")
    }

    @Test func theTailReadIsBoundedWhateverTheFileHolds() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects/-tmp-x", isDirectory: true)
        let url = projects.appendingPathComponent("sess.jsonl")
        // An answer far back, then more than a megabyte of lines that hold no answer.
        var lines = [Self.assistant("buried answer")]
        let filler = #"{"type":"user","message":{"role":"user","content":"\#(String(repeating: "x", count: 900))"}}"#
        lines += Array(repeating: filler, count: 1_500)
        try write(lines.joined(separator: "\n") + "\n", to: url)
        let file = try #require(ClaudeTranscriptLocator.locate(
            sessionID: "sess", projectsDirectory: root.appendingPathComponent("projects"), workingDirectory: "/tmp/x"))
        let reader = try #require(ClaudeTranscriptReader(file: file))
        defer { reader.close() }
        #expect(ProjectLastLine.read(from: reader) == nil)
        #expect(reader.bytesRead <= ProjectLastLine.maxPages * ProjectLastLine.pageBytes + 2 * ClaudeTranscriptReader.chunkBytes,
                "read \(reader.bytesRead) bytes of \(1_500 * 900)")
    }

    @Test func theLastAnswerSkipsToolsSubagentsAndOversizedLines() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let url = projects.appendingPathComponent("-tmp-y/sess.jsonl")
        let huge = Self.assistant(String(repeating: "z", count: ProjectLastLine.maxLineBytes + 10))
        try write([Self.assistant("the real answer"), Self.assistant("a subagent said this", sidechain: true), Self.toolOnly,
                   Self.user, huge].joined(separator: "\n") + "\n", to: url)
        let file = try #require(ClaudeTranscriptLocator.locate(sessionID: "sess", projectsDirectory: projects, workingDirectory: "/tmp/y"))
        let reader = try #require(ClaudeTranscriptReader(file: file))
        defer { reader.close() }
        #expect(ProjectLastLine.read(from: reader) == "the real answer")
    }

    @Test func aLongOrMarkedUpFirstLineIsCutAndCleaned() {
        #expect(ProjectLastLine.summary(of: "\n\n- **Done**: all green\nmore") == "**Done**: all green")
        #expect(ProjectLastLine.summary(of: "```swift\nlet x = 1\n```") == "let x = 1")
        #expect(ProjectLastLine.summary(of: "> quoted\nrest") == "quoted")
        #expect(ProjectLastLine.summary(of: "   \n  ") == nil)
        let long = ProjectLastLine.summary(of: String(repeating: "a", count: 400))
        #expect(long?.count == ProjectLastLine.maxLength && long?.hasSuffix("\u{2026}") == true)
    }


    // MARK: Reads that outlive their rows

    @Test func aQueuedReadWhoseTaskWasCancelledReadsNothing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        defer { rig.model.stop() }
        try write(Self.assistant("done") + "\n", to: transcript(rig, rig.recent))
        let reader = ProjectTailReader()
        let page = ProjectPageGeneration()
        let generation = page.advance()

        // The task is cancelled before the reader gets to it, as a row that scrolled off is.
        let cancelled = Task {
            await reader.lastLine(sessionID: "conv-recent", configDirectory: rig.config,
                                  workingDirectory: rig.folder.path, generation: generation, page: page)
        }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(await reader.reads == 0, "nothing was located or opened")

        // The same ask from a task nobody cancelled reads the line.
        let line = await reader.lastLine(sessionID: "conv-recent", configDirectory: rig.config,
                                         workingDirectory: rig.folder.path, generation: generation, page: page)
        let readsAfter = await reader.reads
        #expect(line == "done" && readsAfter == 1)
    }

    @Test func aQueuedReadOfAPageThatClosedReadsNothing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        try write(Self.assistant("done") + "\n", to: transcript(rig, rig.recent))
        try write(Self.assistant("done too") + "\n", to: transcript(rig, rig.lastWeek))
        await model.openProjectPage(rig.projectID)
        let page = model.projectPage
        let reader = page.tails
        let generation = page.generation

        // Closing the page moves the generation on at once, on the main actor, without asking the reader.
        model.closeProjectPage()
        #expect(page.generation != generation)
        let stale = await reader.lastLine(sessionID: "conv-recent", configDirectory: rig.config,
                                          workingDirectory: rig.folder.path, generation: generation, page: page.pageGeneration)
        let staleReads = await reader.reads
        #expect(stale == nil && staleReads == 0)

        // A page opened again is a new generation: the old asks stay dead, new ones read.
        await model.openProjectPage(rig.projectID)
        let again = await reader.lastLine(sessionID: "conv-recent", configDirectory: rig.config,
                                          workingDirectory: rig.folder.path, generation: generation, page: page.pageGeneration)
        let againReads = await reader.reads
        #expect(again == nil && againReads == 0)
        await model.loadProjectLastLine(rig.recent)
        let finalReads = await reader.reads
        #expect(page.lastLines[rig.recent.session.id] == "done" && finalReads == 1)
    }

    @Test func aRowThatScrolledOffBeforeItsReadFinishedLeavesNoLineBehind() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        try write(Self.assistant("done") + "\n", to: transcript(rig, rig.recent))
        await model.openProjectPage(rig.projectID)
        let row = Task { await model.loadProjectLastLine(rig.recent) }
        row.cancel()
        await row.value
        #expect(model.projectPage.lastLines.isEmpty, "a cancelled ask publishes nothing")
        #expect(await model.projectPage.tails.reads == 0)
        // Drawn again later, the row asks again and gets its line.
        await model.loadProjectLastLine(rig.recent)
        #expect(model.projectPage.lastLines[rig.recent.session.id] == "done")
    }

    @Test func aTranscriptMissLooksOnlyInTheWorkingDirectorysFolder() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        // The transcript sits in another project's folder (a session that moved), not in the working directory's.
        try write(Self.assistant("elsewhere") + "\n", to: projects.appendingPathComponent("-tmp-other/sess.jsonl"))
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("-tmp-here"), withIntermediateDirectories: true)

        #expect(ClaudeTranscriptLocator.locate(sessionID: "sess", projectsDirectory: projects, workingDirectory: "/tmp/here") != nil,
                "the general search still finds it for the callers that want that")
        #expect(ClaudeTranscriptLocator.locate(sessionID: "sess", configDirectory: root, onlyIn: "/tmp/here") == nil)
        #expect(ClaudeTranscriptLocator.locate(sessionID: "sess", projectsDirectory: projects, onlyIn: "/tmp/here") == nil,
                "the same for a caller that holds the projects folder")
        #expect(ProjectLastLine.read(sessionID: "sess", configDirectory: root, workingDirectory: "/tmp/here") == nil,
                "a miss shows no line")
        // In its own folder it is found.
        try write(Self.assistant("here") + "\n", to: projects.appendingPathComponent("-tmp-here/sess.jsonl"))
        #expect(ProjectLastLine.read(sessionID: "sess", configDirectory: root, workingDirectory: "/tmp/here") == "here")
        #expect(ClaudeTranscriptLocator.locate(sessionID: "sess", projectsDirectory: projects, onlyIn: "/tmp/here") != nil)
        // Not a path out of the profile either.
        #expect(ClaudeTranscriptLocator.locate(sessionID: "../sess", configDirectory: root, onlyIn: "/tmp/here") == nil)
    }

    @Test func theSessionListIsLazyOnlyTheRowsInViewAskForTheirLines() async throws {
        enableAccessibilityTree()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        let catalog = try #require(model.catalog)
        let now = Date()
        for index in 0..<150 {
            let session = ManagedSession(provider: .claude, providerConversationID: "conv-many-\(index)", workingDirectory: rig.folder.path)
            let used = now.addingTimeInterval(-TimeInterval(60 + index))
            try await catalog.insertSession(session, title: "many \(index)", createdAt: used, lastUsedAt: used, lifecycle: .idle,
                                            projectID: rig.projectID)
        }
        let hosting = NSHostingController(rootView: ProjectPageView(model: model, projectID: rig.projectID))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 940, height: 700))
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if model.projectPage.records.count >= 150, model.projectPage.reads.transcriptTails > 0 { break }
        }
        try await Task.sleep(for: .milliseconds(300))
        let drawn = model.projectPage.reads.transcriptTails
        #expect(model.projectPage.records.count >= 150)
        #expect(drawn > 0 && drawn < 60, "\(drawn) of \(model.projectPage.records.count) rows asked for a line")
    }

    // MARK: Branch labels, follow-up reads and failures

    private func repository(_ folder: URL, branch: String) throws {
        try write("ref: refs/heads/\(branch)\n", to: folder.appendingPathComponent(".git/HEAD"))
    }

    @Test func theOpenPageKeepsItsSessionsBranchesWhenTheSidebarPrunes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        // A session in a folder of its own, which the sidebar's lists do not show (it was created after they loaded).
        let other = root.appendingPathComponent("worktree", isDirectory: true)
        try repository(other, branch: "feat/token-rotation")
        let session = ManagedSession(provider: .claude, providerConversationID: "conv-wt", workingDirectory: other.path)
        let catalog = try #require(model.catalog)
        try await catalog.insertSession(session, title: "worktree session", createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle,
                                        projectID: rig.projectID)
        #expect(model.rowModels[session.id] == nil)

        await model.openProjectPage(rig.projectID)
        #expect(model.branches[other.path] == .named("feat/token-rotation"))
        let counts = ProjectBranchUse.counts(records: model.projectPage.records, branches: model.branches)
        #expect(counts["feat/token-rotation"] == 1)

        // The sidebar prunes on every list reload: the page's branch column and the Branches tab keep their labels.
        model.pruneRowModels()
        #expect(model.branches[other.path] == .named("feat/token-rotation"))
        #expect(ProjectBranchUse.counts(records: model.projectPage.records, branches: model.branches)["feat/token-rotation"] == 1)

        // Once the page is closed nothing holds them any more.
        model.closeProjectPage()
        model.pruneRowModels()
        #expect(model.branches[other.path] == nil)
    }

    @Test func theListFollowsANewSessionInTheProjectWhileThePageIsOpen() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        await model.openProjectPage(rig.projectID)
        let before = model.projectPage.records.map(\.session.id)
        #expect(before.count == 4 && model.projectPage.reads.sessionPages == 1)

        let catalog = try #require(model.catalog)
        let fresh = ManagedSession(provider: .claude, providerConversationID: "conv-fresh", workingDirectory: rig.folder.path)
        try await catalog.insertSession(fresh, title: "fresh", createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle,
                                        projectID: rig.projectID)
        model.scheduleRefresh()
        await model.settle()
        #expect(model.sessionCounts[rig.projectID] == 5)
        #expect(model.projectPage.records.map(\.session.id) == [fresh.id] + before, "the new session leads, the rest keep their order")
        #expect(model.projectPage.reads.sessionPages == 2)

        // A refresh that finds the same count reads nothing.
        model.scheduleRefresh()
        await model.settle()
        #expect(model.projectPage.reads.sessionPages == 2)
    }

    @Test func aSessionListThatCouldNotBeReadSaysSoInsteadOfLookingEmpty() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        // Another connection takes the table away: the next read of the catalog fails.
        var connection: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("catalog.sqlite3").path, &connection) == SQLITE_OK)
        let other = try #require(connection)
        defer { sqlite3_close(other) }
        #expect(sqlite3_exec(other, "ALTER TABLE sessions RENAME TO sessions_gone", nil, nil, nil) == SQLITE_OK)

        await model.openProjectPage(rig.projectID)
        #expect(model.projectPage.records.isEmpty && model.projectPage.sessionsLoad == .done)
        #expect(model.projectPage.sessionsFailed)

        // The table is back: opening the page again reads the sessions and the flag is gone.
        #expect(sqlite3_exec(other, "ALTER TABLE sessions_gone RENAME TO sessions", nil, nil, nil) == SQLITE_OK)
        await model.openProjectPage(rig.projectID)
        #expect(!model.projectPage.sessionsFailed && model.projectPage.records.count == 4)
    }

    @Test func aPackedRefsFileCutAtItsCapDropsThePartialLastLine() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try gitFixture(root)
        let sha = String(repeating: "e", count: 40)
        // Blank lines up to the cap, then a branch line that the cap cuts inside its name:
        // "<sha> refs/heads/inv" would read as a branch called "inv".
        let keep = "\(sha) refs/heads/inv".utf8.count
        let filler = String(repeating: "\n", count: ProjectGitRefs.maxPackedBytes - keep)
        try write(filler + "\(sha) refs/heads/invented-branch\n", to: repo.appendingPathComponent(".git/packed-refs"))
        let cut = try #require(ProjectGitRefs.read(directory: repo.path))
        #expect(cut.truncated)
        #expect(!cut.branches.contains { $0.name.hasPrefix("inv") }, "a cut line is not a branch")

        // A cap that falls right after a whole line keeps that line.
        let whole = "\(sha) refs/heads/kept\n"
        let exact = String(repeating: "\n", count: ProjectGitRefs.maxPackedBytes - whole.utf8.count)
        try write(exact + whole + "\(sha) refs/heads/after-the-cap\n", to: repo.appendingPathComponent(".git/packed-refs"))
        let kept = try #require(ProjectGitRefs.read(directory: repo.path))
        #expect(kept.truncated && kept.branches.contains { $0.name == "kept" })
        #expect(!kept.branches.contains { $0.name.hasPrefix("after") })
    }

    // MARK: Presets

    @Test func aPresetOpensTheProjectsDraftWithItsWordsAndStartsNothing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.prepareNewSession()
        let own = NewSessionPreset(name: "Run tests", message: "Run the tests and fix failures", permissionMode: "acceptEdits",
                                   model: "claude-opus-5-5", projectID: rig.projectID)
        let everywhere = NewSessionPreset(name: "Review", message: "Review my last commit", permissionMode: "plan")
        let elsewhere = NewSessionPreset(name: "Only there", message: "Not for this project", projectID: rig.elsewhere)
        for preset in [everywhere, own, elsewhere] { model.newSession.addPreset(preset) }
        // The page offers the project's own presets, then those for every project; not another project's.
        #expect(model.presets(for: rig.projectID).map(\.name) == ["Run tests", "Review"])

        model.showProjectPage(rig.projectID)
        model.usePreset(own, projectID: rig.projectID)
        #expect(model.destination == .draft(projectID: rig.projectID), "the draft opens")
        let draft = try #require(model.newSession.draft(for: rig.projectID))
        #expect(draft.text == "Run the tests and fix failures")
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "acceptEdits", source: .pick))
        #expect(model.resolvedStart(for: rig.projectID).model == ResolvedChoice(value: "claude-opus-5-5", source: .pick))
        #expect(rig.intents.starts == 0 && rig.intents.sends == 0, "nothing starts until the user sends")

        // The same behaviour as a click in the draft: a second preset adds to what is there.
        model.usePreset(everywhere, projectID: rig.projectID)
        #expect(model.newSession.draft(for: rig.projectID)?.text == "Run the tests and fix failures\n\nReview my last commit")
        #expect(model.resolvedStart(for: rig.projectID).mode == ResolvedChoice(value: "plan", source: .pick))
        #expect(rig.intents.starts == 0 && rig.intents.sends == 0)
    }

    @Test func aPresetClickLeavesTheDraftsOfOtherProjectsAlone() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = try await rig(root: root)
        let model = rig.model
        defer { model.stop() }
        model.prepareNewSession()
        let preset = NewSessionPreset(name: "Run tests", message: "Run the tests", projectID: rig.projectID)
        model.newSession.addPreset(preset)
        model.usePreset(preset, projectID: rig.projectID)
        #expect(model.newSession.draft(for: rig.elsewhere)?.isVisible != true)
        #expect(model.visibleDrafts.map(\.projectID) == [rig.projectID])
    }

    // MARK: Branches

    private func gitFixture(_ root: URL, head: String = "ref: refs/heads/main\n") throws -> URL {
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try write(head, to: repo.appendingPathComponent(".git/HEAD"))
        return repo
    }

    @Test func branchesComeFromLooseRefsPackedRefsAndHeadWithoutAProcess() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try gitFixture(root)
        let git = repo.appendingPathComponent(".git")
        let sha = String(repeating: "a", count: 40)
        try write(sha + "\n", to: git.appendingPathComponent("refs/heads/main"))
        try write(sha + "\n", to: git.appendingPathComponent("refs/heads/feat/token-rotation"))
        try write(sha + "\n", to: git.appendingPathComponent("refs/heads/fix/webhook.lock"))
        try write("""
        # pack-refs with: peeled fully-peeled sorted
        \(sha) refs/heads/release/1.0
        \(sha) refs/heads/main
        \(sha) refs/remotes/origin/main
        \(sha) refs/tags/v1
        ^\(sha)
        """, to: git.appendingPathComponent("packed-refs"))
        let result = try #require(ProjectGitRefs.read(directory: repo.path))
        #expect(result.current == .named("main"))
        #expect(Set(result.branches.map(\.name)) == ["main", "feat/token-rotation", "release/1.0"], "no lock file, remote, tag or peel line")
        #expect(result.branches.first?.name == "main" && result.branches.first?.isCurrent == true, "the current branch leads")
        #expect(result.branches.first { $0.name == "feat/token-rotation" }?.updated != nil, "a loose ref has a time")
        #expect(result.branches.first { $0.name == "release/1.0" }?.updated == nil, "a packed one has none")
        #expect(!result.truncated)
    }

    @Test func aSubfolderADetachedHeadAndANonRepositoryAreRead() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try gitFixture(root, head: String(repeating: "b", count: 40) + "\n")
        try write("x", to: repo.appendingPathComponent("Sources/App/file.swift"))
        let result = try #require(ProjectGitRefs.read(directory: repo.appendingPathComponent("Sources/App").path))
        #expect(result.current == .detached && result.branches.isEmpty)
        #expect(ProjectGitRefs.read(directory: root.appendingPathComponent("elsewhere").path) == nil)
        let garbage = try gitFixture(root.appendingPathComponent("g"), head: "not a head")
        #expect(ProjectGitRefs.read(directory: garbage.path) == nil)
    }

    @Test func aLinkedWorktreeReadsTheMainRepositorysBranchesAndNamesTheOtherCheckouts() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = try gitFixture(root)
        let git = main.appendingPathComponent(".git")
        let sha = String(repeating: "c", count: 40) + "\n"
        try write(sha, to: git.appendingPathComponent("refs/heads/main"))
        try write(sha, to: git.appendingPathComponent("refs/heads/feat/x"))
        try write(sha, to: git.appendingPathComponent("refs/heads/feat/y"))
        // The linked worktree at <root>/wt has feat/x checked out; <root>/wt2 has feat/y.
        for (name, branch) in [("wt", "feat/x"), ("wt2", "feat/y")] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let admin = git.appendingPathComponent("worktrees/\(name)")
            try write("ref: refs/heads/\(branch)\n", to: admin.appendingPathComponent("HEAD"))
            try write("../..\n", to: admin.appendingPathComponent("commondir"))
            try write(folder.path + "/.git\n", to: admin.appendingPathComponent("gitdir"))
            try write("gitdir: \(admin.path)\n", to: folder.appendingPathComponent(".git"))
        }
        let result = try #require(ProjectGitRefs.read(directory: root.appendingPathComponent("wt").path))
        #expect(result.current == .named("feat/x"))
        let byName = Dictionary(uniqueKeysWithValues: result.branches.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["main", "feat/x", "feat/y"])
        #expect(byName["feat/x"]?.isCurrent == true && byName["feat/x"]?.worktree == nil, "its own checkout is current, not a worktree")
        #expect(byName["main"]?.worktree == main.path, "the main checkout has main")
        #expect(byName["feat/y"]?.worktree == root.appendingPathComponent("wt2").path)
    }

    @Test func theBranchListAndTheFilesItReadsAreBounded() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try gitFixture(root)
        let git = repo.appendingPathComponent(".git")
        let sha = String(repeating: "d", count: 40)
        for index in 0..<(ProjectGitRefs.maxBranches + 40) {
            try write(sha + "\n", to: git.appendingPathComponent("refs/heads/b\(String(format: "%04d", index))"))
        }
        let result = try #require(ProjectGitRefs.read(directory: repo.path))
        #expect(result.branches.count <= ProjectGitRefs.maxBranches && result.truncated)

        // A packed-refs file over the cap is read only up to it.
        let packed = try gitFixture(root.appendingPathComponent("p"))
        let line = "\(sha) refs/heads/packed-branch-with-a-long-name-0000000000000000000000000\n"
        let body = String(repeating: line, count: ProjectGitRefs.maxPackedBytes / line.utf8.count + 100)
        try write(body, to: packed.appendingPathComponent(".git/packed-refs"))
        let capped = try #require(ProjectGitRefs.read(directory: packed.path))
        #expect(capped.truncated && capped.branches.count <= ProjectGitRefs.maxBranches)

        // A HEAD far over its cap is not a head.
        let bad = try gitFixture(root.appendingPathComponent("q"), head: String(repeating: "x", count: 10_000))
        #expect(ProjectGitRefs.read(directory: bad.path) == nil)
    }

    @Test func theBranchesTheSessionsWorkOnAreCounted() throws {
        let one = CatalogSession(session: ManagedSession(provider: .claude, providerConversationID: "1", workingDirectory: "/a"),
                                 title: nil, createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle, pinned: false)
        let two = CatalogSession(session: ManagedSession(provider: .claude, providerConversationID: "2", workingDirectory: "/b"),
                                 title: nil, createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle, pinned: false)
        let three = CatalogSession(session: ManagedSession(provider: .claude, providerConversationID: "3", workingDirectory: "/c"),
                                   title: nil, createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle, pinned: false)
        let counts = ProjectBranchUse.counts(records: [one, two, three], branches: [
            "/a": .named("main"), "/b": .named("main"), "/c": .detached,
        ])
        #expect(counts == ["main": 2])
    }

    // MARK: The project's CLAUDE.md

    @Test func claudeMdIsReadFromTheFolderOrDotClaudeAndCountedByLine() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ProjectInstructionsReader.read(folder: root.path) == nil)

        try write("# Rules\n\n- run the tests\n- keep it small\n", to: root.appendingPathComponent(".claude/CLAUDE.md"))
        let hidden = try #require(ProjectInstructionsReader.read(folder: root.path))
        #expect(hidden.name == ".claude/CLAUDE.md" && hidden.lineCount == 4 && !hidden.truncated)

        try write("# Project\nUse Swift 6.\r\nNo force unwraps.", to: root.appendingPathComponent("CLAUDE.md"))
        let top = try #require(ProjectInstructionsReader.read(folder: root.path))
        #expect(top.name == "CLAUDE.md", "the folder's own file wins")
        #expect(top.lineCount == 3 && top.blocks.count >= 2 && top.modified != nil)
    }

    @Test func claudeMdFollowsALinkToAnotherFileButNotADirectoryOrAnUnreadableName() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("shared instructions\n", to: root.appendingPathComponent("AGENTS.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("CLAUDE.md"),
                                                   withDestinationURL: root.appendingPathComponent("AGENTS.md"))
        #expect(ProjectInstructionsReader.read(folder: root.path)?.lineCount == 1)

        let directory = root.appendingPathComponent("d", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("CLAUDE.md"), withIntermediateDirectories: true)
        #expect(ProjectInstructionsReader.read(folder: directory.path) == nil, "a folder named CLAUDE.md is not read")
    }

    @Test func aLongClaudeMdIsReadOnlyUpToItsCapAndCutAtALineEnd() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let line = String(repeating: "word ", count: 20) + "\n"
        let body = String(repeating: line, count: ProjectInstructionsReader.maxBytes / line.utf8.count * 4)
        try write(body, to: root.appendingPathComponent("CLAUDE.md"))
        let result = try #require(ProjectInstructionsReader.read(folder: root.path))
        #expect(result.truncated && result.lineCount == nil)
        #expect(result.byteCount == body.utf8.count, "the size is the file's")
        let shown = result.blocks.reduce(0) { total, block in
            if case .paragraph(let text) = block { return total + text.utf8.count }
            return total
        }
        #expect(shown > 0 && shown <= ProjectInstructionsReader.maxBytes)
    }
}
