import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora

/// L2a: the persisted use, and what the diagnostics export leaves out.
struct RemoraUsageStoreTests {
    @Test func useSurvivesAReopenAndKeepsFourteenDays() async throws {
        // A clock walks 20 days; each day has one question and one brief.
        let walker = try RemoraMemoryFixture(now: (2026, 10, 2, 12))
        defer { walker.remove() }
        var usage = RemoraUsage(calendar: walker.calendar, clock: { walker.now }, persistedAt: walker.file("usage.json"))
        for day in 0..<20 {
            walker.now = walker.date(2026, 10, 2, 12).addingTimeInterval(Double(day) * 86_400)
            usage.recordStart(.question)
            usage.recordStart(.brief)
            usage.recordResult(tokens: RemoraTokenUsage(input: 1, cacheCreation: 2, cacheRead: 3, output: 4, cacheCreation5m: 1, cacheCreation1h: 1), costUSD: 0.25)
        }
        #expect(usage.days.count == 14)
        #expect(usage.today.questions == 1 && usage.today.briefs == 1 && usage.today.calls == 2)

        usage = RemoraUsage(calendar: walker.calendar, clock: { walker.now }, persistedAt: walker.file("usage.json"))
        #expect(usage.days.count == 14)
        let today = usage.today
        #expect(today.questions == 1 && today.briefs == 1 && abs(today.costUSD - 0.25) < 1e-9)
        #expect(today.tokens == RemoraTokenUsage(input: 1, cacheCreation: 2, cacheRead: 3, output: 4, cacheCreation5m: 1, cacheCreation1h: 1))
        #expect(usage.days.first?.start == walker.calendar.startOfDay(for: walker.date(2026, 10, 8, 12)))
        #expect(walker.mode("usage.json") == 0o600)
        let raw = try #require(walker.text("usage.json"))
        #expect(raw.contains("\"day\":\"2026-10-21\"") && !raw.contains("2026-10-07"), "the 15th day back is gone")

        // The next day starts at zero and yesterday joins the history.
        walker.now = walker.date(2026, 10, 22, 8)
        #expect(usage.today.calls == 0 && usage.days.count == 13 && usage.days.last?.calls == 2)
    }

    @Test func aDayBoundaryHoldsAcrossAReopen() throws {
        let fixture = try RemoraMemoryFixture(now: (2026, 10, 21, 23))
        defer { fixture.remove() }
        var usage = RemoraUsage(calendar: fixture.calendar, clock: { fixture.now }, persistedAt: fixture.file("usage.json"))
        usage.recordStart(.question)
        fixture.now = fixture.date(2026, 10, 22, 0, 30)
        usage = RemoraUsage(calendar: fixture.calendar, clock: { fixture.now }, persistedAt: fixture.file("usage.json"))
        #expect(usage.today.calls == 0)
        #expect(usage.days.map(\.questions) == [1])
    }

    @Test func aCorruptOrMissingFileStartsEmpty() throws {
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try "not json".write(to: fixture.file("usage.json"), atomically: true, encoding: .utf8)
        let usage = RemoraUsage(calendar: fixture.calendar, clock: { fixture.now }, persistedAt: fixture.file("usage.json"))
        #expect(usage.today.calls == 0 && usage.days.isEmpty)
        usage.recordStart(.brief)
        #expect(RemoraUsage(calendar: fixture.calendar, clock: { fixture.now }, persistedAt: fixture.file("usage.json")).today.briefs == 1)
    }

    @Test func theDiagnosticsExportOfADataRootThatHoldsRemoraHoldsNoneOfIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remora-diag-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try RemoraMemoryFixture()
        defer { fixture.remove() }
        // The store lives where the app puts it: <data root>/remora/.
        let memory = try RemoraMemory(directory: root.appendingPathComponent("remora", isDirectory: true), timeZone: fixture.zone, clock: { fixture.now })
        let project = UUID()
        try await memory.appendJournal(fixture.entry(0, question: "ZEBRA-QUESTION", answer: "ZEBRA-ANSWER."))
        try await memory.replaceNote(project: project, items: [RemoraNoteItem(text: "ZEBRA-NOTE", sessions: [UUID()])])
        memory.usage.recordStart(.question)
        try await memory.replaceNote(project: project, items: [RemoraNoteItem(text: "ZEBRA-NOTE", sessions: [UUID()])])

        let summary = DiagnosticsSummary(
            generatedAt: Date(), application: .init(version: "1", build: nil, macOS: "test"), claudeCLI: nil,
            catalog: nil, usage: nil, planLimitsFailure: nil, hooks: HookCounterSnapshot(), log: nil)
        let folder = root.appendingPathComponent("diagnostics/exports/\(DiagnosticsExport.folderPrefix)test", isDirectory: true)
        let log: DiagnosticsExport.LogRunner = { output in
            try? Data("{}\n".utf8).write(to: output)
            return .collected(bytes: 3, truncated: false)
        }
        try await DiagnosticsExport.collect(to: folder, dataRoot: root, summary: summary, log: log)
        var everything = ""
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            everything += (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        #expect(!everything.contains("ZEBRA") && !everything.contains(project.uuidString) && !everything.contains("remora"))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains { $0.contains("remora") || $0 == "usage.json" })
    }
}
