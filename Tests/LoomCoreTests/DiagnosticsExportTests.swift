import Darwin
import Foundation
import Testing
@testable import LoomCore

/// H1-B items 1 and 9: the hook client's failure traces and the diagnostics export (a folder of
/// ids, counts and versions; never a session's content).
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DiagnosticsExportTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loom-diag-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let fakeLog: DiagnosticsExport.LogRunner = { output in
        try? Data("{\"subsystem\":\"local.loom.desktop\"}\n".utf8).write(to: output)
        return .collected(bytes: 34, truncated: false)
    }

    private func allText(under folder: URL) throws -> String {
        var text = ""
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            text += String(decoding: try Data(contentsOf: folder.appendingPathComponent(name)), as: UTF8.self)
        }
        return text
    }

    // MARK: Hook client

    @Test func theHookClientNamesEachWayAHookFailsWithoutContent() throws {
        let root = URL(fileURLWithPath: "/tmp/lh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let envelope = ClaudeHookEnvelope(sessionID: UUID(), managedRunID: UUID(),
            payload: Data(#"{"session_id":"s","hook_event_name":"Stop","last_assistant_message":"SECRET"}"#.utf8))

        // Nothing there: the socket does not exist.
        do { try ClaudeHookClient.send(envelope, socketPath: root.appendingPathComponent("none.sock").path, authenticationToken: "t") }
        catch { #expect(ClaudeHookClient.failureDescription(error).contains("does not exist")) }

        // A socket left by a crashed Loom: nothing listens, the connection is refused.
        let stale = root.appendingPathComponent("stale.sock").path
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try unixAddress(path: stale)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        Darwin.close(descriptor)
        do { try ClaudeHookClient.send(envelope, socketPath: stale, authenticationToken: "t"); Issue.record("sent to a dead socket") }
        catch { #expect(ClaudeHookClient.failureDescription(error).contains("refused")) }

        // A wrong token is refused by a live server and counted.
        let live = root.appendingPathComponent("live.sock").path
        let server = try ClaudeHookServer(socketPath: live, authenticationToken: "right") { _ in }
        defer { server.stop() }
        let before = HookDiagnostics.snapshot().rejectedToken
        do { try ClaudeHookClient.send(envelope, socketPath: live, authenticationToken: "wrong"); Issue.record("token accepted") }
        catch { #expect(ClaudeHookClient.failureDescription(error) == "token rejected by Loom") }
        #expect(HookDiagnostics.snapshot().rejectedToken == before + 1)
        for text in [ClaudeHookClient.failureDescription(ClaudeHookTransportError.timeout("connect")),
                     ClaudeHookClient.failureDescription(ClaudeHookTransportError.messageTooLarge)] {
            #expect(!text.contains("SECRET"))
        }
        #expect(ClaudeHookClient.failureDescription(ClaudeHookTransportError.timeout("connect")) == "connect timed out")
    }

    @Test func theRealHelperExitsNonZeroWhenNothingListensAndZeroWhenLoomAnswers() throws {
        let root = URL(fileURLWithPath: "/tmp/lh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        func run(socket: String, token: String) throws -> Int32 {
            let process = Process()
            process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-hook")
            process.environment = ["LOOM_HOOK_SOCKET": socket, "LOOM_HOOK_TOKEN": token,
                                   "LOOM_SESSION_ID": UUID().uuidString, "LOOM_MANAGED_RUN_ID": UUID().uuidString]
            let input = Pipe()
            process.standardInput = input
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(#"{"session_id":"s","hook_event_name":"SessionStart"}"#.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        }
        #expect(try run(socket: root.appendingPathComponent("none.sock").path, token: "t") == 1)
        let live = root.appendingPathComponent("live.sock").path
        let server = try ClaudeHookServer(socketPath: live, authenticationToken: "right") { _ in }
        defer { server.stop() }
        #expect(try run(socket: live, token: "wrong") == 1)
        #expect(try run(socket: live, token: "right") == 0)
    }

    // MARK: Export

    @Test func theExportHoldsTheSummaryTheJournalAndTheLogAndNoSessionContent() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let project = context.root.appendingPathComponent("TopSecretProjectFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let added = try await context.catalog.addProject(path: project.path)
        let titled = ManagedSession(provider: .claude, workingDirectory: project.path)
        try await context.catalog.insertSession(titled, title: "PRIVATE-TITLE-OF-A-SESSION", projectID: added.project.id)
        let (launch, screen) = try await SessionRuntimeTests.launchClaude(context)
        #expect(await screen.contains("FAKE-CLAUDE READY"))
        try await screen.send("PRIVATE-PROMPT-TEXT")
        #expect(await screen.contains("echo: PRIVATE-PROMPT-TEXT"))
        #expect(await SessionRuntimeTests.waitUntil { await context.supervisor.providerWorkState(sessionID: launch.sessionID)?.activity == .turnComplete })
        let failure = PlanLimitsFailure(category: .timedOut, at: Date(timeIntervalSince1970: 1_791_374_400))
        let usage = UsageDiagnostics(lastScan: UsageScanReport(), lastScanAt: nil, linesNotUnderstood: 4)

        let folder = DiagnosticsExport.defaultFolder(dataRoot: context.catalog.dataRoot)
        let written = try await context.runtime.collectDiagnostics(
            to: folder, usage: usage, planLimitsFailure: failure, log: fakeLog)
        #expect(written == folder)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names.isSuperset(of: ["summary.json", "log.ndjson", DiagnosticJournal.currentName]))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(DiagnosticsSummary.self, from: Data(contentsOf: folder.appendingPathComponent("summary.json")))
        #expect(summary.claudeCLI?.version == "fake 1")
        #expect(summary.claudeCLI?.detectedOptions.contains("--settings") == true)
        #expect(summary.claudeCLI?.missingRequiredOptions.isEmpty == true)
        #expect(summary.catalog?.schemaVersion == Int(SessionCatalog.schemaVersion))
        #expect(summary.catalog?.sessions == 2 && summary.catalog?.projects == 1)
        #expect(summary.catalog?.openRuns == 1 && summary.catalog?.pendingDeletions == 0)
        #expect(summary.usage?.linesNotUnderstood == 4)
        #expect(summary.planLimitsFailure == failure)
        #expect(summary.hooks.applied > 0 && summary.hooks.received > 0)
        #expect(summary.log == .init(included: true, bytes: 34, truncated: false, failure: nil))
        #expect(!summary.application.macOS.isEmpty)

        // Nothing a user typed or named is anywhere in the folder.
        let text = try allText(under: folder)
        for secret in ["PRIVATE-TITLE-OF-A-SESSION", "PRIVATE-PROMPT-TEXT", "TopSecretProjectFolder", context.root.path] {
            #expect(!text.contains(secret), "\(secret) leaked into the export")
        }
        // The journal inside carries the launch and the Claude CLI.
        #expect(text.contains("\"launch\"") && text.contains("claude_cli"))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func theLaunchAndTheQuitSummaryAreJournaledByTheCoreSoTheyOutliveTheRunDirectory() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let report = await context.runtime.shutdown()
        #expect(report.succeeded)
        let lines = DiagnosticJournal.forDataRoot(context.catalog.dataRoot).lines()
        let launch = try #require(lines.first { $0.contains("\"event\":\"launch\"") })
        #expect(launch.contains("macOS"))
        let quit = try #require(lines.first { $0.contains("\"event\":\"quit\"") })
        #expect(quit.contains("\"succeeded\":true") && quit.contains("\"signals\":0") && quit.contains("\"errors\":0"))
        // Counts only: nothing of the report's process records or error texts.
        #expect(!quit.contains("command") && !quit.contains("identity"))
    }

    @Test func aRecoveryThatSetSomethingAsideIsJournaledAndAPlainRelaunchIsNot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appendingPathComponent("runs", isDirectory: true)
        let previous = runs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: previous.appendingPathComponent("owner.json"))   // not a live owner, no scopes
        let plain = await PreviousRunRecovery.recover(runsDirectory: runs, current: nil, scopeTimeout: 1)
        #expect(plain.removedDirectories == 1)
        #expect(DiagnosticJournal.forDataRoot(root).lines().isEmpty)

        let broken = runs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: broken.appendingPathComponent("ledger.json"))
        let report = await PreviousRunRecovery.recover(runsDirectory: runs, current: nil, scopeTimeout: 1)
        #expect(report.quarantinedDirectories == 1)
        let line = try #require(DiagnosticJournal.forDataRoot(root).lines().first)
        #expect(line.contains("\"event\":\"recovery\"") && line.contains("\"quarantinedDirectories\":1"))
        #expect(!line.contains(broken.lastPathComponent))
    }

    @Test func aFailedLogIsReportedInTheSummaryNotAsAnError() async throws {
        let context = try await SessionRuntimeTests.makeContext()
        defer { context.cleanup() }
        let folder = DiagnosticsExport.defaultFolder(dataRoot: context.catalog.dataRoot)
        _ = try await context.runtime.collectDiagnostics(to: folder, log: { _ in .failed("timed out") })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(DiagnosticsSummary.self, from: Data(contentsOf: folder.appendingPathComponent("summary.json")))
        #expect(summary.log == .init(included: false, bytes: 0, truncated: false, failure: "timed out"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("log.ndjson").path))
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func atMostThreeExportsAreKeptAndOnlyOnesLoomMadeAreRemoved() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exports = root.appendingPathComponent("diagnostics/exports", isDirectory: true)
        let foreign = exports.appendingPathComponent("\(DiagnosticsExport.folderPrefix)handmade", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let summary = DiagnosticsSummary(
            generatedAt: Date(), application: .init(version: "1", build: nil, macOS: "test"), claudeCLI: nil,
            catalog: nil, usage: nil, planLimitsFailure: nil, hooks: HookCounterSnapshot(), log: nil)
        var folders: [URL] = []
        for day in 0..<5 {
            let folder = DiagnosticsExport.defaultFolder(dataRoot: root, now: Date(timeIntervalSince1970: 1_791_374_400 + Double(day) * 86_400))
            folders.append(try await DiagnosticsExport.collect(to: folder, dataRoot: root, summary: summary, log: fakeLog))
        }
        let kept = Set(try FileManager.default.contentsOfDirectory(atPath: exports.path))
        #expect(kept == Set(folders.suffix(3).map(\.lastPathComponent) + [foreign.lastPathComponent]))
    }

    @Test func anExistingNonEmptyFolderIsRefusedAndNothingIsChanged() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("note.txt"))
        let summary = DiagnosticsSummary(
            generatedAt: Date(), application: .init(version: "1", build: nil, macOS: "test"), claudeCLI: nil,
            catalog: nil, usage: nil, planLimitsFailure: nil, hooks: HookCounterSnapshot(), log: nil)
        await #expect(throws: (any Error).self) {
            _ = try await DiagnosticsExport.collect(to: folder, dataRoot: root, summary: summary, log: fakeLog)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["note.txt"])
    }

    // MARK: The log run

    @Test func theLogCommandIsTheSubsystemQueryOverTheLastDayForThisAppBundleOnly() {
        let arguments = DiagnosticsExport.logArguments(bundlePath: "/Applications/Loom Dev.app")
        #expect(arguments == [
            "show", "--last", "24h", "--predicate",
            "subsystem == \"local.loom.desktop\" && processImagePath BEGINSWITH \"/Applications/Loom Dev.app/\"",
            "--style", "ndjson",
        ])
        // A trailing slash is not doubled, and the prefix ends at a path separator: "Loom.app" does not
        // match the images of "Loom.app.old" or of the other flavor.
        #expect(DiagnosticsExport.logArguments(bundlePath: "/Applications/Loom.app/")[4]
            == "subsystem == \"local.loom.desktop\" && processImagePath BEGINSWITH \"/Applications/Loom.app/\"")
    }

    @Test func aBundlePathCannotBreakOutOfThePredicateString() {
        let arguments = DiagnosticsExport.logArguments(bundlePath: "/tmp/a\"b\\c.app")
        #expect(arguments[4] == "subsystem == \"local.loom.desktop\" && processImagePath BEGINSWITH \"/tmp/a\\\"b\\\\c.app/\"")
    }

    @Test func theLogOutputIsCappedAndTheRunIsBoundedByATimeout() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("log.ndjson")
        // 1 MB of output against a 4 KB cap.
        let capped = DiagnosticsExport.runLogShow(to: output, cap: 4_096, timeout: 10,
            executable: "/bin/sh", arguments: ["-c", "head -c 1000000 /dev/zero | tr '\\\\0' 'x'"])
        #expect(capped == .collected(bytes: 4_096, truncated: true))
        #expect(try Data(contentsOf: output).count == 4_096)
        // A command that never ends is stopped.
        let began = ContinuousClock.now
        let hung = DiagnosticsExport.runLogShow(to: output, cap: 4_096, timeout: 0.4,
            executable: "/bin/sh", arguments: ["-c", "exec sleep 30"])
        #expect(hung == .failed("timed out"))
        #expect(ContinuousClock.now - began < .seconds(10))
        // A small output is complete.
        let small = DiagnosticsExport.runLogShow(to: output, cap: 4_096, timeout: 10,
            executable: "/bin/sh", arguments: ["-c", "echo hello"])
        #expect(small == .collected(bytes: 6, truncated: false))
    }
}
