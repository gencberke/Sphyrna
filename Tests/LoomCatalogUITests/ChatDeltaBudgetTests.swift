import AppKit
import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI

extension ChatHosted {
    /// The chat budgets that must hold as the transcript grows (V2-CONCEPT §5.7, V2-PLAN §7 "Budgets as tests"). Two kinds
    /// of number: counts (bytes read from a file, rows drawn) are exact and the same in every build; times are for a debug
    /// build and are stated as a ceiling with room for a loaded Mac, plus a ratio between two transcript sizes that does not
    /// depend on the build or the machine. Every number prints as a `BUDGET ...` line.
    @MainActor
    @Suite
    struct ChatDeltaBudgetTests {
        /// What a delta costs on a stream of about 21,000 rows is stated in counts, which are the same in every build and on
        /// every Mac: the turns whose rows were derived, the entries a change carried and the rows drawn again. A clock cannot
        /// state it (a loaded Mac crosses any ceiling, and this test failed in a full run that way), so the times below are
        /// printed as `BUDGET` lines for the record and nothing asserts them. Measured on an M2 in debug: a typical delta 3 to 6 ms
        /// (the rows are derived in 0.2 ms; the rest is AppKit updating the table), the delta that starts a turn about 20 ms; the
        /// full rebuild this replaced took 241 ms. A release build is several times faster.
        /// A delta touches the newest turn, the one before it, and a turn that starts: derivation may not go past this.
        static let turnsDerivedPerDeltaCeiling = 3
        /// The one time ceiling left, for `ChatBudgetTests` (a delta on a stream with a clock: a loaded Mac may cross it).
        static let worstDeltaCeilingMs = 60.0
        /// The entries one change of this test's script carries (a prompt and a tool, a result, a few words).
        static let entriesPerChangeCeiling = 4

        struct DeltaRun {
            var rows: Int
            var typical: Double
            var worst: Double
            var times: [Double]
            var redrawn: Int
            var oldRowsKept: Bool
            /// What the lens spent reading each growth (off the main thread).
            var lensTimes: [Double]
            /// Per delta: applying the change to the model, deriving the rows, updating the stream.
            var parts: [ChatPresentation.Timings]
            /// Per delta: turns whose rows were derived, and entries the change carried (appended and updated).
            var derived: [Int]
            var carried: [Int]
        }

        private static func milliseconds(_ since: ContinuousClock.Instant) -> Double {
            let d = ContinuousClock.now - since
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }

