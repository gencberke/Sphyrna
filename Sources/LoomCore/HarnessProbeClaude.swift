import Foundation

/// Claude Code's side of the probe: the plan-limits child that already exists (`ClaudePlanLimitsFetcher`), its `PlanLimits`
/// mapped to the neutral windows, and the account its `initialize` answer named, which `PlanLimitsReading` carries in
/// memory beside them, and the models the same answer listed (the model catalog's full names, D-100 round). No token days:
/// the usage index owns those for Claude. Why an ask failed travels in the reading, so the probe reports it.
public struct ClaudeProbeSource: HarnessProbeSource {
    private let fetcher: any PlanLimitsFetching

    public init(fetcher: any PlanLimitsFetching) { self.fetcher = fetcher }

    public func read() async -> HarnessProbeAnswer? { await ask().answer }

    public func ask() async -> HarnessProbeAsk {
        let reading = await fetcher.fetchReading()
        let answer = Self.answer(reading)
        return HarnessProbeAsk(answer: answer.isEmpty ? nil : answer, failure: reading.failure)
    }

    /// The neutral answer for one reading. A failed ask gives no windows (not empty ones), so the probe keeps the last good
    /// ones; an ask that succeeded gives the windows it found.
    static func answer(_ reading: PlanLimitsReading) -> HarnessProbeAnswer {
        HarnessProbeAnswer(account: reading.account, windows: reading.limits.map(windows(of:)),
                           models: reading.models.isEmpty ? nil : reading.models)
    }

    /// The five-hour and weekly windows of `limits`, five-hour first, with the ids and lengths the Claude plan has.
    public static func windows(of limits: PlanLimits) -> [HarnessLimitWindow] {
        var windows: [HarnessLimitWindow] = []
        if let window = limits.fiveHour { windows.append(neutral(window, id: ClaudeLimitWindow.fiveHour, kind: .fiveHour)) }
        if let window = limits.weekly { windows.append(neutral(window, id: ClaudeLimitWindow.sevenDay, kind: .weekly)) }
        return windows
    }

    private static func neutral(_ window: PlanLimitWindow, id: String, kind: PlanLimitKind) -> HarnessLimitWindow {
        let minutes = Int(kind.duration / 60)
        return HarnessLimitWindow(
            id: id, name: HarnessLimitWindow.lengthName(minutes: minutes), durationMinutes: minutes,
            usedPercent: window.usedPercent, resetsAt: window.resetsAt)
    }
}

/// The ids of Claude's two limit windows. The probe names them here and the Usage page reads them by the same constants.
public enum ClaudeLimitWindow {
    public static let fiveHour = "five_hour"
    public static let sevenDay = "seven_day"
}
