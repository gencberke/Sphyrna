import CLoomTestSupport
import Darwin
import Foundation

func emit(_ object: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(0x0a)
    try FileHandle.standardOutput.write(contentsOf: data)
}

func spawn(escape: Bool, apple: Bool) throws -> pid_t {
    let path = apple ? "/bin/sleep" : (Bundle.main.executableURL?.path
        ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
    let argument = apple ? "30" : "stubborn"
    var pid: pid_t = 0
    let result = path.withCString { executable in
        argument.withCString { mode in
            "--silent".withCString { silent in
                let arguments: [UnsafePointer<CChar>?] = apple
                    ? [executable, mode, nil] : [executable, mode, silent, nil]
                return arguments.withUnsafeBufferPointer { buffer in
                    loom_fixture_spawn(executable, buffer.baseAddress, escape ? 1 : 0, &pid)
                }
            }
        }
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
    }
    return pid
}

func runMCP() throws {
    while let line = readLine() {
        guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = request["id"] else { continue }
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        switch request["method"] as? String {
        case "initialize":
            let parameters = request["params"] as? [String: Any]
            if let version = parameters?["protocolVersion"] as? String {
                response["result"] = [
                    "protocolVersion": version,
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "loom-test-mcp", "version": "0.1"],
                ] as [String: Any]
            } else {
                response["error"] = ["code": -32602, "message": "Missing protocolVersion"]
            }
        case "tools/list":
            response["result"] = ["tools": []] as [String: Any]
        case "ping":
            response["result"] = [:] as [String: Any]
        default:
            response["error"] = ["code": -32601, "message": "Method not found"]
        }
        try emit(response)
    }
}

do {
    // Bound the whole fixture, including setup and the exec handshake.
    let inheritedTimeout = alarm(0)
    alarm(inheritedTimeout > 0 ? min(inheritedTimeout, 29) : 29)
    switch CommandLine.arguments.dropFirst().first ?? "inspect" {
    case "mcp":
        try runMCP()
    case "inspect":
        var size = winsize()
        _ = ioctl(STDIN_FILENO, TIOCGWINSZ, &size)
        let environment = ProcessInfo.processInfo.environment
        var output: [String: Any] = [
            "pid": getpid(), "ppid": getppid(), "pgid": getpgrp(),
            "sid": getsid(0), "tty": isatty(STDIN_FILENO) != 0,
            "rows": Int(size.ws_row), "cols": Int(size.ws_col),
            "environmentKeys": environment.keys.sorted(),
        ]
        output["LOOM_RUN_ID"] = environment["LOOM_RUN_ID"] ?? NSNull()
        output["LOOM_SESSION_ID"] = environment["LOOM_SESSION_ID"] ?? NSNull()
        try emit(output)
        loom_fixture_wait(0)
    case "stubborn":
        loom_fixture_ignore_termination()
        if !CommandLine.arguments.contains("--silent") {
            try emit(["pid": getpid(), "mode": "stubborn"])
        }
        loom_fixture_wait(1)
    case "quick-exit":
        try emit(["pid": getpid(), "mode": "quick-exit"])
        exit(7)
    case "burst-exit":
        try emit(["pid": getpid(), "mode": "burst-exit", "bytes": 512 * 1024])
        try FileHandle.standardOutput.write(contentsOf: Data(repeating: 0x5a, count: 512 * 1024))
        exit(0)
    case "large-burst-exit":
        let byteCount = 8 * 1024 * 1024
        try emit(["pid": getpid(), "mode": "large-burst-exit", "bytes": byteCount])
        try FileHandle.standardOutput.write(contentsOf: Data(repeating: 0x59, count: byteCount))
        exit(0)
    case "group", "escape", "escape-exit", "apple-escape":
        let mode = CommandLine.arguments[1]
        let descendant = try spawn(escape: mode != "group", apple: mode == "apple-escape")
        try emit(["pid": getpid(), "descendantPID": descendant, "mode": mode])
        if mode == "escape-exit" { exit(0) }
        loom_fixture_wait(0)
    default:
        throw NSError(domain: "LoomTestChild", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected inspect, stubborn, quick-exit, burst-exit, large-burst-exit, group, escape, escape-exit, apple-escape, or mcp"])
    }
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("loom-test-child: \(error)\n".utf8))
    exit(1)
}
