import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// The launch question for a damaged catalog (H1 item 2): what it says and which buttons it has.
struct CatalogRecoveryPromptTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func backup(_ seconds: TimeInterval) -> CatalogBackupInfo {
        let date = Date(timeIntervalSince1970: seconds)
        return CatalogBackupInfo(url: URL(fileURLWithPath: "/data/backups/catalog-\(Int(seconds)).sqlite3"),
                                 createdAt: date, byteCount: 4_096)
    }

    @Test func withBackupsItOffersRestoreFirstThenStartFreshThenQuit() {
        let newest = backup(1_791_374_400), older = backup(1_791_000_000) // 7 Oct 2026 12:00 UTC, then earlier
        let prompt = CatalogRecoveryPrompt.make(backups: [newest, older], timeZone: utc)
        #expect(prompt.buttons.map(\.title) == ["Restore Backup", "Start Fresh", "Quit"])
        #expect(prompt.buttons.map(\.choice) == [.restore(newest), .startFresh, .quit])
        #expect(prompt.text.contains(CatalogRecoveryPrompt.date(newest.createdAt, utc)), "the newest backup's date, in the system locale")
        #expect(!prompt.text.contains(CatalogRecoveryPrompt.date(older.createdAt, utc)))
    }

    @Test func theDateIsWrittenInTheGivenZone() {
        let date = Date(timeIntervalSince1970: 1_791_374_400) // 2026-10-07 12:00:00 UTC
        let gb = Locale(identifier: "en_GB")
        #expect(CatalogRecoveryPrompt.date(date, utc, locale: gb).contains("12:00"))
        #expect(CatalogRecoveryPrompt.date(date, TimeZone(secondsFromGMT: 3 * 3_600)!, locale: gb).contains("15:00"))
        #expect(CatalogRecoveryPrompt.date(date, utc, locale: gb).contains("2026"))
    }

    @Test func withoutABackupThereIsNoRestoreButStartFreshAndQuit() {
        let prompt = CatalogRecoveryPrompt.make(backups: [], timeZone: utc)
        #expect(prompt.buttons.map(\.title) == ["Start Fresh", "Quit"])
        #expect(prompt.buttons.map(\.choice) == [.startFresh, .quit])
        #expect(!prompt.text.contains("Restore"))
        #expect(prompt.text.contains("no backup"))
    }

    @Test func theTextSaysWhatHappenedAndThatTheDamagedFileIsKept() {
        for backups in [[], [backup(1_791_374_400)]] {
            let prompt = CatalogRecoveryPrompt.make(backups: backups, timeZone: utc)
            #expect(prompt.title == "Loom could not open the session list")
            #expect(prompt.text.contains("damaged"))
            #expect(prompt.text.contains("keeps the damaged file next to it until a session is permanently deleted"))
            #expect(!prompt.text.lowercased().contains("conversation"))
        }
    }
}
