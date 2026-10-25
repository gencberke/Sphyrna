import Foundation
import LoomChat
import LoomCore
import SwiftUI

/// What the Overview tab says about a session, as a plain value so the words can be tested without a view: the facts of
/// the session (its state, when it started, the Claude Code version, the model and its effort, the permission mode), the
/// worktree (project, branch and its base, folder), the files of the last turn and the subagents. The context is drawn
/// separately from `UsageModel.contexts`. A Codex session has what it always had (its state, start, project, branch and
/// folder); nothing is asked of Codex for the rest.
struct InspectorOverviewContent: Equatable {
    /// The permission mode: the title under Loom's name, and the key the mode's icon and tone are looked up by.
    struct Mode: Equatable {
        let title: String
        let key: String?
    }

    struct FileRow: Equatable, Identifiable {
        let id: String
        /// The file's own name; the path is its tooltip.
        let name: String
        let path: String
        let added: Int
        let removed: Int
    }

    /// The last turn's edits, once they were read; `isRead` is false before that, so no empty sentence is said too early.
    struct LastTurn: Equatable {
        let files: [FileRow]
        /// Files past `LoomTheme.Overview.maxFiles`.
        let more: Int
        let isRead: Bool

        var isEmpty: Bool { isRead && files.isEmpty }
    }

    struct Agents: Equatable {
        let running: Int
        let rows: [InspectorAgentsContent.Row]
        /// Subagents past `LoomTheme.Overview.maxAgents`.
        let more: Int

        var title: String { "Agents \u{00B7} \(running) running" }
    }

    /// The state's word: the pill's label; "Not running" for a session with no run, "—" for an ended one.
    let status: String
    /// The session's creation: "14:02 today", "Yesterday 09:12", a date.
    let started: String
    /// "Claude Code 2.1.300"; nil for another harness and while no source knows the version.
    let claudeCode: String?
    /// The model's short name (the header segment's source); nil for a session with no reading and no model picked.
    let model: String?
    /// The effort in the CLI's own word, lowercase ("high"); nil when none is known.
    let effort: String?
    let mode: Mode?
    let project: String?
    let branch: String?
    /// The branch it is measured against, when known and not the branch itself.
    let base: String?
    /// The folder as the row shows it ("~/…/loom-v2/wt/ink") and in full (what the copy button copies).
    let folder: String
    let folderPath: String
    /// Nil where the harness's edits are not read (Codex): no section.
    let lastTurn: LastTurn?
    /// Nil for a session that never had a subagent: no section.
    let agents: Agents?

    /// `reportedMode` and `reportedEffort` are the run's own words (the Chat composer's, else the hooks'); `launchedMode` and
    /// `launchedEffort` are the stored launch choices, which hold until the run reports (and for a stopped session).
    init(status: String, createdAt: Date, now: Date, provider: ManagedSession.Provider, claudeVersion: String?, model: String?,
         reportedMode: String?, launchedMode: String?, reportedEffort: String?, launchedEffort: String?,
         project: String?, branch: String?, base: String?, directory: String,
         edits: [ChangesFile]?, readsEdits: Bool, subagents: [SubagentRecord]?, waiting: Set<String> = [],
         home: String = NSHomeDirectory(), calendar: Calendar = .current, locale: Locale = .current) {
        let reportsRun = HarnessCapabilities.intrinsic(of: provider).reportsRunSettings
        self.status = status
        started = LoomDateFormat.started(createdAt, now: now, calendar: calendar, locale: locale)
        claudeCode = reportsRun ? claudeVersion.flatMap { $0.isEmpty ? nil : "Claude Code \($0)" } : nil
        self.model = reportsRun ? model : nil
        effort = reportsRun ? Self.effortWord(reportedEffort ?? launchedEffort) : nil
        mode = reportsRun ? Self.mode(reportedMode ?? launchedMode) : nil
        self.project = project
        self.branch = branch
        self.base = GitBaseBranch.shown(base: base, branch: branch)
        folderPath = directory
        folder = OverviewFolderText.display(directory, home: home)
        if readsEdits {
            let rows = (edits ?? []).map { file in
                FileRow(id: file.id, name: (file.displayPath as NSString).lastPathComponent, path: file.displayPath,
                        added: file.added, removed: file.removed)
            }
            lastTurn = LastTurn(files: Array(rows.prefix(LoomTheme.Overview.maxFiles)),
                                more: max(0, rows.count - LoomTheme.Overview.maxFiles), isRead: edits != nil)
        } else {
            lastTurn = nil
        }
        agents = Self.agents(subagents, now: now, waiting: waiting)
    }

    /// The CLI's word, trimmed and in lowercase ("high", "xhigh"); nil for none.
    static func effortWord(_ raw: String?) -> String? {
        guard let word = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !word.isEmpty else { return nil }
        return word
    }

    /// The mode as Loom names it. `dontAsk` is what Ask runs on (D-63), so it takes Ask's look; a word Loom has no name for
    /// keeps the CLI's own and takes the neutral shield (`ComposerModeLook`).
    static func mode(_ raw: String?) -> Mode? {
        guard let raw, !raw.isEmpty else { return nil }
        let key = raw == ClaudePermissionMode.ask.cliValue ? ClaudePermissionMode.ask.rawValue : raw
        return Mode(title: ClaudePermissionMode.title(forRaw: raw), key: key)
    }

