import Foundation

public struct ShutdownReport: Codable, Sendable {
    /// Nil preserves decoding of earlier reports; false means the count is unknown.
    public let remainingCountVerified: Bool?
    public let elapsedSeconds: Double
    public let signals: [SignalAttempt]
    public let remaining: [ProcessRecord]
    public let errors: [String]
    public let outsideOwnership: [ProcessRecord]
    public let ownershipGuarantee: String

    public init(remainingCountVerified: Bool? = nil,
                elapsedSeconds: Double, signals: [SignalAttempt], remaining: [ProcessRecord],
                errors: [String], outsideOwnership: [ProcessRecord], ownershipGuarantee: String) {
        self.remainingCountVerified = remainingCountVerified
        self.elapsedSeconds = elapsedSeconds
        self.signals = signals
        self.remaining = remaining
        self.errors = errors
        self.outsideOwnership = outsideOwnership
        self.ownershipGuarantee = ownershipGuarantee
    }

    public var succeeded: Bool {
        remainingCountVerified != false && remaining.isEmpty && errors.isEmpty && outsideOwnership.isEmpty
    }
}

public struct SignalAttempt: Codable, Sendable {
    public let identity: ProcessIdentity
    public let signal: Int32
}
