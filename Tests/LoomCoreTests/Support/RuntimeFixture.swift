import Darwin
import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport

// The runtime fixture the runtime suites share: the products directory, real paths, the recorders and the context.
enum RuntimeFixture {
    static var binaries: URL {
        Products.directory
    }
}

/// `resolvingSymlinksInPath` keeps `/var`; a child's cwd is the real `/private/var` path.
func realPath(_ url: URL) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return url.path }
    return String(cString: buffer)
}

final class HoldingWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private(set) var writes = 0

    func write(_ data: Data) async throws -> Int {
        while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(5)) }
        lock.withLock { writes += 1 }
        return data.count
    }

    func release() { lock.withLock { released = true } }
}

final class InputErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TerminalInputError] = []
    func append(_ error: TerminalInputError) { lock.withLock { storage.append(error) } }
    var values: [TerminalInputError] { lock.withLock { storage } }
}

final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// Toggles the resolver between failing and working so retries can be tested.
final class ToolchainSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (any Error)?
    private(set) var calls = 0
    private var begun = 0
    private var pause: TimeInterval = 0

    func slow(by seconds: TimeInterval) { lock.withLock { pause = seconds } }
    var delay: TimeInterval { lock.withLock { pause } }
    func beginResolution() { lock.withLock { begun += 1 } }
    var resolutionsBegun: Int { lock.withLock { begun } }

    func fail(with error: (any Error)?) { lock.withLock { failure = error } }

    func check() throws {
        try lock.withLock {
            calls += 1
            if let failure { throw failure }
        }
    }
}

struct RuntimeContext {
    let root: URL
    let home: URL
    let catalog: SessionCatalog
    let supervisor: ProcessSupervisor
    let runtime: SessionRuntime
    let toolchainSwitch: ToolchainSwitch
    let state: URL
    let profile: URL

    var events: SessionEventHub { supervisor.events }

    func cleanup() {
        RunScopeLauncher.removeOwnedBundle(in: root)
        try? FileManager.default.removeItem(at: socketDirectory)
    }

    let socketDirectory: URL
}
