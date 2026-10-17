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
        "\(100 - Int((pace.usedFraction * 100).rounded()))% left"
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

/// One plan window's pace: its name and what is left, a meter of what is used with a tick where an
/// even pace would stand, and whether the limit lasts. The caller passes the time it draws at (the
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

    /// Green for a limit that lasts, orange for one that runs out, the quiet tone while there is no verdict.
    private var sentenceStyle: Color {
        switch pace.status {
        case .tooEarly: LoomTheme.Text.secondary
        case .underPace, .onPace: LoomTheme.PlanPaceLine.lasts
        case .overPace: LoomTheme.PlanPaceLine.runsOut
        }
    }

    private var meter: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: LoomTheme.PlanPaceLine.meterRadius).fill(LoomTheme.PlanPaceLine.track)
                RoundedRectangle(cornerRadius: LoomTheme.PlanPaceLine.meterRadius)
                    .fill(pace.status == .overPace ? LoomTheme.PlanPaceLine.fillOver : LoomTheme.PlanPaceLine.fill)
                    .frame(width: width * pace.usedFraction)
                // Where an even pace would stand now; the fill left of it means the limit lasts.
                Rectangle().fill(LoomTheme.PlanPaceLine.tick)
                    .frame(width: LoomTheme.PlanPaceLine.tickWidth,
                           height: LoomTheme.PlanPaceLine.meterHeight + 2 * LoomTheme.PlanPaceLine.tickOverhang)
                    .offset(x: min(max(width * pace.elapsedFraction - LoomTheme.PlanPaceLine.tickWidth / 2, 0),
                                   width - LoomTheme.PlanPaceLine.tickWidth))
            }
            .frame(height: LoomTheme.PlanPaceLine.meterHeight)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: LoomTheme.PlanPaceLine.meterHeight + 2 * LoomTheme.PlanPaceLine.tickOverhang)
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