    /// The section is there once the session has had a subagent, with the running ones counted ("Agents · 0 running" after
    /// they finished). Running ones come first, then the interrupted and the finished, each oldest first.
    static func agents(_ records: [SubagentRecord]?, now: Date, waiting: Set<String> = []) -> Agents? {
        guard let records, !records.isEmpty else { return nil }
        let content = InspectorAgentsContent(records: records, now: now, waiting: waiting)
        let live = content.running.filter { $0.note == nil }
        let rest = content.running.filter { $0.note != nil } + content.finished
        let rows = live + rest
        return Agents(running: live.count, rows: Array(rows.prefix(LoomTheme.Overview.maxAgents)),
                      more: max(0, rows.count - LoomTheme.Overview.maxAgents))
    }
}

/// Where the Overview's run facts come from. On the Chat face the composer's own words win: the driver's version, the
/// mode and effort the CLI reported, and the choices it launched with. A terminal session has the hooks' words
/// (`SessionViewState`), then the stored launch choices and the runtime's toolchain probe.
struct OverviewRunWords: Equatable {
    let version: String?
    let reportedMode: String?
    let launchedMode: String?
    let reportedEffort: String?
    let launchedEffort: String?

    static func pick(composer: ChatComposerState?, live: SessionViewState?, launchedVersion: String?,
                     launchedMode: String?, launchedEffort: String?) -> OverviewRunWords {
        OverviewRunWords(
            version: composer?.claudeCodeVersion ?? launchedVersion,
            reportedMode: composer?.permissionMode ?? live?.permissionMode,
            launchedMode: composer?.choices.permissionMode ?? launchedMode,
            reportedEffort: composer?.reportedEffort ?? live?.effort,
            launchedEffort: composer?.choices.effort ?? launchedEffort)
    }
}

/// The words of the Overview's context block (the reference's "38% of the window" over "76.1K of 200K tokens"). The grouped
/// caption of `ContextRingText` stays for the surfaces that use it.
enum OverviewContextText {
    static func headline(_ usage: ContextUsage) -> String {
        usage.percent.map { "\(UsageFormat.percent($0)) of the window" } ?? "\(UsageFormat.tokens(usage.tokens)) tokens"
    }

    static func detail(_ usage: ContextUsage) -> String {
        guard let window = usage.window else { return "Window unknown" }
        return "\(UsageFormat.tokens(usage.tokens)) of \(UsageFormat.tokens(window)) tokens"
    }
}

/// The words of the Overview's Usage block (RESCUE C2): a session's tokens by kind for its main thread and its subagents,
/// their total, and the price table's API equivalent (never a share of the plan).
struct OverviewUsageText: Equatable {
    struct Column: Equatable {
        let title: String
        let input: String
        let cacheWrite: String
        let cacheRead: String
        let output: String
        let cost: String
    }

    let columns: [Column]

    init(_ usage: SessionUsage) {
        func column(_ title: String, _ part: SessionUsage.Part) -> Column {
            Column(title: title, input: UsageFormat.tokens(part.tokens.input), cacheWrite: UsageFormat.tokens(part.tokens.cacheWrite),
                   cacheRead: UsageFormat.tokens(part.tokens.cacheRead), output: UsageFormat.tokens(part.tokens.output),
                   cost: part.estimatedCostUSD.map(UsageFormat.cost) ?? "\u{2014}")
        }
        columns = [column("Main", usage.main), column("Subagents", usage.subagents), column("Total", usage.total)]
    }

    static let costLabel = "API equivalent"
    static let none = "No usage recorded for this session yet."
    static let failed = "The usage could not be read."
}

/// The folder as the Overview shows it: under the home folder as "~", and long paths cut in the middle ("~/…/loom-v2/wt/ink").
enum OverviewFolderText {
    /// The last folders kept after the "…".
    static let tail = 3

    static func display(_ path: String, home: String = NSHomeDirectory()) -> String {
        let shown = abbreviated(path, home: home)
        let parts = shown.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let underHome = shown.hasPrefix("~")
        let names = underHome ? Array(parts.dropFirst()) : parts
        guard names.count > tail else { return shown }
        return (underHome ? "~/\u{2026}/" : "/\u{2026}/") + names.suffix(tail).joined(separator: "/")
    }

    private static func abbreviated(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

extension LoomDateFormat {
    /// When a session started, as the Overview says it: "14:02 today", "Yesterday 09:12", and a date beyond that.
    static func started(_ date: Date, now: Date, zone: TimeZone? = nil, calendar: Calendar = .current,
                        locale: Locale = .current) -> String {
        let time = Self.time(date, zone: zone, locale: locale, calendar: calendar)
        var calendar = calendar
        if let zone { calendar.timeZone = zone }
        if calendar.isDate(date, inSameDayAs: now) { return "\(time) today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        return Self.date(date, zone: zone, locale: locale, calendar: calendar)
    }
}

/// The reason line in words. An approval reads as on every surface (`SessionReasonLine.approvalText`, for example
/// "Asks to run: git push origin fix/webhook-sig"). Built from content, so it is shown here and never logged.
enum InspectorReasonText {
    static func line(_ reason: StatusReason) -> String? {
        switch reason.kind {
        case let .approval(tool):
            return SessionReasonLine.approvalText(tool: tool, detail: reason.detail)
        case .question:
            return reason.detail.map { "Question: \($0)" } ?? "Has a question"
        case .planReady:
            return "Plan ready for review"
        case .input:
            return "Waiting for your input"
        case .turnDone:
            let work = reason.work.isEmpty ? nil : "\(reason.work.total) running in the background"
            return [reason.detail, work].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case let .failure(category):
            return reason.detail ?? category ?? "The turn failed"
        case .automaticTurn:
            return reason.detail ?? "Working on a background task's report"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
