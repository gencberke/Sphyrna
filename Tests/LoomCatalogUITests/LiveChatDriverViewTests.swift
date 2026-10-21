import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// The live chat end to end (V16): the real Chat driver on the fake provider (a scoped supervisor, the runtime's Chat-face
// start, the fake's chat engine and its transcript under the isolated profile), its feed and presentation, and a stream
// whose rows are checked against a full rebuild after every change.

private final class LiveViewBundleAnchor: NSObject {}

struct LiveRig {
    let root: URL
    let profile: URL
    let socketDirectory: URL
    let runtime: SessionRuntime

    /// `forkable`: the fake CLI's help lists `--fork-session`, as a CLI that can fork a session does (the Side tab's fork).
    static func make(environment: [String: String] = [:], forkable: Bool = false) async throws -> LiveRig {
        let binaries = Bundle(for: LiveViewBundleAnchor.self).bundleURL.deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-live-view-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let profile = root.appendingPathComponent("claude-config", isDirectory: true)
        for directory in [home, profile] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let socketDirectory = URL(fileURLWithPath: "/tmp/lv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fake = bin.appendingPathComponent("loom-fake-provider")
        try FileManager.default.copyItem(at: binaries.appendingPathComponent("loom-fake-provider"), to: fake)
        let bundle = try RunScopeLauncher.assembleOwnedBundle(executable: binaries.appendingPathComponent("loom-run-host"), in: root)
        let supervisor = try await ProcessSupervisor.restoring(
            catalog: catalog,
            scopeLauncher: RunScopeLauncher(hostBundle: bundle, socketDirectory: socketDirectory.appendingPathComponent("rs"))
        )
        let fakePath = fake.path
        let resolver: ProviderToolchainResolver = { provider in
            ProviderToolchain(
                provider: provider, executable: fakePath,
                capabilities: ProviderCapabilities(
                    version: "fake 1",
                    help: "--settings <settings> --session-id <id> --effort <level> -n, --name <name> --plugin-dir <path> "
                        + "--permission-mode <mode> --model <model>" + (forkable ? " --fork-session" : ""),
                    serverHelp: "--listen <URL>"
                ),
                environment: ["PATH": "/usr/bin:/bin", "HOME": home.path].merging(environment) { _, new in new },
                profileDirectory: profile, extraArguments: []
            )
        }
        let runtime = SessionRuntime(
            supervisor: supervisor, catalog: catalog,
            configuration: SessionRuntimeConfiguration(
                toolchains: resolver,
                hookHelperPath: binaries.appendingPathComponent("loom-hook").path,
                socketDirectory: socketDirectory, homeDirectory: home.path,
                idlePolicy: SessionIdlePolicy(), codexIdentityTimeout: 3,
                claudePluginDirectory: root.appendingPathComponent("claude-plugin", isDirectory: true),
                hookSilenceGrace: 3, catalogBackupDelay: nil
            )
        )
        try await runtime.start()
        return LiveRig(root: root, profile: profile, socketDirectory: socketDirectory, runtime: runtime)
    }

    func finish() async {
        let report = await runtime.shutdown()
        #expect(report.succeeded)
        RunScopeLauncher.removeOwnedBundle(in: root)
        try? FileManager.default.removeItem(at: socketDirectory)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct LiveChatDriverViewTests {
    private func waitUntil(_ seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    private func idle(_ driver: ChatSessionDriver) async -> Bool {
        await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning }
    }

    private static func prompts(_ model: TurnModel) -> [String] {
        model.entries.compactMap { if case let .user(prompt) = $0.body { prompt.text } else { nil } }
    }

    private static func userRows(_ rows: [ChatRow]) -> Int {
        rows.filter { if case .user = $0.kind { true } else { false } }.count
    }

    /// A Chat session that already ran a turn is opened: its history comes from the transcript and the live turns from the
    /// driver, the turn at the joint once. Then a request card, an interrupt and `/clear`, each drawn as a full rebuild would
    /// draw it.
    @Test func theDriversSessionStreamsUnderItsHistoryThroughRequestsAnInterruptAndAClear() async throws {
        final class Mismatches { var reports: [String] = [] }
        let found = Mismatches()
        #if DEBUG
        ChatPresentation.verifiesRows = true
        ChatPresentation.onMismatch = { found.reports.append($0) }
        defer {
            ChatPresentation.verifiesRows = false
            ChatPresentation.onMismatch = nil
        }
        #endif
        let rig = try await LiveRig.make()
        let id = UUID()
        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root)
        let attachments = ChatAttachments()
        let driver = try await host.startNewSession(projectID: nil, sessionID: id)
        try await driver.send("hello before the view")
        #expect(await idle(driver))

        // The view opens now: the transcript holds the first turn, and so does the live model.
        let conversation = id.uuidString.lowercased()
        let feed = attachments.attachment(for: driver) {
            LiveChatFeed(source: driver, card: id, conversationID: conversation, configDirectory: rig.profile, workingDirectory: nil)
        }
        #expect(attachments.attachment(for: driver) { LiveChatFeed(source: driver, card: id, conversationID: nil, configDirectory: nil,
                                                            workingDirectory: nil) } === feed)
        let stream = ChatHostedStream()
        feed.attach(stream.controller)
        feed.start()
        #expect(await waitUntil { feed.phase == .ready && Self.prompts(feed.presentation.model) == ["hello before the view"] })
        #expect(Self.userRows(stream.controller.rows) == 1)

