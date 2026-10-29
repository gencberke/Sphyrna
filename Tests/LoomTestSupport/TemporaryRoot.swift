import Foundation

/// A folder of a test's own under the temporary directory, removed when the test lets go of it. `defer { root.remove() }`
/// right after making one keeps the folder from outliving a test that throws.
public struct TemporaryRoot: Sendable {
    public let url: URL

    /// Makes `<tmp>/<prefix>-<uuid>`.
    public init(_ prefix: String = "loom-test") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func appending(_ component: String, directory: Bool = false) -> URL {
        url.appendingPathComponent(component, isDirectory: directory)
    }

    public func remove() { try? FileManager.default.removeItem(at: url) }
}
