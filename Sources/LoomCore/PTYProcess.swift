import CLoomPOSIX
import Darwin
import Foundation

/// Access through a serialized lifecycle owner. Closing the PTY does not imply all descendants exited.
public final class PTYProcess {
    public let pid: Int32
    public private(set) var masterFD: Int32
    public private(set) var exitStatus: Int32?

    init(executable: String, arguments: [String], environment: [String: String], directory: String,
         rows: UInt16, columns: UInt16) throws {
        let values = [executable] + arguments + environment.map { "\($0.key)=\($0.value)" } + [directory]
        guard values.allSatisfy({ !$0.utf8.contains(0) }), rows > 0, columns > 0 else {
            throw LoomError.message("Invalid launch argument or terminal size")
        }
        let argv = ([executable] + arguments).map { strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var fd: Int32 = -1
        let child = (argv + [nil]).withUnsafeBufferPointer { args in
            (envp + [nil]).withUnsafeBufferPointer { env in
                loom_spawn_pty(executable, args.baseAddress, env.baseAddress, directory, rows, columns, &fd)
            }
        }
        guard child >= 0 else { throw LoomError.system("PTY spawn", errno) }
        pid = child
        masterFD = fd
    }

    /// A child that a run host started on the slave side of `masterFD`. Loom is
    /// not its parent: exit statuses arrive from the host, not waitpid.
    init(adoptingPID pid: Int32, masterFD: Int32) {
        self.pid = pid
        self.masterFD = masterFD
    }

    deinit { if masterFD >= 0 { Darwin.close(masterFD) } }

    public func resize(rows: UInt16, columns: UInt16) throws {
        guard rows > 0, columns > 0 else { throw LoomError.message("Terminal size must be positive") }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(masterFD, TIOCSWINSZ, &size) == 0 else { throw LoomError.system("PTY resize", errno) }
    }

    public func readAvailable() throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        // Bound work per call so a busy terminal cannot starve lifecycle processing.
        for _ in 0..<16 {
            let count = Darwin.read(masterFD, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)); continue }
            if count == 0 || errno == EIO || errno == EAGAIN { break }
            if errno == EINTR { continue }
            throw LoomError.system("PTY read", errno)
        }
        return data
    }

    /// Returns the number accepted; caller retains the remainder when the PTY applies backpressure.
    public func write(_ data: Data) throws -> Int {
        let result = data.withUnsafeBytes { Darwin.write(masterFD, $0.baseAddress, $0.count) }
        if result < 0 {
            if errno == EAGAIN || errno == EINTR { return 0 }
            throw LoomError.system("PTY write", errno)
        }
        return result
    }

    @discardableResult public func pollExit() -> Int32? {
        guard exitStatus == nil else { return exitStatus }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { exitStatus = status }
        return exitStatus
    }

    public func closeTerminal() {
        if masterFD >= 0 { Darwin.close(masterFD); masterFD = -1 }
    }

    func detachTerminal() -> Int32 {
        precondition(masterFD >= 0)
        let descriptor = masterFD
        masterFD = -1
        return descriptor
    }

    /// Safe immediately after spawn while this object still owns the unreaped
    /// child and therefore keeps its PID reserved against reuse.
    func terminateUnregisteredChild() {
        _ = Darwin.kill(pid, SIGKILL)
        while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
        exitStatus = SIGKILL
        closeTerminal()
    }
}
