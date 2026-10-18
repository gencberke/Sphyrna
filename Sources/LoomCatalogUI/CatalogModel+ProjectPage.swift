import Foundation
import LoomCore
import Observation

/// The tabs of the project page.
public enum ProjectPageTab: String, CaseIterable, Sendable {
    case sessions = "Sessions"
    case branches = "Branches"
    case instructions = "Instructions"
}

/// How far a part of the page has been read. Nothing is read before the page opens.
public enum ProjectPageLoad: Equatable, Sendable {
    case idle
    case loading
    case done
}

/// What the page has read since it opened, counted per kind (tests and the evidence snapshot).
public struct ProjectPageReads: Equatable, Sendable {
    public var sessionPages = 0
    public var usageLookups = 0
    public var gitReads = 0
    public var instructionReads = 0
    public var transcriptTails = 0
    public var total: Int { sessionPages + usageLookups + gitReads + instructionReads + transcriptTails }
}

/// The state of the project page (V08). The page reads when it opens (`CatalogModel.openProjectPage`, run by
/// the view's task, so closing the page cancels it) and holds what it read until the next open: the project's
/// sessions from the catalog, their last lines (read lazily, one per row on screen), the repository's
/// branches, the past week's usage and the CLAUDE.md. Nothing is watched and nothing polls.
@MainActor @Observable
public final class ProjectPageState {
    public internal(set) var projectID: UUID?
    public internal(set) var tab = ProjectPageTab.sessions
    public internal(set) var sessionsLoad = ProjectPageLoad.idle
    public internal(set) var records: [CatalogSession] = []
    /// The first read of the sessions failed (the catalog could not be read): the page says so instead of
    /// showing a project with no sessions.
    public internal(set) var sessionsFailed = false
    public internal(set) var hasMore = false
    public internal(set) var isLoadingMore = false
    /// The past seven days; nil until read, or when the index could not answer.
    public internal(set) var usage: ProjectUsage?
    public internal(set) var usageLoad = ProjectPageLoad.idle
    var branches: ProjectBranches?
    public internal(set) var branchesLoad = ProjectPageLoad.idle
    var instructions: ProjectInstructions?
    public internal(set) var instructionsLoad = ProjectPageLoad.idle
    /// A transcript's last line by session; "" is a transcript that holds none.
    public internal(set) var lastLines: [UUID: String] = [:]
    public internal(set) var reads = ProjectPageReads()

    /// Which opening this is: bumped when the page opens and when it closes, and read by the tail reader on its
    /// own queue (`ProjectPageGeneration`).
    @ObservationIgnored let pageGeneration = ProjectPageGeneration()
    var generation: Int { pageGeneration.current }
    @ObservationIgnored var cursor: CatalogCursor?
    @ObservationIgnored var pendingLines: Set<UUID> = []
    @ObservationIgnored let tails = ProjectTailReader()
    /// The working directories of the sessions read, so the model keeps their branches while the page is open.
    @ObservationIgnored var folders: Set<String> = []
    /// The re-read of the first page after the project's session count changed (a test waits for it).
    @ObservationIgnored var refreshTask: Task<Void, Never>?

    public init() {}

    /// The page opens on `projectID`: everything read for another project (or an earlier visit) is dropped.
    func begin(_ projectID: UUID) {
        pageGeneration.advance()
        refreshTask?.cancel()
        refreshTask = nil
        self.projectID = projectID
        tab = .sessions
        sessionsLoad = .loading
        sessionsFailed = false
        records = []
        folders = []
        hasMore = false
        isLoadingMore = false
        cursor = nil
        usage = nil
        usageLoad = .loading
        branches = nil
        branchesLoad = .loading
        instructions = nil
        instructionsLoad = .loading
        lastLines = [:]
        pendingLines = []
        reads = ProjectPageReads()
    }

