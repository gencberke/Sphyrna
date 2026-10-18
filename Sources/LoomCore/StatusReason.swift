import Foundation

/// What a Claude session has running in the background at the end of a turn, from `Stop.background_tasks`
/// (a `shell` or a `subagent`, S0) and `session_crons`. Only entries that still run count; a task Claude
/// lists as completed, failed or killed is over. A `Stop` with work left is "turn done, work running".
public struct BackgroundWork: Equatable, Sendable {
    public var shells: Int
    public var subagents: Int
    /// Workflows, monitors and any task type this build does not know.
    public var others: Int
    public var scheduled: Int

    public init(shells: Int = 0, subagents: Int = 0, others: Int = 0, scheduled: Int = 0) {
        self.shells = shells
        self.subagents = subagents
        self.others = others
        self.scheduled = scheduled
    }

    /// The tasks of `background_tasks`, without the scheduled ones.
    public var tasks: Int { shells + subagents + others }
    public var total: Int { tasks + scheduled }
    public var isEmpty: Bool { total == 0 }

    static let finishedStatuses: Set<String> = ["completed", "failed", "killed", "stopped", "cancelled", "canceled"]

    static func parse(tasks value: Any?, scheduled crons: Any?) -> BackgroundWork {
        var work = BackgroundWork(scheduled: collectionCount(crons))
        if let tasks = value as? [Any] {
            for case let task as [String: Any] in tasks {
                if let status = task["status"] as? String, finishedStatuses.contains(status) { continue }
                switch task["type"] as? String {
                case "shell": work.shells += 1
                case "subagent": work.subagents += 1
                default: work.others += 1
                }
            }
            // Entries that are not objects still say something is running (a shape this build does not know).
            work.others += tasks.filter { !($0 is [String: Any]) }.count
        } else if let tasks = value as? [String: Any] {
            work.others += tasks.count
        }
        return work
    }

    private static func collectionCount(_ value: Any?) -> Int {
        if let values = value as? [Any] { return values.count }
        if let values = value as? [String: Any] { return values.count }
        return 0
    }
}