        // A send streams its rows.
        try await driver.send("second message")
        #expect(await idle(driver))
        #expect(await waitUntil { feed.presentation.model.texts.last == "Fake answer to: second message" })
        #expect(Self.prompts(feed.presentation.model) == ["hello before the view", "second message"])

        // A request: answered, it stays in the stream as a card.
        try await driver.send("/scenario approval")
        #expect(await waitUntil { await driver.snapshot().requests.count == 1 })
        let request = try #require(await driver.snapshot().requests.first)
        try await driver.respond(to: request.requestID, with: .allow(updatedInput: request.request.input),
                                 record: RequestRecord(kind: .approval, summary: "Allowed once: rm -rf build"))
        #expect(await idle(driver))
        #expect(await waitUntil { feed.presentation.model.entries.contains { if case .request = $0.body { true } else { false } } })
        // The settled turn folds it; the Verbose view (⌃O) shows every row.
        feed.presentation.setViewMode(.verbose)
        #expect(stream.controller.rows.contains { if case .request = $0.kind { true } else { false } })
        feed.presentation.setViewMode(.normal)

        // An interrupt: the turn reads "You stopped".
        try await driver.send("/scenario work 3000")
        #expect(await waitUntil { await driver.currentPhase == .working })
        await driver.interrupt()
        #expect(await idle(driver))
        #expect(await waitUntil { feed.presentation.model.turns.last?.status == .interrupted })
        #expect(await waitUntil { stream.controller.rows.contains { if case .divider = $0.kind { true } else { false } } })

        // `/clear`: the stream follows the run to the new card, with the marker and nothing of the old conversation.
        let before = feed.presentation
        try await driver.send("/clear")
        #expect(await waitUntil { await driver.sessionID != id })
        let card = await driver.sessionID
        #expect(await waitUntil { feed.card == card && feed.presentation !== before && feed.presentation.isLoaded })
        #expect(attachments.attachment(for: driver) { LiveChatFeed(source: driver, card: card, conversationID: nil, configDirectory: nil,
                                                            workingDirectory: nil) } === feed)
        #expect(feed.presentation.model.markers.contains(.reset(trigger: "clear")))
        #expect(Self.prompts(feed.presentation.model).isEmpty)
        try await driver.send("after the clear")
        #expect(await idle(driver))
        #expect(await waitUntil { Self.prompts(feed.presentation.model) == ["after the clear"] })
        #expect(Self.userRows(stream.controller.rows) == 1)

        let expected = await driver.snapshot().model
        #expect(await waitUntil { feed.presentation.model.rowInputsEqual(expected) })
        #expect(found.reports.isEmpty, "\(found.reports)")
        stream.controller.stop()
        _ = try await driver.stop()
        await rig.finish()
    }
}

