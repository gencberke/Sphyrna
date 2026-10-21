import Foundation

/// The day's brief as Remora keeps it, so Home shows it again after a relaunch the same day: what the brief showed (its text,
/// chips, drafts, cited sessions, proposed facts and footer), the sessions it read and when it started.
public struct RemoraKeptBrief: Equatable, Sendable {
    /// When the brief started (the day it belongs to ends at the next 04:00, `RemoraSchedule.dayStart`).
    public var startedAt: Date
    /// The brief as shown: the model's text without its closing block.
    public var text: String
    public var cited: [String]
    public var chips: [RemoraChip]
    public var drafts: [RemoraDraft]
    /// Facts the brief proposed; empty when Propose things to remember was off.
    public var proposedFacts: [String]
    /// The sessions the pack read, in its order.
    public var readSessionIDs: [UUID]
    /// "read 6 sessions and 3 project notes".
    public var footer: String

    public init(startedAt: Date, text: String, cited: [String] = [], chips: [RemoraChip] = [], drafts: [RemoraDraft] = [],
                proposedFacts: [String] = [], readSessionIDs: [UUID] = [], footer: String = "") {
        self.startedAt = startedAt
        self.text = text
        self.cited = cited
        self.chips = chips
        self.drafts = drafts
        self.proposedFacts = proposedFacts
        self.readSessionIDs = readSessionIDs
        self.footer = footer
    }

    /// A brief that answered, as the host handed it to the app.
    init(_ answer: RemoraHostAnswer, startedAt: Date) {
        self.init(startedAt: startedAt, text: answer.answer.text, cited: answer.answer.cited, chips: answer.answer.chips,
                  drafts: answer.answer.drafts, proposedFacts: answer.proposedFacts, readSessionIDs: answer.readSessionIDs,
                  footer: answer.footer)
    }

    /// Every session the brief names: what deleting a session or excluding its project looks for.
    var sessionIDs: Set<UUID> {
        var ids = Set(readSessionIDs)
        for text in cited + chips.map(\.sessionID) + drafts.map(\.sessionID) { if let id = UUID(uuidString: text) { ids.insert(id) } }
        return ids
    }
}

/// `<data root>/remora/day-brief.json` (0600, written atomically): the one kept brief. `RemoraAnswer` is not `Codable`, so
/// the file has a shape of its own with a `version`. Nothing reads it at launch.
struct RemoraKeptBriefFile: Sendable {
    static let fileName = "day-brief.json"
    static let version = 1

    private struct Stored: Codable {
        struct Chip: Codable {
            var session: String
            var why: String
        }

        struct Draft: Codable {
            var session: String
            var text: String
        }

        var version = RemoraKeptBriefFile.version
        /// Seconds since 1970.
        var startedAt: Double
        var text: String
        var cited: [String]
        var chips: [Chip]
        var drafts: [Draft]
        var facts: [String]
        /// The sessions the pack read.
        var sessions: [String]
        var footer: String
    }

    let url: URL

    init(directory: URL) { url = directory.appendingPathComponent(Self.fileName) }

    /// The kept brief, whatever its day; nil when there is none or this build cannot read it.
    func read() -> RemoraKeptBrief? {
        guard let data = RemoraFiles.read(url), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == Self.version, stored.startedAt.isFinite else { return nil }
        return RemoraKeptBrief(
            startedAt: Date(timeIntervalSince1970: stored.startedAt), text: stored.text, cited: stored.cited,
            chips: stored.chips.map { RemoraChip(sessionID: $0.session, why: $0.why) },
            drafts: stored.drafts.map { RemoraDraft(sessionID: $0.session, text: $0.text) }, proposedFacts: stored.facts,
            readSessionIDs: stored.sessions.compactMap(UUID.init(uuidString:)), footer: stored.footer)
    }

    func write(_ brief: RemoraKeptBrief) throws {
        let stored = Stored(
            startedAt: brief.startedAt.timeIntervalSince1970, text: brief.text, cited: brief.cited,
            chips: brief.chips.map { .init(session: $0.sessionID, why: $0.why) },
            drafts: brief.drafts.map { .init(session: $0.sessionID, text: $0.text) }, facts: brief.proposedFacts,
            sessions: brief.readSessionIDs.map(\.uuidString), footer: brief.footer)
        try RemoraFiles.ensureDirectory(url.deletingLastPathComponent())
        try RemoraFiles.writeAtomically(try JSONEncoder().encode(stored), to: url)
    }

    func remove() { RemoraFiles.remove(url) }
}
