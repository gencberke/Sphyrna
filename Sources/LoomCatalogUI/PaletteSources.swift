import Foundation
import LoomCore

/// What the open palette reads besides what the model already holds in memory. Both are asked once per settled
/// query, from one task that the next keystroke cancels; neither runs while the palette is closed. A protocol so
/// the tests can hold a search open and watch it being cancelled.
@MainActor
protocol PaletteSources: AnyObject {
    /// Catalog sessions whose title, provider or project match, newest first (a bounded read).
    func olderSessions(matching query: String) async throws -> [CatalogSession]
    /// The transcript scan. `progress` is called on the main actor with the hits so far.
    func searchTranscripts(query: String, budget: PaletteSearchBudget,
                           progress: @escaping @MainActor (PaletteTranscriptOutcome) -> Void) async throws -> PaletteTranscriptOutcome
}

/// A session to look for a transcript of: values only, so they cross to the scanning task.
struct PaletteSessionRef: Sendable {
    let id: UUID
    let conversationID: String
    let kind: HarnessTranscriptKind
    let workingDirectory: String
    let title: String
    let project: String?
    let lastActivityAt: Date
}

/// The sessions one open palette looks for transcripts of, read from the catalog once: the newest by activity,
/// at most the cap, and whether the cap left newer-than-`cutoff` sessions out.
struct PaletteCandidates: Sendable {
    let refs: [PaletteSessionRef]
    /// The catalog had more sessions than the cap, and the oldest one kept was still active at `lastActivityAt`.
    let cutAfter: Date?

    /// Whether sessions active since `cutoff` were left out by the cap.
    func cuts(since cutoff: Date) -> Bool { cutAfter.map { $0 >= cutoff } ?? false }
}

/// Where a candidate's transcript is, as found once per open.
enum PaletteLocation: Sendable {
    case found(PaletteTranscriptFile)
    case missing
    case unavailable
}

@MainActor
final class LivePaletteSources: PaletteSources {
    /// The sessions looked at for a transcript, newest activity first. The scan reads at most the budget either way.
    static let defaultMaximumSessions = 400
    static let olderLimit = 12

    let maximumSessions: Int
    private unowned let model: CatalogModel
    private let transcriptsDirectory: () -> URL?
    /// What this open of the palette found, kept until it closes (this object lives from open to close): the
    /// candidates, and where the transcript of each is. A second query asks the catalog and the disk for neither.
    private var candidates: PaletteCandidates?
    private var locations: [UUID: PaletteLocation] = [:]
    private var locatedProjects: URL?
    private var locatedCodexHome: URL?
    private var locatedCodexGeneration: UInt64 = 0
    /// How many transcripts were looked for on disk, and how many times the catalog was asked for the candidates
    /// (a test counts them: after the first query a second one adds none).
    private(set) var locateCalls = 0
    private(set) var candidateReads = 0

    init(model: CatalogModel, maximumSessions: Int = LivePaletteSources.defaultMaximumSessions,
         transcriptsDirectory: @escaping () -> URL?) {
        self.model = model
        self.maximumSessions = maximumSessions
        self.transcriptsDirectory = transcriptsDirectory
    }

    func olderSessions(matching query: String) async throws -> [CatalogSession] {
        guard let catalog = model.catalog else { return [] }
        return try await catalog.searchSessions(search: query, order: .recentActivity, groupLimit: Self.olderLimit).sessions
    }

    func searchTranscripts(query: String, budget: PaletteSearchBudget,
                           progress: @escaping @MainActor (PaletteTranscriptOutcome) -> Void) async throws -> PaletteTranscriptOutcome {
        guard let catalog = model.catalog else {
            var outcome = PaletteTranscriptOutcome()
            outcome.coverage.unavailable = true
            return outcome
        }
        let projects = transcriptsDirectory()
        let codexHome = model.codexConfigDirectory
        let sourceGeneration = model.codexConfigGeneration
        guard projects != nil || codexHome != nil else {
            var outcome = PaletteTranscriptOutcome()
            outcome.coverage.unavailable = true
            return outcome
        }
        if locatedProjects != projects || locatedCodexHome != codexHome || locatedCodexGeneration != sourceGeneration {
            locations.removeAll()
            locatedProjects = projects
            locatedCodexHome = codexHome
            locatedCodexGeneration = sourceGeneration
        }
        let cutoff = Date().addingTimeInterval(-budget.window)
        let pool = try await candidatePool(catalog)
        guard currentSource(projects: projects, codexHome: codexHome, generation: sourceGeneration) else { throw CancellationError() }
        let wanted = pool.refs.filter { $0.lastActivityAt >= cutoff }
        // Only the transcripts not looked for yet in this open (the older pass adds the ones past 14 days).
        let unknown = wanted.filter { locations[$0.id] == nil }
        if !unknown.isEmpty {
            locateCalls += unknown.count
            let found = await Self.locate(unknown, projects: projects, codexHome: codexHome)
            guard currentSource(projects: projects, codexHome: codexHome, generation: sourceGeneration) else { throw CancellationError() }
            for (id, location) in found { locations[id] = location }
        }
        let files: [PaletteTranscriptFile] = wanted.compactMap { ref in
            guard case .found(let file)? = locations[ref.id] else { return nil }
            return file
        }
        var outcome = await Self.scan(query: query, files: files, budget: budget) { [weak self] outcome in
            Task { @MainActor [weak self] in
                guard let self, self.currentSource(projects: projects, codexHome: codexHome, generation: sourceGeneration) else { return }
                progress(outcome)
            }
        }
        guard currentSource(projects: projects, codexHome: codexHome, generation: sourceGeneration) else { throw CancellationError() }
        outcome.coverage.unavailable = wanted.contains { ref in
            guard let location = locations[ref.id] else { return true }
            if case .unavailable = location { return true }
            return false
        }
        if pool.cuts(since: cutoff) { outcome.coverage.sessionCap = maximumSessions }
        return outcome
    }