        /// A session of `turns` turns with every older page loaded (the way a reader who scrolled to the top has it), then
        /// `deltas` small growths of the newest turn: a new prompt, then tools finishing and starting and a few words.
        static func run(turns: Int, deltas: Int) async throws -> DeltaRun {
            ChatSessionMemoryStore.removeAll()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-delta-\(UUID().uuidString)", isDirectory: true)
            let folder = root.appendingPathComponent("projects/-tmp-delta", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID().uuidString.lowercased()
            let url = folder.appendingPathComponent("\(id).jsonl")
            var text = ""
            for index in 0..<turns {
                text += ChatFixture.turn(index, tools: [ChatFixture.bash("make \(index)")], answer: "Answer \(index).", start: index % 3000)
                    .joined(separator: "\n") + "\n"
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            let located = try #require(ClaudeTranscriptLocator.locate(sessionID: id, configDirectory: root))
            let lens = try #require(TranscriptLens(file: located))
            var latest = await lens.coldOpenChange()
            while latest.hasOlder, let older = await lens.loadOlderChange() { latest = older }

            let model = ChatTranscriptModel(sessionID: id, configDirectory: root, workingDirectory: nil, isWorking: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            model.controller.scrollView.frame = window.contentView!.bounds
            window.contentView!.addSubview(model.controller.scrollView)
            window.contentView!.layoutSubtreeIfNeeded()
            model.setWindowVisible(true)
            model.presentation.beginSource()
            model.presentation.apply(latest)
            for _ in 0..<8 { model.controller.scrollView.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(15)) }
            let rows = model.controller.rows.count
            let before = model.controller.rows

            ChatRenderProbe.watch()
            defer { ChatRenderProbe.stop() }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            var times: [Double] = []
            var lensTimes: [Double] = []
            var parts: [ChatPresentation.Timings] = []
            var derived: [Int] = []
            var carried: [Int] = []
            var tool = 0
            for delta in 0..<deltas {
                var lines: [String] = []
                let second = 10 + delta
                switch delta % 3 {
                case 0 where delta == 0:
                    lines = [ChatFixture.user("next step", uuid: "live-u", at: 5)]
                    fallthrough
                case 0:
                    tool += 1
                    lines.append(ChatFixture.assistant("live-m\(tool)", uuid: "live-c\(tool)",
                                                       blocks: [ChatFixture.tool("live-t\(tool)", "Bash", ["command": .string("swift build \(tool)")])], at: second))
                case 1:
                    lines = [ChatFixture.result("live-t\(tool)", "Build complete \(tool)", at: second)]
                default:
                    lines = [ChatFixture.assistant("live-w\(delta)", uuid: "live-a\(delta)", blocks: [ChatFixture.text("Step \(delta) is done, moving on.")], at: second)]
                }
                try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
                let read = ContinuousClock.now
                let growth = await lens.readGrowthChange()
                lensTimes.append(milliseconds(read))
                let start = ContinuousClock.now
                let derivedBefore = model.presentation.rowTurnsDerived
                model.presentation.apply(growth)
                times.append(milliseconds(start))
                derived.append(model.presentation.rowTurnsDerived - derivedBefore)
                carried.append(growth.appended.count + growth.updated.count)
                parts.append(model.presentation.lastTimings)
                for _ in 0..<3 { model.controller.scrollView.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
            }
            try handle.close()
            let kept = before.count - 8
            let oldRowsKept = Array(model.controller.rows.prefix(kept)) == Array(before.prefix(kept))
            let redrawn = ChatRenderProbe.configured.count
            model.close()
            await lens.close()
            let sorted = times.sorted()
            // The first delta starts a turn (the one before it settles); the rest are the typical ones.
            let steady = Array(times.dropFirst()).sorted()
            return DeltaRun(rows: rows, typical: steady[steady.count / 2], worst: sorted.last ?? 0, times: times, redrawn: redrawn, oldRowsKept: oldRowsKept, lensTimes: lensTimes, parts: parts, derived: derived, carried: carried)
        }

        @Test func aDeltaCostsTheNewestTurnNotTheTranscript() async throws {
            let small = try await Self.run(turns: 700, deltas: 30)
            let large = try await Self.run(turns: 7_000, deltas: 30)
            #if DEBUG
            let build = "debug"
            #else
            let build = "release"
            #endif
            print(String(format: "BUDGET delta %d rows: typical=%.2f ms worst=%.2f ms first=%.2f ms redrawn=%d | %d rows: typical=%.2f ms worst=%.2f ms first=%.2f ms redrawn=%d | ratio=%.2f (%@ build)",
                         small.rows, small.typical, small.worst, small.times[0], small.redrawn,
                         large.rows, large.typical, large.worst, large.times[0], large.redrawn, large.typical / max(small.typical, 0.01), build))
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            print(String(format: "BUDGET delta parts at %d rows (median over deltas): model apply=%.3f ms, derive rows=%.3f ms, update stream=%.3f ms",
                         large.rows, median(large.parts.map(\.model)), median(large.parts.map(\.derive)), median(large.parts.map(\.stream))))
            print(String(format: "BUDGET delta lens read (off the main thread): %d rows median=%.2f ms; %d rows median=%.2f ms",
                         small.rows, small.lensTimes.sorted()[small.lensTimes.count / 2], large.rows, large.lensTimes.sorted()[large.lensTimes.count / 2]))
            print("BUDGET delta counts: turns derived per delta \(small.derived.max() ?? 0) at \(small.rows) rows, \(large.derived.max() ?? 0) at \(large.rows) rows; entries carried per change at most \(large.carried.max() ?? 0)")
            #expect(large.rows >= 21_000, "rows loaded: \(large.rows)")
            #expect(large.oldRowsKept, "the rows of the turns a delta did not touch are the rows they were")
            // The turns a delta derives do not depend on the transcript: the same at 700 turns and at 7,000.
            #expect((large.derived.max() ?? 0) <= Self.turnsDerivedPerDeltaCeiling, "turns derived per delta: \(large.derived)")
            #expect(large.derived == small.derived, "turns derived per delta, \(small.rows) rows: \(small.derived), \(large.rows) rows: \(large.derived)")
            #expect((large.carried.max() ?? 0) <= Self.entriesPerChangeCeiling, "entries carried per change: \(large.carried)")
            // Only rows of the newest turn are drawn again: a few per delta, never the transcript.
            #expect(large.redrawn <= 30 * 8, "rows drawn again: \(large.redrawn)")
            #expect(large.redrawn <= small.redrawn + 8, "rows drawn again, \(small.rows) rows: \(small.redrawn), \(large.rows) rows: \(large.redrawn)")
        }

        // MARK: A slow main thread, a covered window

        /// A session of `turns` turns, all read at once, in a hosted window, followed by a feed.
        private static func followedSession(turns: Int, in root: URL) async throws -> (model: ChatTranscriptModel, url: URL, window: NSWindow) {
            ChatSessionMemoryStore.removeAll()
            let folder = root.appendingPathComponent("projects/-tmp-burst", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = UUID().uuidString.lowercased()
            let url = folder.appendingPathComponent("\(id).jsonl")
            var text = ""
            for index in 0..<turns {
                text += ChatFixture.turn(index, tools: [ChatFixture.bash("make \(index)")], answer: "Answer \(index).", start: index % 3000)
                    .joined(separator: "\n") + "\n"
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            var limits = TranscriptLens.Limits()
            limits.coldOpenTurns = turns + 1
            limits.coldOpenBytes = 256 * 1024 * 1024
            let model = ChatTranscriptModel(sessionID: id, configDirectory: root, workingDirectory: nil, isWorking: true, limits: limits)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
            model.controller.scrollView.frame = window.contentView!.bounds
            window.contentView!.addSubview(model.controller.scrollView)
            window.contentView!.layoutSubtreeIfNeeded()
            model.setWindowVisible(true)
            model.setOnScreen(true)
            while model.phase == .resolving { try await Task.sleep(for: .milliseconds(10)) }
            for _ in 0..<10 { model.controller.scrollView.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            return (model, url, window)
        }

        /// A flag one thread sets and another reads.
        final class WriteDone: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var isSet: Bool { lock.withLock { value } }
            func set() { lock.withLock { value = true } }
        }

        /// The main thread does something long (a layout, a big redraw): nothing else runs on it meanwhile.
        private static func blockTheMainThread(for seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

        private static func peakResidentMiB() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_maxrss) / 1_048_576
        }

        @Test func aBusyMainThreadCostsOneRebuildNotOneForEveryBurst() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-burst-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let session = try await Self.followedSession(turns: 7_000, in: root)
            let model = session.model
            #expect(model.controller.rows.count >= 21_000, "rows: \(model.controller.rows.count)")
            let before = model.presentation.rebuilds
            let peakBefore = Self.peakResidentMiB()

            // Six bursts 50 ms apart are written while the main thread is blocked for 400 ms (the feed reads every 50 ms).
            let url = session.url
            let written = WriteDone()
            let writer = Task.detached {
                defer { written.set() }
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                for burst in 0..<6 {
                    var lines: [String] = []
                    if burst == 0 { lines.append(ChatFixture.user("next step", uuid: "burst-u", at: 5)) }
                    lines.append(ChatFixture.assistant("burst-m\(burst)", uuid: "burst-c\(burst)",
                                                       blocks: [ChatFixture.tool("burst-t\(burst)", "Bash", ["command": .string("swift build \(burst)")])], at: 10 + burst))
                    try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
                    try await Task.sleep(for: .milliseconds(50))
                }
                try handle.close()
            }
            // Blocked for 400 ms, and for as long as the writer needs after that (a slow Mac): every burst lands while it is blocked.
            Self.blockTheMainThread(for: 0.4)
            while !written.isSet { Self.blockTheMainThread(for: 0.05) }
            Self.blockTheMainThread(for: 0.15)
            try await writer.value
            var quiet = 0
            var last = model.presentation.rebuilds
            while quiet < 8 {
                try await Task.sleep(for: .milliseconds(50))
                model.controller.scrollView.layoutSubtreeIfNeeded()
                let now = model.presentation.rebuilds
                quiet = now == last ? quiet + 1 : 0
                last = now
            }
            let rebuilt = model.presentation.rebuilds - before
            print(String(format: "BUDGET busy main thread: 6 bursts in 300 ms, main blocked 400 ms: %d rebuilds; peak resident %.0f MiB before, %.0f MiB after",
                         rebuilt, peakBefore, Self.peakResidentMiB()))
            #expect(model.model.entries.contains { $0.id == "burst-t5" }, "everything that was written arrived")
            #expect(rebuilt >= 1 && rebuilt <= 2, "rebuilds: \(rebuilt)")
            model.close()
        }

        @Test func coveringAndUncoveringTheWindowOfAnUnchangedFileRebuildsNothing() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-cover-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let session = try await Self.followedSession(turns: 300, in: root)
            let model = session.model
            let rows = model.controller.rows
            let before = model.presentation.rebuilds
            for _ in 0..<4 {
                model.setWindowVisible(false)
                #expect(!model.isFeeding)
                try await Task.sleep(for: .milliseconds(60))
                model.setWindowVisible(true)
                #expect(model.isFeeding)
                try await Task.sleep(for: .milliseconds(200))
            }
            print("BUDGET cover/uncover x4 on an unchanged file: \(model.presentation.rebuilds - before) rebuilds")
            #expect(model.presentation.rebuilds == before)
            #expect(model.controller.rows == rows)
            model.close()
        }

        // MARK: Deriving rows

        /// The rows' share of a delta, without the table: `ChatRowStore.update` after one growth of the newest turn.
        /// Deriving 21,000 rows from scratch takes 70 to 150 ms in a debug build (it grows with the rows); a delta takes
        /// about 0.1 ms at any size. The test states it as the turns derived per delta (a count), not as a time.
        private static func storeDeltas(turns: Int, deltas: Int) -> (rows: Int, full: Double, times: [Double], derived: [Int]) {
            var lines: [String] = []
            for index in 0..<turns {
                lines += ChatFixture.turn(index, tools: [ChatFixture.bash("make \(index)")], answer: "Answer \(index).", start: index % 3000)
            }
            var model = ChatFixture.model(lines)
            var offset = ChatFixture.size(of: lines)
            func input(_ tick: Int) -> ChatBuildInput {
                ChatBuildInput(model: model, isWorking: true, lastActivity: Date(timeIntervalSince1970: 1_800_000_000 + Double(tick)))
            }
            var store = ChatRowStore()
            let begin = ContinuousClock.now
            _ = store.update(input(0), cause: .replaced)
            let full = milliseconds(begin)
            var times: [Double] = []
            var derived: [Int] = []
            var tool = 0
            for delta in 0..<deltas {
                var added: [String] = []
                switch delta % 3 {
                case 0:
                    tool += 1
                    if delta == 0 { added.append(ChatFixture.user("next step", uuid: "live-u", at: 5)) }
                    added.append(ChatFixture.assistant("live-m\(tool)", uuid: "live-c\(tool)",
                                                       blocks: [ChatFixture.tool("live-t\(tool)", "Bash", ["command": .string("swift build \(tool)")])], at: 10 + delta))
                case 1:
                    added.append(ChatFixture.result("live-t\(tool)", "Build complete \(tool)", at: 10 + delta))
                default:
                    added.append(ChatFixture.assistant("live-w\(delta)", uuid: "live-a\(delta)", blocks: [ChatFixture.text("Step \(delta) is done.")], at: 10 + delta))
                }
                var change = ModelDelta()
                for line in added {
                    let bytes = Data(line.utf8)
                    let made = model.apply(record: TranscriptLineRecord(offset: offset, length: bytes.count, bytes: bytes))
                    change.inserted += made.inserted
                    for id in made.updated where !change.inserted.contains(id) && !change.updated.contains(id) { change.updated.append(id) }
                    offset += UInt64(bytes.count + 1)
                }
                let snapshot = input(delta + 1)
                let start = ContinuousClock.now
                let derivedBefore = store.turnsDerived
                _ = store.update(snapshot, cause: .growth(change))
                times.append(milliseconds(start))
                derived.append(store.turnsDerived - derivedBefore)
            }
            return (store.rows.count, full, times, derived)
        }

        @Test func derivingTheRowsOfADeltaCostsTheNewestTurnNotTheTranscript() {
            let small = Self.storeDeltas(turns: 700, deltas: 60)
            let large = Self.storeDeltas(turns: 7_000, deltas: 60)
            func median(_ times: [Double]) -> Double { times.dropFirst().sorted()[(times.count - 1) / 2] }
            print(String(format: "BUDGET derive %d rows: full=%.1f ms, delta median=%.3f ms max=%.3f ms | %d rows: full=%.1f ms, delta median=%.3f ms max=%.3f ms",
                         small.rows, small.full, median(small.times), small.times.max() ?? 0,
                         large.rows, large.full, median(large.times), large.times.max() ?? 0))
            print("BUDGET derive counts: turns derived per delta \(small.derived.max() ?? 0) at \(small.rows) rows, \(large.derived.max() ?? 0) at \(large.rows) rows")
            #expect(large.rows >= 21_000)
            #expect((large.derived.max() ?? 0) <= Self.turnsDerivedPerDeltaCeiling, "turns derived per delta: \(large.derived)")
            #expect(large.derived == small.derived, "\(small.rows) rows: \(small.derived), \(large.rows) rows: \(large.derived)")
        }

        // MARK: Cold open

        @Test func openingAHugeTranscriptReadsAboutOnePointFiveMiBFromTheTail() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-cold-\(UUID().uuidString)", isDirectory: true)
            let folder = root.appendingPathComponent("projects/-tmp-cold", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID().uuidString.lowercased()
            let file = folder.appendingPathComponent("\(id).jsonl")
            let made = try ChatBudgetTests.writeLongTranscript(megabytes: 80, to: file)
            #expect(made.bytes >= 80_000_000)

            let located = try #require(ClaudeTranscriptLocator.locate(sessionID: id, configDirectory: root))
            let lens = try #require(TranscriptLens(file: located))
            let opened = await lens.coldOpen()
            let limits = TranscriptLens.Limits()
            print(String(format: "BUDGET cold-open file=%.1f MB bytesRead=%d (%.2f MiB) turns=%d", Double(made.bytes) / 1e6, opened.bytesRead,
                         Double(opened.bytesRead) / 1_048_576, opened.model.turns.count))
            #expect(opened.bytesRead > 0)
            #expect(opened.bytesRead <= limits.coldOpenBytes, "a cold open reads at most 1.5 MiB")
            #expect(opened.model.turns.count == limits.coldOpenTurns)
            #expect(opened.hasOlder)

            // An older page is read only when asked for (the stream asks when the reader nears the top), and it is bounded too.
            let older = try #require(await lens.loadOlder())
            let page = older.bytesRead - opened.bytesRead
            print("BUDGET older-page bytesRead=\(page) turns=\(older.model.turns.count)")
            #expect(page > 0 && page <= limits.olderBytes)
            #expect(older.model.turns.count == limits.coldOpenTurns + limits.olderTurns)
            #expect(older.bytesRead < made.bytes / 10, "two reads of a file this size are a small part of it")
            await lens.close()
        }

        @Test func olderTurnsLoadWhenTheReaderScrollsToTheTopAndNotBefore() async throws {
            ChatSessionMemoryStore.removeAll()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-chat-scroll-\(UUID().uuidString)", isDirectory: true)
            let folder = root.appendingPathComponent("projects/-tmp-scroll", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID().uuidString.lowercased()
            _ = try ChatBudgetTests.writeLongTranscript(megabytes: 50, to: folder.appendingPathComponent("\(id).jsonl"))

            let model = ChatTranscriptModel(sessionID: id, configDirectory: root, workingDirectory: nil)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            model.controller.scrollView.frame = window.contentView!.bounds
            window.contentView!.addSubview(model.controller.scrollView)
            window.contentView!.layoutSubtreeIfNeeded()
            model.setWindowVisible(true)
            model.setOnScreen(true)
            while model.phase == .resolving { try await Task.sleep(for: .milliseconds(5)) }
            for _ in 0..<10 { model.controller.scrollView.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let opening = model.controller.rows.count
            #expect(model.hasOlder)
            #expect(model.controller.isFollowing)
            #expect(opening < 100, "only the newest turns became rows: \(opening)")

            // Nothing more is read while the reader stays near the end.
            for _ in 0..<10 { model.controller.scrollView.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(model.controller.rows.count == opening)

            model.controller.handleKey(.home)
            var waited = 0
            while model.controller.rows.count == opening, waited < 400 {
                model.controller.scrollView.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
                waited += 1
            }
            print("BUDGET older-on-scroll rows \(opening) -> \(model.controller.rows.count)")
            #expect(model.controller.rows.count > opening, "the top of the stream asked for older turns")
            #expect(model.controller.rows.count < opening * 5, "one page of older turns, not the file")
            model.close()
        }
    }
}