/// The short reason a session shows its status, kept in memory only. It changes at hook boundaries (a
/// permission request, a stop, a failure, a prompt) and, when the registry shows an approval was answered
/// or cancelled without a hook, by being dropped: never per frame. It is built from content (a command, a
/// path, a question, the assistant's last words), so it is never logged, journaled or persisted;
/// `description` and `debugDescription` redact it so that an interpolated state cannot leak it.
public struct StatusReason: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// A tool waits for permission. `detail` is the command or path, `note` the model's description.
        case approval(tool: String)
        /// `AskUserQuestion`. `detail` is the question's header.
        case question
        /// `ExitPlanMode`: the plan is ready for review. No content is kept.
        case planReady
        /// Claude waits for the user in another way (an MCP elicitation, `agent_needs_input`).
        case input
        /// A turn ended. `detail` is the first line of Claude's last message.
        case turnDone
        /// A turn ended with an API error. `category` is Claude's `error` string; `detail` the first line
        /// of the error text.
        case failure(category: String?)
        /// A turn Claude started by itself after a background task reported back (the prompt began with
        /// `<task-notification>`); `detail` is the task's one-line summary.
        case automaticTurn
    }

    public static let maximumDetailLength = 200

    public let kind: Kind
    public let detail: String?
    /// Bash's `description`, shown beside the command when a card has room.
    public let note: String?
    /// What was still running when the turn ended (`.turnDone` only).
    public let work: BackgroundWork

    public init(_ kind: Kind, detail: String? = nil, note: String? = nil, work: BackgroundWork = BackgroundWork()) {
        self.kind = kind
        self.detail = detail
        self.note = note
        self.work = work
    }

    public var description: String { "StatusReason(\(Self.name(of: kind)), redacted)" }
    public var debugDescription: String { description }

    private static func name(of kind: Kind) -> String {
        switch kind {
        case .approval: "approval"
        case .question: "question"
        case .planReady: "planReady"
        case .input: "input"
        case .turnDone: "turnDone"
        case .failure: "failure"
        case .automaticTurn: "automaticTurn"
        }
    }

    /// Whether the reason still describes `activity`. A reason that no longer does is dropped, so a card
    /// never says "Wants to run `ls`" next to a status that is not waiting for approval.
    func holds(for activity: AgentActivity) -> Bool {
        switch (kind, activity) {
        case (.approval, .waitingForApproval), (.question, .waitingForApproval), (.planReady, .waitingForApproval):
            true
        case (.input, .waitingForInput), (.automaticTurn, .working): true
        case (.turnDone, .turnComplete), (.turnDone, .waitingForInput), (.turnDone, .atPrompt): true
        case (.failure, .failed): true
        default: false
        }
    }

    // MARK: From a hook payload

    /// The reason a `PermissionRequest` states: the tool and the command or path for an approval, the
    /// header of a question, "plan ready".
    static func permission(toolName: String?, toolInput: Any?) -> StatusReason {
        let input = toolInput as? [String: Any] ?? [:]
        switch toolName {
        case "ExitPlanMode":
            return StatusReason(.planReady)
        case "AskUserQuestion":
            let first = (input["questions"] as? [Any])?.first as? [String: Any]
            let header = (first?["header"] as? String).flatMap { oneLine($0) }
                ?? (first?["question"] as? String).flatMap { oneLine($0) }
            return StatusReason(.question, detail: header)
        default:
            let tool = toolName.flatMap { oneLine($0, limit: 80) } ?? "Tool"
            let detail = ["command", "file_path", "notebook_path", "path", "url", "pattern", "query", "description"]
                .lazy.compactMap { (input[$0] as? String).flatMap { oneLine($0) } }.first
            let note = toolName == "Bash" ? (input["description"] as? String).flatMap { oneLine($0) } : nil
            return StatusReason(.approval(tool: tool), detail: detail, note: note == detail ? nil : note)
        }
    }

    static func turnDone(lastMessage: String?, work: BackgroundWork) -> StatusReason {
        StatusReason(.turnDone, detail: lastMessage.flatMap { firstLine($0) }, work: work)
    }

    static func failure(error: String?, message: String?, details: String?) -> StatusReason {
        let category = error.flatMap { oneLine($0, limit: 80) }
        let line = message.flatMap { firstLine($0) } ?? details.flatMap { firstLine($0) }
        return StatusReason(.failure(category: category), detail: line)
    }

    /// The one line a task notification carries in its `<summary>`.
    static func automaticTurn(prompt: String?) -> StatusReason {
        var summary: String?
        if let prompt, let open = prompt.range(of: "<summary>"),
           let close = prompt.range(of: "</summary>", range: open.upperBound..<prompt.endIndex) {
            summary = oneLine(String(prompt[open.upperBound..<close.lowerBound]))
        }
        return StatusReason(.automaticTurn, detail: summary)
    }

    // MARK: Text

    /// The first line with something on it, cleaned. Only the head of the text is looked at.
    static func firstLine(_ text: String, limit: Int = maximumDetailLength) -> String? {
        for line in text.prefix(limit * 10).split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            if let cleaned = oneLine(String(line), limit: limit) { return cleaned }
        }
        return nil
    }

    /// One bounded line: whitespace collapsed, control, bidirectional and zero-width scalars dropped, cut
    /// at a character boundary. Nil when nothing is left. Agent text is untrusted and shown verbatim. Package-visible so
    /// that every place that shows a line of agent or user text cleans it the same way.
    package static func oneLine(_ text: String, limit: Int = maximumDetailLength) -> String? {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars.prefix(limit * 8) {
            if scalar.properties.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            if isInvisible(scalar) { continue }
            if pendingSpace { result.append(" "); pendingSpace = false }
            result.append(scalar)
        }
        let line = String(result)
        guard !line.isEmpty else { return nil }
        guard line.count > limit else { return line }
        return String(line.prefix(limit - 1)) + "…"
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true
        // The joiners (U+200C, U+200D) stay: emoji sequences and some scripts need them.
        case 0x200B, 0x200E, 0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0x061C, 0xFEFF: true
        default: false
        }
    }
}
