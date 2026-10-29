import Foundation
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

struct ChatWorkTests {
    private func call(_ name: String, _ input: JSONValue, output: String = "ok") -> ToolCall {
        let lines = [ChatFixture.user("go", uuid: "u"),
                     ChatFixture.assistant("m", uuid: "c", blocks: [ChatFixture.tool("t", name, input)], at: 1),
                     ChatFixture.result("t", output, at: 2)]
        return ChatFixture.calls(lines)[0]
    }

    @Test func labelsNameWhatEachToolDid() {
        let read = ChatWork.label(for: call("Read", ["file_path": "/p/a.swift"]), workingDirectory: "/p")
        #expect(ChatWork.sentence(read, running: false) == "Read a.swift")
        #expect(ChatWork.sentence(read, running: true) == "Reading a.swift")
        let bash = ChatWork.label(for: call("Bash", ["command": "swift build\nsecond line"]), workingDirectory: nil)
        #expect(ChatWork.sentence(bash, running: false) == "Ran swift build")
        let grep = ChatWork.label(for: call("Grep", ["pattern": "foo", "path": "/p/src"]), workingDirectory: "/p")
        #expect(grep.subject == "\u{201C}foo\u{201D} in src")
        let mcp = ChatWork.label(for: call("mcp__github__list_issues", [:]), workingDirectory: nil)
        #expect(mcp.subject == "github \u{00B7} list_issues")
        #expect(mcp.kind == .other)
    }

    @Test func aWriteThatCreatedAFileSaysCreated() {
        let created = call("Write", ["file_path": "/p/a", "content": "x"], output: "File created successfully at: /p/a")
        #expect(ChatWork.label(for: created, workingDirectory: nil).verb == "Created")
        let updated = call("Write", ["file_path": "/p/a", "content": "x"], output: "The file /p/a has been updated.")
        #expect(ChatWork.label(for: updated, workingDirectory: nil).verb == "Edited")
    }

    @Test func pathsAreShownRelativeToTheWorkingFolderThenHome() {
        #expect(ChatWork.shorten("/proj/src/a.swift", workingDirectory: "/proj") == "src/a.swift")
        #expect(ChatWork.shorten("/proj/src/a.swift", workingDirectory: "/proj/") == "src/a.swift")
        #expect(ChatWork.shorten("/projects/a", workingDirectory: "/proj") == "/projects/a")
        #expect(ChatWork.shorten(NSHomeDirectory() + "/x/y", workingDirectory: nil) == "~/x/y")
    }

    @Test func theSummaryNamesTheTwoBestKindsAndCountsTheRest() {
        var calls: [ToolCall] = []
        for index in 0..<3 { calls.append(call("Edit", ["file_path": .string("/p/f\(index)")])) }
        for _ in 0..<2 { calls.append(call("Bash", ["command": "ls"])) }
        for _ in 0..<4 { calls.append(call("Read", ["file_path": "/p/r"])) }
        #expect(ChatWork.summary(of: calls) == "Changed 3 files, ran 2 commands and 4 other actions")
        #expect(ChatWork.summary(of: calls, capitalized: false).hasPrefix("changed 3 files"))
    }

    /// Ask refused the call: nothing was changed or run, so the summary says so instead of "changed 1 file".
    @Test func aCallAskRefusedIsNotCountedAsWorkAndIsSaidOnce() {
        var refused = call("Write", ["file_path": "/p/a", "content": "x"], output: "Permission to use Write has been denied.")
        refused.status = .refusedInAsk
        #expect(ChatWork.summary(of: [refused]) == "Worked \u{00B7} 1 refused in Ask")
        #expect(ChatWork.summary(of: [refused], capitalized: false) == "1 refused in Ask")
        let read = call("Read", ["file_path": "/p/r"])
        #expect(ChatWork.summary(of: [read, refused]) == "Read 1 file \u{00B7} 1 refused in Ask")
        #expect(ChatWork.summary(of: [read]) == "Read 1 file")
    }

    @Test func markersNameModesInLoomsWordsAndDontAskIsAsk() {
        #expect(ChatMarkerText.text(.modeChanged("dontAsk")) == "Mode changed to Ask")
        #expect(ChatMarkerText.text(.modeChanged("default")) == "Mode changed to Ask before edits")
        #expect(ChatMarkerText.text(.modeChanged("bypassPermissions")) == "Mode changed to Full access")
        #expect(ChatMarkerText.text(.sessionStart(model: "Opus 5.5", permissionMode: "default")) == "Session started \u{00B7} Opus 5.5 \u{00B7} Ask before edits")
    }

    @Test func editsToOneFileCountAsOneFile() {
        let calls = [call("Edit", ["file_path": "/p/a"]), call("Edit", ["file_path": "/p/a"]), call("Bash", ["command": "x"])]
        #expect(ChatWork.summary(of: calls) == "Changed 1 file and ran 1 command")
    }

    @Test func aSingleKindReadsAsOnePhraseAndAgentsCount() {
        #expect(ChatWork.summary(of: [call("Read", ["file_path": "/a"]), call("Read", ["file_path": "/b"])]) == "Read 2 files")
        #expect(ChatWork.summary(of: [], agents: 2) == "Ran 2 agents")
        #expect(ChatWork.summary(of: [], thinkingOnly: true) == "Thought")
        #expect(ChatWork.summary(of: []) == "Worked")
    }

    @Test func markdownIsStrippedForOneLinePreviews() {
        #expect(ChatWork.stripMarkdown("**Bold** and `code`") == "Bold and code")
    }
}
