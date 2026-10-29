import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI

struct ChatWorkTests {
    @Test func theChangedFilesTreeMergesSingleChildFolders() {
        let files = [ChangedFile(path: "src/auth/login.swift", added: 4, removed: 1),
                     ChangedFile(path: "src/auth/token.swift", added: 2, removed: 0),
                     ChangedFile(path: "README.md", added: 1, removed: 0)]
        let lines = ChatWork.tree(of: files)
        #expect(lines.contains { $0.isFolder && $0.name.hasPrefix("src/auth") })
        #expect(lines.filter { !$0.isFolder }.count == 3)
        #expect(lines.reduce(0) { $0 + ($1.isFolder ? 0 : $1.added) } == 7)
    }
}
