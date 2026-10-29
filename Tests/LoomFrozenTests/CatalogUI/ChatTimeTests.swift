import Foundation
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

struct ChatTimeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func durationsReadShort() {
        #expect(ChatTime.duration(seconds: 0.2) == "0s")
        #expect(ChatTime.duration(seconds: 12) == "12s")
        #expect(ChatTime.duration(seconds: 252) == "4m 12s")
        #expect(ChatTime.duration(seconds: 3900) == "1h 5m")
        #expect(ChatTime.duration(milliseconds: -5) == "0s")
    }

    @Test func theClockKeepsTwoDigitSeconds() {
        #expect(ChatTime.clock(seconds: 42) == "42s")
        #expect(ChatTime.clock(seconds: 185) == "3m 05s")
        #expect(ChatTime.clock(seconds: 3720) == "1h 02m")
    }

    @Test func messageTimesFollowTheDay() {
        let locale = Locale(identifier: "en_US_POSIX")
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15, minute: 0))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9, minute: 5))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 9, minute: 5))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9, minute: 5))!
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 8, day: 3, hour: 9, minute: 5))!
        let todayLabel = ChatTime.label(for: today, now: now, calendar: calendar, locale: locale)
        #expect(!todayLabel.contains("yesterday") && !todayLabel.contains("Oct"))
        #expect(ChatTime.label(for: yesterday, now: now, calendar: calendar, locale: locale).hasPrefix("yesterday at "))
        let earlierLabel = ChatTime.label(for: earlier, now: now, calendar: calendar, locale: locale)
        #expect(earlierLabel.contains("Aug") && !earlierLabel.contains("2026"))
        #expect(ChatTime.label(for: lastYear, now: now, calendar: calendar, locale: locale).contains("2025"))
    }

    @Test func gapsReadInTheLargestSensibleUnit() {
        #expect(ChatTime.gap(seconds: 20) == "a moment")
        #expect(ChatTime.gap(seconds: 60) == "1 minute")
        #expect(ChatTime.gap(seconds: 3 * 3600) == "3 hours")
        #expect(ChatTime.gap(seconds: 4 * 86400) == "4 days")
    }
}
