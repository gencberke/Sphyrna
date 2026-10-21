import Foundation
import Network

/// The one reachability read Home makes before the morning brief (`briefRemoraIfDue(homeShown:isOnline:)`, DESIGN §20 Cost): is
/// there a route to the network at all. It asks a path monitor for its first path and cancels the monitor at once, within a bound of one
/// second, so nothing stays running: no watcher, no timer, no observer. (`SCNetworkReachability`'s synchronous read is the simpler
/// tool, but it is deprecated since macOS 14.4.) A Mac with no route starts no brief and records nothing, so the next Home tries again.
enum NetworkReach {
    /// How long the monitor may take to report its first path. It reports within milliseconds.
    static let bound: DispatchTimeInterval = .seconds(1)

    /// Whether a path's status is a usable route: satisfied, not one that still needs a connection to be made. Pure.
    static func isOnline(status: NWPath.Status) -> Bool { status == .satisfied }

    /// The first path's status, read once; nil when none came within the bound. The wait is on a global queue's thread, not on the
    /// cooperative pool.
    nonisolated static func firstStatus(bound: DispatchTimeInterval = NetworkReach.bound) async -> NWPath.Status? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let monitor = NWPathMonitor()
                let reading = FirstPath()
                monitor.pathUpdateHandler = { reading.set($0.status) }
                monitor.start(queue: DispatchQueue(label: "local.loom.network-reach"))
                reading.wait(bound)
                monitor.cancel()
                continuation.resume(returning: reading.status)
            }
        }
    }

    /// What the evidence run says instead of the system (`network:<on|off>`); nil reads the system. Set only by development
    /// evidence.
    @MainActor static var evidenceOverride: Bool?

    /// One read. A read that gets no path counts as online: it must not hold the brief back on its own (the call fails by itself if
    /// there is no network).
    @MainActor
    static func isOnline() async -> Bool {
        if let evidenceOverride { return evidenceOverride }
        guard let status = await firstStatus() else { return true }
        return isOnline(status: status)
    }
}

/// The first path of one monitor, handed from its queue to the waiting thread.
private final class FirstPath: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var first: NWPath.Status?

    var status: NWPath.Status? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }

    func set(_ status: NWPath.Status) {
        lock.lock()
        let isFirst = first == nil
        if isFirst { first = status }
        lock.unlock()
        if isFirst { semaphore.signal() }
    }

    func wait(_ bound: DispatchTimeInterval) { _ = semaphore.wait(timeout: .now() + bound) }
}
