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
    let workingDirectory: String
    let title: String
    let project: String?
}

@MainActor
final class LivePaletteSources: PaletteSources {
    /// The sessions looked at for a transcript, newest activity first. The scan reads at most the budget either way.
    static let maximumSessions = 400
    static let olderLimit = 12

    private unowned let model: CatalogModel
    private let transcriptsDirectory: () -> URL?

    init(model: CatalogModel, transcriptsDirectory: @escaping () -> URL?) {
        self.model = model
        self.transcriptsDirectory = transcriptsDirectory
    }

    func olderSessions(matching query: String) async throws -> [CatalogSession] {
        guard let catalog = model.catalog else { return [] }
        return try await catalog.searchSessions(search: query, order: .recentActivity, groupLimit: Self.olderLimit).sessions
    }

    func searchTranscripts(query: String, budget: PaletteSearchBudget,
                           progress: @escaping @MainActor (PaletteTranscriptOutcome) -> Void) async throws -> PaletteTranscriptOutcome {
        guard let catalog = model.catalog, let projects = transcriptsDirectory() else {
            var outcome = PaletteTranscriptOutcome()
            outcome.coverage.unavailable = true
            return outcome
        }
        let cutoff = Date().addingTimeInterval(-budget.window)
        let recent = try await catalog.searchSessions(search: "", order: .recentActivity, groupLimit: Self.maximumSessions)
        let refs: [PaletteSessionRef] = recent.sessions.compactMap { record in
            guard record.session.provider == .claude, record.lastActivityAt >= cutoff,
                  let conversation = record.session.providerConversationID else { return nil }
            let project = model.projectName(for: record)
            return PaletteSessionRef(id: record.session.id, conversationID: conversation,
                                     workingDirectory: record.session.workingDirectory,
                                     title: record.displayTitle(projectName: project), project: project)
        }
        return await Self.scan(query: query, refs: refs, projects: projects, budget: budget) { outcome in
            Task { @MainActor in progress(outcome) }
        }
    }

    /// Finds each session's transcript and scans them, off the main actor. The calling task's cancellation reaches
    /// the scan, which looks at it between chunks.
    private nonisolated static func scan(query: String, refs: [PaletteSessionRef], projects: URL, budget: PaletteSearchBudget,
                                         progress: @escaping @Sendable (PaletteTranscriptOutcome) -> Void) async -> PaletteTranscriptOutcome {
        var files: [PaletteTranscriptFile] = []
        for ref in refs {
            if Task.isCancelled { break }
            guard let located = ClaudeTranscriptLocator.locate(
                sessionID: ref.conversationID, projectsDirectory: projects, workingDirectory: ref.workingDirectory)
            else { continue }
            var info = stat()
            guard stat(located.path, &info) == 0 else { continue }
            files.append(PaletteTranscriptFile(
                sessionID: ref.id, path: located.path, title: ref.title, project: ref.project,
                modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))))
        }
        return PaletteTranscriptScanner.scan(query: query, files: files, budget: budget, progress: progress)
    }
}

/// The one line that says why a session needs the user, from the reason its status carries.
enum PaletteReasonText {
    static func line(reason: StatusReason?, indicator: SessionIndicator, awaitingOpenApproval: Bool) -> String? {
        if awaitingOpenApproval { return "wants to open a session" }
        if let reason {
            switch reason.kind {
            case .approval(let tool):
                if tool == "Bash" { return "allow " + (reason.detail ?? "a command") }
                return "allow " + [tool, reason.detail].compactMap { $0 }.joined(separator: " ")
            case .question: return reason.detail.map { "asks: " + $0 } ?? "has a question"
            case .planReady: return "plan ready for review"
            case .input: return "waiting for your input"
            case .turnDone: if let detail = reason.detail { return detail }
            case .failure(let category): return reason.detail ?? category ?? "failed"
            case .automaticTurn: break
            }
        }
        switch indicator {
        case .waitingForApproval: return "needs approval"
        case .waitingForInput: return "waiting for you"
        case .failed(let message): return message ?? "failed"
        case .stopUnverified: return "stop not verified"
        case .problem(let message): return message
        case .identityUnclear: return "identity unclear"
        case .unviewedCompletion: return "finished"
        default: return nil
        }
    }
}
