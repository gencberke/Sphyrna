import Foundation
import LoomCore

/// What the branch strip of a draft asks for.
enum BranchKind: String, Equatable, Sendable, Codable, CaseIterable {
    case stay
    case newBranch
    case newWorktree
}

/// One project's draft session (V07): the text, the picks made in the draft and the strip's branch choice.
/// Nothing here starts anything; the first send turns it into a `NewSessionLaunch`.
public struct SessionDraft: Equatable, Identifiable, Sendable {
    /// The project the draft belongs to; nil is a draft with no project.
    public let projectID: UUID?
    public var text: String
    var modePick: DraftPick = .inherit
    var modelPick: DraftPick = .inherit
    var branchKind: BranchKind = .stay
    /// A branch name the user typed; nil follows the suggestion made from the text.
    var branchName: String?
    /// "Start anyway": the user saw that the ticket has a session and wants a second one.
    var allowDuplicateTicket = false
    public var updatedAt: Date

    public var id: String { Self.id(for: projectID) }

    public static func id(for projectID: UUID?) -> String { projectID?.uuidString ?? "none" }

    init(projectID: UUID?, text: String = "", updatedAt: Date = Date()) {
        self.projectID = projectID
        self.text = text
        self.updatedAt = updatedAt
    }

    /// A draft with text is kept and listed; an empty one is invisible (CHAT-SPEC → Draft session).
    public var isVisible: Bool { !trimmedText.isEmpty }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A saved first message with its starting mode and model, one click in the draft (V07). Without a project it
/// is offered in every project.
public struct NewSessionPreset: Equatable, Identifiable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var message: String
    public var permissionMode: String?
    public var model: String?
    public var projectID: UUID?

    public init(id: UUID = UUID(), name: String, message: String, permissionMode: String? = nil,
                model: String? = nil, projectID: UUID? = nil) {
        self.id = id
        self.name = name
        self.message = message
        self.permissionMode = permissionMode
        self.model = model
        self.projectID = projectID
    }
}

/// Names for the branch a draft may create: from the ticket, else from the first words of the message.
enum NewSessionBranchNames {
    /// `feat/PAY-418-reverse-charge-note` with a ticket, `loom/fix-the-flaky-test` without; never empty.
    static func suggest(ticket: String?, text: String, now: Date = Date()) -> String {
        var rest = text
        if let ticket { rest = rest.replacingOccurrences(of: ticket, with: " ") }
        let words = slug(rest, words: 4, limit: 32)
        if let ticket { return words.isEmpty ? "feat/\(ticket)" : "feat/\(ticket)-\(words)" }
        if !words.isEmpty { return "loom/\(words)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd-HHmm"
        return "loom/session-\(formatter.string(from: now))"
    }

    /// Lowercase ASCII words of the first line joined by dashes, at most `words` words and `limit` characters.
    static func slug(_ text: String, words: Int, limit: Int) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let folded = firstLine.replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var parts: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        var result = ""
        for part in parts.prefix(words) {
            let next = result.isEmpty ? part : result + "-" + part
            if next.count > limit { break }
            result = next
        }
        return result
    }

    /// A cheap check before Git is asked (Git's own `check-ref-format` has the last word at the send).
    static func isPlausible(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 120, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.hasSuffix(".lock"), !name.contains(".."), !name.contains("//"),
              !name.contains("@{") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.value > 0x20 && scalar.value != 0x7F && !" ~^:?*[\\".unicodeScalars.contains(scalar)
        }
    }
}
