import AppKit
import Foundation
@testable import LoomChat
import LoomCore
import Testing
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// A scripted Chat driver: a live model whose changes go out as the driver's do (a snapshot first, then numbered growth),
/// with a change that can be lost on the way, a `/clear` move, and the live state.
actor ScriptedLiveSource: ChatLiveSource {
    private(set) var model = TurnModel(source: .live)
    private var sequence = 0
    private var entries = 0
    private var turns = 0
    private var state: ChatLiveState
    private var changeSubscribers: [AsyncStream<ModelChange>.Continuation] = []
    private var updateSubscribers: [AsyncStream<Void>.Continuation] = []
    private(set) var snapshots = 0

    init(card: UUID, conversationID: String?) {
        state = ChatLiveState(sessionID: card, conversationID: conversationID, phase: .ready)
    }

    func modelChanges() -> ChatModelChanges {
        let (stream, continuation) = AsyncStream.makeStream(of: ModelChange.self)
        changeSubscribers.append(continuation)
        continuation.yield(model.snapshot(sequence: sequence, hasOlder: false))
        return ChatModelChanges(changes: stream)
    }

    func snapshotChange() -> ModelChange {
        snapshots += 1
        return model.snapshot(sequence: sequence, hasOlder: false)
    }

    func liveState() -> ChatLiveState { state }

    func updates() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        updateSubscribers.append(continuation)
        continuation.yield()
        return stream
    }

    /// A change of the live model; `deliver: false` loses it on the way (the reader sees the next number only).
    func change(deliver: Bool = true, _ make: @Sendable (inout TurnModel) -> ModelDelta) {
        let delta = make(&model)
        sequence += 1
        let change = model.growth(sequence: sequence, entriesBefore: entries, turnsBefore: turns, delta: delta, hasOlder: false)
        entries = model.entries.count
        turns = model.turns.count
        if deliver { for continuation in changeSubscribers { continuation.yield(change) } }
    }

    func setState(_ edit: @Sendable (inout ChatLiveState) -> Void) {
        edit(&state)
        for continuation in updateSubscribers { continuation.yield() }
    }

    /// A new run begins (a resume): what the model holds now is the earlier runs'.
    func startRun(at time: Date = Date()) {
        state.runStart = LiveHistoryJoin.RunStart(entries: model.entries.count, turns: model.turns.count,
                                                  unknownRecords: model.unknownRecordCount, time: time,
                                                  generation: state.runStart.generation + 1)
        for continuation in updateSubscribers { continuation.yield() }
    }

    /// `/clear`: the run moves to `card` and the model starts over with the marker.
    func clear(to card: UUID) {
        state.sessionID = card
        state.conversationID = nil
        state.runStart = LiveHistoryJoin.RunStart()
        var fresh = TurnModel(source: .live)
        fresh.appendMarker(.reset(trigger: "clear"))
        model = fresh
        sequence += 1
        entries = model.entries.count
        turns = model.turns.count
        for continuation in changeSubscribers { continuation.yield(model.snapshot(sequence: sequence, hasOlder: false)) }
        for continuation in updateSubscribers { continuation.yield() }
    }
}

extension ChatHosted {
    /// The live chat's feed: the transcript's history above the driver's live model in one presentation, kept consistent
    /// with a full rebuild after every change (`ChatRowCheck`).
    @MainActor
    @Suite
    struct LiveChatFeedTests {
        struct Profile {
            let root: URL
            let id = UUID().uuidString.lowercased()
            let file: URL

            init(lines: [String]) throws {
                root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-live-feed-\(UUID().uuidString)", isDirectory: true)
                let folder = root.appendingPathComponent("projects/-tmp-live-feed", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                file = folder.appendingPathComponent("\(id).jsonl")
                try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            }

            func append(_ lines: [String]) throws {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            }

            func remove() { try? FileManager.default.removeItem(at: root) }
        }

        private func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        nonisolated private static func assistant(_ messageID: String, _ text: String) -> StreamMessage {
            LiveScript.message(["type": "assistant", "uuid": .string("a-" + messageID), "session_id": "s1", "parent_tool_use_id": .null,
                                "message": ["id": .string(messageID), "role": "assistant", "model": "m",
                                            "content": [["type": "text", "text": .string(text)]]]])
        }

