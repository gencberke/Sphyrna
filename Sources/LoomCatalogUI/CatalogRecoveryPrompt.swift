import Foundation
import LoomCore

/// The question asked at launch when the catalog file is damaged: what the alert says and which buttons it
/// has, given the backups that exist. The alert itself is AppKit glue in the app; nothing here shows anything.
public struct CatalogRecoveryPrompt: Equatable, Sendable {
    public enum Choice: Equatable, Sendable {
        /// Restore the newest backup.
        case restore(CatalogBackupInfo)
        /// Set the damaged file aside and begin with an empty list.
        case startFresh
        case quit
    }

    public struct Button: Equatable, Sendable {
        public let title: String
        public let choice: Choice
    }

    public let title: String
    public let text: String
    /// In the order the alert shows them; the first answers Return.
    public let buttons: [Button]

    /// - Parameters:
    ///   - backups: the catalog's backups, newest first (`CatalogRecovery.backups(forCatalogAt:)`).
    ///   - timeZone: how the backup's date is written.
    public static func make(backups: [CatalogBackupInfo], timeZone: TimeZone = .current) -> CatalogRecoveryPrompt {
        let kept = "Loom keeps the damaged file next to it until a session is permanently deleted."
        guard let newest = backups.first else {
            return CatalogRecoveryPrompt(
                title: "Loom could not open the session list",
                text: "The file that holds the session list is damaged, and no backup of it was found. \(kept) "
                    + "Start Fresh begins with an empty list; your Claude transcripts are not touched.",
                buttons: [.init(title: "Start Fresh", choice: .startFresh), .init(title: "Quit", choice: .quit)])
        }
        return CatalogRecoveryPrompt(
            title: "Loom could not open the session list",
            text: "The file that holds the session list is damaged. \(kept) "
                + "Restore Backup brings back the list as of \(date(newest.createdAt, timeZone)); sessions added after "
                + "that are missing from it. Start Fresh begins with an empty list instead. Your Claude transcripts are not touched.",
            buttons: [.init(title: "Restore Backup", choice: .restore(newest)),
                      .init(title: "Start Fresh", choice: .startFresh), .init(title: "Quit", choice: .quit)])
    }

    /// `11 Oct 2026 at 09:14`, in English like the rest of the app's copy.
    static func date(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "d MMM yyyy 'at' HH:mm"
        return formatter.string(from: date)
    }
}