extension LiveChatDriverViewTests {
    /// The sends of one run, as the fake writes them the way the CLI does (S1): an idle send and a slash command are `user`
    /// records under the uuid Loom sent; a send a running turn reads (`next`, and `now` from the queue or "Read now") is a
    /// `queued_command` attachment with a uuid of its own, naming Loom's as `source_uuid`, plus `queue-operation`
    /// records. A history read that overlaps the whole run shows each prompt once. A driver made after a relaunch marks
    /// its resume "Resumed", not "Session started".
    @Test func everyKindOfSendShowsOnceUnderAnOverlappingHistoryRead() async throws {
        final class Mismatches { var reports: [String] = [] }
        let found = Mismatches()
        #if DEBUG
        ChatPresentation.verifiesRows = true
        ChatPresentation.onMismatch = { found.reports.append($0) }
        defer {
            ChatPresentation.verifiesRows = false
            ChatPresentation.onMismatch = nil
        }
        #endif
        let rig = try await LiveRig.make()
        let id = UUID()
        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root)
        let driver = try await host.startNewSession(projectID: nil, sessionID: id)
        try await driver.send("plain send")
        #expect(await idle(driver))
        try await driver.send("/scenario bash")
        #expect(await idle(driver))

        // Turns of three one-second steps, each with a send that lands while a step runs (a send during the opening text
        // would cut the turn instead). After each, a step "now" moved to the background may finish as a turn of its own.
        let tools = { (model: TurnModel) in model.entries.filter { if case .tool = $0.body { true } else { false } }.count }
        func whileAStepRuns(_ scenario: String, _ send: () async throws -> Void) async throws {
            let before = tools(await driver.snapshot().model)
            try await driver.send(scenario)
            #expect(await waitUntil { tools(await driver.snapshot().model) > before }, "\(scenario)")
            // The step's call streams first; the step itself runs a second after it.
            try await Task.sleep(for: .milliseconds(300))
            try await send()
            #expect(await idle(driver), "\(scenario)")
            try await Task.sleep(for: .seconds(2))
            #expect(await idle(driver), "\(scenario)")
        }
        // `next`: read at the step's end.
        try await whileAStepRuns("/scenario work 3000") { try await driver.send("mid-turn next") }
        // "Read now": taken back and sent again with `now` under a new uuid.
        try await whileAStepRuns("/scenario work 3001") {
            guard case let .sent(uuid) = try await driver.send("read me now") else { return }
            let taken = try await driver.readNow(messageID: uuid)
            #expect(taken, "the step read the message before Read now")
            #expect(await driver.snapshot().model.sentUUID(ofRow: uuid) != uuid)
        }
        // `now` from the queue.
        try await whileAStepRuns("/scenario work 3002") {
            _ = try await driver.send("from the queue", timing: .afterTurn)
            let queued = try #require(await driver.snapshot().queue.items.first?.id)
            try await driver.sendQueuedNow(id: queued)
        }

