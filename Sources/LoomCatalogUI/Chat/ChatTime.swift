import Foundation

/// Durations and message times of the stream. Times use the system locale (CHAT-SPEC → Messages, T3 Code's rule):
/// today the time only, yesterday "yesterday at 14:05", older the date, with the year only when it is not the current one.
enum ChatTime {
    /// "12s", "4m 12s", "1h 5m". Under a second reads "0s"; never negative.
    static func duration(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func duration(milliseconds: Double) -> String { duration(seconds: milliseconds / 1000) }

    /// The live row's timer: "42s", "3m 05s", "1h 02m".
    static func clock(seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }

    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                                   timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        if !sameYear { style = style.year() }
        return date.formatted(style) + ", " + time
    }

    /// "Resumed after 4 days".
    static func gap(seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "a moment" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
        let hours = minutes / 60
        if hours < 48 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        let days = hours / 24
        return "\(days) days"
    }
}
