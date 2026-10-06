import CLoomTestSupport
import Darwin
import Foundation
import Metal

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


// Terminal fixtures (CP5 A) write through raw fd 1 so every chunk is its own
// PTY read where timing allows; splits exercise the engine's parser state.
func writeRaw(_ bytes: [UInt8]) {
    var offset = 0
    while offset < bytes.count {
        let count = bytes[offset...].withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
        if count > 0 { offset += count } else if errno != EINTR && errno != EAGAIN { exit(3) }
    }
}

func enterRawMode() {
    var attributes = termios()
    guard tcgetattr(STDIN_FILENO, &attributes) == 0 else { return }
    cfmakeraw(&attributes)
    tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
}

func readByte() -> UInt8? {
    var byte: UInt8 = 0
    while true {
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        if count == 1 { return byte }
        if count < 0 && errno == EINTR { continue }
        return nil
    }
}

/// Split UTF-8/ANSI, Turkish/emoji, truecolor, alternate screen, then a
/// device status query whose reply must come back through Loom's input path.
func runTerminalSample() {
    enterRawMode()
    let pieces: [[UInt8]] = [
        Array("\u{1b}[3".utf8), Array("8;2;255;100;0mTRUE".utf8), Array("\u{1b}[0m ".utf8),
    ] + Array("Türkçe ğüşıöç İ 🧵\r\n".utf8).map { [$0] } + [
        Array("\u{1b}[?1049hALTSCREEN".utf8), Array("\u{1b}[?1049l".utf8),
        Array("MAIN-AGAIN\r\n".utf8),
    ]
    for piece in pieces { writeRaw(piece); usleep(1_000) }
    writeRaw(Array("\u{1b}[6n".utf8))
    var reply: [UInt8] = []
    while let byte = readByte() {
        reply.append(byte)
        if byte == UInt8(ascii: "R") || reply.count > 32 { break }
    }
    let visible = reply.map { $0 == 0x1b ? "ESC" : String(UnicodeScalar($0)) }.joined()
    writeRaw(Array("REPLY:\(visible)\r\nREADY\r\n".utf8))
    // Digest every input byte until Ctrl-D so ordering and completeness of
    // keys and pastes can be checked byte for byte.
    var hash: UInt64 = 0xcbf29ce484222325
    var count = 0
    while let byte = readByte(), byte != 0x04 {
        hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        count += 1
    }
    writeRaw(Array("INPUT:\(count):\(String(hash, radix: 16))\r\n".utf8))
    loom_fixture_wait(0)
}

/// Same as `writeRaw(_: [UInt8])` for a caller-owned buffer, so hot loops can
/// reuse one allocation. Partial writes continue where the kernel stopped.
func writeRaw(_ bytes: UnsafePointer<UInt8>, count total: Int) {
    var offset = 0
    while offset < total {
        let count = Darwin.write(STDOUT_FILENO, bytes + offset, total - offset)
        if count > 0 { offset += count } else if errno != EINTR && errno != EAGAIN { exit(3) }
    }
}

func footerBytes(sent: Int, start: UInt64) -> [UInt8] {
    let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    return Array("\r\nEND bytes=\(sent) seconds=\(String(format: "%.3f", seconds))\r\n".utf8)
}

/// Fixed-size numbered lines at a paced rate (`bytesPerSecond > 0`) or as one
/// burst. Totals are exact so consumers can prove zero byte loss.
/// Records are `L%09d ` + `x`*51 + CRLF; the hot path only advances the nine
/// decimal digits of one reusable record and copies it, with no formatting.
func runStream(bytesPerSecond: Int, totalBytes: Int) {
    enterRawMode() // No ONLCR: bytes on the wire are exactly the bytes written.
    let lineLength = 64
    var record = [UInt8](repeating: UInt8(ascii: "x"), count: lineLength)
    record[0] = UInt8(ascii: "L")
    for index in 1...9 { record[index] = UInt8(ascii: "0") }
    record[10] = UInt8(ascii: " ")
    record[lineLength - 2] = 0x0d
    record[lineLength - 1] = 0x0a
    let tickBytes = bytesPerSecond > 0 ? max(lineLength, bytesPerSecond / 100) : 256 * 1024
    // A tick appends whole records while below tickBytes: at most 63 bytes over.
    let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: tickBytes + lineLength)
    defer { chunk.deallocate() }
    var sent = 0
    let start = DispatchTime.now().uptimeNanoseconds
    record.withUnsafeMutableBufferPointer { record in
        while sent < totalBytes {
            var filled = 0
            while filled < tickBytes, sent + filled < totalBytes {
                let keep = min(lineLength, totalBytes - sent - filled)
                memcpy(chunk + filled, record.baseAddress!, keep)
                filled += keep
                var digit = 9 // Decimal increment of the record counter in place.
                while digit >= 1 {
                    if record[digit] == UInt8(ascii: "9") { record[digit] = UInt8(ascii: "0"); digit -= 1 } else { record[digit] += 1; break }
                }
            }
            writeRaw(chunk, count: filled)
            sent += filled
            if bytesPerSecond > 0 {
                let due = UInt64(Double(sent) / Double(bytesPerSecond) * 1_000_000_000)
                let elapsed = DispatchTime.now().uptimeNanoseconds - start
                if due > elapsed { usleep(useconds_t((due - elapsed) / 1_000)) }
            }
        }
    }
    writeRaw(footerBytes(sent: sent, start: start))
    loom_fixture_wait(0)
}