    private func currentSource(projects: URL?, codexHome: URL?, generation: UInt64) -> Bool {
        !Task.isCancelled && transcriptsDirectory() == projects && model.codexConfigDirectory == codexHome
            && model.codexConfigGeneration == generation
    }

    /// The newest sessions of the catalog with a supported transcript identity, read once per open.
    private func candidatePool(_ catalog: SessionCatalog) async throws -> PaletteCandidates {
        if let candidates { return candidates }
        candidateReads += 1
        let recent = try await catalog.searchSessions(search: "", order: .recentActivity, groupLimit: maximumSessions)
        let refs: [PaletteSessionRef] = recent.sessions.compactMap { record in
            guard model.capabilities(of: record.session.provider).readsTranscript,
                  let conversation = record.session.providerConversationID,
                  let kind = HarnessTranscriptKind(provider: record.session.provider) else { return nil }
            let project = model.projectName(for: record)
            return PaletteSessionRef(id: record.session.id, conversationID: conversation, kind: kind,
                                     workingDirectory: record.session.workingDirectory,
                                     title: record.displayTitle(projectName: project), project: project,
                                     lastActivityAt: record.lastActivityAt)
        }
        let pool = PaletteCandidates(refs: refs, cutAfter: recent.next == nil ? nil : recent.sessions.last?.lastActivityAt)
        candidates = pool
        return pool
    }

    /// Finds transcripts off the main actor using each harness's bounded locator. Claude searches only the folder
    /// for the session's working directory; Codex searches the configured home's recorded session ids. Stops when cancelled.
    private nonisolated static func locate(_ refs: [PaletteSessionRef], projects: URL?, codexHome: URL?) async -> [(UUID, PaletteLocation)] {
        var found: [(UUID, PaletteLocation)] = []
        let codexIDs = refs.compactMap { ref -> String? in
            if case .codex = ref.kind { return ref.conversationID }
            return nil
        }
        let codex = codexHome.map { CodexRolloutLocator.locate(sessionIDs: codexIDs, home: $0) }
        for ref in refs {
            if Task.isCancelled { break }
            let path: String?
            switch ref.kind {
            case .claude:
                guard let projects else { found.append((ref.id, .unavailable)); continue }
                path = ClaudeTranscriptLocator.locate(
                    sessionID: ref.conversationID, projectsDirectory: projects, onlyIn: ref.workingDirectory)?.path
            case .codex:
                guard let codex, codex.complete else { found.append((ref.id, .unavailable)); continue }
                path = UUID(uuidString: ref.conversationID).flatMap { codex.files[$0.uuidString.lowercased()]?.path }
            }
            guard let path else { found.append((ref.id, .missing)); continue }
            var info = stat()
            guard stat(path, &info) == 0 else {
                found.append((ref.id, .missing))
                continue
            }
            found.append((ref.id, .found(PaletteTranscriptFile(
                sessionID: ref.id, path: path, title: ref.title, project: ref.project,
                modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)), kind: ref.kind))))
        }
        return found
    }

    /// Scans the files, off the main actor. The calling task's cancellation reaches the scan, which looks at it
    /// between chunks.
    private nonisolated static func scan(query: String, files: [PaletteTranscriptFile], budget: PaletteSearchBudget,
                                         progress: @escaping @Sendable (PaletteTranscriptOutcome) -> Void) async -> PaletteTranscriptOutcome {
        PaletteTranscriptScanner.scan(query: query, files: files, budget: budget, progress: progress)
    }
}

/// The one line that says why a session needs the user. The words are the sidebar's and Home's (`SessionReasonLine`,
/// built from the same `StatusReason`), so a session reads the same on every surface; with no reason the state's own
/// label stands in, as on Home.
enum PaletteReasonText {
    static func line(reason: StatusReason?, indicator: SessionIndicator, awaitingOpenApproval: Bool) -> String? {
        if awaitingOpenApproval { return "Wants to open a session" }
        if let text = SessionReasonLine(reason)?.text { return text }
        switch indicator {
        case .problem(let message): return message
        case .failed(let message): return message.map { "Failed: \($0)" } ?? indicator.label
        default: return indicator.needsAttention ? indicator.label : nil
        }
    }
}