        // The transcript holds the run as the CLI writes it.
        let conversation = try #require(await driver.liveState().conversationID)
        let listing = FileManager.default.subpaths(atPath: rig.profile.path) ?? []
        let file = try #require(ClaudeTranscriptLocator.locate(sessionID: conversation, configDirectory: rig.profile,
                                                               workingDirectory: nil), "\(conversation) \(listing)")
        let lines = try String(contentsOfFile: file.path, encoding: .utf8).split(separator: "\n")
        for text in ["mid-turn next", "read me now", "from the queue"] {
            #expect(lines.contains { $0.contains("\"queued_command\"") && $0.contains(text) }, "\(text): \(Self.shapes(lines))")
        }
        #expect(lines.contains { $0.contains("\"queue-operation\"") && $0.contains("absorbed_mid_turn") })

        // The view opens after everything ran: the transcript overlaps the whole live run.
        let feed = LiveChatFeed(source: driver, card: id, conversationID: conversation, configDirectory: rig.profile,
                                workingDirectory: nil)
        let stream = ChatHostedStream()
        feed.attach(stream.controller)
        feed.start()
        let sent = ["plain send", "/scenario bash", "/scenario work 3000", "mid-turn next", "/scenario work 3001", "read me now",
                    "/scenario work 3002", "from the queue"]
        #expect(await waitUntil { feed.phase == .ready && Set(Self.prompts(feed.presentation.model)) == Set(sent) })
        let prompts = Self.prompts(feed.presentation.model)
        #expect(prompts.count == sent.count, "\(prompts)")
        #expect(Self.userRows(stream.controller.rows) == sent.count)
        // One "Session started": the run's own marker, no made-up row above it.
        #expect(feed.presentation.model.markers.filter { if case .sessionStart = $0 { true } else { false } }.count == 1)
        #expect(!stream.controller.rows.contains { $0.kind.tag == "start" })
        #expect(found.reports.isEmpty, "\(found.reports)")
        stream.controller.stop()
        _ = try await driver.stop()

        // The app runs again: a new host and driver resume the session.
        let again = ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root)
        let resumed = again.driver(for: id)
        try await resumed.resume()
        #expect(await idle(resumed))
        let markers = await resumed.snapshot().model.markers
        #expect(markers.contains(.resumed(secondsSinceLastActivity: nil)))
        #expect(!markers.contains { if case .sessionStart = $0 { true } else { false } })
        _ = try await resumed.stop()
        await rig.finish()
    }

    private static func shapes(_ lines: [Substring]) -> [String] {
        lines.map { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return "?" }
            let message = object["message"] as? [String: Any]
            let content = (message?["content"] as? String) ?? (object["content"] as? String) ?? ""
            let attachment = (object["attachment"] as? [String: Any])?["type"] as? String ?? ""
            return "\(object["type"] ?? "")/\(object["operation"] ?? "")\(attachment) \(content.prefix(30))"
        }
    }

    /// The host keeps the attachments in use and at most `attachmentLimit` others, the least recently used going first.
    @Test func theHostKeepsAFewFeedsAndThoseInUse() async throws {
        let rig = try await LiveRig.make()
        let host = ChatSessionHost(runtime: rig.runtime, dataRoot: rig.root)
        let attachments = ChatAttachments()
        let drivers = (0..<6).map { _ in host.driver(for: UUID()) }
        var feeds: [LiveChatFeed] = []
        for (index, driver) in drivers.enumerated() {
            let feed = attachments.attachment(for: driver) {
                LiveChatFeed(source: driver, card: UUID(), conversationID: nil, configDirectory: nil, workingDirectory: nil)
            }
            feed.onUnused = { [weak attachments, weak driver] in
                guard let attachments, let driver else { return }
                attachments.releaseAttachment(for: driver)
            }
            if index == 0 { feed.viewAppeared() }
            feeds.append(feed)
        }
        let kept = { (driver: ChatSessionDriver) -> Bool in (attachments.existingAttachment(for: driver) as LiveChatFeed?) != nil }
        #expect(attachments.attachedDriverOrder.count == ChatAttachments.limit)
        #expect(kept(drivers[0]))
        #expect(!kept(drivers[1]) && !kept(drivers[2]))
        #expect(drivers[3...].allSatisfy(kept))
        // Not let go while shown; let go once its view went (its run never lived).
        attachments.releaseAttachment(for: drivers[0])
        #expect(kept(drivers[0]))
        feeds[0].viewWentAway(ChatStreamController(context: ChatRowContext()))
        #expect(!kept(drivers[0]))
        await rig.finish()
    }
}

private extension TurnModel {
    var texts: [String] { entries.compactMap { if case let .assistantText(text) = $0.body { text.text } else { nil } } }
    var markers: [Marker] { entries.compactMap { if case let .marker(marker) = $0.body { marker } else { nil } } }
}
