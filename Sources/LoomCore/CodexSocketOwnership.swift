import CryptoKit
import Darwin
import Darwin.libproc
import Foundation

/// A socket is usable or removable only while it is the node the owned server
/// created. Codex 0.164 may put its listener at a hashed path and symlink the
/// requested path to it. Neither path, nor an unknown replacement, is removed
/// unless its identity has been recorded and the listener has stopped.
struct CodexSocketOwnership: Sendable {
    struct Node: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
        let uid: uid_t
        let mode: mode_t
    }

    let requested: String
    let hashed: String
    private(set) var requestedNode: Node?
    private(set) var targetNode: Node?
    private(set) var target: String?

    init(requested: String, hashedDirectory: String? = nil) throws {
        self.requested = requested
        let digest = SHA256.hash(data: Data(requested.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = hashedDirectory ?? "/private/tmp/codex-daemon-\(geteuid())"
        hashed = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(digest).path
        try Self.checkPrivateDirectory(URL(fileURLWithPath: requested).deletingLastPathComponent().path)
        if try Self.node(directory) != nil { try Self.checkPrivateDirectory(directory) }
        guard try Self.node(requested) == nil, try Self.node(hashed) == nil else {
            throw LoomError.message("Codex app-server socket path already exists")
        }
    }

    /// Called before connecting. An incomplete bind is retried, but an unknown
    /// link or node is never followed. The exact spawned process must own a
    /// listening Unix socket bound to the recorded target.
    mutating func claimIfReady(leader: ProcessIdentity) throws -> Bool {
        if requestedNode != nil {
            guard try remainingSocket() == target, let target else {
                throw LoomError.message("Codex app-server socket disappeared during startup")
            }
            return Self.ownsListener(leader: leader, path: target)
        }
        guard let request = try Self.node(requested) else { return false }
        let socketPath: String
        let socketNode: Node
        if request.mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
            guard request.uid == geteuid(),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: requested)) == hashed else {
                throw LoomError.message("Codex app-server socket link is not owned")
            }
            try Self.checkPrivateDirectory(URL(fileURLWithPath: hashed).deletingLastPathComponent().path)
            guard let node = try Self.node(hashed) else { return false }
            socketPath = hashed
            socketNode = node
        } else {
            socketPath = requested
            socketNode = request
        }
        guard socketNode.mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), socketNode.uid == geteuid() else {
            throw LoomError.message("Codex app-server socket node is not owned")
        }
        guard socketNode.mode & 0o7777 == 0o600 else { return false }
        guard Self.ownsListener(leader: leader, path: socketPath) else { return false }
        guard try Self.node(requested) == request, try Self.node(socketPath) == socketNode else {
            throw LoomError.message("Codex app-server socket changed during startup")
        }
        requestedNode = request
        targetNode = socketNode
        target = socketPath
        return true
    }

    /// Validates all recorded nodes and says whether a listener check is needed.
    func remainingSocket() throws -> String? {
        guard let requestedNode, let targetNode, let target else {
            guard try Self.node(requested) == nil, try Self.node(hashed) == nil else {
                throw LoomError.message("Codex app-server socket ownership could not be verified")
            }
            return nil
        }
        if let current = try Self.node(requested), current != requestedNode {
            throw LoomError.message("Codex app-server socket was replaced")
        }
        if let current = try Self.node(target), current != targetNode {
            throw LoomError.message("Codex app-server socket target was replaced")
        }
        return try Self.node(target) == nil ? nil : target
    }

    /// Called only after an unbound check and scope-empty verification. Recheck
    /// inode/birth metadata immediately before unlinking either recorded node.
    func removeRemaining() throws {
        _ = try remainingSocket()
        guard let requestedNode, let targetNode, let target else { return }
        if target != requested, try Self.node(target) == targetNode {
            guard unlink(target) == 0 || errno == ENOENT else { throw LoomError.system("remove Codex socket", errno) }
        }
        if try Self.node(requested) == requestedNode {
            guard unlink(requested) == 0 || errno == ENOENT else { throw LoomError.system("remove Codex socket link", errno) }
        }
    }

    private static func node(_ path: String) throws -> Node? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw LoomError.system("inspect Codex socket", errno)
        }
        return Node(device: info.st_dev, inode: info.st_ino,
                    birthSeconds: info.st_birthtimespec.tv_sec, birthNanoseconds: info.st_birthtimespec.tv_nsec,
                    uid: info.st_uid, mode: info.st_mode)
    }

    private static func checkPrivateDirectory(_ path: String) throws {
        guard let directory = try node(path), directory.uid == geteuid(),
              directory.mode & mode_t(S_IFMT) == mode_t(S_IFDIR), directory.mode & 0o077 == 0 else {
            throw LoomError.message("Codex socket directory is not private and owned")
        }
    }

    private static func ownsListener(leader: ProcessIdentity, path: String) -> Bool {
        guard ProcessTable.record(pid: leader.pid)?.identity == leader else { return false }
        let itemSize = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(leader.pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0, needed <= Int32(itemSize * 4096) else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / itemSize + 64)
        let capacity = descriptors.count * itemSize
        let bytes = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(leader.pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0, Int(bytes) < capacity else { return false }
        for descriptor in descriptors.prefix(Int(bytes) / itemSize) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(leader.pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_family == AF_UNIX,
                  Int32(info.psi.soi_options) & Int32(SO_ACCEPTCONN) != 0 else { continue }
            var address = info.psi.soi_proto.pri_un.unsi_addr.ua_sun
            let bound = withUnsafeBytes(of: &address.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if bound == path, ProcessTable.record(pid: leader.pid)?.identity == leader { return true }
        }
        return false
    }
}
