import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct C3ConnectionsTests {
    @Test func pathSwitchesAndHomeActionsFollowOneCatalogue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-c3-\(UUID())", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func install(_ name: String) throws {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for name in ["claude", "codex", "agy"] { try install(name) }

        let storeURL = root.appendingPathComponent("preferences.json")
        let store = UIPreferencesStore(url: storeURL)
        try store.update { $0.setHarnessConnected(HarnessID.opencode, true) }
        let connections = HarnessConnections(choices: store.current.harnessChoices) { id, on in
            MainActor.assumeIsolated { _ = try? store.update { $0.setHarnessConnected(id, on) } }
        }
        let rig = ConnectionsTests.Rig(claude: HarnessProbeAnswer(account: HarnessAccount.none, windows: []),
                                       codex: ConnectionsTests.max, codexFound: true, connections: connections)
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: store)
        model.harnessConnections = connections
        model.installHarnessHealth(rig.model)
        rig.model.checkAll()
        await rig.model.settle()
        model.installHarnessAvailability(HarnessAvailabilityReader(environment: { [path = bin.path] in ["PATH": path] }))
        #expect(await inspectorWaitUntil { model.harnessAvailability != nil })

        func row(_ id: HarnessID) throws -> ConnectionsContent.HarnessRow {
            try #require(model.connectionRows.first { $0.id == id })
        }
        #expect(model.connectionRows.map(\.id) == HarnessCatalogue.ids)
        let claude = try row(.claude), codex = try row(.codex), agy = try row(.agy)
        #expect(claude.availability == .on && codex.availability == .on)
        #expect(agy.availability == .off && agy.canSwitch)
        for id in [HarnessID.opencode, .pi] {
            let missing = try row(id)
            #expect(missing.availability == .notFound && !missing.isOn && !missing.canSwitch)
            #expect(missing.headline == "Not found on this Mac")
            #expect(missing.missingExplanation.contains("`\(missing.descriptor.command)`"))
        }
        model.setHarnessConnected(.opencode, false)
        #expect(connections.isOn(.opencode), "the disabled switch cannot erase the saved choice")
        let cards = model.homeConnect.cards
        #expect(cards.map(\.id) == [.claude, .codex, .agy])
        #expect(cards.first { $0.id == .claude }?.action?.title == "Copy Sign-In Command")
        #expect(cards.first { $0.id == .agy }?.action == .turnOn)
        #expect(cards.first { $0.id == .codex }?.action == nil)

        model.setHarnessConnected(.agy, true)
        let enabledAgy = try row(.agy)
        #expect(enabledAgy.availability == .on && enabledAgy.headline == "Found")
        #expect(model.homeConnect.cards.first { $0.id == .agy }?.action == nil)
        #expect(UIPreferencesStore(url: storeURL).current.isHarnessConnected(HarnessID.agy))
        #expect(!model.homeConnect.cards.first { $0.id == .agy }!.row.buildSupportsSessions)
        model.setHarnessConnected(.agy, false)
        #expect(!UIPreferencesStore(url: storeURL).current.isHarnessConnected(HarnessID.agy))
        #expect(model.homeConnect.cards.first { $0.id == .agy }?.action == .turnOn)
        model.setHarnessConnected(.agy, true)

        let stale = HarnessHealth(provider: .claude, state: .ready, headline: "Ready", executable: "/old/claude", version: [2, 1, 300])
        let missingAgain = ConnectionsContent.harnessRow(descriptor: HarnessCatalogue.descriptor(for: .claude)!,
                                                          availability: HarnessAvailability(id: .claude, state: .notFound),
                                                          switchedOn: true, health: stale, buildSupportsSessions: true, canStart: false)
        #expect(missingAgain.version == "—" && missingAgain.headline == "Not found on this Mac")

        try install("pi")
        model.recheckHarness(.pi)
        #expect(await inspectorWaitUntil { model.harnessAvailability?[.pi]?.isFound == true })
        let pi = try row(.pi)
        #expect(pi.availability == .off && pi.canSwitch)
        #expect(model.homeConnect.cards.map(\.id) == [.claude, .codex, .agy, .pi])
        #expect(model.homeConnect.cards.first { $0.id == .pi }?.action == .turnOn)

        let command = try #require(HarnessCatalogue.descriptor(for: .pi)?.install)
        var copied = "", opened = 0
        rig.model.copyToPasteboard = { copied = $0 }
        rig.model.openTerminalApp = { opened += 1; return true }
        rig.model.copy(command, forHarness: .pi)
        rig.model.openTerminal(forHarness: .pi)
        #expect(copied == command.command && opened == 1)
    }

    @Test func checkAgainWaitsForPathRefreshBeforeCheckingHealth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-c3-order-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["claude", "codex"] {
            let url = root.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let gate = C3PathGate(path: root.path)
        let connections = HarnessConnections()
        let rig = ConnectionsTests.Rig(codex: ConnectionsTests.max, codexFound: true, connections: connections)
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        model.harnessConnections = connections
        model.installHarnessHealth(rig.model)
        rig.model.checkAll()
        await rig.model.settle()
        model.installHarnessAvailability(HarnessAvailabilityReader(environment: { await gate.read() }))
        #expect(await inspectorWaitUntil { model.harnessAvailability != nil })

        for all in [false, true] {
            let claudeBefore = rig.claude.asks, codexBefore = rig.codex.asks
            await gate.arm()
            if all { model.recheckHarnesses() } else { model.recheckHarness(.claude) }
            await gate.waitUntilBlocked()
            await rig.model.settle()
            #expect(rig.claude.asks == claudeBefore && rig.codex.asks == codexBefore,
                    "no provider check may use the old shell environment")
            await gate.release()
            #expect(await inspectorWaitUntil { rig.claude.asks > claudeBefore && (!all || rig.codex.asks > codexBefore) })
            #expect(await inspectorWaitUntil { !model.harnessRecheckInProgress })
            await rig.model.settle()
        }
    }

    @Test func checkAgainStaysPendingAcrossPathAndHealthAndIgnoresDuplicates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-c3-pending-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pathGate = C3PathGate(path: root.path)
        let probeGate = C3ProbeGate(answer: ConnectionsTests.max)
        let connections = HarnessConnections()
        let probe = HarnessProbe(connections: connections, sources: [.claude: probeGate])
        let checker = HarnessHealthChecker(connections: connections, probe: probe, toolchain: { ConnectionsTests.toolchain($0) })
        let health = HarnessHealthModel(connections: connections, checker: checker)
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        model.harnessConnections = connections
        model.installHarnessHealth(health)
        model.installHarnessAvailability(HarnessAvailabilityReader(environment: { await pathGate.read() }))
        #expect(await inspectorWaitUntil { model.harnessAvailability != nil })
        await pathGate.arm()
        model.recheckHarness(.claude)
        #expect(model.harnessRecheckInProgress, "pending is set synchronously before the shell read starts")
        await pathGate.waitUntilBlocked()
        let reads = await pathGate.reads
        model.recheckHarnesses()
        await Task.yield()
        #expect(await pathGate.reads == reads, "a second Check Again does not schedule another PATH read")
        await pathGate.release()
        await probeGate.waitUntilBlocked()
        #expect(model.harnessRecheckInProgress, "pending stays set while provider health is still running")
        await probeGate.release()
        #expect(await inspectorWaitUntil { !model.harnessRecheckInProgress })
    }

    @Test func blockedResumeAndHandoverNameTheSwitchAndMissingCLI() {
        let preferences = UIPreferencesStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("c3-\(UUID()).json"))
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: preferences)
        let record = CatalogSession(
            session: ManagedSession(provider: .claude, providerConversationID: "fixture", workingDirectory: "/tmp"),
            title: nil, createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle, pinned: false)
        let row = SessionRowModel(record: record, live: nil)
        let connections = HarnessConnections(choices: [.claude: false])
        model.harnessConnections = connections
        #expect(model.resumeUnavailableReason(row) == "Claude is off")
        #expect(model.continueUnavailableReason(in: .terminal, row: row) == "Claude is off")
        connections.setOn(.claude, true)
        model.harnessAvailability = [.claude: HarnessAvailability(id: .claude, state: .notFound)]
        #expect(model.resumeUnavailableReason(row) == "Not found on this Mac")
        #expect(model.continueUnavailableReason(in: .terminal, row: row) == "Not found on this Mac")
        #expect(!model.canContinue(in: .terminal, row: row))
    }

    @Test func opencodeTintPreservesItsTwoTonesAndCutout() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let image = try #require(NSImage(contentsOf: root.appendingPathComponent("assets/harness/harness-opencode.png")))
        let renderer = ImageRenderer(content: OpencodeHarnessMark(image: image, tint: .white).frame(width: 128, height: 128))
        renderer.scale = 1
        let cgImage = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        func alpha(_ x: Int, _ y: Int) -> CGFloat { bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        let outside = alpha(0, 0)
        let body = max(alpha(20, 20), alpha(20, 107))
        let inset = alpha(64, 64)
        let cutout = min(alpha(64, 30), alpha(64, 97))
        #expect(outside < 0.05 && cutout < 0.1)
        #expect(body > inset + 0.3 && inset > 0.1, "the template keeps the pale body and darker inset distinct")
    }
}


private actor C3PathGate {
    private let path: String
    private var shouldBlock = false
    private(set) var reads = 0
    private var blocked: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    init(path: String) { self.path = path }
    func arm() { shouldBlock = true }
    func read() async -> [String: String] {
        reads += 1
        if shouldBlock {
            shouldBlock = false
            await withCheckedContinuation { continuation in
                blocked = continuation
                for arrival in arrivals { arrival.resume() }
                arrivals.removeAll()
            }
        }
        return ["PATH": path]
    }
    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private actor C3ProbeGate: HarnessProbeSource {
    private let answer: HarnessProbeAnswer
    private var blockedOnce = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    init(answer: HarnessProbeAnswer) { self.answer = answer }
    func read() async -> HarnessProbeAnswer? {
        if !blockedOnce {
            blockedOnce = true
            await withCheckedContinuation { continuation in
                blocked = continuation
                for arrival in arrivals { arrival.resume() }
                arrivals.removeAll()
            }
        }
        return answer
    }
    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}
