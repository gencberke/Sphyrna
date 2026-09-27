import Darwin
import Foundation

/// Resource coalition ownership is additive; shared launch contexts must never be claimed.
public struct CoalitionCapability: Codable, Equatable, Sendable {
    public let resourceID: UInt64?
    public let bootSessionID: String?
    public let detail: String
    public init(resourceID: UInt64?, detail: String, bootSessionID: String? = ProcessTable.bootSessionID()) {
        self.resourceID = resourceID
        self.detail = detail
        self.bootSessionID = bootSessionID
    }

    public var guarantee: String {
        resourceID == nil
            ? "Narrowed ownership: session, observed ancestry and readable run markers only; unobserved unmarked escapes may remain. \(detail)"
            : "Exclusive resource coalition plus session, observed ancestry and readable run markers. \(detail)"
    }

    public static let current = probe()

    public static func probe(forceFailure: Bool = ProcessInfo.processInfo.environment["LOOM_FORCE_COALITION_FAILURE"] == "1") -> Self {
        guard !forceFailure else { return Self(resourceID: nil, detail: "Coalition capability failure forced.") }
        guard ProcessTable.bootSessionID() != nil,
              let ownID = ProcessTable.resourceCoalition(pid: getpid()),
              let records = try? ProcessTable.snapshot() else {
            return Self(resourceID: nil, detail: "Coalition query unavailable.")
        }
        for record in records where record.identity.pid != getpid() {
            let identifier = ProcessTable.resourceCoalition(pid: record.identity.pid)
            if identifier == ownID {
                return Self(resourceID: nil, detail: "Shared coalition \(ownID); another process is present.")
            }
            // An unreadable live process prevents proving exclusivity.
            if record.identity.pid > 0, !record.zombie, identifier == nil {
                guard let now = try? ProcessTable.snapshot() else {
                    return Self(resourceID: nil, detail: "Cannot confirm coalition exclusivity: snapshot failed.")
                }
                if now.contains(where: { $0.identity == record.identity }) {
                    return Self(resourceID: nil, detail: "Cannot prove coalition exclusivity: unreadable process \(record.identity.pid).")
                }
            }
        }
        return Self(resourceID: ownID, detail: "Exclusive coalition \(ownID) verified before launch.")
    }
}
