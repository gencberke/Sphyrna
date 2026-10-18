import Foundation
import LoomCore

/// Reads a tracker key (`PAY-418`) out of what the user types in a draft (V07). The tracker prefixes are not
/// known yet, so the pattern is generic: two to ten capitals or digits starting with a capital, a dash, up to six
/// digits, not part of a longer word. A later setting names the prefixes (`allowedPrefixes`); until then a
/// short list of look-alikes that are not trackers (`UTF-8`, `SHA-256`) is left out.
struct TicketPattern: Equatable, Sendable {
    /// When set, only these prefixes count (the configurable list, later). Nil: any prefix.
    var allowedPrefixes: Set<String>?

    static let generic = TicketPattern(allowedPrefixes: nil)

    /// Prefixes of well-known formats that are not trackers.
    static let notTrackers: Set<String> = [
        "UTF", "SHA", "ISO", "RFC", "MD", "AES", "RSA", "TLS", "SSL", "HTTP", "PEP", "CVE", "USB", "IPV", "TCP", "UDP",
    ]

    private static let expression = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_-])([A-Z][A-Z0-9]{1,9})-([0-9]{1,6})(?![A-Za-z0-9_])")

    /// The first key in `text`, as written; nil when there is none.
    func firstKey(in text: String) -> String? {
        let whole = NSRange(text.startIndex..., in: text)
        var found: String?
        Self.expression.enumerateMatches(in: text, range: whole) { match, _, stop in
            guard let match, let prefixRange = Range(match.range(at: 1), in: text),
                  let range = Range(match.range, in: text) else { return }
            let prefix = String(text[prefixRange])
            if let allowed = allowedPrefixes {
                guard allowed.contains(prefix) else { return }
            } else if Self.notTrackers.contains(prefix) {
                return
            }
            found = String(text[range])
            stop.pointee = true
        }
        return found
    }
}

/// What a draft knows about its ticket key, for the line inside the composer (CHAT-SPEC, D-40).
enum TicketStatus: Equatable, Sendable {
    /// No key in the text, or no project to look in.
    case none
    /// A key, and no session for it in the project.
    case free(key: String)
    /// A key that already has a session in the project: the line offers Open instead of a copy.
    case exists(key: String, sessionID: UUID, title: String?)

    var key: String? {
        switch self {
        case .none: nil
        case .free(let key), .exists(let key, _, _): key
        }
    }
}
