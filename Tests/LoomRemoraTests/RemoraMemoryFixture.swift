import Foundation
@testable import LoomRemora

/// A temporary `remora/` folder, a settable clock and a fixed time zone (Istanbul: UTC+3 all year), for the memory's tests.
final class RemoraMemoryFixture: @unchecked Sendable {
    let directory: URL
    let zone = TimeZone(identifier: "Europe/Istanbul")!
    private let lock = NSLock()
    private var current: Date

    init(now: (year: Int, month: Int, day: Int, hour: Int) = (2026, 10, 21, 12)) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("remora-memory-\(UUID())", isDirectory: true)
        current = Date(timeIntervalSince1970: 0)
        current = date(now.year, now.month, now.day, now.hour)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A day `age` days before the clock, at `hour`.
    func daysAgo(_ age: Int, hour: Int = 10, minute: Int = 0) -> Date {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -age, to: start)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    func open() throws -> RemoraMemory {
        try RemoraMemory(directory: directory, timeZone: zone, clock: { [self] in now })
    }

    func file(_ path: String) -> URL { directory.appendingPathComponent(path) }

    func names(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: file(folder).path)) ?? []).sorted()
    }

    func text(_ path: String) -> String? { try? String(contentsOf: file(path), encoding: .utf8) }

    func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file(path).path)[.posixPermissions]) as? Int) ?? -1
    }

    /// Writes a day's file straight to disk (a history made before the store existed).
    func writeDay(_ age: Int, _ entries: [RemoraJournalEntry]) throws {
        let day = RemoraDay(daysAgo(age), calendar: calendar)
        try FileManager.default.createDirectory(at: file("journal"), withIntermediateDirectories: true)
        let text = entries.map { $0.line(timeZone: zone) }.joined(separator: "\n") + "\n"
        try text.write(to: file("journal/\(day.string).md"), atomically: true, encoding: .utf8)
    }

    func entry(_ age: Int = 0, hour: Int = 10, kind: RemoraKind = .question, question: String? = "What moved?", answer: String = "Two sessions moved.",
               sessions: [UUID] = [], summary: String? = nil) -> RemoraJournalEntry {
        RemoraJournalEntry.make(kind: kind, question: question, answerText: answer, sessions: sessions, model: "claude-sonnet-5-5",
                                tokens: 100, summary: summary, date: daysAgo(age, hour: hour))
    }
}