    /// The page closed: what it holds is released, and a read that is still under way is dropped.
    func end() {
        pageGeneration.advance()
        refreshTask?.cancel()
        refreshTask = nil
        projectID = nil
        sessionsLoad = .idle
        sessionsFailed = false
        records = []
        folders = []
        hasMore = false
        cursor = nil
        usage = nil
        usageLoad = .idle
        branches = nil
        branchesLoad = .idle
        instructions = nil
        instructionsLoad = .idle
        lastLines = [:]
        pendingLines = []
    }
}

extension CatalogSession {
    /// Sorts after `other` in the list's order (newest activity first, then the id, both descending).
    func isOlder(than other: CatalogSession) -> Bool {
        (lastActivityAt, session.id.uuidString) < (other.lastActivityAt, other.session.id.uuidString)
    }
}

/// The words of a session row's last line: what Loom holds about the session now, else the end of its transcript.
enum ProjectSessionLine {
    /// The reason's line, unless it only says "Turn done": the transcript's last answer is more than that.
    static func text(reason: StatusReason?, transcript: String?) -> String? {
        if let reason, let line = SessionReasonLine(reason), !isBareTurnDone(reason) { return line.text }
        if let transcript, !transcript.isEmpty { return transcript }
        return nil
    }

    /// Whether the reason holds a line worth showing, so the transcript need not be read for the row.
    static func holdsLine(_ reason: StatusReason?) -> Bool {
        guard let reason else { return false }
        return SessionReasonLine(reason) != nil && !isBareTurnDone(reason)
    }

    private static func isBareTurnDone(_ reason: StatusReason) -> Bool {
        if case .turnDone = reason.kind { return reason.detail == nil && reason.work.tasks == 0 }
        return false
    }
}

extension CatalogModel {
    /// Shows a project's page.
    public func showProjectPage(_ projectID: UUID) { navigate(to: .projectPage(projectID)) }

    /// The most session rows the page reads while looking for the week's sessions.
    static let projectPageWeekRows = 500
    /// A little more than a week, so a session used at the edge of the usage range is still asked about.
    static let projectPageWeekSlack: TimeInterval = 8 * 86_400

    /// The page opens: reads the project's sessions, branches, CLAUDE.md and the week's usage, once each.
    /// The view runs it as its task; when the page closes the task ends and what is still being read is dropped.
    public func openProjectPage(_ projectID: UUID) async {
        let page = projectPage
        page.begin(projectID)
        guard let project = projects.first(where: { $0.id == projectID }) else {
            page.sessionsLoad = .done
            page.usageLoad = .done
            page.branchesLoad = .done
            page.instructionsLoad = .done
            return
        }
        let generation = page.generation
        async let sessions: Void = readProjectSessions(project, generation: generation)
        async let branches: Void = readProjectBranches(project, generation: generation)
        async let instructions: Void = readProjectInstructions(project, generation: generation)
        _ = await (sessions, branches, instructions)
    }

    /// The page closed.
    public func closeProjectPage() { projectPage.end() }

    /// The project's session count changed while its page is open (a session was started, or deleted): the
    /// first page of the list is read again, as Home reads again when the counts change. What was loaded
    /// beyond the first page stays; nothing polls.
    func projectSessionCountsChanged(from before: [UUID?: Int]) {
        let page = projectPage
        guard let projectID = page.projectID, page.sessionsLoad == .done,
              before[projectID] != sessionCounts[projectID] else { return }
        page.refreshTask?.cancel()
        let generation = page.generation
        page.refreshTask = Task { [weak self] in await self?.rereadFirstProjectPage(projectID, generation: generation) }
    }

    private func rereadFirstProjectPage(_ projectID: UUID, generation: Int) async {
        let page = projectPage
        guard let catalog, isCurrent(generation) else { return }
        page.reads.sessionPages += 1
        guard let first = try? await catalog.sessionPage(
            CatalogQuery(scope: .project(projectID), order: .recentActivity), after: nil),
            isCurrent(generation) else { return }
        page.folders.formUnion(first.sessions.map(\.session.workingDirectory))
        await ensureBranches(for: first.sessions)
        guard isCurrent(generation) else { return }
        // Rows loaded beyond this page keep their place; a row of the old first page that is not in the new
        // one was deleted.
        var older: [CatalogSession] = []
        if let boundary = first.sessions.last, first.next != nil {
            let inFirst = Set(first.sessions.map(\.session.id))
            older = page.records.filter { !inFirst.contains($0.session.id) && $0.isOlder(than: boundary) }
        }
        page.records = first.sessions + older
        if older.isEmpty {
            page.cursor = first.next
            page.hasMore = first.next != nil
        }
        page.sessionsFailed = false
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && projectPage.generation == generation
    }

