import LoomCore
import SwiftUI

/// The words of the plan pace line (`Resets 16:40 · at this pace it lasts`).
enum PlanPaceText {
    static func title(_ kind: PlanLimitKind) -> String {
        switch kind {
        case .fiveHour: "5-hour window"
        case .weekly: "Weekly"
        }
    }

    static func remaining(_ pace: PlanPace) -> String {
        "\(UsageFormat.percent(100 - Int((pace.usedFraction * 100).rounded()))) left"
    }

    /// `16:40`, or `Mon 09:00` when it is not today.
    static func moment(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.isDate(date, inSameDayAs: now) ? "" : UsageText.weekday(date, timeZone) + " "
        return day + UsageText.time(date, timeZone)
    }

    /// Whether the limit lasts, in plain words: `at this pace it lasts`, `at this pace it runs out 15:55`,
    /// or `limit reached` once it is used up; nil early in the window, when no rate says anything.
    static func verdict(_ pace: PlanPace, now: Date, timeZone: TimeZone) -> String? {
        switch pace.status {
        case .tooEarly:
            return nil
        case .underPace, .onPace:
            return "at this pace it lasts"
        case .overPace:
            guard pace.usedFraction < 1, let runsOutAt = pace.runsOutAt else { return "limit reached" }
            return "at this pace it runs out \(moment(runsOutAt, now: now, timeZone: timeZone))"
        }
    }

    /// The whole second line: the reset time, then the verdict when there is one.
    static func sentence(_ pace: PlanPace, now: Date, timeZone: TimeZone) -> String {
        let reset = "Resets \(moment(pace.resetsAt, now: now, timeZone: timeZone))"
        guard let verdict = verdict(pace, now: now, timeZone: timeZone) else { return reset }
        return "\(reset) · \(verdict)"
    }
}

/// One plan window's pace: its name and what is left, a meter of what is left with a tick where an
/// even pace would leave it, and whether the limit lasts. The caller passes the time it draws at (the
/// model's minute tick), so the view itself never wakes.
struct PlanPaceLine: View {
    let pace: PlanPace
    let now: Date
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.PlanPaceLine.titleGap) {
            HStack {
                Text(PlanPaceText.title(pace.kind)).font(LoomTheme.Typography.bodyStrong)
                    .foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: LoomTheme.Space.chipSplitGap)
                Text(PlanPaceText.remaining(pace)).font(LoomTheme.Typography.small).monospacedDigit()
                    .foregroundStyle(LoomTheme.Text.secondary)
            }
            meter
            Text(PlanPaceText.sentence(pace, now: now, timeZone: timeZone))
                .font(LoomTheme.Typography.caption)
                .foregroundStyle(sentenceStyle)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(PlanPaceText.title(pace.kind)), \(PlanPaceText.remaining(pace))")
        .accessibilityValue(PlanPaceText.sentence(pace, now: now, timeZone: timeZone))
    }

    /// Neutral for a limit that lasts, orange for one that runs out, the quiet tone while there is no verdict.
    private var sentenceStyle: Color {
        switch pace.status {
        case .tooEarly, .underPace, .onPace: LoomTheme.PlanPaceLine.lasts
        case .overPace: LoomTheme.PlanPaceLine.runsOut
        }
    }

    /// What is left: a fill from the leading edge, as the footer chip draws it, in the neutral tone; orange when the window runs
    /// out or little is left. The tick is where an even pace would leave the remainder now: a fill beyond it is a limit that
    /// lasts.
    nonisolated static func remainingFraction(_ pace: PlanPace) -> Double { min(max(1 - pace.usedFraction, 0), 1) }
    static func tickFraction(_ pace: PlanPace) -> Double { min(max(1 - pace.elapsedFraction, 0), 1) }
    /// Under 20 % left, in whole percent as the footer chip counts it: exactly 20 % left is not low (1 - 0.8 is 0.19999999999999996).
    nonisolated static func isLow(_ pace: PlanPace) -> Bool {
        pace.status == .overPace || (remainingFraction(pace) * 100).rounded() < LoomTheme.PlanPaceLine.lowBelow * 100
    }

    private var meter: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: LoomTheme.PlanPaceLine.meterRadius).fill(LoomTheme.PlanPaceLine.track)
                RoundedRectangle(cornerRadius: LoomTheme.PlanPaceLine.meterRadius)
                    .fill(Self.isLow(pace) ? LoomTheme.PlanPaceLine.fillOver : LoomTheme.PlanPaceLine.fill)
                    .frame(width: width * Self.remainingFraction(pace))
                Rectangle().fill(LoomTheme.PlanPaceLine.tick)
                    .frame(width: LoomTheme.PlanPaceLine.tickWidth,
                           height: LoomTheme.PlanPaceLine.meterHeight + 2 * LoomTheme.PlanPaceLine.tickOverhang)
                    .offset(x: min(max(width * Self.tickFraction(pace) - LoomTheme.PlanPaceLine.tickWidth / 2, 0),
                                   width - LoomTheme.PlanPaceLine.tickWidth))
            }
            .frame(height: LoomTheme.PlanPaceLine.meterHeight)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: LoomTheme.PlanPaceLine.meterHeight + 2 * LoomTheme.PlanPaceLine.tickOverhang)
    }
}

