import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(1))) struct SendMessageCommandTests {
    @Test func helpAndBoundedInputWorkWithoutAProvider() throws {
        var output: [String] = [], errors: [String] = []
        let printer = OpenSessionCommand.Output(standardOutput: { output.append($0) }, standardError: { errors.append($0) })
        #expect(SendMessageCommand.run(arguments: ["send", "--help"], environment: [:], output: printer) == 0)
        #expect(output.joined().contains("user's approval") && output.joined().contains("inbox"))
        #expect(SendMessageCommand.run(arguments: ["inbox"], environment: [:], output: printer) == 3)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-command-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("message")
        let env = ["SPHYRNA_TASK_SOCKET": root.appendingPathComponent("missing.sock").path,
            "SPHYRNA_TASK_TOKEN": "fake", "SPHYRNA_TASK_SESSION_ID": UUID().uuidString,
            "SPHYRNA_TASK_RUN_ID": UUID().uuidString, "SPHYRNA_TASK_GENERATION": UUID().uuidString]
        try Data(repeating: 0x78, count: 16_385).write(to: file)
        let args = ["send", UUID().uuidString, "--message-file", file.path]
        #expect(SendMessageCommand.run(arguments: args, environment: env, output: printer) == 2)
        try Data([0x61, 0, 0x62]).write(to: file)
        #expect(SendMessageCommand.run(arguments: args, environment: env, output: printer) == 2)
        #expect(errors.contains { $0.contains("valid UTF-8") })
    }

    @Test func aNonRegularMessagePathCannotHangTheHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-fifo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("input")
        #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)
        let process = Process(), ended = DispatchSemaphore(value: 0)
        process.executableURL = RuntimeFixture.binaries.appendingPathComponent("loom-hook")
        process.arguments = ["send", UUID().uuidString, "--message-file", fifo.path]
        process.environment = ["SPHYRNA_TASK_SOCKET": root.appendingPathComponent("missing.sock").path,
            "SPHYRNA_TASK_TOKEN": "fake", "SPHYRNA_TASK_SESSION_ID": UUID().uuidString,
            "SPHYRNA_TASK_RUN_ID": UUID().uuidString, "SPHYRNA_TASK_GENERATION": UUID().uuidString]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice; process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + 5) != .success && process.isRunning {
            process.terminate()
            if ended.wait(timeout: .now() + 1) != .success { kill(process.processIdentifier, SIGKILL); _ = ended.wait(timeout: .now() + 1) }
            Issue.record("the helper blocked opening a FIFO")
        } else { #expect(process.terminationStatus == 2) }
    }

}
