import Foundation
import LoomCore
import Testing
@testable import LoomCatalogUI

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ChangesCacheTests {
    private let byteLimit = 16 * 1_024 * 1_024
    private let entryLimit = 64

    private func data(_ index: Int, bytes: Int) -> ChangesScopeData {
        let path = "/fixture/file-\(index).swift"
        let file = ChangesFile(id: path, displayPath: "file-\(index).swift", absolutePath: path, added: 1, removed: 0)
        let hunk = DiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 1,
                            lines: ["+" + String(repeating: "x", count: bytes)])
        return ChangesScopeData(files: [file], hunks: [path: [hunk]])
    }

    @Test func oldScopePayloadsAreBoundedWhileDraftsAndTheOpenCommentSurvive() throws {
        let cache = ChangesState()
        var ids: [UUID] = []
        let anchor = ChangeAnchor(fileID: "/fixture/file-0.swift", line: 1, removed: false, text: "line")
        for index in 0..<128 {
            let id = UUID()
            ids.append(id)
            let session = cache.session(for: id)
            session.setState(.ready(data(index, bytes: 256 * 1_024)), for: .lastTurn)
            if index == 0 {
                session.select(anchor.fileID, in: .lastTurn)
                session.saveComment("Saved comment", at: anchor, displayPath: "file-0.swift", in: .lastTurn)
                session.composing = anchor
                session.composingText = "Unsent text"
                session.sendStatus = .failed("Try again")
            }
        }
        let retained = ids.compactMap { cache.existing($0)?.state(.lastTurn).data }
        let bytes = retained.flatMap { $0.hunks.values }.flatMap { $0 }.flatMap(\.lines).reduce(0) { $0 + $1.utf8.count }
        #expect(retained.count <= entryLimit)
        #expect(bytes <= byteLimit)
        let first = try #require(cache.existing(ids[0]))
        #expect(first.state(.lastTurn) == .idle)
        #expect(first.selected[.lastTurn] == anchor.fileID)
        #expect(first.comments(in: .lastTurn).map(\.text) == ["Saved comment"])
        #expect(first.composing == anchor && first.composingText == "Unsent text" && first.sendStatus == .failed("Try again"))
        #expect(cache.existing(ids[127])?.state(.lastTurn).data != nil)
    }

    @Test func branchDiffPayloadsAreBoundedIndependentlyOfTheUsersComment() throws {
        let cache = ChangesState()
        let session = cache.session(for: UUID())
        session.scope = .branch
        session.setState(.ready(ChangesScopeData(files: [])), for: .branch)
        let anchor = ChangeAnchor(fileID: "file-0.swift", line: 1, removed: false, text: "line")
        session.saveComment("Keep this", at: anchor, displayPath: anchor.fileID, in: .branch)
        session.composing = anchor
        session.composingText = "Still editing"
        for index in 0..<128 {
            let file = "file-\(index).swift"
            let hunk = DiffHunk(oldStart: 1, oldLines: 0, newStart: 1, newLines: 1,
                                lines: ["+" + String(repeating: "x", count: 256 * 1_024)])
            session.select(file, in: .branch)
            session.setGitDiff(.hunks([hunk]), for: file)
        }
        let retained = session.gitDiffs.values.compactMap { diff -> [DiffHunk]? in
            if case let .hunks(hunks) = diff { return hunks }
            return nil
        }
        let bytes = retained.flatMap { $0 }.flatMap(\.lines).reduce(0) { $0 + $1.utf8.count }
        #expect(retained.count <= entryLimit && bytes <= byteLimit)
        #expect(session.gitDiffs["file-0.swift"] == nil && session.gitDiffs["file-127.swift"] != nil)
        #expect(session.selected[.branch] == "file-127.swift")
        #expect(session.comments(in: .branch).map(\.text) == ["Keep this"])
        #expect(session.composing == anchor && session.composingText == "Still editing")
    }

    @Test func oneOversizedScopeIsReportedWithoutKeepingItsPayloadOrDiscardingDrafts() {
        let cache = ChangesState()
        let session = cache.session(for: UUID())
        let anchor = ChangeAnchor(fileID: "/fixture/file-0.swift", line: 1, removed: false, text: "line")
        session.saveComment("Keep this", at: anchor, displayPath: "file-0.swift", in: .lastTurn)
        session.composing = anchor
        session.composingText = "Still editing"
        session.setState(.ready(data(0, bytes: byteLimit + 1)), for: .lastTurn)
        if case let .failed(reason) = session.state(.lastTurn) {
            #expect(reason.contains("too large"))
        } else {
            Issue.record("An oversized scope must show a bounded failure instead of retaining its payload")
        }
        #expect(session.comments(in: .lastTurn).map(\.text) == ["Keep this"])
        #expect(session.composing == anchor && session.composingText == "Still editing")
    }
}
