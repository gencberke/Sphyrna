import CryptoKit
import Darwin
import Foundation

/// Captured before the native run. Only these app-created nodes can be
/// removed; any extra file or replaced/modified node is retained.
struct AgyDiscoveryWitness: Sendable {
    struct Node: Sendable {
        let path: String
        let device: dev_t
        let inode: ino_t
        let isDirectory: Bool
        let digest: Data?
    }
    let directories: [Node]
    let files: [Node]

    static func capture(root: URL) -> AgyDiscoveryWitness? {
        let directories = ["", ".agents", ".agents/skills", ".agents/skills/sphyrna"]
        let files = [".agents/hooks.json", ".agents/skills/sphyrna/SKILL.md"]
        func path(_ part: String) -> String { part.isEmpty ? root.path : root.appendingPathComponent(part).path }
        let dirs = directories.compactMap { node(path($0), directory: true) }
        let regular = files.compactMap { node(path($0), directory: false) }
        guard dirs.count == directories.count, regular.count == files.count else { return nil }
        return AgyDiscoveryWitness(directories: dirs, files: regular)
    }

    /// A retry tolerates nodes already removed by an earlier attempt, but it
    /// never follows a link or removes an unrecognised file.
    func remove() -> Bool {
        for item in directories + files where !matchesOrMissing(item) { return false }
        for item in files {
            guard matchesOrMissing(item) else { return false }
            if unlink(item.path) != 0 && errno != ENOENT { return false }
        }
        for item in directories.reversed() {
            guard matchesOrMissing(item) else { return false }
            if rmdir(item.path) != 0 && errno != ENOENT { return false }
        }
        return true
    }

    private static func node(_ path: String, directory: Bool) -> Node? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG),
              directory || info.st_nlink == 1 else { return nil }
        let digest: Data?
        if directory { digest = nil }
        else {
            guard let bytes = fileDigest(path, device: info.st_dev, inode: info.st_ino) else { return nil }
            digest = bytes
        }
        return Node(path: path, device: info.st_dev, inode: info.st_ino, isDirectory: directory, digest: digest)
    }

    private func matchesOrMissing(_ node: Node) -> Bool {
        var info = stat()
        guard lstat(node.path, &info) == 0 else { return errno == ENOENT }
        guard info.st_uid == geteuid(), info.st_dev == node.device, info.st_ino == node.inode,
              info.st_mode & mode_t(S_IFMT) == mode_t(node.isDirectory ? S_IFDIR : S_IFREG) else { return false }
        guard !node.isDirectory else { return true }
        return node.digest == Self.fileDigest(node.path, device: node.device, inode: node.inode)
    }

    private static func fileDigest(_ path: String, device: dev_t, inode: ino_t) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_dev == device, info.st_ino == inode,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= 64 * 1024 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { bytes in
            pread(fd, bytes.baseAddress, bytes.count, 0)
        }
        guard count == data.count else { return nil }
        return Data(SHA256.hash(data: data))
    }
}
