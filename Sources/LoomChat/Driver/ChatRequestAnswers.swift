import Foundation
import LoomCore

// What a card can say to the CLI (V18, CHAT-SPEC → Requests). Everything here is pure: a request and an answer in, the
// wire decision and the one line the stream keeps out. The driver sends it (`ChatSessionDriver.answer`); nothing here, and
// nothing in the driver, ever answers by itself.

/// The subagent that asked a request: `agent_id` joined with the `task_started` record of that id (S1 §B S2). The request
/// has no name of its own.
public struct ChatRequestAgent: Sendable, Equatable {
    public var id: String
    public var type: String?
    public var description: String?

    public init(id: String, type: String? = nil, description: String? = nil) {
        self.id = id
        self.type = type
        self.description = description
    }

    /// "code-reviewer", else the task's description, else "A subagent".
    public var name: String {
        if let type, !type.isEmpty { return type }
        if let description, !description.isEmpty { return description }
        return "A subagent"
    }
}

/// One question of an `AskUserQuestion` request.
public struct ChatQuestion: Sendable, Equatable {
    public struct Option: Sendable, Equatable {
        public var label: String
        public var detail: String?
        /// A preview the CLI offers beside the option (mono text).
        public var preview: String?
    }

    public var question: String
    public var header: String?
    public var multiSelect: Bool
    public var options: [Option]
}

/// How the user answers a waiting request. One value per explicit user action: the driver never builds one itself.
public enum ChatRequestAnswer: Sendable, Equatable {
    /// `allow` with `updatedInput` set to the original input.
    case allowOnce
    /// `allow` with the request's own suggestions, kept for the session only (or a rule for the tool), so no settings
    /// file is written. Refused when the request does not offer it (`ChatPendingRequest.canAllowForSession`).
    case allowForSession
    /// `deny` with the user's note, or a short default message.
    case deny(note: String?)
    /// `deny` with `interrupt: true`: the turn ends too.
    case denyAndStop(note: String?)
    /// A question's answers, one per question (every question needs one).
    case answers([ChatQuestionAnswer])
    /// ExitPlanMode: `allow` with `setMode` for `mode`, which keeps the turn going. Always sent, whatever the mode.
    case approvePlan(mode: String)
    /// ExitPlanMode: `deny` with the user's feedback; Claude keeps planning in the same turn.
    case keepPlanning(feedback: String?)

    public static let defaultDenyMessage = "The user denied this request."
    public static let defaultFeedback = "Keep planning."
}

/// The answer to one question: labels picked, or the user's own words ("Other").
public struct ChatQuestionAnswer: Sendable, Equatable {
    public var question: String
    public var picks: [String]
    public var other: String?

    public init(question: String, picks: [String] = [], other: String? = nil) {
        self.question = question
        self.picks = picks
        self.other = other
    }

    /// The text the CLI gets under the question: the user's own words, else the picked labels joined with ", ".
    public var value: String {
        let typed = other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.isEmpty ? picks.joined(separator: ", ") : typed
    }

    public var isAnswered: Bool { !value.isEmpty }
}

/// A request that left the waiting list, with the one line it leaves behind.
public struct ChatSettledRequest: Sendable, Equatable, Identifiable {
    public enum Outcome: Sendable, Equatable {
        /// The user answered it.
        case answered
        /// The CLI withdrew it (an interrupt, a Stop): "Cancelled".
        case cancelled
        /// Its tool call finished some other way.
        case resolved
        /// The process ended while it waited and Loom did not stop it: Claude stopped before the user answered.
        case processEnded
    }

    public var id: String
    public let kind: ChatPendingRequest.Kind
    public let recordKind: RequestRecord.Kind
    /// The tool the request was for (its card's title and kind read from it).
    public let toolName: String
    /// What it was about, on one line ("rm -rf build").
    public let subject: String
    public let outcome: Outcome
    /// "Allowed once: git push origin fix/webhook-sig".
    public let summary: String
    public let settledAt: Date

