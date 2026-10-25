import Foundation
import LoomCore

/// The words for a failed plan-limits ask (a category, never provider output).
extension PlanLimitsFailure.Category {
    /// A short reason for the Usage page; nil for a cancelled ask, which is not a failure.
    var reason: String? {
        switch self {
        case .noToolchain: "Sphyrna could not find Claude."
        case .spawnFailed: "Claude could not be started."
        case .writeFailed: "Claude did not accept the request."
        case .timedOut: "Claude did not answer in time."
        case .endedWithoutAnswer: "Claude ended without answering."
        case .outputTooLarge: "Claude's answer was too large to read."
        case .notAvailable: "Claude reported no plan limits for this account."
        case .cancelled: nil
        }
    }
}

/// Number and money text for the usage surfaces (plans/STAGE-U.md, design picks). Locale-independent:
/// the app's copy is English and the chip must not change width with the system's number format.
enum UsageFormat {
    private static let units: [(suffix: String, spoken: String, size: Double)] = [
        ("", "", 1), ("K", " thousand", 1e3), ("M", " million", 1e6), ("B", " billion", 1e9),
    ]

    /// Exact below 1,000, then K, M and B with at most three significant digits and no trailing
    /// zeros: `940K`, `1.2M`, `12.4M`, `1.28B`.
    static func tokens(_ value: Int64) -> String {
        let (scaled, unit) = scale(value)
        return trimmed(scaled) + units[unit].suffix
    }

    /// The same figure for VoiceOver: `1.2 million`.
    static func spokenTokens(_ value: Int64) -> String {
        let (scaled, unit) = scale(value)
        return trimmed(scaled) + units[unit].spoken
    }

    /// `1,204,310`
    static func grouped(_ value: Int64) -> String {
        let digits = String(value.magnitude)
        var result = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return (value < 0 ? "-" : "") + String(result.reversed())
    }

    /// `~$3.10`, and whole dollars from $1,000: `~$12,846`.
    static func cost(_ usd: Double) -> String {
        "~$" + dollars(usd, cents: false)
    }

    /// `$12,845.60`, for tooltips.
    static func fullCost(_ usd: Double) -> String {
        "$" + dollars(usd, cents: true)
    }

    /// The one percent format of every surface: the figure and the sign with no space, `61%`.
    static func percent(_ value: Int) -> String { "\(value)%" }

    /// A fraction (0 to 1) as `61%`.
    static func percent(fraction: Double) -> String { percent(Int((fraction * 100).rounded())) }

    /// The share of `part` in `whole` as `61%`, or nil when there is no whole.
    static func percent(_ part: Int64, of whole: Int64) -> String? {
        guard whole > 0 else { return nil }
        return percent(fraction: Double(part) / Double(whole))
    }

    /// How long until `date`, in two units at most, rounded up: `12m`, `3h 15m`, `2d 4h`; a past date reads `1m`.
    static func untilReset(_ date: Date, from now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return hours % 24 == 0 ? "\(hours / 24)d" : "\(hours / 24)d \(hours % 24)h"
    }

    // MARK: Pieces

    /// The unit index and the value in that unit, rounded to three significant digits; a value
    /// that rounds up to 1000 moves to the next unit (999,500 is `1M`, not `1000K`).
    private static func scale(_ value: Int64) -> (Double, Int) {
        guard value >= 1_000 else { return (Double(value), 0) }
        var unit = value >= 1_000_000_000 ? 3 : (value >= 1_000_000 ? 2 : 1)
        var scaled = rounded(Double(value) / units[unit].size)
        if scaled >= 1_000, unit < units.count - 1 {
            unit += 1
            scaled = rounded(Double(value) / units[unit].size)
        }
        return (scaled, unit)
    }

    private static func rounded(_ value: Double) -> Double {
        let places = value < 10 ? 100.0 : (value < 100 ? 10.0 : 1.0)
        return (value * places).rounded(.toNearestOrAwayFromZero) / places
    }

    private static func trimmed(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.contains("."), text.hasSuffix("0") || text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func dollars(_ usd: Double, cents: Bool) -> String {
        let value = max(usd, 0)
        let hundredths = (value * 100).rounded(.toNearestOrAwayFromZero)
        let whole = Int64(hundredths / 100)
        if cents || hundredths < 100_000 {
            return grouped(whole) + String(format: ".%02d", Int(hundredths) % 100)
        }
        return grouped(Int64(value.rounded(.toNearestOrAwayFromZero)))
    }
}
