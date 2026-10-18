import Foundation

/// The one place a Date becomes text for the user: times, dates and day headings all follow the system locale
/// and its 12 or 24 hour clock (DESIGN §7, "times use the system locale"), so no surface reads "08:41" beside
/// another that reads "8:41 AM". Relative ages ("5m", "3h") are `RelativeTime`. A formatter is made once per
/// kind, locale, calendar and zone (`FormatterCache`); callers pass a locale, calendar or zone only to pin it
/// (the usage page reads its own time zone, tests pin a locale).
enum LoomDateFormat {
    /// What a formatter draws.
    private enum Kind: String {
        /// The time of day, "8:41 AM" or "08:41".
        case time
        /// The date with its year, "Oct 18, 2026".
        case date
        /// Date and time, "Oct 18, 2026 at 8:41 AM".
        case dateTime
        /// The day of the month without a year, "Oct 18".
        case dayMonth
        /// The weekday, "Sun".
        case weekday
        /// The weekday in full, "Sunday".
        case weekdayLong
        /// A short weekday with the day, "Sun, Oct 18".
        case weekdayDayMonth
        /// The weekday, day and month in full, "Sunday, October 18".
        case fullDate
        /// The hour, "9 AM" or "09".
        case hour
        /// The hour with minutes, "5:30 PM", for a zone whose hours do not start on the hour.
        case hourMinute
    }

    private static let formatters = FormatterCache()
    /// How many formatters were ever made (a test counts it).
    static var formattersCreated: Int { formatters.created }

    static func time(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        string(.time, date, zone, locale, calendar)
    }

    static func date(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        string(.date, date, zone, locale, calendar)
    }

    static func dateTime(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        string(.dateTime, date, zone, locale, calendar)
    }

    static func dayMonth(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        string(.dayMonth, date, zone, locale, calendar)
    }

    static func weekday(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        string(.weekday, date, zone, locale, calendar)
    }

    static func weekdayLong(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        string(.weekdayLong, date, zone, locale, calendar)
    }

    static func weekdayDayMonth(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        string(.weekdayDayMonth, date, zone, locale, calendar)
    }

    static func fullDate(_ date: Date, zone: TimeZone? = nil, locale: Locale = .current, calendar: Calendar = .current) -> String {
        string(.fullDate, date, zone, locale, calendar)
    }

    /// The hour of the day for a chart label: "9 AM", and with minutes ("5:30 PM") in a zone whose hour
    /// boundary is not on the hour.
    static func hour(_ date: Date, zone: TimeZone, locale: Locale = .current, calendar: Calendar = .current) -> String {
        string(zone.secondsFromGMT(for: date) % 3_600 == 0 ? .hour : .hourMinute, date, zone, locale, calendar)
    }

    private static func string(_ kind: Kind, _ date: Date, _ zone: TimeZone?, _ locale: Locale, _ calendar: Calendar) -> String {
        let zone = zone ?? calendar.timeZone
        let key = "\(kind.rawValue)|\(locale.identifier)|\(calendar.identifier)|\(zone.identifier)|\(calendar.firstWeekday)"
        return formatters.string(from: date, key: key) { formatter in
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = zone
            switch kind {
            case .time: formatter.dateStyle = .none; formatter.timeStyle = .short
            case .date: formatter.dateStyle = .medium; formatter.timeStyle = .none
            case .dateTime: formatter.dateStyle = .medium; formatter.timeStyle = .short
            case .dayMonth: formatter.setLocalizedDateFormatFromTemplate("MMMd")
            case .weekday: formatter.setLocalizedDateFormatFromTemplate("EEE")
            case .weekdayLong: formatter.setLocalizedDateFormatFromTemplate("EEEE")
            case .weekdayDayMonth: formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
            case .fullDate: formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
            case .hour: formatter.setLocalizedDateFormatFromTemplate("j")
            case .hourMinute: formatter.setLocalizedDateFormatFromTemplate("jmm")
            }
        }
    }
}
