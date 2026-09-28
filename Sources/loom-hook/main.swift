import Darwin
import Foundation
import LoomCore

@main
struct LoomHook {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        guard let socketPath = environment["LOOM_HOOK_SOCKET"],
              let authenticationToken = environment["LOOM_HOOK_TOKEN"],
              let sessionText = environment["LOOM_SESSION_ID"],
              let sessionID = UUID(uuidString: sessionText),
              let runText = environment["LOOM_MANAGED_RUN_ID"],
              let managedRunID = UUID(uuidString: runText),
              let payload = try? readStandardInput(),
              (try? ClaudeHookEvent(payload: payload)) != nil else {
            exit(1)
        }
        let envelope = ClaudeHookEnvelope(
            sessionID: sessionID, managedRunID: managedRunID, payload: payload
        )
        do {
            try ClaudeHookClient.send(
                envelope, socketPath: socketPath,
                authenticationToken: authenticationToken
            )
        } catch {
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
}
