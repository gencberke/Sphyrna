import Foundation
import Testing
import LoomCore
@testable import LoomCatalogUI

@MainActor
struct DisplayAndPreferencesTests {
    private func record(lifecycle: SessionLifecycle = .active, title: String? = nil,
                        project: UUID? = nil, used: TimeInterval = 0) -> CatalogSession {
        CatalogSession(
            session: ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: title,
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: used),
            lifecycle: lifecycle, pinned: false, projectID: project
        )
    }

    @Test func indicatorSeparatesRunsFromLifecycleAndNeverInventsAFinish() {
        let run = UUID()
        func live(_ activity: AgentActivity?, pending: Int = 0, unviewed: Bool = false, failure: String? = nil,
                  runID: UUID? = run) -> SessionViewState {
            SessionViewState(status: activity.map { ProviderWorkState(activity: $0, pendingProviderWorkCount: pending) },
                             runID: runID, stopFailure: failure, unviewedCompletion: unviewed)
        }
        let base = record()
        #expect(SessionIndicator(record: base, live: nil) == .ended)
        #expect(SessionIndicator(record: record(lifecycle: .idle), live: nil) == .idle)
        #expect(SessionIndicator(record: record(lifecycle: .stale), live: nil) == .stale)
        #expect(SessionIndicator(record: base, live: live(nil)) == .unknown)
        #expect(SessionIndicator(record: base, live: live(.unknown)) == .unknown)
        // A Claude that just started or resumed sits at its prompt: ready, nothing to attend to.
        #expect(SessionIndicator(record: base, live: live(.atPrompt)) == .ready)
        #expect(SessionIndicator.ready.label == "Ready" && !SessionIndicator.ready.needsAttention)
        #expect(SessionIndicator(record: base, live: live(.working)) == .working)
        #expect(SessionIndicator(record: base, live: live(.waitingForApproval)) == .waitingForApproval)
        #expect(SessionIndicator(record: base, live: live(.waitingForInput)) == .waitingForInput)
        #expect(SessionIndicator(record: base, live: live(.failed("boom"))) == .failed("boom"))
        #expect(SessionIndicator(record: base, live: live(.turnComplete)) == .ready)
        #expect(SessionIndicator(record: base, live: live(.turnComplete, unviewed: true)) == .unviewedCompletion)
        // A finished turn with provider work still pending is not "finished".
        #expect(SessionIndicator(record: base, live: live(.turnComplete, pending: 2, unviewed: true)) == .working)
        // An unverified stop wins over everything, with or without a live run.
        #expect(SessionIndicator(record: base, live: live(.turnComplete, failure: "x")) == .stopUnverified("x"))
        #expect(SessionIndicator(record: record(lifecycle: .idle), live: live(nil, failure: "y", runID: nil))
                == .stopUnverified("y"))
        // The run ended; the idle lifecycle from the catalog shows, and a reliable unseen finish survives.
        #expect(SessionIndicator(record: record(lifecycle: .idle), live: live(nil, runID: nil)) == .idle)
        #expect(SessionIndicator(record: base, live: live(nil, unviewed: true, runID: nil)) == .unviewedCompletion)
        // Hub lifecycle overrides the row only when the hub reported one.
        #expect(SessionIndicator(record: base, live: SessionViewState(lifecycle: .stale)) == .stale)
    }

    @Test func defaultTitleUsesProviderAndProject() {
        #expect(record(title: "Mine").displayTitle(projectName: "p") == "Mine")
        #expect(record().displayTitle(projectName: "rocket") == "Claude · rocket")
        #expect(record(title: "").displayTitle(projectName: nil) == "Claude · No project")
    }

    @Test func relativeTimeIsLastUseNotWorkingTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func text(_ seconds: TimeInterval) -> String { RelativeTime.string(from: now.addingTimeInterval(-seconds), to: now) }
        #expect(text(5) == "now")
        #expect(text(29 * 60) == "29m")
        #expect(text(3 * 3_600) == "3h")
        #expect(text(2 * 86_400) == "2d")
        #expect(text(15 * 86_400) == "2w")
        #expect(text(400 * 86_400) == "1y")
        #expect(RelativeTime.string(from: now.addingTimeInterval(60), to: now) == "now")
    }

    @Test func activityRowsGroupIntoCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12))!
        func row(_ daysAgo: Double, hour: Double = 0) -> SessionRowModel {
            SessionRowModel(record: record(used: now.timeIntervalSince1970 - daysAgo * 86_400 - hour * 3_600), live: nil)
        }
        let sections = DayGrouping.sections(
            [row(0), row(0, hour: 1), row(1), row(1, hour: 2), row(3), row(40)], now: now, calendar: calendar
        )
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Friday", "Aug 19"])
        #expect(sections.map(\.rows.count) == [2, 2, 1, 1])
    }

    // MARK: Preferences

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("loom-prefs-\(UUID())", isDirectory: true)
            .appendingPathComponent("ui-preferences.json")
    }

    @Test func preferencesRoundTripClampAndWriteOnlyWhenChanged() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = UIPreferencesStore(url: url)
        #expect(store.current == UIPreferences())
        #expect(!FileManager.default.fileExists(atPath: url.path)) // nothing written for defaults

        let id = UUID()
        try store.update { $0.viewMode = .projects; $0.selectedSessionID = id; $0.sidebarWidth = 9_999 }
        #expect(store.current.sidebarWidth == 520)
        let reloaded = UIPreferencesStore(url: url)
        #expect(reloaded.current == store.current)
        #expect(reloaded.current.viewMode == .projects && reloaded.current.selectedSessionID == id)

        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.03)
        try store.update { $0.viewMode = .projects } // same value
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == modified)
        try store.update { $0.sidebarWidth = 10 }
        #expect(store.current.sidebarWidth == 220)
    }

    @Test func openTabsPersistAndDecodeTolerantly() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ids = (0..<10).map { _ in UUID() }
        let store = UIPreferencesStore(url: url)
        #expect(store.current.openTabs.isEmpty)
        // Duplicates collapse (first wins) and the list is capped when written.
        try store.update { $0.openTabs = [ids[0], ids[1], ids[0]] + ids }
        #expect(store.current.openTabs == Array(ids.prefix(UIPreferences.maxOpenTabs)))
        #expect(UIPreferencesStore(url: url).current.openTabs == store.current.openTabs)

        // A hand-edited file: bad entries drop only themselves; a wrong type or a missing key means no tabs.
        let tolerant = temporaryFile()
        defer { try? FileManager.default.removeItem(at: tolerant.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: tolerant.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"openTabs": ["\#(ids[2])", "not-a-uuid", 7, "\#(ids[2])", "\#(ids[3])"] }"#
        try Data(json.utf8).write(to: tolerant)
        #expect(UIPreferencesStore(url: tolerant).current.openTabs == [ids[2], ids[3]])
        try Data(#"{"openTabs": "nope"}"#.utf8).write(to: tolerant)
        #expect(UIPreferencesStore(url: tolerant).current.openTabs.isEmpty)
        try Data(#"{"viewMode": "projects"}"#.utf8).write(to: tolerant)
        let missing = UIPreferencesStore(url: tolerant)
        #expect(missing.current.openTabs.isEmpty && missing.current.viewMode == .projects)
    }

    @Test func deferredPreferenceChangesStayInMemoryUntilFlushed() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = UIPreferencesStore(url: url)
        let id = UUID()
        store.apply { $0.selectedSessionID = id }
        #expect(store.current.selectedSessionID == id)
        #expect(!FileManager.default.fileExists(atPath: url.path) && store.writeCount == 0)
        try store.flush()
        try store.flush() // nothing new: no second write
        #expect(store.writeCount == 1)
        #expect(UIPreferencesStore(url: url).current.selectedSessionID == id)
    }

    @Test func unreadablePreferencesAreKeptAsideAndDefaultsUsed() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let store = UIPreferencesStore(url: url)
        #expect(store.current == UIPreferences())
        #expect(store.loadNotice?.contains("unreadable") == true)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.hasPrefix("ui-preferences.unreadable-") })

        // Unknown and missing keys are tolerated.
        let tolerant = temporaryFile()
        defer { try? FileManager.default.removeItem(at: tolerant.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: tolerant.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"futureKey": 7, "viewMode": "projects", "sidebarWidth": "wide"}"#.utf8).write(to: tolerant)
        let loaded = UIPreferencesStore(url: tolerant)
        #expect(loaded.current.viewMode == .projects)
        #expect(loaded.current.sidebarWidth == UIPreferences.defaultSidebarWidth)
    }

    @Test func preferencesWriteFailureIsReportedNotSwallowed() throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("loom-prefs-file-\(UUID())")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = UIPreferencesStore(url: blocker.appendingPathComponent("ui-preferences.json"))
        #expect(throws: (any Error).self) { try store.update { $0.viewMode = .projects } }
    }
}