        nonisolated private static func echo(_ text: String, uuid: String) -> StreamMessage {
            LiveScript.message(["type": "user", "uuid": .string(uuid), "session_id": "s1", "isReplay": true,
                                "message": ["role": "user", "content": .string(text)]])
        }

        /// A whole live turn, a change per step: the prompt, its echo, the answer, the result. `losing` loses the answer's change.
        private static func liveTurn(_ source: ScriptedLiveSource, _ n: Int, losing: Bool = false) async {
            await source.change { $0.appendPendingUser(uuid: "u\(n)", text: "prompt \(n)") }
            await source.change { $0.apply(echo("prompt \(n)", uuid: "u\(n)")) }
            await source.change(deliver: !losing) { $0.apply(assistant("m\(n)", "answer \(n)")) }
            await source.change { $0.apply(LiveScript.result()) }
        }

        private static func prompts(_ model: TurnModel) -> [String] {
            model.entries.compactMap { if case let .user(prompt) = $0.body { prompt.text } else { nil } }
        }

        @Test func theHandOffShowsTheBoundaryTurnOnceAndNothingIsDrawnTwice() async throws {
            // Two turns before the run, and the run's first turn, which the CLI already wrote.
            let profile = try Profile(lines: ChatFixture.turn(1) + ChatFixture.turn(2, start: 10) + [
                ChatFixture.user("prompt 3", uuid: "u3", at: 20),
                ChatFixture.assistant("m3", uuid: "a3", blocks: [ChatFixture.text("answer 3")], at: 21),
            ])
            defer { profile.remove() }
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: profile.id)
            await Self.liveTurn(source, 3)
            let feed = LiveChatFeed(source: source, card: card, conversationID: profile.id, configDirectory: profile.root,
                                    workingDirectory: nil)
            let stream = ChatHostedStream()
            let rowCheck = ChatRowCheck(feed)
            feed.attach(stream.controller)
            feed.start()
            #expect(await waitUntil { feed.phase == .ready && Self.prompts(feed.presentation.model).count == 3 })
            #expect(Self.prompts(feed.presentation.model) == ["prompt 1", "prompt 2", "prompt 3"])
            let rows = stream.controller.rows
            #expect(Set(rows.map(\.id)).count == rows.count)
            #expect(rows.filter { if case .user = $0.kind { true } else { false } }.count == 3)

            // The run goes on: the driver's changes grow the stream; the transcript's growth is not read.
            await Self.liveTurn(source, 4)
            try profile.append([ChatFixture.user("prompt 4", uuid: "u4", at: 30), ChatFixture.assistant("m4", uuid: "a4", blocks: [ChatFixture.text("answer 4")], at: 31)])
            #expect(await waitUntil { Self.prompts(feed.presentation.model).count == 4 })
            await stream.settle()
            #expect(Self.prompts(feed.presentation.model) == ["prompt 1", "prompt 2", "prompt 3", "prompt 4"])
            #expect(feed.presentation.model.rowInputsEqual(feed.joinedModelForTesting))
            #expect(stream.controller.rows.filter { if case .user = $0.kind { true } else { false } }.count == 4)
            #expect(feed.snapshotsAsked == 0)
            rowCheck.expectClean("the feed")
            stream.controller.stop()
        }

        @Test func aNewRunReadsTheHistoryAgainWithWhatRanInTheTerminalBetween() async throws {
            let profile = try Profile(lines: [ChatFixture.user("prompt 1", uuid: "u1", at: 0),
                                              ChatFixture.assistant("m1", uuid: "a1", blocks: [ChatFixture.text("answer 1")], at: 1)])
            defer { profile.remove() }
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: profile.id)
            await Self.liveTurn(source, 1)
            let feed = LiveChatFeed(source: source, card: card, conversationID: profile.id, configDirectory: profile.root,
                                    workingDirectory: nil)
            let stream = ChatHostedStream()
            let rowCheck = ChatRowCheck(feed)
            feed.attach(stream.controller)
            feed.start()
            #expect(await waitUntil { feed.phase == .ready && Self.prompts(feed.presentation.model) == ["prompt 1"] })
            // A turn in the terminal, then the Chat face again: the same driver, a new run.
            try profile.append([ChatFixture.user("prompt 2", uuid: "u2", at: 10),
                                ChatFixture.assistant("m2", uuid: "a2", blocks: [ChatFixture.text("answer 2")], at: 11)])
            await source.startRun()
            await Self.liveTurn(source, 3)
            try profile.append([ChatFixture.user("prompt 3", uuid: "u3", at: 20),
                                ChatFixture.assistant("m3", uuid: "a3", blocks: [ChatFixture.text("answer 3")], at: 21)])
            #expect(await waitUntil { Self.prompts(feed.presentation.model) == ["prompt 1", "prompt 2", "prompt 3"] })
            await Self.liveTurn(source, 4)
            #expect(await waitUntil { Self.prompts(feed.presentation.model).count == 4 })
            #expect(Self.prompts(feed.presentation.model) == ["prompt 1", "prompt 2", "prompt 3", "prompt 4"])
            #expect(feed.presentation.model.rowInputsEqual(feed.joinedModelForTesting))
            rowCheck.expectClean("the feed")
            stream.controller.stop()
        }

