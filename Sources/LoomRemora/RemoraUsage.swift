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

/// What Remora's calls used today, in memory (L2 persists it): the numbers of Settings' "Use" line. A call counts when its
/// child starts; its tokens and cost are added when its `result` arrives (a refused or failed call that was billed
/// counts too; one that was cancelled or timed out before a result has none to add). The day turns over at local midnight.
public final class RemoraUsage: Sendable {
    public struct Day: Equatable, Sendable {
        public var start: Date
        public var questions = 0
        public var briefs = 0
        public var tokens = RemoraTokenUsage()
        public var costUSD = 0.0
        public var calls: Int { questions + briefs }
    }

    private let state: Mutex<Day>
    private let calendar: Calendar
    private let clock: @Sendable () -> Date

    public init(calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.calendar = calendar
        self.clock = clock
        state = Mutex(Day(start: calendar.startOfDay(for: clock())))
    }

    /// Today's numbers; zero after midnight.
    public var today: Day { update { _ in } }

    func recordStart(_ kind: RemoraKind) {
        update { day in
            switch kind {
            case .question: day.questions += 1
            case .brief: day.briefs += 1
            }
        }
    }

    func recordResult(tokens: RemoraTokenUsage, costUSD: Double?) {
        update { day in
            day.tokens = day.tokens + tokens
            day.costUSD += costUSD ?? 0
        }
    }

    @discardableResult
    private func update(_ change: (inout Day) -> Void) -> Day {
        let startOfToday = calendar.startOfDay(for: clock())
        return state.withLock { day in
            if day.start != startOfToday { day = Day(start: startOfToday) }
            change(&day)
            return day
        }
    }
}