    /// Keeps what the folded line and a cut-off card need, never the request's whole input (a settled request lives
    /// until the next run; its input can be megabytes).
    public init(request: ChatPendingRequest, outcome: Outcome, summary: String, settledAt: Date) {
        id = request.requestID
        kind = request.kind
        recordKind = request.recordKind
        toolName = request.request.toolName
        subject = request.subject
        self.outcome = outcome
        self.summary = summary
        self.settledAt = settledAt
    }
}

// MARK: Reading a request

extension ChatPendingRequest {
    /// The keys whose text says what a tool call is about, most telling first (the same the hook-reported reason reads).
    static let detailKeys = ["command", "file_path", "notebook_path", "path", "url", "pattern", "query", "description"]

    /// What the call is about on one line: the command, the path, the address. Nil when its input has none.
    public var detail: String? {
        for key in Self.detailKeys {
            if let text = request.input[key]?.string, let line = StatusReason.oneLine(text) { return line }
        }
        return nil
    }

    /// What the stream's line names: the detail, else the tool's display name, else its name.
    public var subject: String {
        switch kind {
        case .question:
            let headers = questions.compactMap { $0.header ?? StatusReason.oneLine($0.question, limit: 60) }
            return headers.isEmpty ? "a question" : headers.joined(separator: ", ")
        case .plan:
            return "the plan"
        case .approval:
            return detail ?? request.displayName.flatMap { StatusReason.oneLine($0, limit: 80) }
                ?? StatusReason.oneLine(request.toolName, limit: 80) ?? "a tool"
        }
    }

    /// The questions of an `AskUserQuestion` request (empty for any other).
    public var questions: [ChatQuestion] {
        guard kind == .question else { return [] }
        return (request.input["questions"]?.array ?? []).compactMap { item in
            guard let text = item["question"]?.string else { return nil }
            let options = (item["options"]?.array ?? []).compactMap { option -> ChatQuestion.Option? in
                guard let label = option["label"]?.string else { return nil }
                return ChatQuestion.Option(label: label, detail: option["description"]?.string,
                                           preview: option["preview"]?.string)
            }
            return ChatQuestion(question: text, header: item["header"]?.string, multiSelect: item["multiSelect"]?.bool ?? false,
                                options: options)
        }
    }

    /// The plan of an `ExitPlanMode` request: its markdown and the file it was saved to.
    public var plan: (markdown: String, filePath: String?)? {
        guard kind == .plan, let markdown = request.input["plan"]?.string else { return nil }
        return (markdown, request.input["planFilePath"]?.string)
    }

    /// A Bash command that writes through a redirection (`> file`, `>> file`, `2> file`) asks again every time, even
    /// after "allow for this session" (S1 §D11), so the card offers Allow once only. `>&` (a file descriptor) is not one.
    /// A `>` inside quotes counts too: the cost of a false positive is one missing button, never a wrong answer.
    public var redirectsOutput: Bool {
        guard request.toolName == "Bash" || request.toolName == "PowerShell", let command = request.input["command"]?.string else {
            return false
        }
        return Self.writesToFile(command)
    }

