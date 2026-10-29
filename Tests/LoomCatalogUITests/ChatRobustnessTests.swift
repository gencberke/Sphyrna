import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

extension ChatHosted {
    /// Edge cases of content that arrives from a transcript: a huge "Show all", a cut-off escape, a long line, a long detail.
    @MainActor
    struct ChatRobustnessTests {
        // MARK: Diff

        @Test func aVeryLongWriteLineIsClipped() {
            let blob = String(repeating: "a", count: 60_000)
            let lines = [ChatFixture.user("go", uuid: "u1"),
                         ChatFixture.assistant("m1", uuid: "c1", blocks: [ChatFixture.tool("w1", "Write", ["file_path": "/p/min.js", "content": .string(blob + "\nshort")])], at: 1),
                         ChatFixture.result("w1", "File created successfully", at: 2)]
            let call = ChatFixture.calls(lines)[0]
            let diff = ChatDiff.lines(for: call)
            #expect(diff.count == 2)
            #expect(diff[0].text.count == ChatDiff.maximumLineCharacters + 1)
            #expect(diff[0].text.hasSuffix("\u{2026}"))
            #expect(diff[1].text == "short")
        }
    }
}
