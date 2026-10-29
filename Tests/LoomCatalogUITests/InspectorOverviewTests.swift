import Foundation
import LoomChat
import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// The inspector's Overview as plain values: which rows a session has, where each value comes from when more than one source
/// knows it, and the words (the start, the folder, the context). No view and no window.
struct InspectorOverviewTests {
    private static let zone = TimeZone(identifier: "Europe/Istanbul")!
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static let locale = Locale(identifier: "en_GB")
    /// 21 Oct 2026, 15:30 in Istanbul.
    private static let now = Date(timeIntervalSince1970: 1_792_585_800)

    /// A Claude session in a project on a named branch, with nothing else known.
    static func content(
        provider: ManagedSession.Provider = .claude, created: Date = now.addingTimeInterval(-3_600), claudeVersion: String? = nil,
        model: String? = nil, reportedMode: String? = nil, launchedMode: String? = nil, reportedEffort: String? = nil,
        launchedEffort: String? = nil, project: String? = "loom", branch: String? = "ui/ink-sidebar", base: String? = "main",
        directory: String = "/Users/me/Library/Caches/loom-v2/wt/ink", edits: [ChangesFile]? = nil, readsEdits: Bool = true,
        subagents: [SubagentRecord]? = nil
    ) -> InspectorOverviewContent {
        InspectorOverviewContent(
            status: "Working", createdAt: created, now: now, provider: provider, claudeVersion: claudeVersion, model: model,
            reportedMode: reportedMode, launchedMode: launchedMode, reportedEffort: reportedEffort, launchedEffort: launchedEffort,
            project: project, branch: branch, base: base, directory: directory, edits: edits, readsEdits: readsEdits,
            subagents: subagents, home: "/Users/me", calendar: calendar, locale: locale)
    }

    private func file(_ path: String, _ added: Int, _ removed: Int) -> ChangesFile {
        ChangesFile(id: "/w/\(path)", displayPath: path, absolutePath: "/w/\(path)", added: added, removed: removed)
    }

    // MARK: The session's rows

    @Test func aClaudeSessionShowsItsVersionModelEffortAndMode() {
        let content = Self.content(claudeVersion: "2.1.300", model: "Opus 5.5", reportedMode: "default", reportedEffort: "high")
        #expect(content.claudeCode == "Claude Code 2.1.300")
        #expect(content.model == "Opus 5.5" && content.effort == "high")
        #expect(content.mode == InspectorOverviewContent.Mode(title: "Ask before edits", key: "default"))
        #expect(content.status == "Working")
    }

    @Test func anUnknownVersionModelAndModeLeaveTheirRowsOut() {
        let content = Self.content()
        #expect(content.claudeCode == nil && content.model == nil && content.effort == nil && content.mode == nil)
        #expect(Self.content(claudeVersion: "").claudeCode == nil, "an empty answer is no version")
    }

    @Test func theEffortIsTheCLIsWordInLowercase() {
        #expect(Self.content(reportedEffort: "High").effort == "high")
        #expect(Self.content(reportedEffort: "xhigh").effort == "xhigh", "not the composer's 'Extra high'")
        #expect(Self.content(reportedEffort: "  ").effort == nil)
    }

    @Test func theRunsOwnModeAndEffortWinOverTheStoredLaunchChoices() {
        let live = Self.content(reportedMode: "acceptEdits", launchedMode: "default", reportedEffort: "max", launchedEffort: "low")
        #expect(live.mode?.title == "Accept edits" && live.effort == "max")
        // Until the run reports, the stored choices hold.
        let stored = Self.content(launchedMode: "plan", launchedEffort: "low")
        #expect(stored.mode?.title == "Plan" && stored.effort == "low")
    }

