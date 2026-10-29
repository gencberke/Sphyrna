import Foundation
import LoomCore
import Testing
@testable import LoomChat
@testable import LoomChatTestRigs

/// The Changes tab's source for the turn scopes (V20): Claude's own edits, read from the end of the session's transcript.
/// Every file is made in a temporary folder and removed.
@Suite(.timeLimit(.minutes(2)))
struct EditScanTests {
    // MARK: Records

    // MARK: Tests

    @Test func theChangedFilesCardCountsFromTheStreamsToolCalls() {
        func tool(_ name: String, _ path: String, added: Int, removed: Int, _ status: ToolCall.Status = .succeeded) -> ToolCall {
            ToolCall(id: UUID().uuidString, name: name, input: ["file_path": .string(path)], status: status, output: nil, images: [],
                     exitCode: nil, changes: LineChanges(added: added, removed: removed), startedAt: nil, endedAt: nil)
        }
        let files = EditScan.changedFiles(in: [tool("Edit", "/p/src/a.swift", added: 2, removed: 1), tool("Edit", "/p/src/b.swift", added: 1, removed: 0),
                                               tool("Edit", "/p/src/a.swift", added: 3, removed: 0), tool("Read", "/p/src/c.swift", added: 0, removed: 0),
                                               tool("Edit", "/p/src/d.swift", added: 9, removed: 9, .failed)],
                                          workingDirectory: "/p")
        #expect(files == [ChangedFile(path: "src/a.swift", added: 5, removed: 1), ChangedFile(path: "src/b.swift", added: 1, removed: 0)])
    }
}
