import Foundation

/// The choices for a new session, independent of the engine that will eventually launch it.
public struct HarnessLaunchChoices: Equatable, Sendable, Codable {
    public var harness: HarnessID
    public var model: String?
    public var effort: String?
    public var mode: HarnessMode?

    public init(harness: HarnessID = .claude, model: String? = nil, effort: String? = nil, mode: HarnessMode? = nil) {
        self.harness = harness
        self.model = model
        self.effort = effort
        self.mode = mode
    }

    public init(_ legacy: ClaudeLaunchChoices) {
        self.init(model: legacy.model, effort: legacy.effort, mode: HarnessMode.fromStored(legacy.permissionMode))
    }

    /// The frozen Claude runtime only receives choices owned by Claude.
    public var claudeChoices: ClaudeLaunchChoices? {
        guard harness == .claude else { return nil }
        return ClaudeLaunchChoices(permissionMode: mode?.rawValue, model: model, effort: effort)
    }

    public var isEmpty: Bool { model == nil && effort == nil && mode == nil }
    /// Compatibility spelling for the existing Claude-facing display and evidence callers.
    public var permissionMode: String? { mode?.rawValue }

    /// Keep an effort the new model offers; otherwise use its default. Never carry Full access across harnesses.
    public func choosing(_ entry: ModelCatalogEntry) -> HarnessLaunchChoices {
        let descriptor = HarnessCatalogue.descriptor(for: entry.harness)
        let changedHarness = harness != entry.harness
        let keptMode: HarnessMode? = mode.flatMap { mode -> HarnessMode? in
            guard descriptor?.modes.contains(mode) == true, !(changedHarness && mode == .fullAccess) else { return nil }
            return mode
        }
        let safeDefault: HarnessMode? = descriptor?.defaultMode.flatMap { $0 == .fullAccess ? nil : $0 }
        let retainedEffort = effort.flatMap { entry.efforts.contains($0) && HarnessEffort.isToken($0) ? $0 : nil }
        let defaultEffort = entry.defaultEffort.flatMap { entry.efforts.contains($0) && HarnessEffort.isToken($0) ? $0 : nil }
        return HarnessLaunchChoices(harness: entry.harness, model: entry.id,
                                    effort: retainedEffort ?? defaultEffort,
                                    mode: keptMode ?? safeDefault)
    }

    /// Full access cannot be inherited as a project's last-used choice.
    public func remembered(over previous: HarnessLaunchChoices?) -> HarnessLaunchChoices {
        var result = previous.flatMap { $0.harness == harness ? $0 : nil } ?? HarnessLaunchChoices(harness: harness)
        if result.mode == .fullAccess { result.mode = nil }
        if let mode, mode != .fullAccess { result.mode = mode }
        if let model { result.model = model }
        if let effort { result.effort = effort }
        return result
    }

    /// Validate against a cached model list. No discovery or model call is made here.
    public func validate(models: [ModelCatalogEntry], allowFullAccess: Bool = true) throws {
        guard let descriptor = HarnessCatalogue.descriptor(for: harness) else {
            throw OpenSessionRejection("the harness is not known")
        }
        if let model, !ClaudeLaunchChoices.isSafeToken(model) {
            throw OpenSessionRejection("the model is not a safe model name")
        }
        if let mode {
            guard allowFullAccess || mode != .fullAccess else {
                throw OpenSessionRejection("Full access is never an agent's choice")
            }
            guard descriptor.modes.contains(mode) else { throw OpenSessionRejection("the mode is not supported by this harness") }
        }
        if let effort {
            let levels: [String]
            if let model {
                levels = models.first { $0.harness == harness && $0.id == model }?.efforts ?? []
            } else {
                levels = models.first { $0.harness == harness && ($0.isDefault || $0.id == "default") }?.efforts
                    ?? descriptor.defaultEfforts
            }
            guard HarnessEffort.isToken(effort), levels.contains(effort) else {
                throw OpenSessionRejection("the effort is not supported by this model")
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case harness, model, effort, mode, permissionMode }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        harness = try container.decodeIfPresent(HarnessID.self, forKey: .harness) ?? .claude
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        if let rawMode = try? container.decode(String.self, forKey: .mode) {
            mode = HarnessMode(rawValue: rawMode)
        } else {
            mode = HarnessMode.fromStored(try container.decodeIfPresent(String.self, forKey: .permissionMode))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(harness, forKey: .harness)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encodeIfPresent(mode, forKey: .mode)
    }
}

/// The latest harness and each harness's own remembered choices for one project.
public struct HarnessProjectChoices: Equatable, Sendable, Codable {
    public var lastHarness: HarnessID
    public var byHarness: [String: HarnessLaunchChoices]

    public init(lastHarness: HarnessID = .claude, byHarness: [String: HarnessLaunchChoices] = [:]) {
        self.lastHarness = lastHarness
        self.byHarness = byHarness
    }

    public func choices(for harness: HarnessID) -> HarnessLaunchChoices? { byHarness[harness.rawValue] }
}