    /// Whether a shell command redirects output to a file. Not redirects to a file: a target of `/dev/null` (`>/dev/null`,
    /// `2>/dev/null`, `&>/dev/null`, `>>/dev/null`) and a descriptor duplication (`2>&1`, `>&2`, `>&-`). Redirects to a
    /// file: `>file`, `>>file`, `2>file`, `&>file`, `>|file`, and `>&word` with a word that is not a descriptor. The
    /// scan does not parse quoting or here-documents: a `>` inside quotes or in a here-document body counts as a
    /// redirect when its word is not `/dev/null` (the cost of a false positive is one missing button, never a wrong
    /// answer).
    static func writesToFile(_ command: String) -> Bool {
        let characters = Array(command)
        var index = 0
        func skipSpaces(_ at: inout Int) { while at < characters.count, characters[at] == " " || characters[at] == "\t" { at += 1 } }
        func word(from start: Int) -> String {
            var end = start
            var quote: Character?
            while end < characters.count {
                let character = characters[end]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if " \t\n;|&<>()".contains(character) {
                    break
                }
                end += 1
            }
            return String(characters[start..<end]).filter { $0 != "\"" && $0 != "'" }
        }
        while index < characters.count {
            guard characters[index] == ">" else {
                index += 1
                continue
            }
            var at = index + 1
            if at < characters.count, characters[at] == ">" || characters[at] == "|" { at += 1 }
            if at < characters.count, characters[at] == "&" {
                // A duplication (`>&2`, `>&-`) or, with a word that is not a descriptor, a file.
                at += 1
                skipSpaces(&at)
                let target = word(from: at)
                let isDescriptor = !target.isEmpty && (target == "-" || target.allSatisfy(\.isNumber))
                if !isDescriptor { return true }
            } else {
                skipSpaces(&at)
                if word(from: at) != "/dev/null" { return true }
            }
            index = max(at, index + 1)
        }
        return false
    }

    /// What "allow for this session" would send: the request's own suggestions with the destination `session`, else a rule
    /// for the tool. A shell command with no suggestion gets none: a rule for the whole tool would allow every command, and
    /// the CLI offers no such choice there either.
    public var sessionPermissions: [PermissionUpdate] {
        guard kind == .approval, !redirectsOutput else { return [] }
        if !request.permissionSuggestions.isEmpty {
            return request.permissionSuggestions.map { suggestion in
                var update = suggestion
                update.destination = "session"
                return update
            }
        }
        switch request.toolName {
        case "Bash", "PowerShell": return []
        default: return [.allowRule(toolName: request.toolName)]
        }
    }

    /// The label of the "for this session" button: with no suggestion from the CLI the answer is a rule for the whole tool,
    /// and the button says so.
    public var sessionButtonTitle: String {
        request.permissionSuggestions.isEmpty ? "Allow all \(request.toolName) this session" : "Allow for this session"
    }

    /// Whether the card offers "Allow for this session".
    public var canAllowForSession: Bool { !sessionPermissions.isEmpty }

    public var recordKind: RequestRecord.Kind {
        switch kind {
        case .approval: .approval
        case .question: .question
        case .plan: .plan
        }
    }
}

extension Array where Element == PermissionUpdate {
    /// "Bash(npm test:*)", "accept edits mode": what a set of updates grants, for the stream's line.
    var grantDescription: String {
        var parts: [String] = []
        for update in self {
            switch update.type {
            case "addRules", "replaceRules":
                for rule in update.fields["rules"]?.array ?? [] {
                    guard let tool = rule["toolName"]?.string else { continue }
                    if let content = rule["ruleContent"]?.string, !content.isEmpty { parts.append("\(tool)(\(content))") } else { parts.append(tool) }
                }
            case "setMode":
                if let mode = update.fields["mode"]?.string { parts.append("\(ChatModeNames.title(mode)) mode") }
            case "addDirectories":
                for directory in update.fields["directories"]?.array ?? [] {
                    if let path = directory.string { parts.append(path) }
                }
            default:
                if let type = update.type { parts.append(type) }
            }
        }
        return parts.isEmpty ? "this request" : parts.joined(separator: ", ")
    }
}

/// How permission modes read in the stream and on the plan card.
public enum ChatModeNames {
    public static func title(_ mode: String) -> String {
        switch mode {
        case "default": "Ask before edits"
        case "acceptEdits": "Accept edits"
        case "auto": "Auto"
        case "plan": "Plan"
        case "dontAsk": "Don't ask"
        case "bypassPermissions": "Bypass permissions"
        default: mode
        }
    }
}

// MARK: Building the answer

/// The decision to send and the line to keep, from a request and an answer.
struct ChatAnswerPlan: Equatable {
    var decision: PermissionDecision
    var record: RequestRecord
    /// The mode a plan approval sets, for the session's choices.
    var mode: String?
}

