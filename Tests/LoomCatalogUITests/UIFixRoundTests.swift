import AppKit
import Foundation
import SwiftUI
import Testing
import LoomChat
@testable import LoomCore
@testable import LoomCatalogUI

/// Release A UI fix round: the pure rules behind the small fixes (formats, wrapping, wording, snippets, counts).
@MainActor
struct UIFixRoundTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-07 12:00:00 UTC.
    private let noon = Date(timeIntervalSince1970: 1_791_374_400)

    // MARK: Item 5: one set of locale-aware formatters

    /// The locale writes a narrow no-break space before AM and PM; the expectations below write a plain one.
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

    @Test func timesAndDatesFollowTheLocale() {
        let us = Locale(identifier: "en_US"), gb = Locale(identifier: "en_GB"), de = Locale(identifier: "de_DE")
        #expect(plain(LoomDateFormat.time(noon, zone: utc, locale: us)) == "12:00 PM")
        #expect(LoomDateFormat.time(noon, zone: utc, locale: gb) == "12:00")
        #expect(LoomDateFormat.time(noon, zone: utc, locale: de) == "12:00")
        #expect(LoomDateFormat.weekdayDayMonth(noon, zone: utc, locale: us) != LoomDateFormat.weekdayDayMonth(noon, zone: utc, locale: de))
        #expect(LoomDateFormat.fullDate(noon, zone: utc, locale: us) == "Wednesday, October 7")
        #expect(LoomDateFormat.fullDate(noon, zone: utc, locale: de).contains("Oktober"))
        #expect(LoomDateFormat.date(noon, zone: utc, locale: us) == "Oct 7, 2026")
        #expect(LoomDateFormat.dayMonth(noon, zone: utc, locale: us) == "Oct 7")
        #expect(LoomDateFormat.weekday(noon, zone: utc, locale: us) == "Wed")
        #expect(plain(LoomDateFormat.hour(noon, zone: utc, locale: us)) == "12 PM")
        #expect(plain(LoomDateFormat.hour(noon, zone: TimeZone(secondsFromGMT: 19_800)!, locale: us)) == "5:30 PM")
    }

    @Test func everySurfaceReadsTheSameTimeForTheSameMoment() {
        // The usage footer, the chat's message time, the plan limits and the settings all go through one formatter.
        let gb = Locale(identifier: "en_GB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let expected = LoomDateFormat.time(noon, zone: utc, locale: gb)
        #expect(UsageText.time(noon, utc, locale: gb) == expected)
        #expect(ChatTime.label(for: noon, now: noon, calendar: calendar, locale: gb) == expected)
        #expect(UsageText.date(noon, utc, locale: gb) == LoomDateFormat.weekdayDayMonth(noon, zone: utc, locale: gb))
        #expect(UsageText.priceDate("2026-10-07", locale: gb) == LoomDateFormat.date(noon, zone: utc, locale: gb))
        #expect(CatalogRecoveryPrompt.date(noon, utc, locale: gb) == LoomDateFormat.dateTime(noon, zone: utc, locale: gb))
        let day = calendar.startOfDay(for: noon.addingTimeInterval(-3 * 86_400))
        #expect(DayGrouping.title(for: day, now: noon, calendar: calendar, locale: gb)
                == LoomDateFormat.weekdayLong(day, locale: gb, calendar: calendar))
        #expect(DayGrouping.title(for: day, now: noon, calendar: calendar, locale: Locale(identifier: "de_DE")) == "Sonntag")
    }

    @Test func oneFormatterIsMadePerKindLocaleAndZone() {
        let before = LoomDateFormat.formattersCreated
        for step in 0..<50 { _ = LoomDateFormat.time(noon.addingTimeInterval(Double(step) * 60), zone: utc, locale: Locale(identifier: "fr_FR")) }
        #expect(LoomDateFormat.formattersCreated - before <= 1)
    }

    // MARK: Polish: one percent format

    @Test func percentsAreWrittenWithoutASpaceEverywhere() {
        #expect(UsageFormat.percent(41) == "41%")
        #expect(UsageFormat.percent(fraction: 0.414) == "41%")
        #expect(UsageFormat.percent(61, of: 100) == "61%")
        #expect(UsageChipContent.Limit(name: "Wk", remainingPercent: 41).text == "Wk 41%")
        #expect(ContextRingText.label(ContextUsage(tokens: 84_200, window: 200_000, model: "m")) == "84.2K · 42%")
    }

    // MARK: Item 8: items wrap whole, side cards go under the list

    @Test func flowLayoutBreaksBetweenItemsNeverInsideOne() {
        #expect(FlowLayout.lines(widths: [60, 60, 60], spacing: 10, available: 200) == [[0, 1, 2]])
        #expect(FlowLayout.lines(widths: [60, 60, 60], spacing: 10, available: 190) == [[0, 1], [2]])
        #expect(FlowLayout.lines(widths: [150, 60], spacing: 10, available: 100) == [[0], [1]], "an item wider than the line stands alone")
        #expect(FlowLayout.lines(widths: [], spacing: 10, available: 100) == [[]])
    }

    // Moved with the project page's Ink look (DESIGN §10 Side cards, C1): narrow puts Presets above the list and Past 7 days under it,
    // and the Presets card is always there (it used to drop out while the project had no preset).
    @Test func narrowPutsPresetsAboveTheListAndThePastWeekBelowAndTheCardIsAlwaysThere() {
        #expect(ProjectSessionsLayout.arrangement(wide: true) == .init(main: [.list], side: [.presets, .usage]))
        #expect(ProjectSessionsLayout.arrangement(wide: false) == .init(main: [.presets, .list, .usage], side: []))
    }

    // MARK: Item 4: counts say what they count

    @Test func theUsageCountSaysItCountsSessionsWithUsage() {
        #expect(UsageCardText.sessions(2) == "2 sessions with usage")
        #expect(UsageCardText.sessions(1) == "1 session with usage")
    }

    // MARK: Item 9: snippets quote words, not Markdown

    @Test func markdownSyntaxIsStrippedAndWordsStay() {
        let text = "## What happens\n1. `SyncCoordinator` keeps **retries** in a *static* property, see [the notes](https://x.y/z).\n- a snake_case name\n```swift\nlet a = 1\n```\n> quoted"
        let plain = MarkdownPlainText.stripped(text)
        #expect(plain == "What happens\nSyncCoordinator keeps retries in a static property, see the notes.\na snake_case name\nlet a = 1\nquoted")
        #expect(!plain.contains("#") && !plain.contains("**") && !plain.contains("```") && !plain.contains("]("))
    }

    @Test func aSnippetOfAMarkdownMessageHasNoSyntaxAndOneEllipsis() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-snippet-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let body = "Notes first.\n## What happens\n1. `SyncCoordinator` keeps `retries` in a static property. 2. Two tests share it and **both** change it, so one run in ten fails when the order flips and the second reads the first's value. More words follow here to pass the cut."
        let object: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": body]]]]
        let data = try JSONSerialization.data(withJSONObject: object)
        let url = directory.appendingPathComponent("s.jsonl")
        try (String(decoding: data, as: UTF8.self) + "\n").write(to: url, atomically: true, encoding: .utf8)
        let file = PaletteTranscriptFile(sessionID: UUID(), path: url.path, title: "s", project: nil, modified: Date())
        let outcome = PaletteTranscriptScanner.scan(query: "retries", files: [file], budget: .first, shouldStop: { false })
        let snippet = try #require(outcome.hits.first?.snippet)
        let whole = snippet.before + snippet.match + snippet.after
        #expect(snippet.match == "retries")
        #expect(!whole.contains("`") && !whole.contains("**") && !whole.contains("##"), "\(whole)")
        #expect(whole.filter { $0 == "…" }.count <= 2 && !whole.contains("…."), "\(whole)")
        #expect(PaletteTranscriptScanner.edge("tail of it. ", cut: true, leading: false) == "tail of it…")
        #expect(PaletteTranscriptScanner.edge("…. ## head", cut: true, leading: true) == "…## head")
        #expect(PaletteTranscriptScanner.edge("whole", cut: false, leading: true) == "whole")
    }

    // MARK: Item 10: the changed-files card

    @Test func countsHideZerosAndShowBothWhenKnown() {
        #expect(ChatChangeCounts.parts(added: 0, removed: 0).isEmpty, "no counts known: nothing, not +0")
        #expect(ChatChangeCounts.parts(added: 12, removed: 0) == ["+12"])
        #expect(ChatChangeCounts.parts(added: 0, removed: 3) == ["\u{2212}3"])
        #expect(ChatChangeCounts.parts(added: 12, removed: 3) == ["+12", "\u{2212}3"])
    }

    @Test func pathsAreRelativeToTheWorkingFolderWhicheverWayTheSystemFolderIsSpelled() {
        #expect(ChatWork.shorten("/tmp/orbit/Sources/a.swift", workingDirectory: "/private/tmp/orbit") == "Sources/a.swift")
        #expect(ChatWork.shorten("/private/var/x/a.swift", workingDirectory: "/var/x") == "a.swift")
        #expect(ChatWork.shorten("/tmp/other/a.swift", workingDirectory: "/private/tmp/orbit") == "/tmp/other/a.swift")
    }

    @Test func aPathOutsideTheWorkingFolderKeepsItsRootInTheTree() {
        let lines = ChatWork.tree(of: [ChangedFile(path: "/tmp/other/a.swift", added: 1, removed: 0),
                                       ChangedFile(path: "Sources/b.swift", added: 1, removed: 0)])
        #expect(lines.contains { $0.isFolder && $0.name == "/tmp/other/" })
        #expect(lines.contains { $0.isFolder && $0.name == "Sources/" })
    }

    // MARK: Item 11 and 12

    @Test func theViewChipShrinksBelowTheReadingColumn() {
        #expect(ChatViewChip.isCompact(width: 460))
        #expect(!ChatViewChip.isCompact(width: LoomTheme.Chat.chipCompactBelow))
        #expect(!ChatViewChip.isCompact(width: 900))
    }

    @Test func theRecordViewSpeaksOfTheProviderByName() {
        let text = ConversationDetail.resumeExplanation(provider: "Claude")
        #expect(text == "Resume continues this Claude session in its folder. If Claude no longer has it, Sphyrna says so.")
        #expect(!text.lowercased().contains("record") && !text.lowercased().contains("provider"))
    }
}

