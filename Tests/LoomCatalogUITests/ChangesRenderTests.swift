import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCatalogUITestRigs

/// V20: the Changes tab drawn offscreen (a view that is never put in a window). The states it shows are checked by their
/// words; with `LOOM_V20_SNAPSHOTS` set to a folder the same views are saved there as PNGs, one per state and look.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ChangesRenderTests {
    private func hunks() -> [DiffHunk] {
        [DiffHunk(oldStart: 42, oldLines: 4, newStart: 42, newLines: 8, lines: [
            "     def rotate(self, token: str) -> TokenPair:", "         record = self._find_active(token)",
            "-        return self._issue(record.user_id)", "+        if record.revoked_at is not None:",
            "+            self._revoke_family(record.family_id)", "+            raise TokenReuseError(record.family_id)",
            "+        with self.db.transaction():", "+            expires = now() + timedelta(days=30)",
            "+        return self._issue(record.user_id, family_id=record.family_id)", " "]),
         DiffHunk(oldStart: 80, oldLines: 2, newStart: 84, newLines: 2, lines: [" tail", "-old end", "+new end"])]
    }

    private func edits(_ paths: [String]) -> EditScanResult {
        EditScanResult(files: paths.map { path in
            EditedFile(path: path, edits: [EditRecord(toolName: "Edit", toolUseID: "t", timestamp: nil, path: path, hunks: hunks(), isCreate: false)])
        }, truncated: true, bytesCovered: 1)
    }

    private func render(_ model: CatalogModel, _ row: SessionRowModel, dark: Bool, height: CGFloat = 900) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: ChangesTab(model: model, row: row)
            .frame(width: LoomTheme.Rhythm.inspectorWidthReview, height: height)
            .background(LoomTheme.Surface.inspector))
        host.frame = NSRect(x: 0, y: 0, width: LoomTheme.Rhythm.inspectorWidthReview, height: height)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func save(_ rep: NSBitmapImageRep?, _ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["LOOM_V20_SNAPSHOTS"], let rep,
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }

    @Test func theTabDrawsItsStatesInBothLooks() async throws {
        let rig = try await InspectorRig.make()
        defer { rig.cleanup() }
        let model = rig.model
        let id = rig.ids[0]
        model.select(id)
        let row = try #require(model.selectedRow)
        let session = model.changes.session(for: id)
        func filesOf(_ result: EditScanResult) -> [ChangesFile] {
            result.files.map { ChangesFile(id: $0.path, displayPath: $0.path, absolutePath: $0.path, added: $0.added, removed: $0.removed) }
        }
        let result = edits(["src/auth/token_service.py", "src/auth/middleware.py", "tests/test_rotation.py"])
        var hunksByFile: [String: [DiffHunk]] = [:]
        for file in result.files { hunksByFile[file.path] = file.hunks }

        // A turn scope with a file open, one comment saved and another being written.
        session.setState(.ready(ChangesScopeData(files: filesOf(result), hunks: hunksByFile, truncated: true)), for: .lastTurn)
        session.select("src/auth/token_service.py", in: .lastTurn)
        session.saveComment("Use the existing REFRESH_TTL setting instead of the literal 30 days.",
                            at: ChangeAnchor(fileID: "src/auth/token_service.py", line: 46, removed: false,
                                             text: "            expires = now() + timedelta(days=30)"),
                            displayPath: "src/auth/token_service.py", in: .lastTurn)
        model.beginChangeComment(at: ChangeAnchor(fileID: "src/auth/token_service.py", line: 44, removed: true,
                                                  text: "        return self._issue(record.user_id)"), in: id)
        session.composingText = "Why was this dropped?"
        for dark in [true, false] {
            let rep = try #require(render(model, row, dark: dark))
            try save(rep, "turn-\(dark ? "dark" : "light")")
            #expect(rep.pixelsWide > 0 && rep.colorAt(x: 40, y: 400) != nil)
        }

        // The other states.
        session.setState(.off("Not a Git repository"), for: .branch)
        session.setState(.timedOut, for: .wholeSession)
        model.setChangesScope(.branch, for: id)
        try save(try #require(render(model, row, dark: true, height: 300)), "state-off")
        #expect(session.currentState == .off("Not a Git repository"))
        model.setChangesScope(.wholeSession, for: id)
        try save(try #require(render(model, row, dark: true, height: 300)), "state-timed-out")
        #expect(session.currentState == .timedOut)
    }
}