enum ChatAnswerError: Error, Equatable {
    /// The answer is not one this request takes (an approval answer for a question, "for this session" where the card
    /// does not offer it).
    case notOffered
    /// A question has no answer.
    case incomplete
}

extension ChatPendingRequest {
    func answerPlan(for answer: ChatRequestAnswer) throws -> ChatAnswerPlan {
        let input = request.input
        let id = request.toolUseID
        func line(_ text: String) -> String { StatusReason.oneLine(text, limit: 240) ?? text }
        func noted(_ note: String?) -> String? {
            note.flatMap { StatusReason.oneLine($0, limit: 160) }
        }
        switch (kind, answer) {
        case (.approval, .allowOnce):
            return ChatAnswerPlan(decision: .allow(updatedInput: input, toolUseID: id),
                                  record: RequestRecord(kind: .approval, summary: line("Allowed once: \(subject)")))
        case (.approval, .allowForSession):
            let updates = sessionPermissions
            guard !updates.isEmpty else { throw ChatAnswerError.notOffered }
            return ChatAnswerPlan(
                decision: .allow(updatedInput: input, updatedPermissions: updates, toolUseID: id),
                record: RequestRecord(kind: .approval, summary: line("Allowed for this session: \(updates.grantDescription)")),
                mode: updates.compactMap { $0.type == "setMode" ? $0.fields["mode"]?.string : nil }.last)
        case let (.approval, .deny(note)):
            let text = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = text?.isEmpty == false ? text! : ChatRequestAnswer.defaultDenyMessage
            let extra = noted(text).map { " · \($0)" } ?? ""
            return ChatAnswerPlan(decision: .deny(message: message, interrupt: false),
                                  record: RequestRecord(kind: recordKind, summary: line("Denied: \(subject)\(extra)")))
        case let (.approval, .denyAndStop(note)), let (.question, .denyAndStop(note)), let (.plan, .denyAndStop(note)):
            let text = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = text?.isEmpty == false ? text! : ChatRequestAnswer.defaultDenyMessage
            let extra = noted(text).map { " · \($0)" } ?? ""
            return ChatAnswerPlan(decision: .deny(message: message, interrupt: true),
                                  record: RequestRecord(kind: recordKind, summary: line("Denied and stopped: \(subject)\(extra)")))
        case let (.question, .answers(given)):
            let questions = self.questions
            var answers: [String: JSONValue] = [:]
            var chosen: [String] = []
            for question in questions {
                guard let found = given.first(where: { $0.question == question.question }), found.isAnswered else {
                    throw ChatAnswerError.incomplete
                }
                answers[question.question] = .string(found.value)
                chosen.append(found.value)
            }
            var updated = input.object ?? [:]
            updated["answers"] = .object(answers)
            return ChatAnswerPlan(
                decision: .allow(updatedInput: .object(updated), toolUseID: id),
                record: RequestRecord(kind: .question, summary: line("Asked: \(subject) · You chose: \(chosen.joined(separator: " / "))")))
        case let (.plan, .approvePlan(mode)):
            return ChatAnswerPlan(
                decision: .allow(updatedInput: input, updatedPermissions: [.setMode(PermissionMode(rawValue: mode))], toolUseID: id),
                record: RequestRecord(kind: .plan, summary: "Approved the plan · \(ChatModeNames.title(mode))"), mode: mode)
        case let (.plan, .keepPlanning(feedback)):
            let text = feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = text?.isEmpty == false ? text! : ChatRequestAnswer.defaultFeedback
            let extra = noted(text).map { ": \($0)" } ?? ""
            return ChatAnswerPlan(decision: .deny(message: message, interrupt: false),
                                  record: RequestRecord(kind: .plan, summary: line("Kept planning\(extra)")))
        default:
            throw ChatAnswerError.notOffered
        }
    }
}
