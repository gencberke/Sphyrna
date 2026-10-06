import Foundation
import SQLite3

extension SessionCatalog {
    // MARK: Titles

    /// User rename: marks the title custom so terminal title events cannot
    /// replace it. An empty title returns the row to automatic titles.
    @discardableResult
    public func renameSession(sessionID: UUID, to title: String) throws -> String? {
        let normalized = Self.normalizedTitle(title)
        try database.withStatement("""
            UPDATE sessions SET title = ?, title_is_custom = ? WHERE id = ?
            """) { statement in
            try database.bind(normalized, at: 1, to: statement)
            sqlite3_bind_int(statement, 2, normalized == nil ? 0 : 1)
            try database.bind(sessionID.uuidString, at: 3, to: statement)
            try database.stepDone(statement, operation: "rename session")
        }
        try requireChangedSession(sessionID, operation: "rename session")
        return normalized
    }

    /// A title announced by the terminal or provider. Ignored (returns false)
    /// while the user's custom title is set.
    @discardableResult
    public func recordTerminalTitle(sessionID: UUID, title: String) throws -> Bool {
        guard let normalized = Self.normalizedTitle(Self.strippingStatusGlyph(title)) else { return false }
        // An unchanged value is not a write, so "changed" is accurate and a
        // provider that repaints its title every second costs nothing.
        try database.withStatement("""
            UPDATE sessions SET title = ? WHERE id = ? AND title_is_custom = 0 AND title IS NOT ?
            """) { statement in
            try database.bind(normalized, at: 1, to: statement)
            try database.bind(sessionID.uuidString, at: 2, to: statement)
            try database.bind(normalized, at: 3, to: statement)
            try database.stepDone(statement, operation: "record terminal title")
        }
        return sqlite3_changes(database.handle) == 1
    }

    /// Claude Code prefixes its terminal title with a status glyph that
    /// alternates while it works (`◐`/`◑`, or a braille spinner) and `✳` when
    /// it is quiet. Only that narrow known set is removed, never other emoji.
    static func strippingStatusGlyph(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first, isStatusGlyph(first) else { return raw }
        let rest = trimmed.unicodeScalars.dropFirst()
        guard rest.first.map({ $0 == " " }) ?? true else { return raw }
        return String(String.UnicodeScalarView(rest))
    }

    private static func isStatusGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x25D0...0x25D3, 0x2733, 0x2800...0x28FF: true
        default: false
        }
    }

    static func normalizedTitle(_ raw: String) -> String? {
        let flattened = raw.unicodeScalars.map {
            CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                ? " " : Character($0)
        }
        let trimmed = String(flattened).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxTitleLength))
    }
}
