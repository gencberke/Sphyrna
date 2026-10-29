import Darwin
import Foundation
@testable import LoomCore
import SwiftTerm
import Testing
@testable import LoomTerminal

private final class TerminalTestBundleAnchor: NSObject {}

private final class RegistrationAdmissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func record(_ accepted: Bool) { lock.withLock { value = accepted } }
    var accepted: Bool? { lock.withLock { value } }
}

/// Test-only tee: the exact PTY bytes also go to a headless engine so cell
/// attributes (not exposed by the view) can be checked.
private final class TeeSink: TerminalOutputSink, @unchecked Sendable {
    private let first: any TerminalOutputSink
    private let lock = NSLock()
    let headless = Terminal(delegate: HeadlessDelegate(), options: TerminalSurfaceLimits.options)

    init(_ first: any TerminalOutputSink) { self.first = first }

    func receive(_ data: Data) {
        first.receive(data)
        lock.withLock { headless.feed(buffer: ArraySlice(data)) }
    }

    func cell(column: Int, row: Int) -> CharData? {
        lock.withLock { headless.getCharData(col: column, row: row) }
    }
}

private final class HeadlessDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct TerminalSurfaceTests {
    private var childPath: String {
        Bundle(for: TerminalTestBundleAnchor.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("loom-test-child").path
    }

    private func launch(
        _ arguments: [String], surface: TerminalSurface, supervisor: ProcessSupervisor,
        sink: (any TerminalOutputSink)? = nil
    ) async throws -> (sessionID: UUID, runID: UUID, endpoint: TerminalEndpoint) {
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(
            id: sessionID, provider: .synthetic,
            workingDirectory: FileManager.default.temporaryDirectory.path
        ))
        let environment = LaunchEnvironment.make(
            path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID
        )
        let size = surface.gridSize
        let launch = try await supervisor.launch(
            sessionID: sessionID, executable: childPath, arguments: arguments,
            environment: environment, rows: size.rows, columns: size.columns,
            outputSink: sink ?? surface.outputSink
        )
        let runID = try #require(launch.session.currentRun?.id)
        surface.attach(runID: runID, endpoint: launch.terminal)
        return (sessionID, runID, launch.terminal)
    }

