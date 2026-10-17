import Foundation

/// Reading, writing and literal access for `JSONValue`, the one JSON tree of the package. Wire formats that drift
/// (Claude Code's stream-json and transcripts) are read through these accessors, which answer nil on a mismatch,
/// never through strict `Codable` types that one changed field would break.
extension JSONValue {
    // MARK: Reading

    public subscript(key: String) -> JSONValue? {
        if case let .object(members) = self { return members[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case let .array(items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }

    // `string`, `bool`, `array` and `object` are declared with the type.
    public var double: Double? { if case let .number(value) = self { return value } else { return nil } }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    /// A whole number (a fractional or out-of-range number is nil).
    public var int: Int? {
        guard case let .number(value) = self, value.rounded() == value, abs(value) < 9e15 else { return nil }
        return Int(value)
    }

    // MARK: Writing

    /// Compact JSON with sorted keys and no escaped slashes, as one line (no newline).
    public func serialized() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public var serializedString: String { String(decoding: serialized(), as: UTF8.self) }

    // MARK: Bounds

    /// A copy whose strings are cut to `maximumBytes` of UTF-8 each (on a character boundary, with an ellipsis).
    public func clippingStrings(toBytes maximumBytes: Int) -> JSONValue {
        switch self {
        case let .string(text): return .string(text.clipped(toBytes: maximumBytes))
        case let .array(items): return .array(items.map { $0.clippingStrings(toBytes: maximumBytes) })
        case let .object(members): return .object(members.mapValues { $0.clippingStrings(toBytes: maximumBytes) })
        default: return self
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

public extension String {
    /// At most `maximumBytes` of UTF-8, cut on a character boundary, with an ellipsis when cut.
    func clipped(toBytes maximumBytes: Int) -> String {
        let utf8 = self.utf8
        guard utf8.count > maximumBytes else { return self }
        var end = utf8.index(utf8.startIndex, offsetBy: maximumBytes)
        while end > utf8.startIndex, utf8[end] & 0xC0 == 0x80 { end = utf8.index(before: end) }
        return String(self[..<end]) + "…"
    }
}
