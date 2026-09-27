import Foundation

public struct ShutdownReport: Codable, Sendable {
    public let elapsedSeconds: Double
    public let signals: [SignalAttempt]
    public let remaining: [ProcessRecord]
    public let errors: [String]
    public let outsideOwnership: [ProcessRecord]
    public let ownershipGuarantee: String

    public var succeeded: Bool {
        remaining.isEmpty && errors.isEmpty && outsideOwnership.isEmpty
    }
}

public struct SignalAttempt: Codable, Sendable {
    public let identity: ProcessIdentity
    public let signal: Int32
}