    /// On the Chat face the composer's words win: the driver's version, the mode and effort the CLI reported, and the
    /// choices it launched with. Without a composer, the hooks' words and the stored choices.
    @Test func onTheChatFaceTheComposersWordsWinOverTheHooksAndTheStoredChoices() {
        let live = SessionViewState(permissionMode: "acceptEdits", effort: "high")
        var composer = ChatComposerState.idle(sessionID: UUID())
        composer.claudeCodeVersion = "2.1.301"
        composer.permissionMode = "plan"
        composer.reportedEffort = "max"
        composer.choices = ClaudeLaunchChoices(permissionMode: "bypassPermissions", effort: "xhigh")
        let chat = OverviewRunWords.pick(composer: composer, live: live, launchedVersion: "2.1.300", launchedMode: "default",
                                         launchedEffort: "low")
        #expect(chat == OverviewRunWords(version: "2.1.301", reportedMode: "plan", launchedMode: "bypassPermissions",
                                         reportedEffort: "max", launchedEffort: "xhigh"))

        // A composer that knows nothing yet falls through to the hooks and the stored choices.
        let early = OverviewRunWords.pick(composer: .idle(sessionID: UUID()), live: live, launchedVersion: "2.1.300",
                                          launchedMode: "default", launchedEffort: "low")
        #expect(early == OverviewRunWords(version: "2.1.300", reportedMode: "acceptEdits", launchedMode: "default",
                                          reportedEffort: "high", launchedEffort: "low"))

        let terminal = OverviewRunWords.pick(composer: nil, live: live, launchedVersion: nil, launchedMode: "default",
                                             launchedEffort: "low")
        #expect(terminal == OverviewRunWords(version: nil, reportedMode: "acceptEdits", launchedMode: "default",
                                             reportedEffort: "high", launchedEffort: "low"))
    }

    @Test func aModeKeepsItsLookAndAWordLoomDoesNotKnowKeepsTheCLIsOwn() {
        #expect(InspectorOverviewContent.mode("bypassPermissions") == .init(title: "Full access", key: "bypassPermissions"))
        // `dontAsk` is Ask's word to the CLI: it reads "Ask" and takes Ask's look.
        #expect(InspectorOverviewContent.mode("dontAsk") == .init(title: "Ask", key: "ask"))
        #expect(InspectorOverviewContent.mode("someNewMode") == .init(title: "someNewMode", key: "someNewMode"))
        #expect(ComposerModeLook.symbol(forRaw: "someNewMode") == "shield", "an unnamed mode takes the plain shield")
        #expect(ComposerModeLook.symbol(forRaw: InspectorOverviewContent.mode("default")?.key) == "shield")
        #expect(ComposerModeLook.symbol(forRaw: InspectorOverviewContent.mode("dontAsk")?.key) == "bubble.left")
        #expect(InspectorOverviewContent.mode(nil) == nil)
    }

    @Test func aCodexSessionKeepsWhatItAlwaysHadAndNothingNew() {
        let content = Self.content(provider: .codex, claudeVersion: "2.1.300", model: "Opus 5.5", reportedMode: "default",
                                   reportedEffort: "high", readsEdits: false, subagents: nil)
        #expect(content.claudeCode == nil && content.model == nil && content.effort == nil && content.mode == nil)
        #expect(content.lastTurn == nil, "Codex's edits are not read")
        #expect(content.agents == nil)
        #expect(content.project == "loom" && content.branch == "ui/ink-sidebar" && !content.started.isEmpty)
    }

    // MARK: Started

    @Test func theStartIsTodayYesterdayOrADate() {
        func started(_ date: Date) -> String {
            LoomDateFormat.started(date, now: Self.now, calendar: Self.calendar, locale: Self.locale)
        }
        // 14:02 on the same day; 09:12 the day before; a date beyond.
        let today = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 14, minute: 2))!
        let yesterday = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9, minute: 12))!
        let older = Self.calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9, minute: 12))!
        #expect(started(today) == "14:02 today")
        #expect(started(yesterday) == "Yesterday 09:12")
        #expect(started(older) == LoomDateFormat.date(older, locale: Self.locale, calendar: Self.calendar))
        #expect(!started(older).contains("today") && !started(older).contains("Yesterday"))
        // The session's creation, not its last activity: the content reads `createdAt`.
        #expect(Self.content(created: today).started == "14:02 today")
    }

    // MARK: Worktree

    @Test func theBranchPointsAtItsBaseUnlessItIsTheBaseOrTheBaseIsUnknown() {
        #expect(Self.content(branch: "ui/ink-sidebar", base: "main").base == "main")
        #expect(Self.content(branch: "main", base: "main").base == nil, "the branch is the base")
        #expect(Self.content(branch: "ui/x", base: nil).base == nil)
        #expect(Self.content(branch: nil, base: "main").branch == nil)
    }

    @Test func theFolderIsCutInTheMiddleAndCopiesInFull() {
        let content = Self.content(directory: "/Users/me/Library/Caches/loom-v2/wt/ink")
        #expect(content.folder == "~/\u{2026}/loom-v2/wt/ink")
        #expect(content.folderPath == "/Users/me/Library/Caches/loom-v2/wt/ink")
        #expect(OverviewFolderText.display("/Users/me/code/app", home: "/Users/me") == "~/code/app")
        #expect(OverviewFolderText.display("/Users/me", home: "/Users/me") == "~")
        #expect(OverviewFolderText.display("/var/folders/a/b/c/d", home: "/Users/me") == "/\u{2026}/b/c/d")
        #expect(OverviewFolderText.display("/opt/app", home: "/Users/me") == "/opt/app")
        #expect(OverviewFolderText.display("/Users/mebob/a/b/c/d", home: "/Users/me") == "/\u{2026}/b/c/d", "a sibling of home is not home")
    }

    // MARK: Changes, last turn

    @Test func theLastTurnListsTheFilesByNameWithTheirCounts() {
        let content = Self.content(edits: [file("Sources/LoomCatalogUI/SidebarRow.swift", 31, 12), file("Tests/SidebarInkTests.swift", 46, 0)])
        let last = content.lastTurn
        #expect(last?.isRead == true && last?.isEmpty == false && last?.more == 0)
        #expect(last?.files.map(\.name) == ["SidebarRow.swift", "SidebarInkTests.swift"])
        #expect(last?.files.map(\.added) == [31, 46] && last?.files.map(\.removed) == [12, 0])
        #expect(last?.files.first?.path == "Sources/LoomCatalogUI/SidebarRow.swift", "the path is the tooltip")
    }

    @Test func anEmptyLastTurnSaysSoOnlyOnceItWasRead() {
        #expect(Self.content(edits: nil).lastTurn?.isRead == false && Self.content(edits: nil).lastTurn?.isEmpty == false)
        #expect(Self.content(edits: []).lastTurn?.isEmpty == true)
    }

    @Test func aLongLastTurnIsCutAndCounted() {
        let files = (0..<9).map { file("a/f\($0).swift", 1, 0) }
        let last = Self.content(edits: files).lastTurn
        #expect(last?.files.count == LoomTheme.Overview.maxFiles && last?.more == 3)
    }

    // MARK: Agents

    @Test func theAgentsSectionFollowsTheRecords() {
        #expect(Self.content(subagents: nil).agents == nil && Self.content(subagents: []).agents == nil)
        let running = Self.content(subagents: [inspectorRecord("a"), inspectorRecord("b", running: false)]).agents
        #expect(running?.running == 1 && running?.headline == "1 running" && running?.rows.count == 2)
        let none = Self.content(subagents: [inspectorRecord("b", running: false)]).agents
        #expect(none?.running == 0 && none?.headline == "0 running")
    }

    // MARK: Context

    @Test func theContextSaysTheShareAndTheCompactTokens() {
        let known = ContextUsage(tokens: 76_100, window: 200_000, model: "claude-opus-5-5")
        #expect(OverviewContextText.headline(known) == "38% of the window")
        #expect(OverviewContextText.detail(known) == "76.1K of 200K tokens")
        let unknown = ContextUsage(tokens: 84_200, window: nil, model: "m")
        #expect(OverviewContextText.headline(unknown) == "84.2K tokens")
        #expect(OverviewContextText.detail(unknown) == "Window unknown")
        #expect(OverviewContextText.detail(ContextUsage(tokens: 940, window: 1_000_000, model: "m")) == "940 of 1M tokens")
        // The grouped caption stays for the surfaces that use it.
        #expect(ContextRingText.caption(ContextUsage(tokens: 84_200, window: 200_000, model: "m")) == "84,200 of 200,000 tokens")
    }
}

