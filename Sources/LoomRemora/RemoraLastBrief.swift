import Foundation

/// When the last brief started, kept in `<data root>/remora/last-brief.json` (0600, written atomically) so a relaunched app
/// does not run the day's brief again (`RemoraSchedule` is pure; its `lastBrief` is this). Nothing reads it at launch.
struct RemoraLastBrief: Sendable {
    static let fileName = "last-brief.json"

    private struct Stored: Codable {
        var version = 1
        /// Seconds since 1970.
        var lastBrief: Double
    }

    let url: URL

    init(directory: URL) { url = directory.appendingPathComponent(Self.fileName) }

    func read() -> Date? {
        guard let data = RemoraFiles.read(url), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.lastBrief.isFinite else { return nil }
        return Date(timeIntervalSince1970: stored.lastBrief)
    }

    /// Records `date`; nil removes the record (the day's slot is free again).
    func write(_ date: Date?) throws {
        guard let date else { RemoraFiles.remove(url); return }
        try RemoraFiles.ensureDirectory(url.deletingLastPathComponent())
        try RemoraFiles.writeAtomically(try JSONEncoder().encode(Stored(lastBrief: date.timeIntervalSince1970)), to: url)
    }
}
