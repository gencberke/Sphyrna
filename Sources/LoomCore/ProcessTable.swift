import CLoomPOSIX
import Darwin
import Foundation

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startSeconds: Int64
    public let startMicroseconds: Int64
}

public struct ProcessRecord: Codable, Sendable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let processGroup: Int32
    public let sessionID: Int32
    public let userID: UInt32
    public let zombie: Bool
}

public enum ProcessTable {
    public static func bootSessionID() -> String? {
        var buffer = [CChar](repeating: 0, count: 64)
        guard loom_boot_session_uuid(&buffer, buffer.count) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    public static func resourceCoalition(pid: Int32) -> UInt64? {
        var identifier: UInt64 = 0
        guard loom_resource_coalition(pid, &identifier) == 0 else { return nil }
        return identifier
    }

    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard loom_process_path(pid, &buffer, buffer.count) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    public static func physicalFootprint(pid: Int32) -> UInt64? {
        var bytes: UInt64 = 0
        guard loom_physical_footprint(pid, &bytes) == 0 else { return nil }
        return bytes
    }

    public static func snapshot() throws -> [ProcessRecord] {
        var pointer: UnsafeMutablePointer<loom_process_info>?
        var count = 0
        guard loom_processes(&pointer, &count) == 0 else { throw LoomError.system("process snapshot", errno) }
        defer { loom_free_processes(pointer) }
        guard let pointer else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).map {
            ProcessRecord(identity: ProcessIdentity(pid: $0.pid, startSeconds: $0.start_sec, startMicroseconds: $0.start_usec),
                          parentPID: $0.ppid, processGroup: $0.pgid, sessionID: $0.sid,
                          userID: $0.uid, zombie: $0.status == SZOMB)
        }
    }

    public static func runID(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard loom_read_run_id(pid, &buffer, buffer.count) == 1 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    public static func signal(_ identity: ProcessIdentity, _ signal: Int32) throws {
        guard loom_signal_if_matches(identity.pid, identity.startSeconds, identity.startMicroseconds, signal) == 0 else {
            // A process that disappeared or whose PID was reused is no longer this process.
            if errno == ESRCH { return }
            throw LoomError.system("signal \(identity.pid)", errno)
        }
    }
}
