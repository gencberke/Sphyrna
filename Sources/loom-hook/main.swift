import Darwin
import Foundation
import LoomCore

@main
struct LoomHook {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // Claude runs the helper with no arguments for a hook event. Any argument makes it the
        // command agents use (`"$LOOM_CLI" open ...` or `sessions ...`); the hook path below is unchanged.
        if !arguments.isEmpty {
            if arguments.first == "task" {
                exit(SessionTaskCommand.run(arguments: arguments, environment: ProcessInfo.processInfo.environment,
                    readStandardInput: { try readStandardInput(limit: SessionTaskLimits.payloadBytes + 1) },
                    output: .init(
                        standardOutput: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
                        standardError: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
                    )))
            }
            exit(OpenSessionCommand.run(
                arguments: arguments, environment: ProcessInfo.processInfo.environment,
                readStandardInput: { try readStandardInput(limit: 64 * 1024 + 1) },
                output: .init(
                    standardOutput: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
                    standardError: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
                )
            ))
        }
        let environment = ProcessInfo.processInfo.environment
        // Every way out below leaves one line in unified logging (category HookClient): a hook
        // that exits quietly is otherwise indistinguishable from no hook at all.
        guard let socketPath = environment["LOOM_HOOK_SOCKET"],
              let authenticationToken = environment["LOOM_HOOK_TOKEN"],
              let sessionText = environment["LOOM_SESSION_ID"],
              let sessionID = UUID(uuidString: sessionText),
              let runText = environment["LOOM_MANAGED_RUN_ID"],
              let managedRunID = UUID(uuidString: runText) else {
            LoomLog.error(.hookClient, "Hook not sent: Sphyrna's environment variables (LOOM_*) are missing or malformed")
            exit(1)
        }
        guard let payload = try? readStandardInput(), (try? ClaudeHookEvent(payload: payload)) != nil else {
            LoomLog.error(.hookClient, "Hook not sent: the event on standard input is empty, too large or not a Claude hook payload")
            exit(1)
        }
        let envelope = ClaudeHookEnvelope(
            sessionID: sessionID, managedRunID: managedRunID, payload: payload,
            taskGeneration: environment["SPHYRNA_TASK_GENERATION"].flatMap(UUID.init(uuidString:)),
            taskCredential: environment["SPHYRNA_TASK_TOKEN"]
        )
        do {
            try ClaudeHookClient.send(
                envelope, socketPath: socketPath,
                authenticationToken: authenticationToken
            )
        } catch {
            LoomLog.error(.hookClient, "Hook not delivered: \(ClaudeHookClient.failureDescription(error))")
            exit(1)
        }
    }

    private static func readStandardInput() throws -> Data {
        var result = Data()
        while true {
            let remaining = ClaudeHookClient.maximumPayloadByteCount + 1 - result.count
            guard remaining > 0 else { throw ClaudeHookTransportError.messageTooLarge }
            guard let chunk = try FileHandle.standardInput.read(
                upToCount: min(16 * 1024, remaining)
            ), !chunk.isEmpty else { return result }
            result.append(chunk)
        }
    }

    /// At most `limit` bytes: a message past the cap is refused without reading the rest.
    private static func readStandardInput(limit: Int) throws -> Data {
        var result = Data()
        while result.count < limit {
            guard let chunk = try FileHandle.standardInput.read(
                upToCount: min(16 * 1024, limit - result.count)
            ), !chunk.isEmpty else { break }
            result.append(chunk)
        }
        return result
    }
}
