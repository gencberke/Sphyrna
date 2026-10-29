import Foundation
import OSLog
@testable import LoomCore
import LoomTestSupport

/// Reads this test process's own unified-log entries back (`OSLogStore(scope: .currentProcessIdentifier)`): what a
/// diagnostics export would see of the subsystem. Entries can reach the store a moment after the call, so it polls.
enum LogReadBack {
    struct Line: Sendable {
        let level: OSLogEntryLog.Level
        let message: String
    }

    /// The subsystem's lines in `category` since `date` that contain `marker`, once `enough` says they are all there (or
    /// after `seconds`).
    static func lines(category: LoomLogCategory, since date: Date, containing marker: String, seconds: Double = 10,
                      enough: ([Line]) -> Bool = { !$0.isEmpty }) async throws -> [Line] {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let found = try read(category: category, since: date).filter { $0.message.contains(marker) }
            if enough(found) || Date() >= deadline { return found }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func read(category: LoomLogCategory, since date: Date) throws -> [Line] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", LoomSignposts.subsystem, category.rawValue)
        return try store.getEntries(at: store.position(date: date.addingTimeInterval(-1)), matching: predicate)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= date.addingTimeInterval(-1) }
            .map { Line(level: $0.level, message: $0.composedMessage) }
    }
}