/// Claude-TUI-like partial updates (CP5 PERF `spinner1`): a static screen is
/// printed once, then a five-row dynamic region is rewritten in place every
/// frame with cursor-up and erase-line sequences. Rows six and seven stay
/// blank and the cursor rests on row five, so neither a frame nor the two
/// footer line feeds ever reach a line feed on the bottom row: scrollback cannot grow after setup. All bytes
/// derive from (fps, frames); `scripts/cp5-d-measure.py` mirrors this layout.
func spinnerSetup() -> [UInt8] {
    var text = ""
    for index in 0..<200 {
        text += "Static scrollback line \(String(format: "%03d", index)): the quick brown fox jumps over the lazy dog\r\n"
    }
    // Seven placeholder rows (six line feeds), then up two rows onto row five.
    text += "\u{1b}[?25l" + String(repeating: "\r\n", count: 6) + "\u{1b}[2A"
    return Array(text.utf8)
}

func spinnerFrame(_ frame: Int, fps: Int) -> [UInt8] {
    let glyphs = ["·", "✢", "✳", "✶", "✻", "✽"]
    let tokens = frame * 13
    let rows = [
        "\u{1b}[2K\u{1b}[38;5;208m\(glyphs[(frame / 2) % glyphs.count])\u{1b}[0m Thinking… (\(frame / fps)s · ↓ \(tokens / 1000).\((tokens % 1000) / 100)k tokens · esc to interrupt)",
        "\u{1b}[2K\u{1b}[2m  ⎿  Tip: frame \(frame)\u{1b}[0m",
        "\u{1b}[2K╭────────────────────────────────────────────────────────╮",
        "\u{1b}[2K│ > Try \"refactor the session catalog\"                      │",
        "\u{1b}[2K╰────────────────────────────────────────────────────────╯",
    ]
    return Array(("\r\u{1b}[4A" + rows.joined(separator: "\r\n")).utf8)
}

func runSpinner(framesPerSecond: Int, frames: Int) {
    enterRawMode()
    var sent = 0
    let start = DispatchTime.now().uptimeNanoseconds
    let setup = spinnerSetup()
    writeRaw(setup)
    sent += setup.count
    for frame in 0..<frames {
        let bytes = spinnerFrame(frame, fps: framesPerSecond)
        writeRaw(bytes)
        sent += bytes.count
        let due = UInt64(Double(frame + 1) / Double(framesPerSecond) * 1_000_000_000)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        if due > elapsed { usleep(useconds_t((due - elapsed) / 1_000)) }
    }
    writeRaw(footerBytes(sent: sent, start: start))
    loom_fixture_wait(0)
}

