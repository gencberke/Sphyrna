import Foundation
import LoomCore

/// What the branch strip of a draft asks for.
enum BranchKind: String, Equatable, Sendable, Codable, CaseIterable {
    case stay
    case newBranch
    case newWorktree
}

/// One draft session of a project (V07): the text, the picks made in the draft and the strip's branch choice. A project holds
/// any number of drafts, each with its own id. Nothing here starts anything; the first send turns it into a `NewSessionLaunch`.
public struct SessionDraft: Equatable, Identifiable, Sendable {
    /// The draft's own id: what the side tables, the sidebar's row and the saved file know it by.
    public let id: UUID
    /// The project the draft belongs to; nil is a draft with no project. Picking another project in the question moves it.
    public internal(set) var projectID: UUID?
    public var text: String { didSet { hasText = Self.containsContent(text) } }
    /// Whether the text holds anything but white space. Kept up to date when the text is set, so asking is free
    /// on every redraw; the scan stops at the first character that is not white space.
    public private(set) var hasText: Bool
    /// Explicit picks share one owner; inherited defaults are resolved when the draft is read.
    public var choices = HarnessLaunchChoices()
    public var harness: HarnessID { choices.harness }
    /// A new untouched draft follows the project's latest harness until a model or preset is picked.
    var followsProjectHarness = true
    var modelUsesDefault = false
    var effortUsesDefault = false
    var modePick: DraftPick {
        get { choices.mode.map { .value($0.rawValue) } ?? .inherit }
        set {
            if case let .value(raw) = newValue { choices.mode = HarnessMode.fromStored(raw) }
            else { choices.mode = nil }
        }
    }
    var modelPick: DraftPick {
        get { modelUsesDefault ? .claudeDefault : choices.model.map(DraftPick.value) ?? .inherit }
        set {
            modelUsesDefault = newValue == .claudeDefault
            if case let .value(value) = newValue { choices.model = value } else { choices.model = nil }
        }
    }
    var effortPick: DraftPick {
        get { effortUsesDefault ? .claudeDefault : choices.effort.map(DraftPick.value) ?? .inherit }
        set {
            effortUsesDefault = newValue == .claudeDefault
            if case let .value(value) = newValue { choices.effort = value } else { choices.effort = nil }
        }
    }
    var branchKind: BranchKind = .stay
    /// A branch name the user typed; nil follows the suggestion made from the text.
    var branchName: String?
    public var updatedAt: Date

    /// The project as the per-project tables key it (what was last used, the current draft).
    public var projectKey: String { Self.projectKey(for: projectID) }

    public static func projectKey(for projectID: UUID?) -> String { projectID?.uuidString ?? "none" }

    init(id: UUID = UUID(), projectID: UUID?, text: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.projectID = projectID
        self.text = text
        self.hasText = Self.containsContent(text)
        self.updatedAt = updatedAt
    }

    private static func containsContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// A draft with text is kept and listed; an empty one is invisible (CHAT-SPEC → Draft session).
    public var isVisible: Bool { hasText }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A saved first message with its starting mode and model, one click in the draft (V07). Without a project it
/// is offered in every project.
public struct NewSessionPreset: Equatable, Identifiable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var message: String
    public var choices: HarnessLaunchChoices
    public var permissionMode: String? {
        get { choices.mode?.rawValue }
        set { choices.mode = HarnessMode.fromStored(newValue) }
    }
    public var model: String? {
        get { choices.model }
        set { choices.model = newValue }
    }
    public var projectID: UUID?

    public init(id: UUID = UUID(), name: String, message: String, permissionMode: String? = nil,
                model: String? = nil, projectID: UUID? = nil) {
        self.id = id
        self.name = name
        self.message = message
        self.choices = HarnessLaunchChoices(model: model, mode: HarnessMode.fromStored(permissionMode))
        self.projectID = projectID
    }

    public init(id: UUID = UUID(), name: String, message: String, choices: HarnessLaunchChoices, projectID: UUID? = nil) {
        self.id = id
        self.name = name
        self.message = message
        self.choices = choices
        self.projectID = projectID
    }

    private enum CodingKeys: String, CodingKey { case id, name, message, permissionMode, model, projectID, choices }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        message = try container.decode(String.self, forKey: .message)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        choices = try container.decodeIfPresent(HarnessLaunchChoices.self, forKey: .choices)
            ?? HarnessLaunchChoices(model: container.decodeIfPresent(String.self, forKey: .model),
                                    mode: HarnessMode.fromStored(container.decodeIfPresent(String.self, forKey: .permissionMode)))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(projectID, forKey: .projectID)
        try container.encode(choices, forKey: .choices)
        if let legacy = choices.claudeChoices {
            try container.encodeIfPresent(legacy.permissionMode, forKey: .permissionMode)
            try container.encodeIfPresent(legacy.model, forKey: .model)
        }
    }
}

/// Names for the branch a draft may create: from the first words of the message.
enum NewSessionBranchNames {
    /// `sphyrna/fix-the-flaky-test`; never empty.
    static func suggest(text: String, now: Date = Date()) -> String {
        // Only the first line is ever used, so only it is read: this runs on every redraw of a draft with a branch choice.
        let words = slug(firstLine(of: text), words: 4, limit: 32)
        if !words.isEmpty { return "sphyrna/\(words)" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd-HHmm"
        return "sphyrna/session-\(formatter.string(from: now))"
    }

    /// The first line with something on it, found by scanning up to its end and no further.
    static func firstLine(of text: String) -> String {
        String(text.drop { $0.isNewline }.prefix { !$0.isNewline })
    }

    /// Lowercase ASCII words of the first line joined by dashes, at most `words` words and `limit` characters.
    static func slug(_ text: String, words: Int, limit: Int) -> String {
        let folded = firstLine(of: text).replacingOccurrences(of: "ı", with: "i")
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
