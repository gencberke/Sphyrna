import Foundation

/// Reads Git metadata only; it neither launches Git nor polls the filesystem.
public enum GitBranch: Equatable, Sendable {
    case named(String)
    case detached
    case unavailable

    public var label: String {
        switch self {
        case .named(let name): name
        case .detached: "Detached HEAD"
        case .unavailable: "Branch unavailable"
        }
    }

    public static func read(directory: String) -> GitBranch {
        var root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        while true {
            let metadata = root.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: metadata.path, isDirectory: &isDirectory) {
                var gitDirectory = metadata
                if !isDirectory.boolValue {
                    guard let pointer = smallText(metadata), pointer.hasPrefix("gitdir: ") else { return .unavailable }
                    let path = String(pointer.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty else { return .unavailable }
                    gitDirectory = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                        : root.appendingPathComponent(path).standardizedFileURL
                }
                guard let head = smallText(gitDirectory.appendingPathComponent("HEAD"))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return .unavailable }
                if head.hasPrefix("ref: refs/heads/") {
                    let name = String(head.dropFirst(16))
                    return name.isEmpty ? .unavailable : .named(name)
                }
                if [40, 64].contains(head.count), head.allSatisfy({ $0.isHexDigit }) { return .detached }
                return .unavailable
            }
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { return .unavailable }
            root = parent
        }
    }

    private static func smallText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
