import Foundation

/// How Settings says the morning brief starts.
public enum RemoraBriefMode: String, Codable, Equatable, Sendable {
    /// Sphyrna runs it by itself, at most once a day.
    case automatic
    /// Only when the user asks for it.
    case whenIAsk
}

/// What the schedule needs to know: the settings, the clock and the state of the Mac's side of things.
public struct RemoraScheduleInput: Equatable, Sendable {
    public var remoraOn: Bool
    public var briefMode: RemoraBriefMode
    public var now: Date
    public var timeZone: TimeZone
    /// When the last brief ran (started); nil when none ever did.
    public var lastBrief: Date?
    /// The newest `lastActivityAt` of any listed session; nil when there is none.
    public var newestActivity: Date?
    public var homeShown: Bool
    /// What is left of the plan's 5-hour window, 0...1; nil when it is not known (an unknown window never holds a brief back).
    public var windowRemainingShare: Double?
    /// A brief waits while the remaining share is under this.
    public var windowThreshold: Double

    public init(remoraOn: Bool, briefMode: RemoraBriefMode, now: Date, timeZone: TimeZone = .current, lastBrief: Date? = nil,
                newestActivity: Date? = nil, homeShown: Bool, windowRemainingShare: Double? = nil, windowThreshold: Double = 0.10) {
        self.remoraOn = remoraOn
        self.briefMode = briefMode
        self.now = now
        self.timeZone = timeZone
        self.lastBrief = lastBrief
        self.newestActivity = newestActivity
        self.homeShown = homeShown
        self.windowRemainingShare = windowRemainingShare
        self.windowThreshold = windowThreshold
    }
}

public enum RemoraSkipReason: Equatable, Sendable {
    case remoraOff
    /// The brief is set to When I ask.
    case whenIAsk
    /// A brief already ran in the current day (the day starts at 04:00, so before 04:00 it is still yesterday's day).
    case alreadyBriefedToday
    /// No session moved since the last brief (or since the day before, when none ever ran).
    case nothingMoved
    case homeNotShown
}

public enum RemoraWaitReason: Equatable, Sendable {
    /// The plan's 5-hour window has less than the threshold left; questions still run.
    case windowLow(remaining: Double)
}

public enum RemoraBriefDecision: Equatable, Sendable {
    case run
    /// Not now, try again later in the day (the window recovers).
    case wait(RemoraWaitReason)
    /// Not today, or not at all until a setting or the state changes.
    case skip(RemoraSkipReason)
}

/// Whether the morning brief runs now: a pure function of its input, no clock and no state of its own. The caller records
/// the time of a brief that ran as `lastBrief`; from then on every answer for the same day is `.skip(.alreadyBriefedToday)`,
/// so a brief runs at most once per day by construction (a failed brief that was recorded is not retried until the next day,
/// which is the cost rule: the user can ask).
public enum RemoraSchedule {
    /// The day starts at this local hour.
    public static let dayStartHour = 4

    public static func decide(_ input: RemoraScheduleInput) -> RemoraBriefDecision {
        guard input.remoraOn else { return .skip(.remoraOff) }
        guard input.briefMode == .automatic else { return .skip(.whenIAsk) }
        let start = dayStart(containing: input.now, in: input.timeZone)
        if let last = input.lastBrief, last >= start { return .skip(.alreadyBriefedToday) }
        guard let newest = input.newestActivity, newest > briefSince(now: input.now, lastBrief: input.lastBrief, timeZone: input.timeZone)
        else { return .skip(.nothingMoved) }
        guard input.homeShown else { return .skip(.homeNotShown) }
        if let share = input.windowRemainingShare, share < input.windowThreshold { return .wait(.windowLow(remaining: share)) }
        return .run
    }

    /// The 04:00 at or before `date` in the time zone: when its day began.
    public static func dayStart(containing date: Date, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: date) ?? calendar.startOfDay(for: date)
        if today <= date { return today }
        return calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
    }

    /// What a brief covers: since the last brief, or since the start of the day before when none ever ran.
    public static func briefSince(now: Date, lastBrief: Date?, timeZone: TimeZone) -> Date {
        if let lastBrief { return lastBrief }
        let start = dayStart(containing: now, in: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(byAdding: .day, value: -1, to: start) ?? start.addingTimeInterval(-86_400)
    }
}