    // MARK: Sessions and the week's usage

    private func readProjectSessions(_ project: CatalogProject, generation: Int) async {
        let page = projectPage
        var collected: [CatalogSession] = []
        if let catalog {
            let cutoff = Date().addingTimeInterval(-Self.projectPageWeekSlack)
            var cursor: CatalogCursor?
            while true {
                page.reads.sessionPages += 1
                let read: CatalogPage
                do {
                    read = try await catalog.sessionPage(
                        CatalogQuery(scope: .project(project.id), order: .recentActivity), after: cursor)
                } catch {
                    // Only the first page failing leaves the page with nothing to show: say so.
                    if collected.isEmpty, isCurrent(generation) { page.sessionsFailed = true }
                    break
                }
                guard isCurrent(generation) else { break }
                collected += read.sessions
                cursor = read.next
                page.folders.formUnion(read.sessions.map(\.session.workingDirectory))
                await ensureBranches(for: read.sessions)
                guard isCurrent(generation) else { return }
                page.records = collected
                page.cursor = cursor
                page.hasMore = cursor != nil
                if page.sessionsLoad != .done { page.sessionsLoad = .done }
                // Further pages only while the sessions are still inside the week: the usage needs them all.
                guard cursor != nil, let last = collected.last, last.lastActivityAt >= cutoff,
                      collected.count < Self.projectPageWeekRows else { break }
            }
        }
        guard isCurrent(generation) else { return }
        page.sessionsLoad = .done

        let cutoff = Date().addingTimeInterval(-Self.projectPageWeekSlack)
        let identifiers = collected.filter { $0.lastActivityAt >= cutoff }.compactMap { record -> String? in
            guard record.session.provider == .claude, let id = record.session.providerConversationID, !id.isEmpty else { return nil }
            return id
        }
        page.reads.usageLookups += 1
        let usage = await self.usage?.projectUsage(sessions: identifiers)
        guard isCurrent(generation) else { return }
        page.usage = usage
        page.usageLoad = .done
    }

    /// The next page of sessions (the button under the list).
    public func loadMoreProjectSessions() {
        let page = projectPage
        guard let catalog, let projectID = page.projectID, let cursor = page.cursor, !page.isLoadingMore else { return }
        page.isLoadingMore = true
        let generation = page.generation
        Task { [weak self] in
            guard let self else { return }
            defer { if self.projectPage.generation == generation { self.projectPage.isLoadingMore = false } }
            self.projectPage.reads.sessionPages += 1
            guard let read = try? await catalog.sessionPage(
                CatalogQuery(scope: .project(projectID), order: .recentActivity), after: cursor),
                self.projectPage.generation == generation else { return }
            self.projectPage.folders.formUnion(read.sessions.map(\.session.workingDirectory))
            await self.ensureBranches(for: read.sessions)
            guard self.projectPage.generation == generation else { return }
            let known = Set(self.projectPage.records.map(\.session.id))
            self.projectPage.records += read.sessions.filter { !known.contains($0.session.id) }
            self.projectPage.cursor = read.next
            self.projectPage.hasMore = read.next != nil
        }
    }

    // MARK: Last lines

