import Foundation

/// The background work of a Chat-face run, from its own stream (S1): a Bash moved to the background by a `now` send or
/// `background_tasks`, a background subagent. It outlives the turn, so a finished turn with background work is still
/// under way (the hub's `pendingProviderWorkCount`), and Quit counts it as busy.
///
/// - `system/background_tasks_changed{tasks}` replaces the set (S1: replace semantics);
/// - `system/task_started` with `is_backgrounded`, and `task_updated{patch:{is_backgrounded:true}}`, add a task;
/// - `task_updated{patch:{status}}` with an end status, and `task_notification`, remove it.
struct ChatBackgroundTasks: Sendable, Equatable {
    private(set) var ids: Set<String> = []

    var count: Int { ids.count }

    static let endStatuses: Set<String> = ["completed", "failed", "killed", "stopped", "cancelled"]

    /// Applies one record; true when the set changed.
    mutating func apply(_ message: StreamMessage) -> Bool {
        let before = ids
        switch message {
        case let .taskStarted(task) where task.isBackgrounded:
            ids.insert(task.taskID)
        case let .unknown(unknown) where unknown.type == "system":
            let raw = unknown.raw
            switch unknown.subtype {
            case "background_tasks_changed":
                ids = Set((raw["tasks"]?.array ?? []).compactMap { $0["task_id"]?.string })
            case "task_updated":
                guard let id = raw["task_id"]?.string, let patch = raw["patch"] else { break }
                if let status = patch["status"]?.string, Self.endStatuses.contains(status) {
                    ids.remove(id)
                } else if patch["is_backgrounded"]?.bool == true {
                    ids.insert(id)
                }
            case "task_notification":
                if let id = raw["task_id"]?.string { ids.remove(id) }
            default:
                break
            }
        default:
            break
        }
        return ids != before
    }

    mutating func removeAll() {
        ids.removeAll()
    }
}
