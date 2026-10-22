#if LOOM_EVIDENCE
import AppKit
import Foundation
import LoomCatalogUI

/// Remora's glue (L3b): the calls the field and the buttons make, the fake provider's script, and the numbers the snapshot carries.
/// Every call of the model's Remora API written here counts in `RemoraReachTests`.
///
/// - `remora-script:<json>`: writes `remora-fixture.json` into the run's own Claude config folder (`answer`, `mode`, `delayMs`, `chips`,
///   `drafts`, `facts`). Refused unless the run uses `--fake-providers` and that folder is inside the run's data root
///   (`RemoraEvidenceFixture`). Writes `ack-remora-script.json`.
/// - `remora-brief`: Catch Me Up (`briefRemora`). `remora-ask:<text>`: a question to the model, All projects (`askRemora`), as ⌘K's
///   ↵ asks it, not through Home's field: Home shows no answer card for it. `remora-stop`: Stop. Each writes
///   `ack-remora-<name>.json` with whether the model took it.
/// - `remora-draft:<project id>`: the new-session page's Draft Brief (`draftRemoraBrief`). Writes `ack-remora-draft.json` with whether
///   the call started.
/// - `remora-pref:<on|mode|proposals|exclude|include>:<value>`: the Settings controls' model calls (`on` true or false; `mode`
///   automatic or whenIAsk; `proposals` true or false; `exclude` and `include` a project id).
/// - `remora-state:<label>`: writes `state-remora-<label>.json`, the same numbers and ids as the snapshot's `remora{}`.
/// - `network:<on|off|system>`: what the one reachability read before the morning brief answers.
/// The snapshot gains `remora{}`: phase, failure kind, the decision and stop kinds, ids and counts, never a question, an answer or a title;
/// its `draft{}` is Draft Brief's phase, project id, sessions read, cited count and whether the brief was placed or copied, never its text.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not one of these commands.
    func handleRemoraCommand(_ name: String, _ argument: String) async -> Bool {
        guard let app, let model = app.model else { return false }
        switch name {
        case "remora-script":
            guard case .root(let root) = app.dataRoot(), let config = app.evidenceClaudeProfile(root: root) else {
                write("ack-remora-script", ["written": false])
                return true
            }
            write("ack-remora-script", ["written": RemoraEvidenceFixture.write(argument, dataRoot: root, claudeConfig: config,
                                                                              usesFakeProviders: !app.redactsContent)])
        case "remora-brief":
            write("ack-remora-brief", ["started": model.briefRemora()])
        case "remora-ask":
            write("ack-remora-ask", ["started": model.askRemora(argument)])
        case "remora-draft":
            let started: Bool
            if let project = UUID(uuidString: argument) { started = await model.draftRemoraBrief(project: project) } else { started = false }
            write("ack-remora-draft", ["started": started])
        case "remora-stop":
            model.stopRemora()
            write("ack-remora-stop", ["stopped": true])
        case "remora-pref":
            let separator = argument.firstIndex(of: ":")
            let key = separator.map { String(argument[..<$0]) } ?? argument
            let value = separator.map { String(argument[argument.index(after: $0)...]) } ?? ""
            write("ack-remora-pref", ["applied": RemoraEvidenceFixture.setPreference(key, value, on: model)])
        case "remora-state":
            let label = argument.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            write("state-remora-\(label)", app.remoraEvidence)
        case "network":
            RemoraEvidenceFixture.setNetwork(online: argument == "on" ? true : argument == "off" ? false : nil)
            write("ack-network", ["override": argument == "on" || argument == "off" ? argument : "system"])
        default:
            return false
        }
        return true
    }
}

extension AppDelegate {
    /// Remora in numbers and ids for the snapshot.
    var remoraEvidence: [String: Any] {
        guard let model else { return ["host": false] }
        var summary = RemoraEvidenceFixture.summary(of: model)
        if model.hasRemora { summary["draft"] = model.draftRemoraEvidence }
        return summary
    }
}
#endif
