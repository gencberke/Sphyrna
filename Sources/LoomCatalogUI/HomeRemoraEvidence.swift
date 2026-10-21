import Foundation
import LoomRemora

/// The script file development evidence writes for the fake provider's Remora mode (`remora-fixture.json` in the run's Claude config
/// folder; DEVELOPMENT §2). The rule lives here, as plain values, so a test pins it: the file is written only in an evidence run that uses
/// the fake providers, only in a folder that resolves inside the run's own data root, and only with the keys the fixture reads.
/// Like `InkEvidence`, it is inert library code: nothing in the app calls it outside the development evidence.
public enum RemoraEvidenceFixture {
    public static let fileName = "remora-fixture.json"
    /// The keys the fixture reads (`loom-fake-provider/RemoraFixture.swift`).
    static let keys: Set<String> = ["answer", "mode", "delayMs", "chips", "drafts", "facts"]

    /// The path of the script file, or nil when the run may not write one: a real-provider run, or a config folder that is not inside the
    /// data root once `..` and symbolic links are resolved (a folder that is the data root itself is outside it as well).
    public static func target(dataRoot: URL, claudeConfig: URL, usesFakeProviders: Bool) -> URL? {
        guard usesFakeProviders else { return nil }
        let root = resolved(dataRoot)
        let folder = resolved(claudeConfig)
        let rootParts = root.pathComponents
        let folderParts = folder.pathComponents
        guard folderParts.count > rootParts.count, Array(folderParts.prefix(rootParts.count)) == rootParts else { return nil }
        let file = folder.appendingPathComponent(fileName)
        // A link at the file's own place would send the write somewhere else.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil { return nil }
        return file
    }

    /// The script as data: a JSON object with only the fixture's keys; nil for anything else.
    public static func validated(_ text: String) -> Data? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              !object.isEmpty, Set(object.keys).isSubset(of: keys) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Writes the script; false when the rule refuses or the text is not a script. Creates the config folder (inside the data root) when
    /// it is not there yet.
    @discardableResult
    public static func write(_ text: String, dataRoot: URL, claudeConfig: URL, usesFakeProviders: Bool) -> Bool {
        guard let file = target(dataRoot: dataRoot, claudeConfig: claudeConfig, usesFakeProviders: usesFakeProviders),
              let data = validated(text) else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `network:<on|off>`: what the reachability read answers instead of the system (nil reads the system again).
    @MainActor
    public static func setNetwork(online: Bool?) { NetworkReach.evidenceOverride = online }

    /// One of the Settings controls' model calls, by name (`remora-pref:<key>:<value>`): `on` and `proposals` take true or false, `mode`
    /// takes automatic or whenIAsk, `exclude` and `include` take a project id. False for anything else.
    @MainActor
    public static func setPreference(_ key: String, _ value: String, on model: CatalogModel) -> Bool {
        switch key {
        case "on": model.setRemoraOn(value == "true")
        case "proposals": model.setRemoraProposals(value == "true")
        case "mode":
            guard let mode = RemoraBriefMode(rawValue: value) else { return false }
            model.setRemoraBriefMode(mode)
        case "exclude", "include":
            guard let id = UUID(uuidString: value) else { return false }
            model.setRemoraExcluded(id, key == "exclude")
        default: return false
        }
        return true
    }

    /// Remora in numbers and ids for the evidence snapshot: phase, failure kind, the decision and stop kinds, ids and counts, never a
    /// question, an answer or a title.
    @MainActor
    public static func summary(of model: CatalogModel) -> [String: Any] {
        guard model.hasRemora else { return ["host": false] }
        let state = model.remora
        let preferences = state.preferences
        var result: [String: Any] = [
            "host": true,
            "phase": String(describing: state.phase),
            "busy": state.isBusy,
            "failure": state.lastFailure?.rawValue ?? NSNull(),
            "stopped": state.stopped.map { String(describing: $0) } ?? NSNull(),
            "decision": state.lastBriefDecision.map(decisionLabel) ?? NSNull(),
            "streamedCharacters": state.streamedText.count,
            "proposedFacts": state.proposedFacts.count,
            "remembered": state.lastRemembered != nil,
            "undo": state.lastUndo != nil,
            "preferences": [
                "on": preferences.isOn, "briefMode": preferences.briefMode.rawValue, "proposals": preferences.proposals,
                "excludedProjects": preferences.excludedProjects.map(\.uuidString).sorted(),
            ] as [String: Any],
        ]
        if let reading = state.reading {
            result["reading"] = ["sessions": reading.sessions, "projectNotes": reading.projectNotes,
                                 "project": reading.project?.id.uuidString ?? NSNull()] as [String: Any]
        }
        if let answer = state.lastAnswer {
            result["lastAnswer"] = [
                "kind": answer.kind == .brief ? "brief" : "question",
                "chips": answer.answer.chips.map(\.sessionID), "drafts": answer.answer.drafts.map(\.sessionID),
                "read": answer.readSessionIDs.map(\.uuidString), "characters": answer.answer.text.count, "journaled": answer.journaled,
            ] as [String: Any]
        }
        if let kept = state.keptBrief {
            result["keptBrief"] = [
                "startedAt": kept.startedAt.timeIntervalSince1970, "chips": kept.chips.map(\.sessionID),
                "drafts": kept.drafts.map(\.sessionID), "read": kept.readSessionIDs.map(\.uuidString), "facts": kept.proposedFacts.count,
            ] as [String: Any]
        }
        if let usage = state.usage {
            result["usageToday"] = ["questions": usage.today.questions, "briefs": usage.today.briefs,
                                    "tokens": usage.today.tokens.total] as [String: Any]
        }
        return result
    }

    private static func decisionLabel(_ decision: RemoraBriefDecision) -> String {
        switch decision {
        case .run: "run"
        case .wait: "wait"
        case .skip(let reason): "skip:\(reason)"
        }
    }

    /// The path with every link and `..` that exists resolved by the system (`realpath` of the longest part that exists), then the
    /// parts that do not exist yet. A `..` among those is refused (an empty path), so a folder that is not there yet cannot be steered
    /// out of the root, and a link above it is followed before the check.
    private static func resolved(_ url: URL) -> URL {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var existing = parts.count
        while existing > 0 {
            let candidate = "/" + parts.prefix(existing).joined(separator: "/")
            var info = stat()
            if lstat(candidate, &info) == 0 { break }
            existing -= 1
        }
        let head = "/" + parts.prefix(existing).joined(separator: "/")
        let tail = Array(parts.dropFirst(existing))
        guard !tail.contains(".."), let real = realpath(head, nil) else { return URL(fileURLWithPath: "/") }
        defer { free(real) }
        return tail.reduce(URL(fileURLWithPath: String(cString: real))) { $0.appendingPathComponent($1) }
    }
}
