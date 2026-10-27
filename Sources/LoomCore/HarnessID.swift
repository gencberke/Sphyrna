import Foundation

/// A harness Sphyrna knows, as a value that survives a catalog or a preferences file written by another build.
///
/// A string-backed struct rather than an enum: an id this build does not describe still reads (it keeps its own text and
/// `isKnown` is false, `HarnessCatalogue.descriptor(for:)` is nil), so a file written by a newer build opens instead of
/// failing. The stored `ManagedSession.Provider` stays the catalog's provider column, and `HarnessID(_:)` bridges to it.
public struct HarnessID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// The id of a stored provider. A synthetic session (a test fixture) gets its own text and is not a harness.
    public init(_ provider: ManagedSession.Provider) {
        self.rawValue = provider.rawValue
    }

    public static let claude = HarnessID("claude")
    public static let codex = HarnessID("codex")
    public static let opencode = HarnessID("opencode")
    public static let agy = HarnessID("agy")
    public static let pi = HarnessID("pi")

    /// The id an unreadable value reads as. Never one of the catalogue's harnesses.
    public static let unknown = HarnessID("unknown")

    /// The stored provider this build runs the harness with; nil for a harness that has no provider yet (opencode, agy
    /// and pi until E1–E3) and for an id this build does not describe.
    public var provider: ManagedSession.Provider? {
        ManagedSession.Provider(rawValue: rawValue)
    }

    /// Whether `HarnessCatalogue` describes this harness in this build.
    public var isKnown: Bool {
        HarnessCatalogue.descriptor(for: self) != nil
    }

    public var description: String { rawValue }

    /// Decoding never fails: a value that is not a string, or a string this build does not describe, reads as an
    /// unknown harness rather than failing the whole catalog or preferences file. A known value keeps its text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let raw = try? container.decode(String.self), !raw.isEmpty else {
            self = .unknown
            return
        }
        self.init(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ManagedSession.Provider {
    /// This provider's harness id.
    public var harnessID: HarnessID { HarnessID(self) }
}
