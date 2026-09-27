// Compile with Sources/LoomCore/LaunchEnvironment.swift; this is an E2 experiment,
// not a production target. Usage: environment-parent-probe /absolute/report.json
import Darwin
import Foundation

@main
struct EnvironmentParentProbe {
    static let rcKey = "LOOM_E2_RC_CUSTOM"
    static let rcValue = "synthetic-rc-value"

    static func isClaudeKey(_ key: String) -> Bool {
        key.hasPrefix("CLAUDE")
    }

    static func save(_ report: [String: Any], to output: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }

    @MainActor static func main() {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
            fputs("Usage: environment-parent-probe /absolute/report.json\n", stderr)
            exit(2)
        }
        alarm(15)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let parent = ProcessInfo.processInfo.environment
        let parentKeys = parent.keys.sorted()
        let parentClaudeKeys = parentKeys.filter(isClaudeKey)
        let hasMessaging = parentClaudeKeys.contains { $0.hasPrefix("CLAUDE_CODE_MESSAGING_") }
        var report: [String: Any] = [
            "schemaVersion": 1,
            "pid": getpid(), "parentPID": getppid(),
            "parentEnvironmentKeys": parentKeys,
            "parentClaudeKeys": parentClaudeKeys,
            "parentCoverage": [
                "CLAUDECODE": parent["CLAUDECODE"] != nil,
                "CLAUDE_CODE_SESSION_ID": parent["CLAUDE_CODE_SESSION_ID"] != nil,
                "CLAUDE_CODE_MESSAGING_prefix": hasMessaging,
            ],
            "allNamedParentCategoriesPresent": parent["CLAUDECODE"] != nil
                && parent["CLAUDE_CODE_SESSION_ID"] != nil && hasMessaging,
            "assertionsPassed": false,
            "stage": "prepare",
        ]
        let fixture = output.deletingLastPathComponent().appendingPathComponent("zdotdir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: fixture,
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try "export \(rcKey)=\(rcValue)\n".write(to: fixture.appendingPathComponent(".zshrc"),
                atomically: true, encoding: .utf8)
            report["stage"] = "resolve"
            // Parent is the actual host environment. Never manufacture provider markers here.
            let resolution = try LaunchEnvironment.resolve(parent: parent, session: [:], testZDOTDIR: fixture)
            let base = resolution.environment
            report["warningCount"] = resolution.warnings.count
            let runID = UUID(), sessionID = UUID()
            let environment = LaunchEnvironment.make(base: base, runID: runID, sessionID: sessionID)
            report["stage"] = "child"
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            child.arguments = ["-0"]
            child.environment = environment
            child.standardInput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            child.standardOutput = pipe
            try child.run()
            // Raw environment values are inspected only in memory, never written or logged.
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            var observed: [String: String] = [:]
            for entry in bytes.split(separator: 0) {
                guard let text = String(data: Data(entry), encoding: .utf8),
                      let separator = text.firstIndex(of: "=") else {
                    throw ProbeFailure.invalidChildEnvironment
                }
                observed[String(text[..<separator])] = String(text[text.index(after: separator)...])
            }
            let childClaudeKeys = observed.keys.filter(isClaudeKey).sorted()
            let assertions: [String: Bool] = [
                "childExitedSuccessfully": child.terminationStatus == 0,
                "parentClaudeVariablesAbsentInChild": childClaudeKeys.isEmpty,
                "rcCustomVariablePreserved": observed[rcKey] == rcValue,
                "runMarkerMatches": observed["LOOM_RUN_ID"] == runID.uuidString,
                "sessionMarkerMatches": observed["LOOM_SESSION_ID"] == sessionID.uuidString,
                "terminalTypeMatches": observed["TERM"] == "xterm-256color",
            ]
            report["childPID"] = child.processIdentifier
            report["childExitStatus"] = child.terminationStatus
            report["childEnvironmentKeys"] = observed.keys.sorted()
            report["childClaudeKeys"] = childClaudeKeys
            report["assertions"] = assertions
            report["assertionsPassed"] = assertions.values.allSatisfy { $0 }
            report["stage"] = "complete"
            try save(report, to: output)
            if !assertions.values.allSatisfy({ $0 }) { exit(1) }
        } catch {
            // Error descriptions can contain shell output or environment values.
            report["error"] = "Probe operation failed; diagnostic values intentionally omitted"
            try? save(report, to: output)
            fputs("Environment parent probe failed; see safe report for stage and key presence.\n", stderr)
            exit(2)
        }
    }

    enum ProbeFailure: Error { case invalidChildEnvironment }
}
