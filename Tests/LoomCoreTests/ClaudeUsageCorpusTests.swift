import Darwin
import Foundation
import Testing
@testable import LoomCore

/// Volume measurement on a generated corpus (about 1 GiB of synthetic transcripts). Opt-in:
/// `LOOM_USAGE_CORPUS=<dir under ~/Library/Caches>` (never under ~/Documents), optionally
/// `LOOM_USAGE_CORPUS_BYTES` (default 1 GiB) and `LOOM_USAGE_CORPUS_REPORT=<json path>`.
/// The first run generates the corpus; run it again in a fresh process for a clean peak-memory
/// reading. Without the variable the test is skipped. It never reads a real Claude profile.
@Suite struct ClaudeUsageCorpusTests {
    private struct Marker: Codable {
        var bytes: Int64
        var files: Int
        var lines: Int
        var messages: Int
        var inputSum: Int64
        var outputSum: Int64
        var cacheReadSum: Int64
    }

    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    private static func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : -1
    }

    private static func peakBytes() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss) // bytes on macOS
    }

    private static let filler: [UInt8] = Array(String(repeating:
        "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. ",
        count: 64).utf8)

    private static func text(_ length: Int, _ salt: Int) -> String {
        let start = salt % 64
        return String(decoding: filler[start..<(start + min(length, filler.count - start))], as: UTF8.self)
            + String(repeating: "x", count: max(0, length - (filler.count - start)))
    }

    /// Writes transcripts until `target` bytes exist. Deterministic; counts what a correct index must find.
    private static func generate(into projects: URL, target: Int64) throws -> Marker {
        var random = SplitMix(state: 42)
        var marker = Marker(bytes: 0, files: 0, lines: 0, messages: 0, inputSum: 0, outputSum: 0, cacheReadSum: 0)
        let base = Int64(1_790_000_000) // 2026-09
        var file = 0
        while marker.bytes < target {
            let project = "-corpus-project-\(file % 12)"
            let directory = projects.appendingPathComponent(project, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = "corpus-\(file)"
            let url = directory.appendingPathComponent("\(session).jsonl")
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            var chunk = Data()
            var fileBytes = 0
            let fileTarget = 6_000_000 + random.below(6_000_000)
            while fileBytes < fileTarget && marker.bytes + Int64(fileBytes) < target {
                // One turn: a tool-result user line, then an assistant message written once per content block.
                let userText = text(800 + random.below(5_000), random.below(64))
                let user = "{\"type\":\"user\",\"sessionId\":\"\(session)\",\"timestamp\":\"2026-09-20T10:00:00.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"\(userText)\"}]}}\n"
                chunk.append(contentsOf: user.utf8)
                fileBytes += user.utf8.count
                marker.lines += 1

                let n = marker.messages
                let input = 1 + n % 7, output = 10 + n % 90, cacheRead = 1_000 + (n * 37) % 9_000, cw1 = n % 5 == 0 ? 500 : 0
                let day = 1 + (n / 2_000) % 28, hour = (n / 90) % 24, minute = n % 60
                let stamp = String(format: "2026-09-%02dT%02d:%02d:%02d.%03dZ", day, hour, minute, n % 60, n % 1000)
                let blocks = 1 + n % 3
                let body = text(200 + random.below(3_000), random.below(64))
                for block in 0..<blocks {
                    let line = "{\"type\":\"assistant\",\"timestamp\":\"\(stamp)\",\"requestId\":\"req_\(n)\",\"sessionId\":\"\(session)\",\"isSidechain\":false,\"apiBlockIndex\":\(block),\"message\":{\"id\":\"msg_\(n)\",\"model\":\"claude-sonnet-4-6\",\"content\":[{\"type\":\"text\",\"text\":\"\(body)\"}],\"usage\":{\"input_tokens\":\(input),\"cache_creation_input_tokens\":\(cw1),\"cache_creation\":{\"ephemeral_5m_input_tokens\":0,\"ephemeral_1h_input_tokens\":\(cw1)},\"cache_read_input_tokens\":\(cacheRead),\"service_tier\":\"standard\",\"speed\":\"standard\",\"output_tokens\":\(output)}}}\n"
                    chunk.append(contentsOf: line.utf8)
                    fileBytes += line.utf8.count
                    marker.lines += 1
                }
                marker.messages += 1
                marker.inputSum += Int64(input)
                marker.outputSum += Int64(output)
                marker.cacheReadSum += Int64(cacheRead)
                if chunk.count >= 4 * 1024 * 1024 {
                    try handle.write(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: chunk)
            try handle.close()
            marker.bytes += Int64(fileBytes)
            marker.files += 1
            file += 1
            _ = base
        }
        return marker
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOM_USAGE_CORPUS"] != nil))
    func coldScanWarmRefreshAndMemoryOnAGeneratedCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(environment["LOOM_USAGE_CORPUS"]), isDirectory: true)
        #expect(!directory.path.contains("/Documents/"), "corpus must live outside ~/Documents")
        let target = Int64(environment["LOOM_USAGE_CORPUS_BYTES"] ?? "") ?? 1_073_741_824
        let config = directory.appendingPathComponent("config", isDirectory: true)
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        let markerURL = directory.appendingPathComponent("corpus.json")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        chmod(config.path, 0o700)
        let clock = ContinuousClock()
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }

        var generationMs = 0.0
        let marker: Marker
        if let data = try? Data(contentsOf: markerURL), let existing = try? JSONDecoder().decode(Marker.self, from: data) {
            marker = existing
        } else {
            var generated: Marker?
            generationMs = milliseconds(try clock.measure { generated = try Self.generate(into: projects, target: target) })
            marker = try #require(generated)
            try JSONEncoder().encode(marker).write(to: markerURL)
        }

        let databaseURL = directory.appendingPathComponent("usage-index.sqlite3")
        for suffix in ["", "-wal", "-shm"] { unlink(databaseURL.path + suffix) }
        let profile = ClaudeProfileLayout(profileDirectory: config, environment: [:], home: directory)
        let index = ClaudeUsageIndex(databaseURL: databaseURL, profile: profile)
        let now = Date()
        let residentBefore = Self.residentBytes(), peakBefore = Self.peakBytes()

        var cold = UsageScanReport()
        let coldMs = milliseconds(try await clock.measure { cold = try await index.refresh() })
        let residentAfter = Self.residentBytes(), peakAfter = Self.peakBytes()
        let snapshot = try await index.snapshot(range: .all, now: now, timeZone: TimeZone(identifier: "UTC")!)
        #expect(snapshot.messageCount == marker.messages)
        #expect(snapshot.tokens.input == marker.inputSum)
        #expect(snapshot.tokens.output == marker.outputSum)
        #expect(snapshot.tokens.cacheRead == marker.cacheReadSum)
        #expect(cold.bytesRead == marker.bytes)

        var warm = UsageScanReport()
        let warmMs = milliseconds(try await clock.measure { warm = try await index.refresh() })
        #expect(warm.bytesRead == 0 && warm.filesUnchanged == marker.files)

        // One transcript grows by about 1 MiB: the next refresh reads only that.
        let victim = projects.appendingPathComponent("-corpus-project-0/corpus-0.jsonl")
        let appended = (0..<2_500).map { index in
            "{\"type\":\"assistant\",\"timestamp\":\"2026-09-30T10:00:00.000Z\",\"requestId\":\"req_x\(index)\",\"sessionId\":\"corpus-0\",\"isSidechain\":false,\"message\":{\"id\":\"msg_x\(index)\",\"model\":\"claude-sonnet-4-6\",\"content\":[{\"type\":\"text\",\"text\":\"\(Self.text(300, index))\"}],\"usage\":{\"input_tokens\":1,\"cache_read_input_tokens\":0,\"output_tokens\":1}}}\n"
        }.joined()
        let handle = try FileHandle(forWritingTo: victim)
        let originalSize = try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        var tail = UsageScanReport()
        let tailMs = milliseconds(try await clock.measure { tail = try await index.refresh() })
        #expect(tail.bytesRead == Int64(appended.utf8.count) && tail.filesParsed == 1)
        // Put the corpus back so the next run starts from the generated state.
        let restore = try FileHandle(forWritingTo: victim)
        try restore.truncate(atOffset: originalSize)
        try restore.close()

        let snapshotMs = milliseconds(try await clock.measure {
            _ = try await index.snapshot(range: .days(90), now: now, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        })
        let databaseBytes = (try? FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? NSNumber)??.int64Value ?? 0

        let report: [String: Any] = [
            "corpusBytes": marker.bytes, "files": marker.files, "lines": marker.lines, "uniqueMessages": marker.messages,
            "generationMs": generationMs,
            "coldScanMs": coldMs, "coldBytesRead": cold.bytesRead, "coldRecordsAccepted": cold.recordsAccepted,
            "coldThroughputMBps": Double(marker.bytes) / 1_048_576 / (coldMs / 1_000),
            "residentBeforeScanBytes": residentBefore, "residentAfterScanBytes": residentAfter,
            "peakRSSBeforeScanBytes": peakBefore, "peakRSSAfterScanBytes": peakAfter,
            "warmRefreshMs": warmMs, "warmFilesUnchanged": warm.filesUnchanged,
            "appendRefreshMs": tailMs, "appendBytesRead": tail.bytesRead,
            "snapshot90DaysMs": snapshotMs, "databaseBytes": databaseBytes,
            "build": ProcessInfo.processInfo.environment["LOOM_USAGE_CORPUS_BUILD"] ?? "unspecified",
        ]
        if let path = environment["LOOM_USAGE_CORPUS_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print("USAGE-CORPUS", report)
    }
}