do {
    // Bound the whole fixture, including setup and the exec handshake.
    let inheritedTimeout = alarm(0)
    alarm(inheritedTimeout > 0 ? min(inheritedTimeout, 29) : 29)
    switch CommandLine.arguments.dropFirst().first ?? "inspect" {
    case "terminal-sample":
        runTerminalSample()
    case "stream":
        // stream <bytesPerSecond, 0 = burst> <totalBytes>
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let rate = Int(arguments[2]), let total = Int(arguments[3]),
              rate >= 0, total > 0 else {
            throw NSError(domain: "LoomTestChild", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: stream <bytesPerSecond> <totalBytes>"])
        }
        let seconds = rate > 0 ? total / rate : 0
        alarm(UInt32(min(3_600, seconds + 60)))
        runStream(bytesPerSecond: rate, totalBytes: total)
    case "spinner":
        // spinner <framesPerSecond> <frames>
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let fps = Int(arguments[2]), let frames = Int(arguments[3]),
              (1...240).contains(fps), frames > 0 else {
            throw NSError(domain: "LoomTestChild", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: spinner <framesPerSecond> <frames>"])
        }
        alarm(UInt32(min(3_600, frames / fps + 60)))
        runSpinner(framesPerSecond: fps, frames: frames)
    case "interactive":
        // Manual development terminal: the PTY line discipline echoes input.
        alarm(3_600)
        try FileHandle.standardOutput.write(contentsOf: Data("Loom synthetic terminal. Type a line; Ctrl-D exits.\r\n> ".utf8))
        while let line = readLine() {
            try FileHandle.standardOutput.write(contentsOf: Data("echo: \(line)\r\n> ".utf8))
        }
    case "mcp":
        try runMCP()
    case "native-links":
        // Output OSC8 directly: native clipboard paste filters ESC bytes.
        // Only an existing regular file in our isolated probe area is allowed.
        guard CommandLine.arguments.count == 3, CommandLine.arguments[2].hasPrefix("/") else {
            throw NSError(domain: "LoomTestChild", code: 6)
        }
        let file = URL(fileURLWithPath: CommandLine.arguments[2])
            .standardizedFileURL.resolvingSymlinksInPath()
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Loom-Dev/probe", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(probe.path + "/"),
              !file.path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NSError(domain: "LoomTestChild", code: 7)
        }
        alarm(300)
        let links = [
            ("CP5_HTTP", "http://example.com/?loom-cp5-native=http"),
            ("CP5_HTTPS", "https://example.com/?loom-cp5-native=https"),
            ("CP5_LOCAL", file.absoluteString),
            ("CP5_ABSOLUTE", file.path),
        ]
        for (label, target) in links {
            writeRaw(Array("\u{1b}]8;;\(target)\u{1b}\\\(label)\u{1b}]8;;\u{1b}\\\r\n".utf8))
        }
        // Raw path detection is a separate observation from OSC8 dispatch.
        writeRaw(Array("CP5_RAW_PATH: \(file.path)\r\n".utf8))
        loom_fixture_wait(0)
    case "xpc-metal-client":
        // OWN-A4: request an actual per-client Apple XPC compiler instance.
        // Keep the client/library alive until supervisor Stop; no service PID
        // is ever signaled by this fixture.
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "LoomTestChild", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Metal device unavailable"])
        }
        // Both the symbol and shader body change on every launch. Reusing a
        // cached library can otherwise bypass the compiler XPC prerequisite.
        let nonce = DispatchTime.now().uptimeNanoseconds
        let functionName = "loom_own_a4_\(getpid())_\(nonce)"
        let shaderConstant = UInt32(truncatingIfNeeded: nonce) ^ UInt32(bitPattern: getpid())
        let library = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            kernel void \(functionName)(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
                out[i] = i + \(shaderConstant)u;
            }
            """, options: nil)
        guard library.makeFunction(name: functionName) != nil else {
            throw NSError(domain: "LoomTestChild", code: 5)
        }
        try emit(["pid": getpid(), "mode": "xpc-metal-client", "compiled": true])
        withExtendedLifetime((device, library)) { loom_fixture_wait(0) }
    case "tcc-read-probe":
        // Acceptance only: open one caller-selected Documents directory.
        // Never emit its path, entries, file contents, or underlying errors.
        var pathIsDocuments = false
        var success = false
        if CommandLine.arguments.count == 3, CommandLine.arguments[2].hasPrefix("/") {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            let documents = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            pathIsDocuments = directory.path.hasPrefix(documents.path + "/")
            if pathIsDocuments {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
                    if attributes[.type] as? FileAttributeType == .typeDirectory {
                        _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                        success = true
                    }
                } catch { /* Only the redacted outcome is exposed below. */ }
            }
        }
        try emit(["mode": "tcc-read-probe", "pid": getpid(),
                  "pathIsDocuments": pathIsDocuments, "success": success])
        loom_fixture_wait(0)
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
    case "spawn-on-input":
        try emit(["pid": getpid(), "mode": "spawn-on-input"])
        _ = readLine()
        let descendant = try spawn(escape: true, apple: false)
        try emit(["descendantPID": descendant])
        loom_fixture_wait(0)
    case "attach-detach":
        // A debugger-like run: trace an outside process briefly, then let go.
        guard CommandLine.arguments.count >= 3, let target = pid_t(CommandLine.arguments[2]) else {
            throw NSError(domain: "LoomTestChild", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: attach-detach <pid>"])
        }
        let attached = loom_fixture_trace(target, 1)
        guard attached == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(attached)) }
        try emit(["pid": getpid(), "attached": target])
        sleep(2)
        _ = loom_fixture_trace(target, 0)
        try emit(["detached": target])
        loom_fixture_wait(0)
    case "churn":
        let churner = loom_fixture_start_churn(20)
        guard churner > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try emit(["pid": getpid(), "churnerPID": churner, "mode": "churn"])
        loom_fixture_wait(0)
    case "group", "escape", "escape-exit", "apple-escape":
        let mode = CommandLine.arguments[1]
        let descendant = try spawn(escape: mode != "group", apple: mode == "apple-escape")
        try emit(["pid": getpid(), "descendantPID": descendant, "mode": mode])
        if mode == "escape-exit" { exit(0) }
        loom_fixture_wait(0)
    default:
        throw NSError(domain: "LoomTestChild", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Expected terminal-sample, stream, spinner, interactive, native-links, inspect, stubborn, spawn-on-input, quick-exit, burst-exit, large-burst-exit, group, escape, escape-exit, apple-escape, churn, xpc-metal-client, tcc-read-probe, or mcp"])
    }
} catch {
    try? FileHandle.standardError.write(contentsOf: Data("loom-test-child: \(error)\n".utf8))
    exit(1)
}