        /// Chat → Terminal → Chat, then a run that added nothing (stopped at once) and the terminal again: each new run
        /// reads the history again by its generation, and the earlier runs' face markers stay, at their time.
        @Test func aNewRunThatAddedNothingStillReadsTheHistoryAgainAndEarlierMarkersStay() async throws {
            let profile = try Profile(lines: [ChatFixture.user("prompt 1", uuid: "u1", at: 0),
                                              ChatFixture.assistant("m1", uuid: "a1", blocks: [ChatFixture.text("answer 1")], at: 1)])
            defer { profile.remove() }
            let base = try #require(ISO8601DateFormatter().date(from: "2026-10-17T10:00:00Z"))
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: profile.id)
            await Self.liveTurn(source, 1)
            await source.change { $0.appendMarker(.face(.continuedInTerminal), at: base.addingTimeInterval(5)) }
            let feed = LiveChatFeed(source: source, card: card, conversationID: profile.id, configDirectory: profile.root,
                                    workingDirectory: nil)
            let stream = ChatHostedStream()
            let rowCheck = ChatRowCheck(feed)
            feed.attach(stream.controller)
            feed.start()
            #expect(await waitUntil { feed.phase == .ready && Self.prompts(feed.presentation.model) == ["prompt 1"] })
            let markers = { feed.presentation.model.entries.compactMap { if case let .marker(marker) = $0.body { marker } else { nil } } }
            #expect(markers() == [.face(.continuedInTerminal)])

            try profile.append([ChatFixture.user("prompt 2", uuid: "u2", at: 10),
                                ChatFixture.assistant("m2", uuid: "a2", blocks: [ChatFixture.text("answer 2")], at: 11)])
            await source.startRun(at: base.addingTimeInterval(15))
            #expect(await waitUntil { Self.prompts(feed.presentation.model) == ["prompt 1", "prompt 2"] })
            #expect(markers() == [.face(.continuedInTerminal)])
            let entries = feed.presentation.model.entries
            let carried = entries.firstIndex { $0.body == .marker(.face(.continuedInTerminal)) }
            let terminal = entries.firstIndex { $0.id == "u2" }
            #expect(carried != nil && terminal != nil && carried! < terminal!)

