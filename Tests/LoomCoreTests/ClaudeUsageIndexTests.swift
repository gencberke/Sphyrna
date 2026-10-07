import Darwin
import Foundation
import SQLite3
import Testing
@testable import LoomCore

@Suite struct ClaudeUsageIndexTests {
    private func json(_ lines: UsageLine...) -> [String] { lines.map(\.json) }

    // MARK: dedupe

    @Test func perBlockDuplicatesCountOnce() async throws {
        let fixture = try UsageFixture()
        let line = UsageLine(input: 100, output: 50, cacheRead: 1_000).json
        try fixture.write([line, line, line], to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 1)
        #expect(snapshot.tokens == UsageTokens(input: 100, output: 50, cacheRead: 1_000))
    }

    @Test func streamingPartialsKeepTheLargest() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(UsageLine(output: 10), UsageLine(output: 50), UsageLine(output: 30)),
                          to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 1)
        #expect(snapshot.tokens.output == 50)
    }

    @Test func crossFileDuplicatesCountOnce() async throws {
        let fixture = try UsageFixture()
        let line = UsageLine(id: "msg_resume", request: "req_r", input: 7, output: 9).json
        try fixture.write([line], to: fixture.transcript(session: "sess-1"))
        try fixture.write([line], to: fixture.transcript(project: "-tmp-copy", session: "sess-2"))
        let index = fixture.makeIndex()
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 1)
        #expect(snapshot.tokens.input == 7)
    }

    @Test func sidechainFilesCountAndReplaysDoNotDoubleCount() async throws {
        let fixture = try UsageFixture()
        let parent = UsageLine(id: "msg_parent", request: "req_p", input: 100, output: 10, cacheRead: 5_000)
        let own = UsageLine(id: "msg_sub", request: "req_s", input: 3, output: 4, sidechain: true)
        var replay = parent
        replay.request = "req_replay"
        replay.sidechain = true
        // The replay is indexed first; the parent's own row must still win when it arrives.
        let subagent = try fixture.write([own.json, replay.json], to: fixture.subagent(session: "sess-1"))
        try fixture.write([parent.json], to: fixture.transcript(session: "sess-1"))
        let index = fixture.makeIndex()
        try await index.refresh(paths: [subagent])
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 2)
        #expect(snapshot.tokens == UsageTokens(input: 103, output: 14, cacheRead: 5_000))
        #expect(snapshot.sessionCount == 1)
    }

    @Test func sidechainReplayAfterTheParentIsDropped() async throws {
        let fixture = try UsageFixture()
        let parent = UsageLine(id: "msg_parent", request: "req_p", input: 100, output: 10)
        var replay = parent
        replay.request = "req_replay"
        replay.sidechain = true
        replay.output = 99 // even a "larger" replay must not displace the parent
        let parentFile = try fixture.write([parent.json], to: fixture.transcript())
        try fixture.write([replay.json], to: fixture.subagent())
        let index = fixture.makeIndex()
        try await index.refresh(paths: [parentFile])
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 1)
        #expect(snapshot.tokens.output == 10)
    }

    @Test func syntheticAndApiErrorLinesAreIgnored() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(
            UsageLine(id: "m1", model: "<synthetic>", input: 0, output: 0),
            UsageLine(id: "m2", request: "r2", input: 500, output: 500, apiError: true),
            UsageLine(id: "m3", request: "r3", model: "<synthetic>", input: 5, output: 5),
            UsageLine(id: "m4", request: "r4", input: 1, output: 2)),
            to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 1)
        #expect(snapshot.tokens == UsageTokens(input: 1, output: 2))
    }

    // MARK: incremental reads

    @Test func partialLastLineIsNotCountedUntilCompleted() async throws {
        let fixture = try UsageFixture()
        let first = UsageLine(id: "m1", request: "r1", input: 1, output: 1).json
        let second = UsageLine(id: "m2", request: "r2", input: 2, output: 2).json
        let split = second.index(second.startIndex, offsetBy: second.count / 2)
        let url = fixture.transcript()
        try fixture.writeRaw(Data((first + "\n" + second[..<split]).utf8), to: url)
        let index = fixture.makeIndex()
        try await index.refresh()
        var snapshot = try await index.all()
        #expect(snapshot.messageCount == 1)
        // Unchanged partial tail: nothing is re-read.
        let idle = try await index.refresh()
        #expect(idle.bytesRead == 0)
        try fixture.append(Data((second[split...] + "\n").utf8), to: url)
        let completing = try await index.refresh()
        snapshot = try await index.all()
        #expect(snapshot.messageCount == 2)
        #expect(snapshot.tokens == UsageTokens(input: 3, output: 3))
        // Only the unconsumed tail plus the new bytes were read, not the first line again.
        #expect(completing.bytesRead == Int64(second.utf8.count + 1))
    }

    @Test func appendReadsOnlyTheNewBytes() async throws {
        let fixture = try UsageFixture()
        let url = fixture.transcript()
        try fixture.write(json(UsageLine(id: "m1", request: "r1", input: 1, output: 1)), to: url)
        let index = fixture.makeIndex()
        let cold = try await index.refresh()
        #expect(cold.bytesRead == fixture.size(of: url))
        let before = fixture.size(of: url)
        try fixture.append(json(UsageLine(id: "m2", request: "r2", input: 2, output: 2),
                                UsageLine(id: "m3", request: "r3", input: 3, output: 3)), to: url)
        let warm = try await index.refresh()
        #expect(warm.bytesRead == fixture.size(of: url) - before)
        #expect(warm.filesReset == 0)
        let snapshot = try await index.all()
        #expect(snapshot.tokens == UsageTokens(input: 6, output: 6))
        let unchanged = try await index.refresh()
        #expect(unchanged.bytesRead == 0 && unchanged.filesUnchanged == 1)
    }

    @Test func aSecondIndexOnTheSameDatabaseDoesNotRereadFiles() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(UsageLine(input: 4, output: 4)), to: fixture.transcript())
        let first = fixture.makeIndex()
        try await first.refresh()
        let second = fixture.makeIndex()
        let report = try await second.refresh()
        #expect(report.bytesRead == 0 && report.filesUnchanged == 1)
        #expect(try await second.all().tokens.input == 4)
    }

    @Test func refreshOfOnePathTailsOnlyThatFile() async throws {
        let fixture = try UsageFixture()
        let a = fixture.transcript(session: "a"), b = fixture.transcript(session: "b")
        try fixture.write(json(UsageLine(id: "a1", request: "ra1", session: "a")), to: a)
        try fixture.write(json(UsageLine(id: "b1", request: "rb1", session: "b")), to: b)
        let index = fixture.makeIndex()
        try await index.refresh()
        let appended = json(UsageLine(id: "a2", request: "ra2", session: "a"))
        try fixture.append(appended, to: a)
        try fixture.append(json(UsageLine(id: "b2", request: "rb2", session: "b")), to: b)
        let report = try await index.refresh(paths: [a])
        #expect(report.filesSeen == 1)
        #expect(report.bytesRead == Int64(appended[0].utf8.count + 1))
        #expect(try await index.all().messageCount == 3)
    }

    // MARK: rewrite, rotation, shrink

    @Test func shrinkReparsesWithoutDoubleCounting() async throws {
        let fixture = try UsageFixture()
        let url = fixture.transcript()
        try fixture.write(json(UsageLine(id: "m1", request: "r1", input: 5), UsageLine(id: "m2", request: "r2", input: 5),
                               UsageLine(id: "m3", request: "r3", input: 5)), to: url)
        let index = fixture.makeIndex()
        try await index.refresh()
        try fixture.write(json(UsageLine(id: "m1", request: "r1", input: 5)), to: url) // same inode, smaller
        let report = try await index.refresh()
        #expect(report.filesReset == 1)
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 1)
        #expect(snapshot.tokens.input == 5)
    }

    @Test func replacedFileWithANewInodeIsReparsed() async throws {
        let fixture = try UsageFixture()
        let url = fixture.transcript()
        try fixture.write(json(UsageLine(id: "m1", request: "r1", input: 5, output: 100),
                               UsageLine(id: "m2", request: "r2", input: 5, output: 100)), to: url)
        let index = fixture.makeIndex()
        try await index.refresh()
        // A longer replacement written elsewhere and renamed over the old file.
        let staging = fixture.root.appendingPathComponent("staging.jsonl")
        try fixture.write(json(UsageLine(id: "n1", request: "q1", input: 1, output: 100),
                               UsageLine(id: "n2", request: "q2", input: 1, output: 100),
                               UsageLine(id: "n3", request: "q3", input: 1, output: 100)), to: staging)
        #expect(rename(staging.path, url.path) == 0)
        let report = try await index.refresh()
        #expect(report.filesReset == 1)
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 3)
        #expect(snapshot.tokens.input == 3)
    }

    @Test func tamperedBytesBeforeTheOffsetTriggerAReparse() async throws {
        let fixture = try UsageFixture()
        let url = fixture.transcript()
        try fixture.write(json(UsageLine(id: "m1", request: "r1", input: 5, output: 100)), to: url)
        let index = fixture.makeIndex()
        try await index.refresh()
        // Same length, same inode, bigger file after: only the tail guard can notice the edit.
        var bytes = try Data(contentsOf: url)
        let marker = Data("\"output_tokens\":100".utf8)
        let range = try #require(bytes.range(of: marker))
        bytes.replaceSubrange(range, with: Data("\"output_tokens\":200".utf8))
        try fixture.writeRaw(bytes, to: url)
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64
        #expect(inode != nil)
        try fixture.append(json(UsageLine(id: "m2", request: "r2", input: 1, output: 1)), to: url)
        let report = try await index.refresh()
        #expect(report.filesReset == 1)
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 2)
        #expect(snapshot.tokens.output == 201)
    }

    @Test func aVanishedFileNeverReducesTotals() async throws {
        let fixture = try UsageFixture()
        let url = fixture.transcript()
        try fixture.write(json(UsageLine(input: 8, output: 8)), to: url)
        let index = fixture.makeIndex()
        try await index.refresh()
        try FileManager.default.removeItem(at: url)
        try await index.refresh()
        #expect(try await index.all().tokens == UsageTokens(input: 8, output: 8))
    }

    // MARK: discovery

    @Test func orphanedAndSupersededFilesAreExcluded() async throws {
        let fixture = try UsageFixture()
        let dir = fixture.projects.appendingPathComponent("-tmp-proj")
        try fixture.write(json(UsageLine(id: "keep", request: "rk", input: 1)), to: fixture.transcript())
        try fixture.write(json(UsageLine(id: "o", request: "ro", input: 100)),
                          to: dir.appendingPathComponent("sess-1.orphaned-1700000000-abc.jsonl"))
        try fixture.write(json(UsageLine(id: "s", request: "rs", input: 100)),
                          to: dir.appendingPathComponent("sess-1.jsonl.superseded-1700000000"))
        try fixture.write(json(UsageLine(id: "x", request: "rx", input: 100)),
                          to: dir.appendingPathComponent("memory/notes.jsonl"))
        try fixture.write(json(UsageLine(id: "t", request: "rt", input: 100)),
                          to: dir.appendingPathComponent("sess-1/tool-results/out.jsonl"))
        let index = fixture.makeIndex()
        let report = try await index.refresh()
        #expect(report.filesSeen == 1)
        #expect(try await index.all().tokens.input == 1)
    }

    @Test func coldStartSkipsOldFilesUnlessAskedForByPath() async throws {
        let fixture = try UsageFixture()
        let old = fixture.transcript(session: "old"), fresh = fixture.transcript(session: "fresh")
        try fixture.write(json(UsageLine(id: "o", request: "ro", session: "old", input: 10)), to: old)
        try fixture.write(json(UsageLine(id: "f", request: "rf", session: "fresh", input: 1)), to: fresh)
        let longAgo = Date().addingTimeInterval(-120 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)
        let index = fixture.makeIndex()
        let report = try await index.refresh()
        #expect(report.filesSkippedOld == 1 && report.filesParsed == 1)
        #expect(try await index.all().tokens.input == 1)
        try await index.refresh(paths: [old])
        #expect(try await index.all().tokens.input == 11)
    }

    @Test func aSymlinkedProjectsDirectoryOrTranscriptIsNotFollowed() async throws {
        let fixture = try UsageFixture()
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try fixture.write(json(UsageLine(id: "o", request: "ro", input: 100)), to: outside.appendingPathComponent("p/s.jsonl"))
        // A symlinked transcript inside a real projects directory.
        try FileManager.default.createDirectory(at: fixture.projects.appendingPathComponent("-tmp-proj"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.transcript(session: "link"),
                                                   withDestinationURL: outside.appendingPathComponent("p/s.jsonl"))
        let index = fixture.makeIndex()
        try await index.refresh()
        #expect(try await index.all().messageCount == 0)
        // A symlinked projects directory itself.
        try FileManager.default.removeItem(at: fixture.projects)
        try FileManager.default.createSymbolicLink(at: fixture.projects, withDestinationURL: outside)
        try await index.refresh()
        #expect(try await index.all().messageCount == 0)
    }

    // MARK: malformed input

    @Test func malformedLinesAreSkippedWithoutCrashing() async throws {
        let fixture = try UsageFixture()
        let url = fixture.transcript()
        var bytes = Data()
        func add(_ line: String) { bytes.append(Data((line + "\n").utf8)) }
        add(UsageLine(id: "ok1", request: "r1", input: 1, output: 1).json)
        add("{\"type\":\"assistant\",\"message\":{\"usage\":{\"input_tokens\":")          // truncated JSON
        add("not json at all \"usage\" \"assistant\"")                                          // gate passes, decode fails
        bytes.append(Data([0xff, 0xfe, 0x00]) + Data("\"usage\" \"assistant\"".utf8) + Data([0x80, 0x0a])) // binary garbage
        add("{\"type\":\"assistant\",\"timestamp\":\"2026-10-05T10:00:00.000Z\",\"message\":{\"id\":\"nu\",\"model\":\"claude-haiku-4-5\"}}") // no usage
        var noTimestamp = UsageLine(id: "nt", request: "rnt", input: 99).json
        noTimestamp = noTimestamp.replacingOccurrences(of: "\"timestamp\":\"2026-10-05T10:00:00.000Z\",", with: "")
        add(noTimestamp)
        add(UsageLine(id: "neg", request: "rneg", input: -5, output: 3).json)             // negative counter
        add(UsageLine(id: "flt", request: "rflt", input: 1).json.replacingOccurrences(of: "\"input_tokens\":1", with: "\"input_tokens\":1.5"))
        add(UsageLine(id: "str", request: "rstr", input: 1).json.replacingOccurrences(of: "\"input_tokens\":1", with: "\"input_tokens\":\"7\""))
        add("{\"type\":\"assistant\",\"timestamp\":\"yesterday\",\"message\":{\"id\":\"bt\",\"model\":\"claude-haiku-4-5\",\"usage\":{\"input_tokens\":9}}}")
        add(UsageLine(id: "ok2", request: "r2", input: 2, output: 2).json)
        try fixture.writeRaw(bytes, to: url)
        let index = fixture.makeIndex()
        let report = try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 2)
        #expect(snapshot.tokens == UsageTokens(input: 3, output: 3))
        #expect(report.linesMalformed >= 6)
    }

    @Test func oversizedLinesAreSkippedAndTheNextLineIsRead() async throws {
        let fixture = try UsageFixture()
        let url = fixture.transcript()
        let filler = String(repeating: "x", count: 300_000)
        var huge = UsageLine(id: "huge", request: "rh", input: 777).json
        huge = huge.replacingOccurrences(of: "\"text\":\"hi\"", with: "\"text\":\"\(filler)\"")
        try fixture.write([UsageLine(id: "a", request: "ra", input: 1).json, huge,
                           UsageLine(id: "b", request: "rb", input: 2).json], to: url)
        // Small chunks and a 64 KiB line cap exercise buffer growth and the discard path.
        let index = fixture.makeIndex(chunkBytes: 16_384, maximumLineBytes: 65_536)
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.tokens.input == 3)
        #expect(snapshot.messageCount == 2)
    }

    @Test func aLongLineWithinTheCapSpansChunks() async throws {
        let fixture = try UsageFixture()
        let filler = String(repeating: "y", count: 40_000)
        let long = UsageLine(id: "long", request: "rl", input: 5).json
            .replacingOccurrences(of: "\"text\":\"hi\"", with: "\"text\":\"\(filler)\"")
        try fixture.write([long, UsageLine(id: "b", request: "rb", input: 2).json], to: fixture.transcript())
        let index = fixture.makeIndex(chunkBytes: 4_096, maximumLineBytes: 65_536)
        try await index.refresh()
        #expect(try await index.all().tokens.input == 7)
    }

    // MARK: cache split, multipliers, unknown models

    @Test func cacheSplitAndLegacyCacheField() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(
            UsageLine(id: "split", request: "r1", input: 0, output: 0, cw5: 100, cw1: 300),
            UsageLine(id: "legacy", request: "r2", input: 0, output: 0, legacyCache: 40)),
            to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.tokens.cacheWrite5m == 140)
        #expect(snapshot.tokens.cacheWrite1h == 300)
    }

    @Test func costsAreHandComputedPerMessage() async throws {
        let fixture = try UsageFixture()
        // Haiku 4.5: the planning scan's reference message, $0.0222902.
        try fixture.write(json(UsageLine(id: "h", request: "rh", input: 916, output: 84, cw1: 9_303, cacheRead: 23_482)),
                          to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(abs(snapshot.estimatedCostUSD - 0.0222902) < 1e-9)
        #expect(snapshot.unknownModels.isEmpty)
        #expect(snapshot.priceTableAsOf == UsagePricing.asOf)
    }

    @Test func fastModeAndInferenceGeoMultipliers() async throws {
        let fixture = try UsageFixture()
        // Opus 5.5 fast: $8 in / $40 out; 5m write 1.25x, 1h write 2x, read 0.05x of the fast input price.
        // 1,000,000 of each: 8 + 40 + 10 + 16 + 0.4 = $74.40.
        try fixture.write(json(UsageLine(id: "fast", request: "rf", model: "claude-opus-5-5", input: 1_000_000,
                                         output: 1_000_000, cw5: 1_000_000, cw1: 1_000_000, cacheRead: 1_000_000, speed: "fast")),
                          to: fixture.transcript(session: "fast"))
        // Sonnet 4.6 in the US: 1.1x on every category. 1M in + 1M out = (3 + 15) * 1.1 = $19.80.
        try fixture.write(json(UsageLine(id: "geo", request: "rg", session: "geo", model: "claude-sonnet-4-6", input: 1_000_000,
                                         output: 1_000_000, speed: "standard", geo: "us")),
                          to: fixture.transcript(session: "geo"))
        // Opus 5.5 standard, 1M cache reads = 0.05 * 4 = $0.20; web search $10 per 1,000 is not multiplied.
        try fixture.write(json(UsageLine(id: "std", request: "rs", session: "std", model: "claude-opus-5-5", input: 0, output: 0,
                                         cacheRead: 1_000_000, web: 3)),
                          to: fixture.transcript(session: "std"))
        let index = fixture.makeIndex()
        try await index.refresh()
        let snapshot = try await index.all()
        let byModel = Dictionary(uniqueKeysWithValues: snapshot.models.map { ($0.model, $0) })
        #expect(abs(try #require(byModel["claude-sonnet-4-6"]?.estimatedCostUSD) - 19.80) < 1e-9)
        // Fast and standard Opus 5.5 messages share the model row: 74.40 + 0.20 + 0.03.
        #expect(abs(try #require(byModel["claude-opus-5-5"]?.estimatedCostUSD) - 74.63) < 1e-9)
    }

    @Test func unknownModelKeepsTokensButHasNoCost() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(UsageLine(id: "u", request: "ru", model: "claude-nova-9-20271231", input: 10, output: 20),
                               UsageLine(id: "k", request: "rk", input: 10, output: 20)), to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.tokens == UsageTokens(input: 20, output: 40))
        #expect(snapshot.unknownModels == ["claude-nova-9-20271231"])
        #expect(snapshot.hasUnknownCost)
        let unknown = try #require(snapshot.models.first { $0.model == "claude-nova-9-20271231" })
        #expect(unknown.estimatedCostUSD == nil && !unknown.isPriceKnown && unknown.tokens.total == 30)
        #expect(abs(snapshot.estimatedCostUSD - 110e-6) < 1e-12) // the known model only
    }

    @Test func aLegacyCostFieldIsAcceptedWhenPresent() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(UsageLine(id: "u", request: "ru", model: "claude-nova-9", input: 10, output: 20, costUSD: 0.5)),
                          to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(abs(snapshot.estimatedCostUSD - 0.5) < 1e-12)
        #expect(snapshot.unknownModels.isEmpty)
    }

    // MARK: aggregates

    @Test func daysModelsSessionsAndCacheShare() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(
            UsageLine(id: "m1", request: "r1", ts: "2026-10-05T10:00:00.000Z", input: 100, output: 10, cacheRead: 300),
            UsageLine(id: "m2", request: "r2", model: "claude-sonnet-4-6", ts: "2026-10-06T10:00:00.000Z", input: 100, output: 10)),
            to: fixture.transcript(session: "sess-1"))
        try fixture.write(json(
            UsageLine(id: "m3", request: "r3", session: "sess-2", ts: "2026-10-06T11:00:00.000Z", input: 100, output: 10)),
            to: fixture.transcript(session: "sess-2"))
        let index = fixture.makeIndex()
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.provider == .claude)
        #expect(snapshot.messageCount == 3 && snapshot.sessionCount == 2)
        #expect(snapshot.days.map(\.day) == ["2026-10-05", "2026-10-06"])
        #expect(snapshot.days[0].messageCount == 1 && snapshot.days[1].messageCount == 2)
        #expect(snapshot.days[1].sessionCount == 2 && snapshot.days[0].sessionCount == 1)
        #expect(Set(snapshot.models.map(\.model)) == ["claude-haiku-4-5", "claude-sonnet-4-6"])
        #expect(snapshot.models.first?.model == "claude-haiku-4-5") // 2 messages, highest token total
        // cache reads over input + writes + reads: 300 / (300 + 300) = 0.5
        #expect(abs(try #require(snapshot.cacheShare) - 300.0 / 600.0) < 1e-12)
    }

    @Test func rangesCutAtLocalDaysAndHours() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(
            UsageLine(id: "m1", request: "r1", ts: "2026-10-05T10:00:00.000Z", input: 1),
            UsageLine(id: "m2", request: "r2", ts: "2026-10-06T10:00:00.000Z", input: 10),
            UsageLine(id: "m3", request: "r3", ts: "2026-10-07T09:00:00.000Z", input: 100)),
            to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let now = UsageFixture.now // 2026-10-07T12:00Z
        #expect(try await index.snapshot(range: .days(1), now: now, timeZone: UsageFixture.utc).tokens.input == 100)
        #expect(try await index.snapshot(range: .days(2), now: now, timeZone: UsageFixture.utc).tokens.input == 110)
        #expect(try await index.snapshot(range: .last24Hours, now: now, timeZone: UsageFixture.utc).tokens.input == 100)
        let interval = UsageRange.interval(start: UsageFixture.date("2026-10-06T00:00:00Z"), end: UsageFixture.date("2026-10-07T00:00:00Z"))
        #expect(try await index.snapshot(range: interval, now: now, timeZone: UsageFixture.utc).tokens.input == 10)
    }

    @Test func dayBoundariesFollowTheTimeZone() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(
            UsageLine(id: "a", request: "ra", ts: "2026-10-05T23:59:59.999Z", input: 1),
            UsageLine(id: "b", request: "rb", ts: "2026-10-06T00:00:00.000Z", input: 10),
            UsageLine(id: "c", request: "rc", ts: "2026-10-06T06:59:59.999Z", input: 100),
            UsageLine(id: "d", request: "rd", ts: "2026-10-06T07:00:00.000Z", input: 1_000),
            UsageLine(id: "e", request: "re", ts: "2026-10-05T18:29:59.999Z", input: 10_000),
            UsageLine(id: "f", request: "rf", ts: "2026-10-05T18:30:00.000Z", input: 100_000)),
            to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        func perDay(_ zone: String) async throws -> [String: Int64] {
            let snapshot = try await index.all(timeZone: TimeZone(identifier: zone)!)
            return Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.day, $0.tokens.input) })
        }
        // UTC: Oct 5 holds a, e, f (23:59:59.999, 18:29, 18:30); Oct 6 holds b, c, d.
        let utc = try await perDay("UTC")
        #expect(utc["2026-10-05"] == 110_001 && utc["2026-10-06"] == 1_110)
        // Los Angeles (PDT, UTC-7): local midnight is 07:00Z. a, b, c, e, f are still Oct 5 or earlier; d starts Oct 6.
        let la = try await perDay("America/Los_Angeles")
        #expect(la["2026-10-05"] == 110_111 && la["2026-10-06"] == 1_000)
        // Kolkata (UTC+5:30): local midnight is 18:30Z the day before, so e is Oct 5 and f starts Oct 6.
        let kolkata = try await perDay("Asia/Kolkata")
        #expect(kolkata["2026-10-05"] == 10_000)
        #expect(kolkata["2026-10-06"] == 101_111)
    }

    @Test func activityWindowFollowsTheFiveHourBlockRule() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(
            // Old block, ended long before now.
            UsageLine(id: "o", request: "ro", ts: "2026-10-07T01:10:00.000Z", input: 1_000),
            // New block: starts 07:40 -> floored 07:00, ends 12:00 UTC. Gap since the old one is over five hours.
            UsageLine(id: "a", request: "ra", ts: "2026-10-07T07:40:00.000Z", input: 10, output: 5),
            UsageLine(id: "b", request: "rb", ts: "2026-10-07T11:30:00.000Z", input: 20, output: 5)),
            to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let early = try await index.snapshot(range: .all, now: UsageFixture.date("2026-10-07T11:45:00Z"), timeZone: UsageFixture.utc)
        let window = try #require(early.activityWindow)
        #expect(window.start == UsageFixture.date("2026-10-07T07:00:00Z"))
        #expect(window.end == UsageFixture.date("2026-10-07T12:00:00Z"))
        #expect(window.lastActivity == UsageFixture.date("2026-10-07T11:30:00Z"))
        #expect(window.tokens == UsageTokens(input: 30, output: 10) && window.messageCount == 2)
        // After the block's end there is no active window.
        let late = try await index.snapshot(range: .all, now: UsageFixture.date("2026-10-07T12:30:00Z"), timeZone: UsageFixture.utc)
        #expect(late.activityWindow == nil)
    }

    // MARK: forget

    @Test func forgetKeepsTokensAndDropsTheSessionLink() async throws {
        let fixture = try UsageFixture()
        let url = fixture.transcript(session: "gone")
        try fixture.write(json(UsageLine(id: "g1", request: "rg1", session: "gone", input: 40, output: 2)), to: url)
        try fixture.write(json(UsageLine(id: "k1", request: "rk1", session: "kept", input: 6, output: 1)),
                          to: fixture.transcript(session: "kept"))
        try fixture.write(json(UsageLine(id: "g2", request: "rg2", session: "gone", input: 4, output: 0, sidechain: true)),
                          to: fixture.subagent(session: "gone"))
        let index = fixture.makeIndex()
        try await index.refresh()
        #expect(try await index.all().sessionCount == 2)
        let unlinked = try await index.forget(sessionIDs: ["gone"])
        #expect(unlinked == 2)
        var snapshot = try await index.all()
        #expect(snapshot.tokens == UsageTokens(input: 50, output: 3))
        #expect(snapshot.messageCount == 3)
        #expect(snapshot.sessionCount == 1)
        // The transcript is still on disk and grows; re-reading it must not re-link the session.
        try fixture.append(json(UsageLine(id: "g3", request: "rg3", session: "gone", input: 1)), to: url)
        try await index.refresh()
        snapshot = try await index.all()
        #expect(snapshot.tokens.input == 51)
        #expect(snapshot.sessionCount == 1)
    }

    @Test func linesSpanningChunkBoundariesAreAllCounted() async throws {
        let fixture = try UsageFixture()
        let lines = (0..<300).map { UsageLine(id: "m\($0)", request: "r\($0)", input: $0 + 1, output: 0).json }
        let url = try fixture.write(lines, to: fixture.transcript())
        // 1 KiB chunks against ~350-byte lines: most chunk ends fall inside a line.
        let index = fixture.makeIndex(chunkBytes: 1_024, maximumLineBytes: 65_536)
        let report = try await index.refresh()
        #expect(report.bytesRead == fixture.size(of: url))
        #expect(report.recordsAccepted == 300)
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 300)
        #expect(snapshot.tokens.input == 300 * 301 / 2)
    }

    @Test func aCancelledRefreshLeavesTheIndexExact() async throws {
        let fixture = try UsageFixture()
        for session in 0..<20 {
            let lines = (0..<20).map { UsageLine(id: "m\(session)-\($0)", request: "r\(session)-\($0)", session: "s\(session)", input: 1, output: 0).json }
            try fixture.write(lines, to: fixture.transcript(session: "s\(session)"))
        }
        let index = fixture.makeIndex(chunkBytes: 2_048, maximumLineBytes: 65_536)
        let task = Task { try await index.refresh() }
        task.cancel()
        _ = try? await task.value
        try await index.refresh()
        let snapshot = try await index.all()
        #expect(snapshot.messageCount == 400)
        #expect(snapshot.tokens.input == 400)
    }

    @Test func pathsOutsideTheProfileAreRefused() async throws {
        let fixture = try UsageFixture()
        let outside = fixture.root.appendingPathComponent("elsewhere/s.jsonl")
        try fixture.write(json(UsageLine(input: 5)), to: outside)
        let configFile = fixture.config.appendingPathComponent("history.jsonl")
        try fixture.write(json(UsageLine(id: "c", request: "rc", input: 5)), to: configFile)
        let index = fixture.makeIndex()
        let report = try await index.refresh(paths: [outside, configFile])
        #expect(report.filesSeen == 0)
        #expect(try await index.all().messageCount == 0)
    }

    @Test func forgottenSessionsSurviveANewIndexInstance() async throws {
        let fixture = try UsageFixture()
        let url = fixture.transcript(session: "gone")
        try fixture.write(json(UsageLine(id: "g1", request: "rg1", session: "gone", input: 1)), to: url)
        let first = fixture.makeIndex()
        try await first.refresh()
        try await first.forget(sessionIDs: ["gone"])
        try fixture.append(json(UsageLine(id: "g2", request: "rg2", session: "gone", input: 2)), to: url)
        let second = fixture.makeIndex()
        try await second.refresh()
        let snapshot = try await second.all()
        #expect(snapshot.tokens.input == 3 && snapshot.sessionCount == 0)
    }

    // MARK: index file recovery

    @Test func aCorruptDatabaseIsRebuiltFromTheTranscripts() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(UsageLine(input: 12, output: 3)), to: fixture.transcript())
        try Data("this is not a sqlite database, it is long enough to look like one".utf8 + Data(count: 4_096))
            .write(to: fixture.databaseURL)
        let index = fixture.makeIndex()
        try await index.refresh()
        #expect(try await index.all().tokens == UsageTokens(input: 12, output: 3))
    }

    @Test func aNewerSchemaIsDiscardedAndRebuilt() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(UsageLine(input: 12, output: 3)), to: fixture.transcript())
        let first = fixture.makeIndex()
        try await first.refresh()
        var connection: OpaquePointer?
        #expect(sqlite3_open(fixture.databaseURL.path, &connection) == SQLITE_OK)
        #expect(sqlite3_exec(connection, "PRAGMA user_version = 999", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)
        let second = fixture.makeIndex()
        let report = try await second.refresh()
        #expect(report.bytesRead > 0) // the file was parsed again, not trusted
        #expect(try await second.all().tokens == UsageTokens(input: 12, output: 3))
    }

    // MARK: OPT1 - bucketed bars, cheap summaries

    @Test(arguments: ["UTC", "Europe/London", "Asia/Kolkata", "Asia/Kathmandu", "America/Los_Angeles"])
    func hourAndDayBucketsEqualThePerIntervalSnapshots(zone: String) async throws {
        let timeZone = try #require(TimeZone(identifier: zone))
        let fixture = try UsageFixture()
        // Spread over several local days, two models, around the end of British summer time
        // (a 25-hour local day on 2026-10-25) and around fractional-hour zones.
        var lines: [UsageLine] = []
        for step in 0..<400 {
            let seconds = 1_792_800_000 + step * 4_321 // from 2026-10-24T00:00Z, about 20 days
            lines.append(UsageLine(
                id: "m\(step)", request: "r\(step)", session: "s\(step % 5)",
                model: step % 3 == 0 ? "claude-sonnet-4-6" : "claude-haiku-4-5-20251001",
                ts: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(seconds))),
                input: step + 1, output: step % 7, cacheRead: step % 11))
        }
        try fixture.write(lines.map(\.json), to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let now = Date(timeIntervalSince1970: 1_792_800_000 + 14 * 86_400 + 3_700)

        for (size, count) in [(UsageBucketSize.hour, 24), (.hour, 5), (.hour, 60), (.day, 7), (.day, 14)] {
            let buckets = try await index.buckets(size: size, count: count, endingAt: now, timeZone: timeZone)
            #expect(buckets.count == count)
            #expect(buckets.last.map { $0.start <= now && now < $0.end } == true)
            for (before, after) in zip(buckets, buckets.dropFirst()) { #expect(before.end == after.start) }
            for bucket in buckets {
                let snapshot = try await index.snapshot(
                    range: .interval(start: bucket.start, end: bucket.end), now: now, timeZone: timeZone)
                #expect(bucket.tokens == snapshot.tokens)
                #expect(bucket.messageCount == snapshot.messageCount)
            }
            #expect(buckets.map(\.tokens.total).reduce(0, +) > 0)
        }
    }

    /// Monrovia kept a 44 min 30 s offset until January 1972: hour edges that miss the quarter-hour groups
    /// are summed per bucket and still equal the interval snapshots.
    @Test func bucketsOfAZoneWithAnOddOffsetStillEqualTheIntervalSnapshots() async throws {
        let timeZone = try #require(TimeZone(identifier: "Africa/Monrovia"))
        let fixture = try UsageFixture()
        let base = UsageFixture.date("1971-06-01T10:00:00Z")
        let lines = (0..<40).map { step in
            UsageLine(id: "m\(step)", request: "r\(step)",
                      ts: ISO8601DateFormatter().string(from: base.addingTimeInterval(Double(step) * 1_000)),
                      input: step + 1).json
        }
        try fixture.write(lines, to: fixture.transcript())
        let index = fixture.makeIndex(coldStartWindow: 100 * 365 * 86_400)
        try await index.refresh()
        let now = base.addingTimeInterval(45_000)
        let buckets = try await index.buckets(size: .hour, count: 20, endingAt: now, timeZone: timeZone)
        let inputs: [Int64] = buckets.map { $0.tokens.input }
        #expect(inputs.reduce(0, +) == 820)   // 1 + 2 + ... + 40
        for bucket in buckets {
            let snapshot = try await index.snapshot(range: .interval(start: bucket.start, end: bucket.end), now: now, timeZone: timeZone)
            #expect(bucket.tokens == snapshot.tokens)
            #expect(bucket.messageCount == snapshot.messageCount)
        }
    }

    @Test func aSummaryHasTheSameNumbersAsASnapshotWithoutTheActivityWindow() async throws {
        let fixture = try UsageFixture()
        try fixture.write(json(
            UsageLine(id: "a", request: "ra", ts: "2026-10-07T11:00:00.000Z", input: 5, output: 1),
            UsageLine(id: "b", request: "rb", ts: "2026-10-06T08:00:00.000Z", input: 7, output: 2)),
            to: fixture.transcript())
        let index = fixture.makeIndex()
        try await index.refresh()
        let now = UsageFixture.now
        for range in [UsageRange.days(1), .days(7), .all, .last24Hours] {
            let full = try await index.snapshot(range: range, now: now, timeZone: UsageFixture.utc)
            let summary = try await index.summary(range: range, now: now, timeZone: UsageFixture.utc)
            #expect(full.activityWindow != nil)
            #expect(summary.activityWindow == nil)
            #expect(summary == UsageSnapshot(
                provider: full.provider, asOf: full.asOf, priceTableAsOf: full.priceTableAsOf, range: full.range,
                tokens: full.tokens, estimatedCostUSD: full.estimatedCostUSD, unknownModels: full.unknownModels,
                messageCount: full.messageCount, sessionCount: full.sessionCount, days: full.days,
                models: full.models, activityWindow: nil))
        }
    }

    @Test func hasUsageIsAnExistenceCheck() async throws {
        let fixture = try UsageFixture()
        let index = fixture.makeIndex()
        try await index.refresh()
        #expect(try await index.hasUsage() == false)
        try fixture.write(json(UsageLine(input: 1)), to: fixture.transcript())
        try await index.refresh()
        #expect(try await index.hasUsage() == true)
    }

    // MARK: OPT1 - forget keeps no ids

    private func occurrences(of text: String, in fixture: UsageFixture) -> Int {
        var count = 0
        for file in [fixture.databaseURL, URL(fileURLWithPath: fixture.databaseURL.path + "-wal")] {
            var data = (try? Data(contentsOf: file)) ?? Data()
            while let range = data.range(of: Data(text.utf8)) {
                count += 1
                data = data.subdata(in: range.upperBound..<data.count)
            }
        }
        return count
    }

    @Test func aForgottenSessionLeavesNoIdBytesInTheIndexFiles() async throws {
        let fixture = try UsageFixture()
        let doomed = "doomed-\(UUID().uuidString.lowercased())"
        let kept = "kept-\(UUID().uuidString.lowercased())"
        let doomedURL = fixture.transcript(project: "-tmp-doomedproject", session: doomed)
        try fixture.write(json(UsageLine(id: "g1", request: "rg1", session: doomed, input: 40, output: 2)), to: doomedURL)
        try fixture.write(json(UsageLine(id: "g2", request: "rg2", session: doomed, input: 4, sidechain: true)),
                          to: fixture.subagent(project: "-tmp-doomedproject", session: doomed))
        try fixture.write(json(UsageLine(id: "k1", request: "rk1", session: kept, input: 6, output: 1)),
                          to: fixture.transcript(session: kept))
        for filler in 0..<150 { // spread pages and give the file some size
            try fixture.write(json(UsageLine(id: "f\(filler)", request: "rf\(filler)", session: "filler-\(filler)", input: 1)),
                              to: fixture.transcript(session: "filler-\(filler)"))
        }
        let index = fixture.makeIndex()
        try await index.refresh()
        // The probe has power: both ids are on disk before the forget.
        #expect(occurrences(of: doomed, in: fixture) > 0)
        #expect(occurrences(of: kept, in: fixture) > 0)
        let before = try await index.all()

        // The app registers the Loom id and the provider id as they are; case must not matter.
        let unlinked = try await index.forget(sessionIDs: [doomed.uppercased()])
        #expect(unlinked == 2)
        #expect(occurrences(of: doomed, in: fixture) == 0)
        #expect(occurrences(of: doomed.uppercased(), in: fixture) == 0)
        #expect(occurrences(of: "doomedproject", in: fixture) == 0)   // the encoded path of its files
        #expect(occurrences(of: kept, in: fixture) > 0)               // another session is untouched
        #expect((try? Data(contentsOf: URL(fileURLWithPath: fixture.databaseURL.path + "-wal")))?.isEmpty ?? true)
        let after = try await index.all()
        #expect(after.tokens == before.tokens)
        #expect(after.messageCount == before.messageCount)
        #expect(after.sessionCount == before.sessionCount - 1)

        // The transcript is still on disk and grows: it is read again but not linked again.
        try fixture.append(json(UsageLine(id: "g3", request: "rg3", session: doomed, input: 1)), to: doomedURL)
        try await index.refresh()
        let grown = try await index.all()
        #expect(grown.tokens.input == before.tokens.input + 1)
        #expect(grown.sessionCount == after.sessionCount)
        // A new instance still knows (the guard is stored, as a digest).
        let second = fixture.makeIndex()
        try fixture.append(json(UsageLine(id: "g4", request: "rg4", session: doomed, input: 1)), to: doomedURL)
        try await second.refresh()
        let again = try await second.all()
        #expect(again.tokens.input == before.tokens.input + 2)
        #expect(again.sessionCount == after.sessionCount)
    }

    /// A schema 1 index as the previous build wrote it: forgotten ids in clear text and the session's
    /// symbol row still there. Opening it converts the guard to digests and removes both.
    @Test func aSchemaOneIndexLosesItsClearTextForgottenIdsWithoutLosingHistory() async throws {
        let fixture = try UsageFixture()
        let old = "old-gone-session"
        let url = fixture.transcript(session: old)
        try fixture.write(json(UsageLine(id: "o1", request: "ro1", session: old, input: 9)), to: url)
        try fixture.write(json(UsageLine(id: "k1", request: "rk1", session: "kept", input: 3)), to: fixture.transcript(session: "kept"))
        do { try await fixture.makeIndex().refresh() }   // released again: its connection closes

        // Rewrite the database as schema 1 with the old forget applied: session link gone from
        // the messages, the id in `forgotten` (three case variants) and in `symbol`.
        var connection: OpaquePointer?
        #expect(sqlite3_open(fixture.databaseURL.path, &connection) == SQLITE_OK)
        func run(_ sql: String) { #expect(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK, "\(sql)") }
        run("UPDATE msg SET session = NULL WHERE session = (SELECT id FROM symbol WHERE text = '\(old)')")
        run("DROP TABLE forgotten")
        run("CREATE TABLE forgotten (session TEXT PRIMARY KEY) WITHOUT ROWID")
        for variant in [old, old.uppercased()] { run("INSERT INTO forgotten(session) VALUES ('\(variant)')") }
        run("PRAGMA user_version = 1")
        sqlite3_close(connection)
        #expect(occurrences(of: old, in: fixture) > 0)

        let second = fixture.makeIndex()
        _ = try await second.all()   // opens (and converts) the file; nothing is read from transcripts yet
        #expect(occurrences(of: old, in: fixture) == 0)
        #expect(occurrences(of: old.uppercased(), in: fixture) == 0)
        try fixture.append(json(UsageLine(id: "o2", request: "ro2", session: old, input: 1)), to: url)
        try await second.refresh()
        let snapshot = try await second.all()
        #expect(snapshot.tokens.input == 13)
        #expect(snapshot.sessionCount == 1)   // only "kept"; the old session is not linked again
    }
}