    private func waitFor(_ surface: TerminalSurface, contains text: String,
                         seconds: Double = 10) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !surface.screenText().contains(text) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("Timed out waiting for \(text.debugDescription); screen:\n\(surface.screenText())")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func earlyInputIsQueuedBeforeRegistration() async throws {
        let supervisor = try ProcessSupervisor()
        let surface = TerminalSurface()
        surface.view.send(data: Array("unsent draft".utf8)[...])
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(id: sessionID, provider: .synthetic,
            workingDirectory: FileManager.default.temporaryDirectory.path))
        let environment = LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID)
        let launched = try await supervisor.launch(sessionID: sessionID, executable: childPath, arguments: ["interactive"],
            environment: environment, rows: 24, columns: 80, outputSink: surface.outputSink)
        let runID = try #require(launched.session.currentRun?.id)
        let gate = TerminalInputGate(), probe = RegistrationAdmissionProbe()
        gate.observeRegistrations { id in
            let fresh = gate.establishFreshCleanInput(runID: id)
            let accepted = fresh && gate.enqueueAutomatic(runID: id, bytes: Data("unexpected pointer\r".utf8), transaction: { try $0() }) != nil
            probe.record(accepted)
        }
        surface.attach(runID: runID, endpoint: launched.terminal, inputGate: gate)
        #expect(probe.accepted == false)
        surface.view.send(data: [0x0d][...])
        try await waitFor(surface, contains: "echo: unsent draft")
        #expect(!surface.screenText().contains("unexpected pointer"))
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func deferredProtocolAndUserInputFenceRegistrationBeforeMainDelivery() async throws {
        let supervisor = try ProcessSupervisor(), surface = TerminalSurface()
        let sessionID = UUID()
        try await supervisor.createSession(ManagedSession(id: sessionID, provider: .synthetic,
            workingDirectory: FileManager.default.temporaryDirectory.path))
        let environment = LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID)
        let launched = try await supervisor.launch(sessionID: sessionID, executable: childPath, arguments: ["interactive"],
            environment: environment, rows: 24, columns: 80, outputSink: surface.outputSink)
        let runID = try #require(launched.session.currentRun?.id)
        let gate = TerminalInputGate(), probe = RegistrationAdmissionProbe()
        gate.observeRegistrations { id in
            let fresh = gate.establishFreshCleanInput(runID: id)
            probe.record(fresh && gate.enqueueAutomatic(runID: id, bytes: Data("unexpected pointer\r".utf8),
                                                        transaction: { try $0() }) != nil)
        }
        // The response schedules a deferred main delivery; the user bytes
        // join that same delivery before attach in this main-actor turn.
        surface.view.feed(text: "\u{1b}[6n")
        surface.view.send(data: Array("user draft".utf8)[...])
        surface.attach(runID: runID, endpoint: launched.terminal, inputGate: gate)
        #expect(probe.accepted == false)
        try await Task.sleep(for: .milliseconds(30))
        surface.view.send(data: [0x0d][...])
        try await waitFor(surface, contains: "user draft")
        #expect(!surface.screenText().contains("unexpected pointer"))
        #expect((await supervisor.shutdown()).succeeded)
    }

    @Test func earlyParserRepliesStayCleanButMixedEarlyUserInputDoesNot() async throws {
        for mixed in [false, true] {
            let supervisor = try ProcessSupervisor()
            let surface = TerminalSurface()
            surface.view.feed(text: "\u{1b}[6")
            surface.view.feed(text: "n")
            if mixed { surface.view.send(data: Array("user draft".utf8)[...]) }
            // Let the deliberately deferred parser callback reach the launching surface.
            try await Task.sleep(for: .milliseconds(30))
            let sessionID = UUID()
            try await supervisor.createSession(ManagedSession(id: sessionID, provider: .synthetic,
                workingDirectory: FileManager.default.temporaryDirectory.path))
            let environment = LaunchEnvironment.make(path: "/usr/bin:/bin", runID: supervisor.ownershipRunID, sessionID: sessionID)
            let launched = try await supervisor.launch(sessionID: sessionID, executable: childPath, arguments: ["interactive"],
                environment: environment, rows: 24, columns: 80, outputSink: surface.outputSink)
            let runID = try #require(launched.session.currentRun?.id)
            let gate = TerminalInputGate()
            surface.attach(runID: runID, endpoint: launched.terminal, inputGate: gate)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while gate.pendingByteCount(runID: runID) != 0 && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(gate.pendingByteCount(runID: runID) == 0)
            if !mixed {
                while !gate.establishFreshCleanInput(runID: runID) && ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            #expect(gate.establishFreshCleanInput(runID: runID) == !mixed)
            #expect((await supervisor.shutdown()).succeeded)
        }
    }

    @Test func splitSequencesRepliesAndOrderedInputReachTheRun() async throws {
        let supervisor = try ProcessSupervisor()
        let surface = TerminalSurface()
        let tee = TeeSink(surface.outputSink)
        let run = try await launch(["terminal-sample"], surface: surface,
                                   supervisor: supervisor, sink: tee)
        #expect(run.endpoint.scrollback == nil, "engine owns history; no second byte scrollback")

        try await waitFor(surface, contains: "READY")
        let screen = surface.screenText()
        #expect(screen.contains("TRUE Türkçe ğüşıöç İ 🧵"))
        #expect(screen.contains("MAIN-AGAIN"))
        #expect(!screen.contains("ALTSCREEN"), "alternate screen content must not leak to main")
        // The DSR reply was produced by the engine and written by Loom's queue.
        #expect(screen.range(of: #"REPLY:ESC\[\d+;\d+R"#, options: .regularExpression) != nil)
        let colored = try #require(tee.cell(column: 0, row: 0))
        #expect(colored.attribute.fg == .trueColor(red: 255, green: 100, blue: 0))

        // Keys, a bracketed paste and more keys, issued back to back through
        // the engine's own input path (delegate.send on MainActor).
        var expected: [UInt8] = []
        for index in 0..<200 {
            let payload: [UInt8] = index % 50 == 0
                ? Array("\u{1b}[200~çok satırlı\nyapıştırma \(index)\u{1b}[201~".utf8)
                : [UInt8(0x61 + index % 26)]
            surface.view.send(data: payload[...])
            expected += payload
        }
        let large = Array(repeating: UInt8(ascii: "p"), count: 256 * 1024)
        surface.view.send(data: large[...])
        expected += large
        surface.view.send(data: [0x04][...])
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in expected { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        try await waitFor(surface, contains: "INPUT:\(expected.count):\(String(hash, radix: 16))")
        #expect(surface.statistics.inputErrors.isEmpty)

        let report = await supervisor.shutdown()
        #expect(report.succeeded, "\(report)")
    }

    @Test func finderDropUsesBracketedPasteQueueWithoutEnter() async throws {
        let supervisor = try ProcessSupervisor()
        let surface = TerminalSurface()
        _ = try await launch(["terminal-sample"], surface: surface, supervisor: supervisor)
        try await waitFor(surface, contains: "READY")
        surface.outputSink.receive(Data("\u{1b}[?2004h".utf8))
        let paths = [URL(fileURLWithPath: "/tmp/çok boşluk 🧵"), URL(fileURLWithPath: "/tmp/a'b\"c")]
        surface.view.send(data: Array("before".utf8)[...])
        #expect(surface.view.insertDroppedFiles(paths))
        try await Task.sleep(for: .milliseconds(10))
        surface.view.send(data: Array("after".utf8)[...])
        let expected = Array(("before\u{1b}[200~" + LoomTerminalView.quotedPaths(paths)
                              + "\u{1b}[201~after").utf8)
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in expected { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        surface.view.send(data: [0x04][...])
        try await waitFor(surface, contains: "INPUT:\(expected.count):\(String(hash, radix: 16))")
        #expect(surface.statistics.inputErrors.isEmpty)
        let report = await supervisor.shutdown()
        #expect(report.succeeded)
    }

    @Test func endedRunRefusesInputAndNewRunGetsItsOwnSurface() async throws {
        let supervisor = try ProcessSupervisor()
        let first = TerminalSurface()
        let run = try await launch(["terminal-sample"], surface: first, supervisor: supervisor)
        try await waitFor(first, contains: "READY")
        let stop = try await supervisor.stop(sessionID: run.sessionID)
        #expect(stop.succeeded)
        first.runEnded()
        var errors: [TerminalInputError] = []
        first.onInputError = { errors.append($0) }
        first.view.send(data: Array("late".utf8)[...])
        #expect(errors == [.writeFailed("run has ended")])
        // The old endpoint itself also refuses writes after the run ended.
        await #expect(throws: (any Error).self) { _ = try await run.endpoint.write(Data("x".utf8)) }

        let second = TerminalSurface()
        let next = try await launch(["terminal-sample"], surface: second, supervisor: supervisor)
        #expect(next.runID != run.runID)
        try await waitFor(second, contains: "READY")
        #expect(!second.screenText().contains("late"))
        let report = await supervisor.shutdown()
        #expect(report.succeeded, "\(report)")
    }

    /// No window: the engine keeps parsing every byte, nothing is drawn, and
    /// the run has no byte scrollback beside the engine's bounded history.
    @Test func hiddenSurfaceParsesBurstWithoutLossOrFrames() async throws {
        let supervisor = try ProcessSupervisor()
        let surface = TerminalSurface()
        let total = 20 * 1024 * 1024
        _ = try await launch(["stream", "0", String(total)], surface: surface, supervisor: supervisor)
        // Poll the cheap counter; copying the screen contends with the parser.
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        while surface.statistics.outputBytes < total,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await waitFor(surface, contains: "END bytes=\(total)")
        let statistics = surface.statistics
        let trailerLength = surface.screenText().components(separatedBy: "\n")
            .first { $0.hasPrefix("END bytes=") }.map { $0.utf8.count + 4 } ?? 0
        #expect(statistics.outputBytes == total + trailerLength,
                "\(statistics.outputBytes) received for \(total) payload + \(trailerLength) trailer")
        #expect(statistics.engineBytesFed == statistics.outputBytes)
        #expect(statistics.frames == 0)
        // Scrollback is bounded by lines, not by the 20 MiB burst.
        let lines = surface.view.getBufferAsData(kind: .normal).split(separator: 0x0a).count
        #expect(lines <= TerminalSurfaceLimits.scrollbackLines + Int(surface.gridSize.rows) + 1)
        let report = await supervisor.shutdown()
        #expect(report.succeeded, "\(report)")
    }
}
