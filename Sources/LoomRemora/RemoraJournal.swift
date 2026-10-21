import Foundation

/// One call in the journal: written mechanically after the call, with no model call. Its line in the day's file:
///
///     - 09:14 a1b2c3d4 question model=claude-sonnet-5-5 tokens=2532 sessions=<id>,<id> q="…" a="…" s="…"
///
/// The time is local; `a1b2c3d4` is the line's stable id (the × removes the line by it); `q` is the question cut to 200
/// characters (a brief has none), `a` the answer's first sentence cut to 240, `s` the day's one-line summary a brief
/// carries. Text is masked and flat; `"` and `\` are escaped.
public struct RemoraJournalEntry: Equatable, Sendable, Identifiable {
    public enum Limits {
        public static let question = 200
        public static let answer = 240
        public static let summary = 240
    }

    public var id: String
    public var date: Date
    public var kind: RemoraKind
    public var question: String?
    public var answer: String
    /// The sessions the call read (and the answer cites): what forgetting looks for.
    public var sessions: [UUID]
    public var model: String?
    public var tokens: Int
    public var summary: String?

    public init(id: String = RemoraJournalEntry.newID(), date: Date, kind: RemoraKind, question: String? = nil, answer: String,
                sessions: [UUID] = [], model: String? = nil, tokens: Int = 0, summary: String? = nil) {
        self.id = id
        self.date = date
        self.kind = kind
        self.question = question
        self.answer = answer
        self.sessions = sessions
        self.model = model
        self.tokens = tokens
        self.summary = summary
    }

    /// An entry out of what a call produced: the question and the answer's first sentence masked and cut, the summary
    /// likewise, the sessions without repeats.
    public static func make(kind: RemoraKind, question: String?, answerText: String, sessions: [UUID], model: String?, tokens: Int,
                            summary: String?, date: Date) -> Self {
        var seen = Set<UUID>()
        let question = kind == .question ? question.map { RemoraText.line($0, limit: Limits.question) } : nil
        let summary = summary.map { RemoraText.line($0, limit: Limits.summary) }.flatMap { $0.isEmpty ? nil : $0 }
        return Self(
            date: date, kind: kind, question: question, answer: RemoraText.line(RemoraText.firstSentence(answerText), limit: Limits.answer),
            sessions: sessions.filter { seen.insert($0).inserted }, model: model.map(Self.token), tokens: tokens, summary: summary)
    }

    public static func newID() -> String { String(UUID().uuidString.lowercased().prefix(8)) }

    private static func token(_ model: String) -> String {
        let cleaned = model.unicodeScalars.filter { $0.value > 0x20 && $0.value < 0x7F && $0 != "\"" }
        return String(String.UnicodeScalarView(cleaned).prefix(64))
    }

    // MARK: Line

    func line(timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        var line = String(format: "- %02d:%02d %@ %@", parts.hour ?? 0, parts.minute ?? 0, id, kind == .brief ? "brief" : "question")
        if let model, !model.isEmpty { line += " model=\(model)" }
        line += " tokens=\(tokens)"
        if !sessions.isEmpty { line += " sessions=" + sessions.map(\.uuidString).joined(separator: ",") }
        if let question { line += " q=" + Self.quoted(question) }
        line += " a=" + Self.quoted(answer)
        if let summary { line += " s=" + Self.quoted(summary) }
        return line
    }

    /// The entry a line holds, on `day`; nil for a line that is not one.
    init?(line: String, day: RemoraDay, calendar: Calendar) {
        guard line.hasPrefix("- ") else { return nil }
        var rest = Substring(line.dropFirst(2))
        let headEnd = [rest.range(of: " q=\""), rest.range(of: " a=\"")].compactMap { $0 }.map(\.lowerBound).min() ?? rest.endIndex
        let head = rest[..<headEnd].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        rest = rest[headEnd...]
        guard head.count >= 3, head[0].count == 5, head[0].dropFirst(2).first == ":",
              let hour = Int(head[0].prefix(2)), let minute = Int(head[0].suffix(2)), (0..<24).contains(hour), (0..<60).contains(minute),
              head[1].count == 8, head[1].allSatisfy({ $0.isHexDigit }), ["question", "brief"].contains(head[2]) else { return nil }
        var sessions: [UUID] = []
        var model: String?
        var tokens = 0
        for field in head.dropFirst(3) {
            if field.hasPrefix("model=") { model = String(field.dropFirst(6)) }
            else if field.hasPrefix("tokens=") { tokens = Int(field.dropFirst(7)) ?? 0 }
            else if field.hasPrefix("sessions=") { sessions = field.dropFirst(9).split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
        }
        var question: String?
        var answer: String?
        var summary: String?
        while !rest.isEmpty {
            rest = rest.drop { $0 == " " }
            guard rest.count >= 3, rest.dropFirst().first == "=" else { break }
            let key = rest.first
            guard let (value, remainder) = Self.unquote(rest.dropFirst(2)) else { return nil }
            switch key {
            case "q": question = value
            case "a": answer = value
            case "s": summary = value
            default: return nil
            }
            rest = remainder
        }
        guard let answer else { return nil }
        let start = day.start(in: calendar)
        self.init(id: head[1], date: calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start,
                  kind: head[2] == "brief" ? .brief : .question, question: question, answer: answer, sessions: sessions,
                  model: model, tokens: tokens, summary: summary)
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `"…"` at the start of `text`: the unescaped content and what follows the closing quote.
    private static func unquote(_ text: Substring) -> (String, Substring)? {
        guard text.first == "\"" else { return nil }
        var value = ""
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: index)
                guard index < text.endIndex else { return nil }
                value.append(text[index])
            } else if character == "\"" {
                return (value, text[text.index(after: index)...])
            } else {
                value.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }
}