            // The second Chat run added nothing; the terminal ran a turn after it; a third run begins at the same counts.
            try profile.append([ChatFixture.user("prompt 3", uuid: "u3", at: 20),
                                ChatFixture.assistant("m3", uuid: "a3", blocks: [ChatFixture.text("answer 3")], at: 21)])
            await source.startRun(at: base.addingTimeInterval(25))
            #expect(await waitUntil { Self.prompts(feed.presentation.model) == ["prompt 1", "prompt 2", "prompt 3"] })
            #expect(markers() == [.face(.continuedInTerminal)])
            #expect(feed.presentation.model.rowInputsEqual(feed.joinedModelForTesting))
            rowCheck.expectClean("the feed")
            stream.controller.stop()
        }

        /// The live row's "No activity" follows the driver's stdout time alone: Loom's own edits (a pending send) and the
        /// snapshots it takes do not make the session look active.
        @Test func theQuietTimerFollowsTheDriversStdoutOnly() async throws {
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: nil)
            await source.change { $0.appendPendingUser(uuid: "u1", text: "prompt 1") }
            await source.change { $0.apply(Self.echo("prompt 1", uuid: "u1")) }
            let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            let stream = ChatHostedStream()
            feed.attach(stream.controller)
            feed.start()
            let heard = Date().addingTimeInterval(-60)
            await source.setState { state in
                state.turnRunning = true
                state.lastActivity = heard
            }
            let live = { stream.controller.rows.compactMap { row -> LiveRow? in if case let .live(live) = row.kind { live } else { nil } }.first }
            #expect(await waitUntil { live()?.lastActivity == heard })
            await source.change { $0.appendPendingUser(uuid: "u2", text: "a message sent meanwhile") }
            #expect(await waitUntil { Self.prompts(feed.presentation.model).count == 2 })
            await stream.settle()
            #expect(live()?.lastActivity == heard)
            stream.controller.stop()
        }

        @Test func showAllNeedsTheTranscriptsFolderForALiveRow() throws {
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: nil)
            let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            var model = TurnModel(source: .live)
            model.appendMarker(.notice("a live row"))
            let live = try #require(model.entries.first)
            var read = live
            read.sourceOffset = 40
            #expect(!feed.canShowAll(live))
            #expect(feed.canShowAll(read))
            let folder = LiveChatFeed(source: source, card: card, conversationID: nil,
                                      configDirectory: FileManager.default.temporaryDirectory, workingDirectory: nil)
            #expect(folder.canShowAll(live))
        }

        /// A feed nobody shows whose run is over goes (the host lets it go); while a view shows it, or its run lives, it stays.
        @Test func aFeedNobodyShowsWhoseRunIsOverIsLetGo() async throws {
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: nil)
            let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            final class Released { var count = 0 }
            let released = Released()
            feed.onUnused = { released.count += 1 }
            let view = LiveChatViewModel(feed: feed)
            view.setWindowVisible(true)
            view.setOnScreen(true)
            #expect(feed.isInUse)
            #expect(await waitUntil { feed.phase == .ready })
            // The view goes while the run lives: kept.
            view.close()
            #expect(feed.viewCount == 0)
            #expect(feed.isInUse)
            #expect(released.count == 0)
            // The run ends: nobody needs it.
            await source.setState { $0.phase = .stopped }
            #expect(await waitUntil { released.count == 1 })
            #expect(!feed.isInUse)
        }

        private func cutOffState(_ source: ScriptedLiveSource) async {
            let input: JSONValue = ["command": "rm -rf build", "description": "Remove it"]
            let fields: [String: JSONValue] = ["subtype": "can_use_tool", "tool_name": "Bash", "input": input, "tool_use_id": "toolu_a"]
            let pending = ChatPendingRequest(requestID: "a", request: ToolPermissionRequest(json: .object(fields))!,
                                             arrivedAt: Date(), agent: nil)
            let cut = ChatSettledRequest(request: pending, outcome: .processEnded, summary: "Not answered, Claude stopped: rm -rf build",
                                         settledAt: Date())
            // The process is killed while the request waits.
            await source.setState { $0.phase = .failed(.ended); $0.settled = [cut] }
        }

        /// A run that ended with a request unanswered leaves a cut-off card that the ended view draws from this feed. The ended view
        /// counts as a view of it, so the host keeps the feed while that view is shown and lets it go when it goes (M3: a cut-off
        /// card used to keep the feed for as long as the app ran, for a session nobody showed).
        @Test func aFeedOnlyAnEndedViewShowsIsReleasedWhenThatViewGoes() async throws {
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: nil)
            let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            final class Released { var count = 0 }
            let released = Released()
            feed.onUnused = { released.count += 1 }
            await cutOffState(source)
            feed.endedViewAppeared()
            #expect(await waitUntil { feed.cards.cutOff.count == 1 }, "the cut-off card shows from the driver's settled requests")
            try await Task.sleep(for: .milliseconds(100))
            #expect(released.count == 0 && feed.isInUse, "the ended view is on screen")
            feed.endedViewWentAway()
            #expect(released.count == 1 && !feed.isInUse, "nobody shows the feed: the host may let it go")
        }

        /// The driver keeps what was cut off, so a feed that was let go is made again when the session is opened, and shows it.
        @Test func aReleasedFeedShowsTheCutOffCardAgainWhenTheSessionIsOpened() async throws {
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: nil)
            await cutOffState(source)
            let first = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            first.endedViewAppeared()
            #expect(await waitUntil { first.cards.cutOff.count == 1 })
            first.endedViewWentAway()
            let again = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            again.endedViewAppeared()
            #expect(await waitUntil { again.cards.cutOff.count == 1 })
            again.endedViewWentAway()
        }

        /// A run that ends while no view shows its feed lets it go, cut-off card or not.
        @Test func aRunThatEndsUnseenReleasesItsFeedEvenWithACutOffCard() async throws {
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: nil)
            let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            final class Released { var count = 0 }
            let released = Released()
            feed.onUnused = { released.count += 1 }
            feed.start()
            await source.setState { $0.phase = .ready }
            #expect(await waitUntil { feed.isInUse })
            await cutOffState(source)
            #expect(await waitUntil { released.count == 1 })
            #expect(!feed.isInUse)
        }

        @Test func aLostChangeAsksTheDriverForASnapshot() async throws {
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: nil)
            let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            let stream = ChatHostedStream()
            let rowCheck = ChatRowCheck(feed)
            feed.attach(stream.controller)
            feed.start()
            await Self.liveTurn(source, 1)
            #expect(await waitUntil { Self.prompts(feed.presentation.model) == ["prompt 1"] })
            await Self.liveTurn(source, 2, losing: true)
            await Self.liveTurn(source, 3)
            var expected = await source.model
            #expect(await waitUntil { feed.presentation.model.rowInputsEqual(expected) })
            #expect(Self.prompts(feed.presentation.model).count == 3)
            #expect(feed.snapshotsAsked == 1)
            #expect(await source.snapshots == 1)
            await Self.liveTurn(source, 4)
            expected = await source.model
            #expect(await waitUntil { feed.presentation.model.rowInputsEqual(expected) })
            #expect(feed.snapshotsAsked == 1)
            rowCheck.expectClean("the feed")
            stream.controller.stop()
        }

        @Test func clearFollowsTheRunToTheNewCardWithTheMarkerAndNoHistory() async throws {
            let profile = try Profile(lines: ChatFixture.turn(1))
            defer { profile.remove() }
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: profile.id)
            await Self.liveTurn(source, 2)
            let feed = LiveChatFeed(source: source, card: card, conversationID: profile.id, configDirectory: profile.root,
                                    workingDirectory: nil)
            let stream = ChatHostedStream()
            let rowCheck = ChatRowCheck(feed)
            feed.attach(stream.controller)
            feed.start()
            #expect(await waitUntil { Self.prompts(feed.presentation.model) == ["prompt 1", "prompt 2"] })
            let before = feed.presentation

            let newCard = UUID()
            await source.clear(to: newCard)
            #expect(await waitUntil { feed.presentation !== before && feed.presentation.isLoaded })
            #expect(feed.card == newCard)
            #expect(before.controller == nil)
            #expect(feed.presentation.controller === stream.controller)
            let markers = feed.presentation.model.entries.compactMap { if case let .marker(marker) = $0.body { marker } else { nil } }
            #expect(markers == [.reset(trigger: "clear")])
            #expect(Self.prompts(feed.presentation.model).isEmpty)
            await Self.liveTurn(source, 5)
            #expect(await waitUntil { Self.prompts(feed.presentation.model) == ["prompt 5"] })
            #expect(stream.controller.rows.filter { if case .user = $0.kind { true } else { false } }.count == 1)
            rowCheck.expectClean("the feed")
            stream.controller.stop()
        }

        @Test func theLiveRowFollowsTheDriversWorkAndActivityAndTheNoticesItsSignals() async throws {
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: nil)
            await source.change { $0.appendPendingUser(uuid: "u1", text: "prompt 1") }
            let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            let stream = ChatHostedStream()
            let rowCheck = ChatRowCheck(feed)
            feed.attach(stream.controller)
            feed.start()
            #expect(await waitUntil { feed.phase == .ready })
            // A stdout line that changed no row still counts as activity.
            let heard = Date().addingTimeInterval(5)
            await source.setState { state in
                state.turnRunning = true
                state.lastActivity = heard
                state.policySignal = ChatPolicySignal(category: "billing_error", source: .assistantError)
                state.drift = [.unknownRecord(type: "x", subtype: nil), .missingCapability("interrupt_receipt_v1")]
            }
            let live = { stream.controller.rows.compactMap { row -> LiveRow? in if case let .live(live) = row.kind { live } else { nil } }.first }
            #expect(await waitUntil { live()?.lastActivity == heard })
            #expect(feed.policySignal?.category == "billing_error")
            #expect(feed.wireDrift == 1)
            // The turn's result ends it: the live row goes.
            await source.change { $0.apply(LiveScript.result()) }
            await source.setState { $0.turnRunning = false }
            #expect(await waitUntil { live() == nil })
            rowCheck.expectClean("the feed")
            stream.controller.stop()
        }

        @Test func showAllReadsALiveRowsWholeResultFromTheTranscript() async throws {
            let big = (0..<4000).map { "line \($0) of a long output" }.joined(separator: "\n")
            let tool = ChatFixture.tool("t1", "Bash", ["command": "cat big.log"])
            let profile = try Profile(lines: ChatFixture.turn(1) + [
                ChatFixture.user("prompt 2", uuid: "u2", at: 20),
                ChatFixture.assistant("m2", uuid: "a2", blocks: [tool], at: 21),
                ChatFixture.result("t1", big, at: 22),
            ])
            defer { profile.remove() }
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: profile.id)
            await source.change { $0.appendPendingUser(uuid: "u2", text: "prompt 2") }
            await source.change {
                $0.apply(LiveScript.message(["type": "assistant", "uuid": "a2", "session_id": "s1", "parent_tool_use_id": .null,
                                             "message": ["id": "m2", "role": "assistant", "model": "m", "content": [tool]]]))
            }
            await source.change { $0.apply(LiveScript.toolResult("t1", big)) }
            let feed = LiveChatFeed(source: source, card: card, conversationID: profile.id, configDirectory: profile.root,
                                    workingDirectory: nil)
            feed.start()
            #expect(await waitUntil { feed.phase == .ready && feed.presentation.model.entry(id: "t1") != nil })
            let entry = try #require(feed.presentation.model.entry(id: "t1"))
            // A live row: no line of its own, a clipped output.
            #expect(entry.sourceOffset == nil)
            guard case let .tool(call) = entry.body else { Issue.record("not a tool"); return }
            #expect(call.output?.isClipped == true)
            feed.showAll(entry)
            #expect(await waitUntil { feed.presentation.hasFullOutput("t1") })
            // The turn still runs, so its trailing tool sits in the live row; the text is the presentation's.
            guard case let .text(full)? = feed.presentation.buildInput().fullOutputs["t1"] else {
                Issue.record("the whole result was not read")
                return
            }
            #expect(full.hasPrefix("line 0 of a long output"))
            #expect(full.contains("line 3999 of a long output"))
        }

        @Test func aCoveredOrClosedViewKeepsThePresentationGoing() async throws {
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: nil)
            let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            var view: LiveChatViewModel? = LiveChatViewModel(feed: feed)
            view?.setWindowVisible(true)
            view?.setOnScreen(true)
            await Self.liveTurn(source, 1)
            #expect(await waitUntil { Self.prompts(feed.presentation.model) == ["prompt 1"] })
            let presentation = feed.presentation
            #expect(presentation.controller === view?.controller)
            // Covered: nothing is drawn, the model still follows the driver.
            view?.setWindowVisible(false)
            #expect(presentation.controller == nil)
            await Self.liveTurn(source, 2)
            #expect(await waitUntil { Self.prompts(presentation.model).count == 2 })
            // A new view of the same session shows the same presentation, with everything.
            view?.close()
            view = nil
            let again = LiveChatViewModel(feed: feed)
            again.setWindowVisible(true)
            again.setOnScreen(true)
            #expect(feed.presentation === presentation)
            #expect(await waitUntil { again.controller.rows.filter { if case .user = $0.kind { true } else { false } }.count == 2 })
            again.close()
        }

        /// D15: the feed's one-shot tasks (a history read per run, the cards' state per appearance of an ended view) leave its table
        /// when they are done; a long-lived feed does not collect one per run.
        @Test func finishedOneShotTasksDoNotPileUpInALongLivedFeed() async throws {
            let card = UUID()
            let source = ScriptedLiveSource(card: card, conversationID: nil)
            let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
            for _ in 0..<40 {
                feed.endedViewAppeared()
                feed.endedViewWentAway()
            }
            #expect(await waitUntil { feed.activeOneShots == 0 }, "\(feed.activeOneShots) tasks still held")
            feed.start()
            #expect(await waitUntil { feed.phase == .ready })
            for generation in 0..<10 {
                await source.startRun()
                _ = generation
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(feed.activeOneShots == 0)
        }
    }
}