/// The fixes that show in a hosted view (read from the accessibility tree and the laid-out size).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct UIFixRoundViewTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loom-uifix-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func settle(_ window: NSWindow, rounds: Int = 12) async {
        for _ in 0..<rounds {
            try? await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func host<V: View>(_ view: V, width: CGFloat, height: CGFloat = 700) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return (window, hosting)
    }

    @Test func aStoppedSessionsRecordViewNamesClaudeAndHasNoStopButton() async throws {
        enableAccessibilityTree()
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try SessionCatalog(url: dir.appendingPathComponent("c.sqlite3"))
        let session = ManagedSession(provider: .claude, providerConversationID: "abc-123", workingDirectory: dir.path)
        try await catalog.insertSession(session, title: "Stopped", lifecycle: .idle)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: dir.appendingPathComponent("p.json")))
        await model.start()
        model.select(session.id)
        let row = try #require(model.selectedRow)
        defer { model.stop() }
        let (window, hosting) = host(ConversationDetail(model: model, row: row), width: 700)
        defer { window.contentView = nil; window.close() }
        await settle(window)
        let elements = accessibilityElements(in: hosting)
        let labels = elements.compactMap { $0.accessibilityLabel?() }
        let texts = labels + elements.compactMap { element -> String? in
            let value: Any? = element.accessibilityValue?()
            return value as? String
        }
        let ids = elements.compactMap { $0.accessibilityIdentifier?() }
        #expect(texts.contains { $0.contains("Claude session ID") }, "\(texts)")
        #expect(!texts.contains { $0.contains("Provider session") || $0.contains("this record") })
        #expect(texts.contains(ConversationDetail.resumeExplanation(provider: "Claude")))
        #expect(!ids.contains("record-stop"), "a session that is not running has no Stop")
    }

    @Test func theProjectStatsCountRunningSessionsAndNeverCallThemActive() async throws {
        enableAccessibilityTree()
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: dir.appendingPathComponent("c.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        let session = ManagedSession(provider: .claude, providerConversationID: "c1", workingDirectory: folder.path)
        try await catalog.insertSession(session, title: "Live", lifecycle: .idle, projectID: project.id)
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub, preferences: UIPreferencesStore(url: dir.appendingPathComponent("p.json")))
        await model.start()
        defer { model.stop() }
        await hub.publish(sessionID: session.id, change: .runStarted(UUID()))
        _ = await inspectorWaitUntil { model.liveStates[session.id]?.runID != nil }
        let (window, hosting) = host(ProjectPageView(model: model, projectID: project.id), width: 940)
        defer { window.contentView = nil; window.close() }
        await settle(window, rounds: 20)
        let labels = accessibilityElements(in: hosting).compactMap { $0.accessibilityLabel?() }
        #expect(labels.contains("1 running"), "\(labels)")
        #expect(!labels.contains { $0.hasSuffix(" active") })
    }

    @Test func theDraftQuestionNeverLeavesItsQuestionMarkAloneOnALine() async throws {
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("orbit", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: dir.appendingPathComponent("c.sqlite3"))
        let project = try await catalog.addProject(path: folder.path).project
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(), preferences: UIPreferencesStore(url: dir.appendingPathComponent("p.json")))
        await model.start()
        defer { model.stop() }
        // Wide: one line. Medium (the sentence fits, the whole question does not): two rows, the picker and the question mark
        // together. Narrow (the 780 pt window's pane, 400 inside the side insets): the sentence shrinks, still two rows.
        func height(_ width: CGFloat) async -> CGFloat {
            let (window, hosting) = host(Headline(model: model, projectID: project.id).frame(width: width), width: width, height: 400)
            defer { window.contentView = nil; window.close() }
            await settle(window, rounds: 4)
            return hosting.fittingSize.height
        }
        let wide = await height(900)
        let medium = await height(370)
        let narrow = await height(244)
        // The headline's widths scale with the display size (46 pt when they were measured, 34 pt in v4): 500 and 330 become 370
        // and 244. At 34 pt one row is about 38 pt and the gap between the two rows 8: the old break (the sentence, the picker,
        // then the "?") added two rows, about 84 pt; the question mark with the picker adds one, about 46 pt.
        let row = LoomTheme.Draft.question.size * 1.12
        #expect(medium > wide, "the medium headline wraps (\(wide) -> \(medium))")
        #expect(medium - wide < 2 * row, "one extra row, not two (\(wide) -> \(medium))")
        // The shrunk sentence is a little shorter than the full one, never taller: still two rows, not three.
        #expect(narrow > wide && narrow <= medium && narrow - wide < 2 * row, "the narrow headline shrinks its sentence, it does not add a row (\(medium) -> \(narrow))")
    }
}
