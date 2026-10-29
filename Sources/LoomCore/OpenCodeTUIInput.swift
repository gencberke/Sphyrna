import Foundation

/// Exact identity and immutable payload fingerprint presented to the caller's
/// input admission gate. It carries no prompt text.
public struct OpenCodeTUIInputContext: Sendable, Equatable {
    public let appSessionID: UUID
    public let runID: UUID
    public let instanceID: UUID
    public let nativeSessionID: String
    public let requestID: UUID
    public let roundID: UUID
    public let messageID: String
    /// SHA-256 of the sorted-key JSONEncoder encoding of `{id, text}`.
    public let payloadFingerprint: Data
}

/// The caller owns the app-run input/ingress fence. It must reject unknown or
/// dirty composer state and any earlier unclassified native input. An
/// indeterminate completion must block later automatic sends until reconciled,
/// without indefinitely blocking the user's terminal keyboard. This is not a
/// claim of access to the native composer's private sending queue. Acquiring
/// and finishing a lease must be prompt and honor cancellation; acceptance
/// alone cannot authorize a next round before its outcome is proven.
public protocol OpenCodeTUIInputAdmission: Sendable {
    func acquire(for input: OpenCodeTUIInputContext) async throws -> any OpenCodeTUIInputLease
}

public protocol OpenCodeTUIInputLease: Sendable {
    func finish(_ outcome: OpenCodeTUIInputAdmissionOutcome) async
}

public enum OpenCodeTUIInputAdmissionOutcome: Sendable, Equatable {
    case notDispatched
    /// A matching native receipt proves admission, not delivery or completion.
    case accepted
    /// Dispatch may have occurred; automatic input must stay fenced until reconciled.
    case indeterminate
}

/// Bounded transient receipt; neither prompt text nor native responses are
/// retained in the bridge after the caller validates the exact payload.
enum OpenCodeTUIInputReply: Sendable, Equatable {
    case receipt(nativeSessionID: String, messageID: String, text: String)
    case rejected, indeterminate
}
