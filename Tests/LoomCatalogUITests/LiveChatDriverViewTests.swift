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

private struct LiveRig {
    let root: URL
    let profile: URL
    let socketDirectory: URL
    let runtime: SessionRuntime

    static func make() async throws -> LiveRig {
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
                        + "--permission-mode <mode> --model <model>",
                    serverHelp: "--listen <URL>"
                ),
                environment: ["PATH": "/usr/bin:/bin", "HOME": home.path],
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
        let driver = try await host.startNewSession(projectID: nil, sessionID: id)
        try await driver.send("hello before the view")
        #expect(await idle(driver))

        // The view opens now: the transcript holds the first turn, and so does the live model.
        let conversation = id.uuidString.lowercased()
        let feed = host.attachment(for: driver) {
            LiveChatFeed(source: driver, card: id, conversationID: conversation, configDirectory: rig.profile, workingDirectory: nil)
        }
        #expect(host.attachment(for: driver) { LiveChatFeed(source: driver, card: id, conversationID: nil, configDirectory: nil,
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
        #expect(host.attachment(for: driver) { LiveChatFeed(source: driver, card: card, conversationID: nil, configDirectory: nil,
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

private extension TurnModel {
    var texts: [String] { entries.compactMap { if case let .assistantText(text) = $0.body { text.text } else { nil } } }
    var markers: [Marker] { entries.compactMap { if case let .marker(marker) = $0.body { marker } else { nil } } }
}
