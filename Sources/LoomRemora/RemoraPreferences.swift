import Foundation

/// Remora's settings (LOMBOT §6.2): the one place the defaults live. The app keeps the value in its preferences file
/// (`UIPreferences.remora`); the host reads it. A file written before a field existed, or with a value this build does not
/// know, reads as that field's default, one field at a time.
///
/// The defaults are the user's install (§6.2): on, Sonnet, low effort, an automatic brief, no excluded project, proposals
/// on, a brief waits while less than 10 % of the plan's five-hour window is left, `Remora.md` under the data folder, and the
/// brief in the language of the last question (no language set).
/// Whether the public build starts with Remora on is the planner's open point (LOMBOT §11); changing it is one value here.
public struct RemoraPreferences: Codable, Equatable, Sendable {
    public static let defaultModel = "sonnet"
    public static let defaultEffort = "low"
    public static let defaultWindowThreshold = 0.10
    /// `Remora.md` when no path was chosen: in Remora's folder under the data folder, never a vault.
    public static let defaultNoteName = "Remora.md"
    /// No language set: the brief follows the language of the user's last question.
    public static let defaultLanguage: String? = nil

    public var isOn: Bool
    /// `sonnet`, `haiku` or a model id (`RemoraCall` falls back to `sonnet` for anything it cannot pass).
    public var model: String
    /// `low` … `max`.
    public var effort: String
    public var briefMode: RemoraBriefMode
    /// Sessions of these projects never reach a pack, and their notes are deleted when they become excluded.
    public var excludedProjects: Set<UUID>
    /// Whether an answer's proposed facts are offered as "Remember this?".
    public var proposals: Bool
    /// A brief waits while the plan's five-hour window has less than this share left, 0...1.
    public var windowThreshold: Double
    /// An absolute path the user chose for `Remora.md`; nil means `<data root>/remora/Remora.md`.
    public var noteFilePath: String?
    /// The language the morning brief is written in, a BCP-47 code such as `tr` or `en`; nil means the language of the last
    /// question (questions are answered in their own language either way).
    public var language: String?

    public init(isOn: Bool = true, model: String = RemoraPreferences.defaultModel, effort: String = RemoraPreferences.defaultEffort,
                briefMode: RemoraBriefMode = .automatic, excludedProjects: Set<UUID> = [], proposals: Bool = true,
                windowThreshold: Double = RemoraPreferences.defaultWindowThreshold, noteFilePath: String? = nil,
                language: String? = RemoraPreferences.defaultLanguage) {
        self.isOn = isOn
        self.model = model
        self.effort = effort
        self.briefMode = briefMode
        self.excludedProjects = excludedProjects
        self.proposals = proposals
        self.windowThreshold = Self.clampedThreshold(windowThreshold)
        self.noteFilePath = Self.cleaned(noteFilePath)
        self.language = Self.cleanedLanguage(language)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let model = (try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil
        let effort = (try? container.decodeIfPresent(String.self, forKey: .effort)) ?? nil
        let excluded = (try? container.decodeIfPresent([String].self, forKey: .excludedProjects)) ?? nil
        self.init(
            isOn: (try? container.decodeIfPresent(Bool.self, forKey: .isOn)) ?? true,
            model: model.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultModel,
            effort: effort.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultEffort,
            briefMode: (try? container.decodeIfPresent(RemoraBriefMode.self, forKey: .briefMode)) ?? .automatic,
            excludedProjects: Set((excluded ?? []).compactMap(UUID.init(uuidString:))),
            proposals: (try? container.decodeIfPresent(Bool.self, forKey: .proposals)) ?? true,
            windowThreshold: (try? container.decodeIfPresent(Double.self, forKey: .windowThreshold)) ?? Self.defaultWindowThreshold,
            noteFilePath: (try? container.decodeIfPresent(String.self, forKey: .noteFilePath)) ?? nil,
            language: (try? container.decodeIfPresent(String.self, forKey: .language)) ?? Self.defaultLanguage)
    }

    private enum CodingKeys: String, CodingKey {
        case isOn, model, effort, briefMode, excludedProjects, proposals, windowThreshold, noteFilePath, language
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isOn, forKey: .isOn)
        try container.encode(model, forKey: .model)
        try container.encode(effort, forKey: .effort)
        try container.encode(briefMode, forKey: .briefMode)
        try container.encode(excludedProjects.map(\.uuidString).sorted(), forKey: .excludedProjects)
        try container.encode(proposals, forKey: .proposals)
        try container.encode(windowThreshold, forKey: .windowThreshold)
        try container.encodeIfPresent(noteFilePath, forKey: .noteFilePath)
        try container.encodeIfPresent(language, forKey: .language)
    }

    /// Where `Remora.md` is: the chosen absolute path, else the default under `remoraDirectory`.
    public func noteURL(defaultIn remoraDirectory: URL) -> URL {
        if let noteFilePath { return URL(fileURLWithPath: noteFilePath) }
        return remoraDirectory.appendingPathComponent(Self.defaultNoteName)
    }

    static func clampedThreshold(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : defaultWindowThreshold
    }

    /// A language tag: letters and digits in groups of one to eight, joined by hyphens, the first of two or three letters
    /// (`tr`, `en`, `zh-Hans`, `pt-BR`); anything else is "none".
    private static func cleanedLanguage(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines), code.count <= 35,
              code.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil else { return nil }
        return code
    }

    /// Only an absolute path counts; anything else is "none".
    private static func cleaned(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else { return nil }
        return path
    }
}
