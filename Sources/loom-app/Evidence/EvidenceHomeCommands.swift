#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI

/// The Home glue (V05), driven through the model calls the buttons make.
///
/// - `show-home`: what the sidebar's Home row and ⌃⌘H do (`showHome`).
/// - `home-resume:<session id>`: Resume on a Continue card.
/// - `home-project:<project id>`: another project in the start box.
/// The snapshot gains `home{needsYou, finished, continue, sessionsToday, startProject, emptyCatalog, claudeMissing,
/// paces, reads}`: ids and numbers only, never a title or a line.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not one of these commands.
    func handleHomeCommand(_ name: String, _ argument: String) -> Bool {
        guard let model = app?.model else { return false }
        switch name {
        case "show-home": model.showHome()
        case "home-resume":
            guard let id = UUID(uuidString: argument) else { return false }
            model.resumeHomeForEvidence(id)
        case "home-project":
            guard let id = UUID(uuidString: argument) else { return false }
            model.chooseHomeProjectForEvidence(id)
        default: return false
        }
        return true
    }
}

extension AppDelegate {
    /// Home in numbers and ids for the snapshot.
    var homeEvidence: [String: Any] {
        guard let summary = model?.homeSummary() else { return [:] }
        return [
            "needsYou": summary.needsYou.map(\.uuidString), "finished": summary.finished.map(\.uuidString),
            "continue": summary.continueSessions.map(\.uuidString),
            "sessionsToday": summary.sessionsToday ?? NSNull(),
            "startProject": summary.startProjectID?.uuidString ?? NSNull(),
            "emptyCatalog": summary.emptyCatalog, "claudeMissing": summary.claudeMissing,
            "paces": summary.paces, "reads": summary.reads,
        ]
    }
}
#endif
