import Foundation
import LoomChat
import Synchronization

/// The tokens one call used, as Claude reports them in the `result` frame.
public struct RemoraTokenUsage: Equatable, Sendable {
    public var input = 0
    public var cacheCreation = 0
    public var cacheRead = 0
    public var output = 0
    /// How `cacheCreation` splits by cache lifetime (`usage.cache_creation.ephemeral_5m_input_tokens` and
    /// `ephemeral_1h_input_tokens`); zero when the CLI does not report the split.
    public var cacheCreation5m = 0
    public var cacheCreation1h = 0

    public init(input: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0, output: Int = 0,
                cacheCreation5m: Int = 0, cacheCreation1h: Int = 0) {
        self.input = input
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.output = output
        self.cacheCreation5m = cacheCreation5m
        self.cacheCreation1h = cacheCreation1h
    }

    init(_ usage: TokenUsage?, cacheSplit: RemoraCacheSplit? = nil) {
        self.init(input: usage?.inputTokens ?? 0, cacheCreation: usage?.cacheCreationInputTokens ?? 0,
                  cacheRead: usage?.cacheReadInputTokens ?? 0, output: usage?.outputTokens ?? 0,
                  cacheCreation5m: cacheSplit?.fiveMinutes ?? 0, cacheCreation1h: cacheSplit?.oneHour ?? 0)
    }

    public var total: Int { input + cacheCreation + cacheRead + output }

    static func + (left: Self, right: Self) -> Self {
        Self(input: left.input + right.input, cacheCreation: left.cacheCreation + right.cacheCreation,
             cacheRead: left.cacheRead + right.cacheRead, output: left.output + right.output,
             cacheCreation5m: left.cacheCreation5m + right.cacheCreation5m,
             cacheCreation1h: left.cacheCreation1h + right.cacheCreation1h)
    }
}

/// What Remora's calls used, by local day: the numbers of Settings' "Use" line. A call counts when its child starts; its
/// tokens and cost are added when its `result` arrives (a refused or failed call that was billed counts too; one that was
/// cancelled or timed out before a result has none to add). The day turns over at local midnight.
///
/// With `persistedAt` the counter is kept in a file (`usage.json`, 0600, written atomically after every change) and read
/// back when it is made: today's numbers and the days before it, the last 14 days in all, older ones dropped. A write that
/// fails is ignored (a counter never stops a call); the next change writes again.
public final class RemoraUsage: Sendable {
    public static let keptDays = 14
    public static let driftFactor = 3

    public struct Day: Equatable, Sendable {
        public var start: Date
        public var questions = 0
        public var briefs = 0
        /// Draft Brief calls (they run as questions and are not in `questions`).
        public var drafts = 0
        public var tokens = RemoraTokenUsage()
        public var costUSD = 0.0
        /// Calls in which the CLI ignored `CLAUDE_CODE_MESSAGES_PROMPT_CACHE_TTL=5m` (D-86): the one-hour cache write was
        /// more than `driftFactor` times the system prompt's estimated tokens, so the stdin was written under the hour
        /// too. A normal call writes about 1.7 times; an ignored key makes it ten times or more.
        public var cacheDriftCalls = 0
        public var calls: Int { questions + briefs + drafts }

        var isEmpty: Bool { calls == 0 && tokens == RemoraTokenUsage() && costUSD == 0 && cacheDriftCalls == 0 }
    }

    private struct State: Equatable {
        var day: Day
        /// Earlier days with any use, oldest first.
        var history: [Day] = []
    }

    private let state: Mutex<State>
    private let calendar: Calendar
    private let clock: @Sendable () -> Date
    private let file: URL?

