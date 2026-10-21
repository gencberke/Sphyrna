import Foundation
import Testing
@testable import LoomRemora

/// L2b: `Remora.md`, "Remember …" without a call, and the stale system prompt files.
struct RemoraDurableNoteTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remora-note-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func note(at url: URL) -> RemoraDurableNote {
        let zone = TimeZone(identifier: "Europe/Istanbul")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        return RemoraDurableNote(url: url, timeZone: zone, clock: { now })
    }

    private func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? -1 }

    @Test func aMissingFileIsCreatedWithRemorasHeadingsOnTheFirstSave() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sub/Remora.md")
        let note = note(at: url)
        #expect(await note.text().isEmpty)
        #expect(await note.exists == false)
        try await note.remember("The EDD release is on Friday 24 Oct.", project: "edd")
        let text = try String(contentsOf: url, encoding: .utf8)
        for heading in ["## Who I am", "## How you want answers", "## Remembered"] { #expect(text.contains(heading + "\n")) }
        #expect(text.hasSuffix("## Remembered\n- 2026-10-21 \u{00B7} edd \u{00B7} The EDD release is on Friday 24 Oct.\n"))
        #expect(mode(url) == 0o600 && mode(url.deletingLastPathComponent()) == 0o700)
        #expect(await note.alreadyRemembers("the edd release is on friday 24 oct."))
        #expect(await !note.alreadyRemembers("something else"))
    }

    @Test func rememberAndUndoTouchOnlyTheirOwnLineAndForeignTextStaysByteIdentical() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Remora.md")
        let foreign = "---\ntype: agent\nupdated: 2026-10-18\n---\n\n# Remora\r\nMy own preface with trailing spaces   \n\n## Who I am\n- I am what I am\n\n"
            + "## Remembered\n- 2026-10-18 \u{00B7} edd \u{00B7} An old fact\nmy own note in the section\n\n\n## Later\nUser text after, no final newline"
        try foreign.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let note = note(at: url)

        let first = try await note.remember("A new fact")
        let second = try await note.remember("Another fact", project: "Loom \u{00B7} dev")
        let both = try String(contentsOf: url, encoding: .utf8)
        #expect(both == foreign.replacingOccurrences(
            of: "my own note in the section\n",
            with: "my own note in the section\n- 2026-10-21 \u{00B7} A new fact\n- 2026-10-21 \u{00B7} Loom - dev \u{00B7} Another fact\n"))
        #expect(mode(url) == 0o644, "a file the user owns keeps its mode")

        #expect(try await note.undo(first))
        #expect(try String(contentsOf: url, encoding: .utf8) == foreign.replacingOccurrences(
            of: "my own note in the section\n",
            with: "my own note in the section\n- 2026-10-21 \u{00B7} Loom - dev \u{00B7} Another fact\n"))
        #expect(try await !note.undo(first), "spent")
        #expect(try await note.undo(second))
        #expect(try String(contentsOf: url, encoding: .utf8) == foreign, "every foreign byte is back")
    }

    @Test func theSameFactTwiceUndoesOneLineAndAnEditedLineIsLeftAlone() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Remora.md")
        let note = note(at: url)
        let first = try await note.remember("Same")
        let second = try await note.remember("Same")
        #expect(try await note.undo(second))
        #expect(try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\u{00B7} Same\n").count == 2)
        // The user rewrites the line in their editor: the token no longer finds it.
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "Same", with: "Same, reworded")
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(try await !note.undo(first))
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func aFileWithoutTheHeadingGetsItAtTheEndAndTheRestIsUntouched() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Remora.md")
        try "# Mine\nonly this".write(to: url, atomically: true, encoding: .utf8)
        let note = note(at: url)
        let token = try await note.remember("Fact")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("# Mine\nonly this\n"))
        #expect(text.hasSuffix("## Remembered\n- 2026-10-21 \u{00B7} Fact\n"))
        #expect(try await note.undo(token))
        #expect(try String(contentsOf: url, encoding: .utf8).hasPrefix("# Mine\nonly this\n"))
    }

    @Test func aSavePastEightKilobytesIsRefusedWithAReasonAndNothingChanges() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Remora.md")
        let note = note(at: url)
        var tokens: [RemoraUndoToken] = []
        var count = 0
        var refusal: RemoraDurableNote.Refusal?
        while refusal == nil, count < 200 {
            do { tokens.append(try await note.remember("Fact number \(count) " + String(repeating: "x", count: 400))) } catch let error as RemoraDurableNote.Refusal { refusal = error }
            count += 1
        }
        let size = try Data(contentsOf: url).count
        guard case let .tooLarge(limit, wouldBe)? = refusal else { Issue.record("no refusal: \(String(describing: refusal))"); return }
        #expect(limit == 8_000 && wouldBe > 8_000 && size <= 8_000)
        #expect(refusal?.reason.contains("8000") == true)
        let before = try Data(contentsOf: url)
        _ = try? await note.remember(String(repeating: "z", count: 480))
        #expect(try Data(contentsOf: url) == before, "never a silent cut")
        // Room again after an undo.
        #expect(try await note.undo(try #require(tokens.last)))
        _ = try await note.remember("short")
        #expect(try Data(contentsOf: url).count <= 8_000)

        await #expect(throws: RemoraDurableNote.Refusal.emptyFact) { try await note.remember("   \n ") }
        await #expect(throws: RemoraDurableNote.Refusal.factTooLong(limit: 500)) { try await note.remember(String(repeating: "y", count: 501)) }
    }

    @Test func aFileThatIsNotTextIsLeftAlone() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Remora.md")
        let bytes = Data([0xFF, 0xFE, 0x00, 0xC3, 0x28])
        try bytes.write(to: url)
        await #expect(throws: RemoraDurableNote.Refusal.unreadable) { try await note(at: url).remember("x") }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func aSecretInAFactIsMasked() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Remora.md")
        try await note(at: url).remember("my key is sk-abcdefghijklmnopqrstuvwxyz1234")
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("sk-abc"))
    }

    // MARK: "Remember …"

    @Test func aQuestionThatStartsWithRememberIsAnOrderAndOthersAreNot() {
        let table: [(String, String?)] = [
            ("Remember the release is on Friday", "the release is on Friday"),
            ("  remember: the EDD release is Friday 24 Oct.  ", "the EDD release is Friday 24 Oct."),
            ("REMEMBER that I prefer short answers", "I prefer short answers"),
            ("Remember,\nuse pnpm", "use pnpm"),
            ("Hatırla: yayın cuma günü", "yayın cuma günü"),
            ("hatirla yayin cuma", "yayin cuma"),
            ("Remember when we fixed the importer?", nil),
            ("Remember", nil),
            ("Remember:  ", nil),
            ("Remembering the old days", nil),
            ("Please remember this", nil),
            ("Can you remember X", nil),
            ("Neydi o iş? hatırla", nil),
            ("", nil),
        ]
        for (question, expected) in table { #expect(RemoraRemember.fact(in: question) == expected, "\(question)") }
    }

    // MARK: Stale system prompt files

    @Test func staleSystemPromptFilesGoAndNothingElseIsTouched() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let leftovers = ["system-\(UUID().uuidString).txt", "system-1.txt"]
        let keepers = ["system.txt", "system-1.md", "xsystem-1.txt", "usage.json", "Remora.md", "notes.txt"]
        for name in leftovers + keepers { try "x".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let folderNamedLikeOne = root.appendingPathComponent("system-dir.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: folderNamedLikeOne, withIntermediateDirectories: true)
        try "inside".write(to: folderNamedLikeOne.appendingPathComponent("system-in.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("run"), withIntermediateDirectories: true)
        let target = root.appendingPathComponent("notes.txt")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("system-link.txt"), withDestinationURL: target)

        #expect(RemoraCall.removeStaleSystemPrompts(in: root) == 2)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(names == Set(keepers + ["system-dir.txt", "run", "system-link.txt"]))
        #expect(FileManager.default.fileExists(atPath: folderNamedLikeOne.appendingPathComponent("system-in.txt").path))
        #expect(RemoraCall.removeStaleSystemPrompts(in: root) == 0, "idempotent")
        #expect(RemoraCall.removeStaleSystemPrompts(in: root.appendingPathComponent("missing")) == 0)
    }
}