/// The plan limits as one line (V25): "5h 62% left · Wk 74% left · on pace". Plain data, so a test can state it from
/// fixture numbers; `HomeUsage` draws it.
struct PlanLimitsLine: Equatable {
    struct Window: Equatable {
        /// `5-hour window` or `Weekly`, for VoiceOver.
        let title: String
        /// `5h` or `Wk`.
        let name: String
        /// `62% left`.
        let left: String
        /// Under 20 % left (the footer chip's rule).
        let isLow: Bool
    }

    enum Verdict: Equatable {
        case onPace
        case runsOut(name: String, at: String)
        case reached(name: String)

        var text: String {
            switch self {
            case .onPace: "on pace"
            case let .runsOut(name, at): "\(name) runs out \(at)"
            case let .reached(name): "\(name) limit reached"
            }
        }

        var isWarning: Bool { self != .onPace }
    }

    let windows: [Window]
    /// nil early in a window, when no rate says anything.
    let verdict: Verdict?

    init(paces: [PlanPace], now: Date, timeZone: TimeZone) {
        windows = paces.map {
            Window(title: PlanPaceText.title($0.kind), name: $0.kind.chipName, left: PlanPaceText.remaining($0), isLow: PlanPaceLine.isLow($0))
        }
        if let over = paces.first(where: { $0.status == .overPace }) {
            if over.usedFraction < 1, let runsOutAt = over.runsOutAt {
                verdict = .runsOut(name: over.kind.chipName, at: PlanPaceText.moment(runsOutAt, now: now, timeZone: timeZone))
            } else {
                verdict = .reached(name: over.kind.chipName)
            }
        } else if paces.contains(where: { $0.status == .onPace || $0.status == .underPace }) {
            verdict = .onPace
        } else {
            verdict = nil
        }
    }

    /// The line as the Home card shows it.
    var text: String {
        (windows.map { "\($0.name) \($0.left)" } + [verdict?.text].compactMap { $0 }).joined(separator: " \u{00B7} ")
    }

    /// For VoiceOver: "Plan limits, 5-hour window 62% left, weekly 74% left, on pace".
    var spoken: String {
        "Plan limits, " + (windows.map { "\($0.title) \($0.left)" } + [verdict?.text].compactMap { $0 }).joined(separator: ", ")
    }

    /// The tooltip: each window's whole pace sentence.
    func tooltip(paces: [PlanPace], now: Date, timeZone: TimeZone) -> String {
        paces.map {
            "\(PlanPaceText.title($0.kind)), \(PlanPaceText.remaining($0)). \(PlanPaceText.sentence($0, now: now, timeZone: timeZone))"
        }.joined(separator: "\n") + "\nClick for the meters."
    }
}

#Preview("Plan pace line") {
    let now = Date()
    let five = PlanPace(kind: .fiveHour, window: PlanLimitWindow(usedPercent: 38, resetsAt: now.addingTimeInterval(3 * 3_600)), at: now)
    let week = PlanPace(kind: .weekly, window: PlanLimitWindow(usedPercent: 82, resetsAt: now.addingTimeInterval(4 * 86_400)), at: now)
    return VStack(alignment: .leading, spacing: 16) {
        if let five { PlanPaceLine(pace: five, now: now, timeZone: .current) }
        if let week { PlanPaceLine(pace: week, now: now, timeZone: .current) }
    }
    .padding(16)
    .frame(width: 280)
    .background(LoomTheme.Surface.card)
    .environment(\.colorScheme, .dark)
}
