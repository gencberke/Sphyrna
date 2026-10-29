import Darwin
import Foundation
import Testing
@testable import LoomCore

/// What a Codex deletion finds in a Codex home (D-121), on synthetic temporary homes: the target's rollouts wherever Codex
/// keeps them, the index records parsed by their own id, the two entries kept by decision, and a home it must not trust.
struct CodexDataInventoryTests {
    private static func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("loom-codex-inv-\(UUID().uuidString)",
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return home
    }

    private static func write(_ text: String, _ relative: String, in home: URL) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(text.utf8).write(to: url)
    }

    @Test func theNativeIDsAreTheProviderUUIDsOtherThanTheLoomID() {
        let loom = UUID()
        let native = UUID().uuidString
        #expect(CodexDataInventory.nativeIDs(of: [loom.uuidString, native, native.lowercased(), "not-a-uuid"], sessionID: loom)
            == [native.lowercased()])
    }

    @Test func aRolloutNameCarriesItsIDOnlyAsCodexWritesIt() {
        let id = UUID().uuidString.lowercased()
        #expect(CodexDataInventory.rolloutID("rollout-2026-10-30T00-00-00-\(id).jsonl") == id)
        #expect(CodexDataInventory.rolloutID("rollout-2026-10-30T00-00-00-\(id.uppercased()).jsonl.zst") == id)
        #expect(CodexDataInventory.rolloutID("rollout-\(id).jsonl.tmp") == nil)
        #expect(CodexDataInventory.rolloutID("other-2026-\(id).jsonl") == nil)
        #expect(CodexDataInventory.rolloutID("rollout-2026x\(id).jsonl") == nil)
    }

    @Test func theScanFindsOnlyTheTargetsRolloutsAndIndexRecordsAndNamesWhatIsKept() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        try Self.write("plain", "sessions/2026/10/30/rollout-2026-10-30T00-00-00-\(target).jsonl", in: home)
        try Self.write("zst", "sessions/2026/09/01/rollout-2026-09-01T00-00-00-\(target).jsonl.zst", in: home)
        try Self.write("archived", "archived_sessions/rollout-2026-08-01T00-00-00-\(target).jsonl", in: home)
        try Self.write("other", "sessions/2026/10/30/rollout-2026-10-30T00-00-01-\(other).jsonl", in: home)
        try Self.write("""
            {"id":"\(target)","thread_name":"a","updated_at":"x"}
            {"id":"\(other)","thread_name":"mentions \(target)","updated_at":"x"}
            not json \(target)
            {"id":"\(target.uppercased())","thread_name":"b","updated_at":"x"}

            """, "session_index.jsonl", in: home)
        try Self.write("{\"session_id\":\"\(target)\",\"ts\":1,\"text\":\"t\"}\n", "history.jsonl", in: home)
        try Self.write("", "tui-thread-reference-capabilities/\(target)", in: home)

        let scan = try CodexDataInventory.scan(nativeIDs: [target], home: home)
        #expect(scan.rollouts.map(\.relativePath) == [
            "archived_sessions/rollout-2026-08-01T00-00-00-\(target).jsonl",
            "sessions/2026/09/01/rollout-2026-09-01T00-00-00-\(target).jsonl.zst",
            "sessions/2026/10/30/rollout-2026-10-30T00-00-00-\(target).jsonl",
        ])
        #expect(scan.rollouts.map(\.bytes).reduce(0, +) == Int64("plain".utf8.count + "zst".utf8.count + "archived".utf8.count))
        #expect(scan.indexRecords == 2, "parsed ids only: the mention and the malformed line do not count")
        #expect(scan.kept == ["history.jsonl", "tui-thread-reference-capabilities/\(target)"])
        #expect(!scan.isClear)

        let control = try CodexDataInventory.scan(nativeIDs: [other], home: home)
        #expect(control.rollouts.count == 1 && control.indexRecords == 1)
        #expect(control.kept == ["history.jsonl"])
    }

    @Test func aLinkedSessionsFolderOrAWritableHomeIsNotTrusted() throws {
        let home = try Self.makeHome()
        let elsewhere = try Self.makeHome()
        defer { [home, elsewhere].forEach { try? FileManager.default.removeItem(at: $0) } }
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("sessions"), withDestinationURL: elsewhere)
        #expect(throws: CodexDataError.unsafeHome) {
            _ = try CodexDataInventory.scan(nativeIDs: [UUID().uuidString], home: home)
        }
        try FileManager.default.removeItem(at: home.appendingPathComponent("sessions"))
        chmod(home.path, 0o777)
        #expect(throws: CodexDataError.unsafeHome) {
            _ = try CodexDataInventory.scan(nativeIDs: [UUID().uuidString], home: home)
        }
    }

    @Test func onlyCodexsOwnAnswersAboutThisIDMeanTheThreadIsGone() {
        let id = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        func rpc(_ message: String) -> CodexAppServerError { .rpc(code: -32600, message: message, data: nil) }
        // The answers Codex 0.164 gave in the real deletion (REAL.md), and the fake server's.
        for message in ["thread not loaded: \(id)", "no rollout found for thread id \(id)", "thread not found: \(id.uppercased())"] {
            #expect(CodexAppServerClient.isAbsentThreadAnswer(rpc(message), threadID: id), "\(message)")
        }
        for error: any Error in [rpc("thread not loaded: \(other)"), rpc("failed to delete thread: rollout not found"),
                                 rpc("thread \(id) already has an active writer"), CodexAppServerError.closed,
                                 CodexAppServerError.timeout("thread/read")] {
            #expect(!CodexAppServerClient.isAbsentThreadAnswer(error, threadID: id), "\(error)")
        }
    }

    @Test func aWalkThatRunsOutOfItsBudgetIsIncompleteNotEmpty() throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for day in 1...5 { try Self.write("x", "sessions/2026/10/0\(day)/rollout-a-\(UUID().uuidString).jsonl", in: home) }
        #expect(throws: CodexDataError.incomplete) {
            _ = try CodexDataInventory.scan(nativeIDs: [UUID().uuidString], home: home, maximumEntries: 3)
        }
    }
}
