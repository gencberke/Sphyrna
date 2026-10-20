import Foundation
import Testing
@testable import LoomCore

/// V23: a stopped session's subagents, listed from the folder Claude keeps them in. Every folder is made in a temporary
/// directory; the real `~/.claude` is never read.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SubagentFolderReaderTests {
    private final class Folder {
        let root: URL
        var subagents: URL { root.appendingPathComponent("subagents", isDirectory: true) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-subagent-folder-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// An agent: its meta file, and its transcript with a creation time and a last write.
        @discardableResult
        func agent(_ id: String, type: String = "Explore", description: String? = "Look around", toolUseID: String? = nil,
                   depth: Int = 1, created: TimeInterval, written: TimeInterval, transcript: Bool = true) throws -> URL {
            var meta: [String: Any] = ["agentType": type, "spawnDepth": depth, "requestShape": "foreground"]
            if let description { meta["description"] = description }
            if let toolUseID { meta["toolUseId"] = toolUseID }
            let metaURL = subagents.appendingPathComponent("agent-\(id).meta.json")
            try JSONSerialization.data(withJSONObject: meta).write(to: metaURL)
            let transcriptURL = subagents.appendingPathComponent("agent-\(id).jsonl")
            if transcript {
                try Data("{}\n".utf8).write(to: transcriptURL)
                try FileManager.default.setAttributes(
                    [.creationDate: Date(timeIntervalSince1970: created), .modificationDate: Date(timeIntervalSince1970: written)],
                    ofItemAtPath: transcriptURL.path)
            } else {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: written)], ofItemAtPath: metaURL.path)
            }
            return metaURL
        }
    }

    @Test func entriesCarryTheirTypeDescriptionTimesAndTranscriptNewestFirst() throws {
        let folder = try Folder()
        try folder.agent("aold", type: "Explore", description: "Find login flow", toolUseID: "toolu_old", created: 1_000, written: 1_040)
        try folder.agent("anew", type: "general-purpose", description: "Draft the plan", toolUseID: "toolu_new", depth: 2,
                         created: 2_000, written: 2_300)
        try folder.agent("amid", type: "Plan", description: nil, created: 1_500, written: 1_560)

        let entries = SubagentFolderReader.read(folder: folder.subagents)
        #expect(entries.map(\.record.id) == ["anew", "amid", "aold"])
        let newest = try #require(entries.first)
        #expect(newest.record.agentType == "general-purpose" && newest.record.description == "Draft the plan")
        #expect(newest.record.depth == 2 && newest.toolUseID == "toolu_new")
        // The file's time: created is the start, last written is the end, so the list shows how long it ran.
        #expect(newest.record.startedAt == Date(timeIntervalSince1970: 2_000) && newest.record.endedAt == Date(timeIntervalSince1970: 2_300))
        #expect(newest.record.isRunning == false && newest.record.wasInterrupted == false)
        #expect(newest.record.transcriptPath?.hasSuffix("/subagents/agent-anew.jsonl") == true)
        #expect(entries[1].record.description == nil && entries[1].toolUseID == nil)
    }

    @Test func theListIsBoundedAtTheNewestEntries() throws {
        let folder = try Folder()
        for index in 0..<12 {
            try folder.agent("a\(index)", created: 1_000 + TimeInterval(index), written: 1_000 + TimeInterval(index))
        }
        let entries = SubagentFolderReader.read(folder: folder.subagents, limit: 5)
        #expect(entries.map(\.record.id) == ["a11", "a10", "a9", "a8", "a7"])
        #expect(SubagentFolderReader.maximumEntries == 500)
    }

    @Test func anUnreadableMetaFileIsSkippedAndDoesNotCostAnEntryOfTheBound() throws {
        let folder = try Folder()
        try folder.agent("agood1", created: 1_000, written: 1_010)
        let broken = try folder.agent("abroken", created: 3_000, written: 3_010)
        try Data("not json".utf8).write(to: broken)
        let oversized = try folder.agent("abig", created: 2_900, written: 2_910)
        try Data(repeating: 0x20, count: SubagentMeta.maximumFileByteCount + 10).write(to: oversized)
        try folder.agent("agood2", created: 2_000, written: 2_010)
        // A meta file that is a link to another file is not a regular file of this folder.
        let target = folder.root.appendingPathComponent("elsewhere.json")
        try Data(#"{"agentType":"Explore"}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: folder.subagents.appendingPathComponent("agent-alink.meta.json"), withDestinationURL: target)
        // Names that are not Claude's ids, and a workflow's folder one level down, are not listed.
        try Data(#"{"agentType":"Explore"}"#.utf8).write(to: folder.subagents.appendingPathComponent("agent-..%2Fx.meta.json"))
        try FileManager.default.createDirectory(
            at: folder.subagents.appendingPathComponent("workflows/run1", isDirectory: true), withIntermediateDirectories: true)
        try Data(#"{"agentType":"implementer"}"#.utf8).write(
            to: folder.subagents.appendingPathComponent("workflows/run1/agent-awf.meta.json"))

        let entries = SubagentFolderReader.read(folder: folder.subagents, limit: 2)
        #expect(entries.map(\.record.id) == ["agood2", "agood1"])
    }

    @Test func anEntryWithoutATranscriptIsListedWithoutAPathAndAMissingFolderIsEmpty() throws {
        let folder = try Folder()
        try folder.agent("anofile", created: 0, written: 5_000, transcript: false)
        let entry = try #require(SubagentFolderReader.read(folder: folder.subagents).first)
        #expect(entry.record.transcriptPath == nil && entry.record.endedAt == Date(timeIntervalSince1970: 5_000))
        #expect(SubagentFolderReader.read(folder: folder.root.appendingPathComponent("nothing")).isEmpty)
    }
}
