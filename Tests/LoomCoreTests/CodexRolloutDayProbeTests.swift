import Foundation
import Testing
@testable import LoomCore

/// Codex names a rollout's day folder by local time when it creates the thread, and its thread ids are UUIDv7 (the first 48
/// bits are Unix milliseconds), so a lookup reads that folder and its neighbours instead of the whole history. The homes
/// below are synthetic; their history is larger than the lookup's entry budget.
@Suite struct CodexRolloutDayProbeTests {
    private static let budget = 1_000

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-day-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A UUIDv7 whose timestamp is local noon of the given day.
    private func v7(_ year: Int, _ month: Int, _ day: Int) throws -> String {
        let date = try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
        let milliseconds = UInt64(date.timeIntervalSince1970 * 1000)
        var bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        for index in 0..<6 { bytes[index] = UInt8((milliseconds >> (8 * UInt64(5 - index))) & 0xff) }
        bytes[6] = 0x70 | (bytes[6] & 0x0f)
        bytes[8] = 0x80 | (bytes[8] & 0x3f)
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString.lowercased()
    }

    private func folder(_ home: URL, _ day: String) throws -> URL {
        let url = home.appendingPathComponent("sessions/" + day, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func rollout(_ home: URL, day: String, id: String) throws -> URL {
        let file = try folder(home, day).appendingPathComponent("rollout-\(day.replacingOccurrences(of: "/", with: "-"))T12-00-00-\(id).jsonl")
        try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/fixture\"}}\n"
            .write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Two years of other runs (rollout names of other ids, never opened) plus `perDay` of them in each given day.
    private func history(_ home: URL, days: [String], perDay: Int = 4) throws {
        var all = days
        for year in 2024...2025 { for month in 1...12 { for day in 1...28 { all.append(String(format: "%04d/%02d/%02d", year, month, day)) } } }
        for day in all {
            let url = try folder(home, day)
            for _ in 0..<perDay {
                let name = "rollout-\(day.replacingOccurrences(of: "/", with: "-"))T08-00-00-\(UUID().uuidString.lowercased()).jsonl"
                #expect(FileManager.default.createFile(atPath: url.appendingPathComponent(name).path, contents: nil))
            }
        }
    }

    @Test func aV7IdIsFoundInItsDayFolderWithoutWalkingTheHistory() throws {
        let home = try root()
        defer { try? FileManager.default.removeItem(at: home) }
        let days = ["2026/10/27", "2026/10/28", "2026/10/29"]
        try history(home, days: days)
        let id = try v7(2026, 10, 28)
        let file = try rollout(home, day: "2026/10/28", id: id)
        let found = CodexRolloutLocator.locate(sessionIDs: [id], home: home, maximumEntries: Self.budget)
        #expect(found.complete)
        #expect(found.files[id]?.path == file.path)
        // home, sessions, and year, month and day for each of the three derived days; only their names are read.
        #expect(found.directoriesOpened <= 2 + 3 * 3, "opened \(found.directoriesOpened) directories")
        #expect(found.entriesRead <= 3 * 4 + 1, "read \(found.entriesRead) entries")

        // The same id twice in the folders it reads is still no answer.
        let twin = try v7(2026, 10, 28)
        try rollout(home, day: "2026/10/28", id: twin)
        try rollout(home, day: "2026/10/29", id: twin)
        let ambiguous = CodexRolloutLocator.locate(sessionIDs: [twin], home: home, maximumEntries: Self.budget)
        #expect(ambiguous.files[twin] == nil)
    }

    @Test func aMissFallsBackToTheBoundedWalkAndKeepsTheOtherHits() throws {
        let small = try root()
        defer { try? FileManager.default.removeItem(at: small) }
        let moved = try v7(2026, 10, 28)
        let elsewhere = try rollout(small, day: "2025/01/05", id: moved)
        try rollout(small, day: "2026/10/28", id: UUID().uuidString.lowercased())
        let walked = CodexRolloutLocator.locate(sessionIDs: [moved], home: small, maximumEntries: Self.budget)
        #expect(walked.complete)
        #expect(walked.files[moved]?.path == elsewhere.path, "a file outside the derived days is found by the walk")

        let large = try root()
        defer { try? FileManager.default.removeItem(at: large) }
        try history(large, days: ["2026/10/28"])
        let hit = try v7(2026, 10, 28)
        let file = try rollout(large, day: "2026/10/28", id: hit)
        let missing = try v7(2026, 10, 28)
        let lookup = CodexRolloutLocator.locate(sessionIDs: [hit, missing], home: large, maximumEntries: Self.budget)
        #expect(!lookup.complete, "the walk for the missing id ran out of budget")
        #expect(lookup.files[hit]?.path == file.path, "an exhausted walk does not blank an id found in its day")
        #expect(lookup.files[missing] == nil)
    }
}
