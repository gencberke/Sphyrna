import Foundation

/// A local calendar day and the ISO week it belongs to: the names of the journal's files, in the store's time zone.
struct RemoraDay: Hashable, Comparable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// `YYYY-MM-DD`.
    init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var string: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (left: Self, right: Self) -> Bool { left.string < right.string }

    func start(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    /// Whole days from `earlier` to this day.
    func days(since earlier: Self, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: earlier.start(in: calendar), to: start(in: calendar)).day ?? 0
    }

    /// `17 Oct`, the way an item says its date.
    var short: String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(day) \(months[min(max(month, 1), 12) - 1])"
    }
}

/// An ISO week (Monday first): `YYYY-Www`.
struct RemoraWeek: Hashable, Sendable {
    var year: Int
    var week: Int

    init(year: Int, week: Int) {
        self.year = year
        self.week = week
    }

    init(of day: RemoraDay, calendar: Calendar) {
        let iso = Self.isoCalendar(calendar)
        let parts = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day.start(in: iso))
        self.init(year: parts.yearForWeekOfYear ?? day.year, week: parts.weekOfYear ?? 1)
    }

    /// `YYYY-Www`.
    init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 3, parts[1].first == "W",
              let year = Int(parts[0]), let week = Int(parts[1].dropFirst()), (1...53).contains(week) else { return nil }
        self.init(year: year, week: week)
    }

    var string: String { String(format: "%04d-W%02d", year, week) }

    /// The Monday that starts the week, as a day.
    func firstDay(calendar: Calendar) -> RemoraDay {
        let iso = Self.isoCalendar(calendar)
        let monday = iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)) ?? .distantPast
        return RemoraDay(monday, calendar: iso)
    }

    private static func isoCalendar(_ calendar: Calendar) -> Calendar {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        return iso
    }
}
