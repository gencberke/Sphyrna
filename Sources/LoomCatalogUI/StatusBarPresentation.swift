import Foundation
import LoomCore

/// The status bar's compact, comparable snapshot of one harness's cached limits.
struct StatusBarUsage: Equatable {
    struct Window: Equatable, Identifiable {
        let id: String
        let name: String
        let remainingPercent: Int
        let reset: String?
        let spokenReset: String?
    }

    let harness: ManagedSession.Provider
    let windows: [Window]
    let partial: Bool
    var tightest: Window? { windows.min { $0.remainingPercent < $1.remainingPercent } }
    var accessibilityLabel: String {
        guard !windows.isEmpty else {
            return "\(ProviderName.title(harness)), No limits read" + (partial ? ", \(UsageHarnessText.partialWindows)" : "")
        }
        let text = ([ProviderName.title(harness)] + windows.map { window in
            let reset = window.spokenReset.map { ", resets in \($0)" } ?? ""
            return "\(window.name), \(window.remainingPercent)% left\(reset)"
        }).joined(separator: ", ")
        return text + (partial ? ", \(UsageHarnessText.partialWindows)" : "")
    }

    static func make(harness: ManagedSession.Provider, reading: HarnessReading?, now: Date) -> Self {
        let windows = reading?.currentWindows(at: now).map { window in
            Window(id: window.id, name: window.name, remainingPercent: window.remainingPercent,
                   reset: window.resetsAt.map { UsageFormat.untilReset($0, from: now) },
                   spokenReset: window.resetsAt.map { spokenDuration($0, from: now) })
        } ?? []
        return Self(harness: harness, windows: windows, partial: reading.map { !$0.windowsComplete } ?? false)
    }

    static func paceLines(reading: HarnessReading?, now: Date, timeZone: TimeZone) -> [PlanPaceLine.Content] {
        guard let reading else { return [] }
        return reading.currentWindows(at: now).map {
            PlanPaceLine.Content(window: $0, measuredAt: reading.readAt, now: now, timeZone: timeZone, relative: true)
        }
    }

    private static func spokenDuration(_ date: Date, from now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        let hours = minutes / 60
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        if hours >= 24 {
            let days = hours / 24, remainder = hours % 24
            return unit(days, "day") + (remainder == 0 ? "" : " " + unit(remainder, "hour"))
        }
        if hours > 0 {
            let remainder = minutes % 60
            return unit(hours, "hour") + (remainder == 0 ? "" : " " + unit(remainder, "minute"))
        }
        return unit(minutes, "minute")
    }
}