/// The base branch is read from the repository's files, no process: `origin/HEAD`, else a local `main` or `master`.
struct GitBaseBranchTests {
    private func repo(_ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-base-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/refs/heads"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/feature\n".utf8).write(to: root.appendingPathComponent(".git/HEAD"))
        try build(root.appendingPathComponent(".git"))
        return root
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    @Test func originsHeadNamesTheBase() throws {
        let root = try repo { git in
            try write("ref: refs/remotes/origin/develop\n", to: git.appendingPathComponent("refs/remotes/origin/HEAD"))
            try write("abc\n", to: git.appendingPathComponent("refs/heads/main"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GitBaseBranch.read(directory: root.path) == "develop", "origin/HEAD wins over a local main")
        // From a folder inside the repository.
        let inner = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(GitBaseBranch.read(directory: inner.path) == "develop")
    }

    @Test func withoutAnOriginALocalMainThenMasterIsTheBase() throws {
        let main = try repo { git in try write("abc\n", to: git.appendingPathComponent("refs/heads/main")) }
        let master = try repo { git in try write("abc\n", to: git.appendingPathComponent("refs/heads/master")) }
        let both = try repo { git in
            try write("abc\n", to: git.appendingPathComponent("refs/heads/master"))
            try write("abc\n", to: git.appendingPathComponent("refs/heads/main"))
        }
        defer { for url in [main, master, both] { try? FileManager.default.removeItem(at: url) } }
        #expect(GitBaseBranch.read(directory: main.path) == "main")
        #expect(GitBaseBranch.read(directory: master.path) == "master")
        #expect(GitBaseBranch.read(directory: both.path) == "main")
    }

    @Test func aPackedBranchCounts() throws {
        let root = try repo { git in
            try write("# pack-refs with: peeled fully-peeled sorted\nabc123 refs/heads/master\ndef456 refs/heads/feature\n",
                      to: git.appendingPathComponent("packed-refs"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GitBaseBranch.read(directory: root.path) == "master")
    }

    @Test func aRepositoryWithNeitherAndAFolderOutsideOneHaveNoBase() throws {
        let bare = try repo { _ in }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("loom-nobase-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { for url in [bare, outside] { try? FileManager.default.removeItem(at: url) } }
        #expect(GitBaseBranch.read(directory: bare.path) == nil)
        #expect(GitBaseBranch.read(directory: outside.path) == nil)
        #expect(GitBaseBranch.read(directory: "") == nil)
    }

    @Test func aLinkedWorktreeReadsTheMainRepositorysRefs() throws {
        let main = try repo { git in
            try write("ref: refs/remotes/origin/main\n", to: git.appendingPathComponent("refs/remotes/origin/HEAD"))
            try write("../..\n", to: git.appendingPathComponent("worktrees/wt/commondir"))
        }
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("loom-wt-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try write("gitdir: \(main.path)/.git/worktrees/wt\n", to: worktree.appendingPathComponent(".git"))
        defer { for url in [main, worktree] { try? FileManager.default.removeItem(at: url) } }
        #expect(GitBaseBranch.read(directory: worktree.path) == "main")
    }

    @Test func theBaseIsShownOnlyWhenItIsKnownAndNotTheBranchItself() {
        #expect(GitBaseBranch.shown(base: "main", branch: "feature") == "main")
        #expect(GitBaseBranch.shown(base: "main", branch: "main") == nil)
        #expect(GitBaseBranch.shown(base: nil, branch: "main") == nil)
        #expect(GitBaseBranch.shown(base: "", branch: "x") == nil)
    }
}