    public init(calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }, persistedAt file: URL? = nil) {
        self.calendar = calendar
        self.clock = clock
        self.file = file
        var initial = State(day: Day(start: calendar.startOfDay(for: clock())))
        if let file { Self.load(file, calendar: calendar, now: clock(), into: &initial) }
        state = Mutex(initial)
    }

    /// Today's numbers; zero after midnight.
    public var today: Day { update { _ in }.day }

    /// The last 14 days with any use, today's included, oldest first.
    public var days: [Day] {
        let current = update { _ in }
        return current.history + (current.day.isEmpty ? [] : [current.day])
    }

    func recordStart(_ kind: RemoraKind, isDraft: Bool = false) {
        update { state in
            switch kind {
            case .question where isDraft: state.day.drafts += 1
            case .question: state.day.questions += 1
            case .brief: state.day.briefs += 1
            }
        }
    }

    /// `systemPromptTokens` is the call's system prompt in estimated tokens; with it the call is checked for cache drift (0:
    /// not checked).
    func recordResult(tokens: RemoraTokenUsage, costUSD: Double?, systemPromptTokens: Int = 0) {
        update { state in
            state.day.tokens = state.day.tokens + tokens
            state.day.costUSD += costUSD ?? 0
            if systemPromptTokens > 0, tokens.cacheCreation1h > Self.driftFactor * systemPromptTokens { state.day.cacheDriftCalls += 1 }
        }
    }

    @discardableResult
    private func update(_ change: (inout State) -> Void) -> (day: Day, history: [Day]) {
        let startOfToday = calendar.startOfDay(for: clock())
        return state.withLock { state in
            let before = state
            if state.day.start != startOfToday {
                if !state.day.isEmpty { state.history.append(state.day) }
                state.day = Day(start: startOfToday)
            }
            change(&state)
            Self.trim(&state, calendar: calendar, today: startOfToday)
            if let file, state != before { Self.save(state, to: file, calendar: calendar) }
            return (state.day, state.history)
        }
    }

    /// Keeps the days from 13 days before today on.
    private static func trim(_ state: inout State, calendar: Calendar, today: Date) {
        let oldest = calendar.date(byAdding: .day, value: -(keptDays - 1), to: today) ?? .distantPast
        state.history.removeAll { $0.start < oldest }
    }

    // MARK: File

    private struct StoredDay: Codable {
        var day: String
        var questions: Int
        var briefs: Int
        /// Absent in a file from before Draft Brief.
        var drafts: Int?
        var inputTokens: Int
        var cacheCreationTokens: Int
        var cacheReadTokens: Int
        var outputTokens: Int
        var cacheCreation5mTokens: Int
        var cacheCreation1hTokens: Int
        var costUSD: Double
        var cacheDriftCalls: Int?
    }

    private struct Stored: Codable {
        var version = 1
        var days: [StoredDay]
    }

    private static func save(_ state: State, to file: URL, calendar: Calendar) {
        let days = (state.history + (state.day.isEmpty ? [] : [state.day])).map { day in
            StoredDay(day: RemoraDay(day.start, calendar: calendar).string, questions: day.questions, briefs: day.briefs,
                      drafts: day.drafts, inputTokens: day.tokens.input, cacheCreationTokens: day.tokens.cacheCreation,
                      cacheReadTokens: day.tokens.cacheRead, outputTokens: day.tokens.output,
                      cacheCreation5mTokens: day.tokens.cacheCreation5m, cacheCreation1hTokens: day.tokens.cacheCreation1h,
                      costUSD: day.costUSD, cacheDriftCalls: day.cacheDriftCalls)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Stored(days: days)) else { return }
        try? RemoraFiles.ensureDirectory(file.deletingLastPathComponent())
        try? RemoraFiles.writeAtomically(data, to: file)
    }

    private static func load(_ file: URL, calendar: Calendar, now: Date, into state: inout State) {
        guard let data = RemoraFiles.read(file), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        let today = calendar.startOfDay(for: now)
        for item in stored.days.sorted(by: { $0.day < $1.day }) {
            guard let day = RemoraDay(item.day) else { continue }
            let value = Day(
                start: day.start(in: calendar), questions: item.questions, briefs: item.briefs, drafts: item.drafts ?? 0,
                tokens: RemoraTokenUsage(input: item.inputTokens, cacheCreation: item.cacheCreationTokens,
                                         cacheRead: item.cacheReadTokens, output: item.outputTokens,
                                         cacheCreation5m: item.cacheCreation5mTokens, cacheCreation1h: item.cacheCreation1hTokens),
                costUSD: item.costUSD, cacheDriftCalls: item.cacheDriftCalls ?? 0)
            if value.start == today { state.day = value } else if value.start < today, !value.isEmpty { state.history.append(value) }
        }
        trim(&state, calendar: calendar, today: today)
    }
}