    /// Reads the end of the session's transcript for its row, once per visit, one session at a time. A row
    /// that scrolls off before its turn cancels the task and nothing is read for it.
    public func loadProjectLastLine(_ record: CatalogSession) async {
        let page = projectPage
        let id = record.session.id
        guard page.projectID != nil, page.projectID == record.projectID, page.lastLines[id] == nil,
              !page.pendingLines.contains(id), record.session.provider == .claude,
              let conversation = record.session.providerConversationID, !conversation.isEmpty,
              let directory = claudeConfigDirectory, !Task.isCancelled else { return }
        page.pendingLines.insert(id)
        let generation = page.generation
        defer { if page.generation == generation { page.pendingLines.remove(id) } }
        page.reads.transcriptTails += 1
        let text = await page.tails.lastLine(
            sessionID: conversation, configDirectory: directory, workingDirectory: record.session.workingDirectory,
            generation: generation, page: page.pageGeneration)
        // A read that was dropped (the row scrolled off, the page closed) leaves no line behind, so the row
        // asks again if it is drawn again.
        guard !Task.isCancelled, page.generation == generation else { return }
        page.lastLines[id] = text ?? ""
    }

    // MARK: Branches and CLAUDE.md

    private func readProjectBranches(_ project: CatalogProject, generation: Int) async {
        let page = projectPage
        page.reads.gitReads += 1
        let path = project.path
        let branches = await Task.detached(priority: .userInitiated) { ProjectGitRefs.read(directory: path) }.value
        guard isCurrent(generation) else { return }
        page.branches = branches
        page.branchesLoad = .done
    }

    private func readProjectInstructions(_ project: CatalogProject, generation: Int) async {
        let page = projectPage
        page.reads.instructionReads += 1
        let path = project.path
        let instructions = await Task.detached(priority: .userInitiated) { ProjectInstructionsReader.read(folder: path) }.value
        guard isCurrent(generation) else { return }
        page.instructions = instructions
        page.instructionsLoad = .done
    }

    // MARK: Presets

    /// A preset on the project page: the project's draft opens with the preset's message, mode and model in it.
    /// Nothing starts; the user sends (the same as a preset in the draft, D-59).
    func usePreset(_ preset: NewSessionPreset, projectID: UUID) {
        beginNewSession(projectID: projectID)
        applyPreset(preset, projectID: projectID)
    }

    // MARK: Evidence

    /// A click on a tab of the page.
    public func showProjectPageTab(_ tab: ProjectPageTab) { projectPage.tab = tab }

    /// A click on the page's `index`-th preset (evidence); false when there is none.
    public func usePresetForEvidence(index: Int, projectID: UUID) -> Bool {
        let presets = presets(for: projectID)
        guard presets.indices.contains(index) else { return false }
        usePreset(presets[index], projectID: projectID)
        return true
    }

    /// What the page holds, as numbers and flags only: no title, path, branch name or line of text.
    public func projectPageEvidence() -> [String: Any] {
        let page = projectPage
        func load(_ value: ProjectPageLoad) -> String {
            switch value {
            case .idle: "idle"
            case .loading: "loading"
            case .done: "done"
            }
        }
        var usage: [String: Any] = [:]
        if let value = page.usage {
            usage = ["tokens": value.tokens.total, "messages": value.messageCount, "sessions": value.sessionCount,
                     "hasCost": value.estimatedCostUSD != nil]
        }
        return [
            "project": page.projectID?.uuidString ?? "none", "tab": page.tab.rawValue.lowercased(),
            "loads": ["sessions": load(page.sessionsLoad), "usage": load(page.usageLoad),
                      "branches": load(page.branchesLoad), "instructions": load(page.instructionsLoad)],
            "sessions": page.records.count, "hasMore": page.hasMore, "sessionsFailed": page.sessionsFailed, "usage": usage,
            "lastLines": ["read": page.lastLines.count, "found": page.lastLines.values.filter { !$0.isEmpty }.count],
            "branches": page.branches.map { ["count": $0.branches.count, "truncated": $0.truncated] as [String: Any] } ?? [:],
            "instructions": page.instructions.map { ["lines": $0.lineCount ?? -1, "bytes": $0.byteCount, "truncated": $0.truncated] as [String: Any] } ?? [:],
            "reads": ["sessionPages": page.reads.sessionPages, "usageLookups": page.reads.usageLookups, "gitReads": page.reads.gitReads,
                      "instructionReads": page.reads.instructionReads, "transcriptTails": page.reads.transcriptTails],
        ]
    }
}
