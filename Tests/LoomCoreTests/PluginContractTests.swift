import Foundation
import Testing
@testable import LoomCore

/// G1 of the cost-and-context rule (goal 3 of D-83): what Sphyrna's plugin puts into an agent's context is small and does not
/// grow without a test failing. Claude lists a skill's `description` in every session Sphyrna starts; the skill's body is read
/// only when the agent uses the skill, and the style's body only while the session is in Ask.
@Suite struct PluginContractTests {
    private func installed() throws -> (root: URL, files: [String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-plugin-contract-\(UUID())", isDirectory: true)
        try ClaudeLoomPlugin.install(in: root)
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []))
        var files: [String] = []
        let base = root.resolvingSymlinksInPath().path
        for case let url as URL in enumerator {
            if (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                files.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
            }
        }
        return (root, files.sorted())
    }

    /// The frontmatter fields (one line each) and the body of a Markdown file with a `---` header.
    private func parse(_ text: String) throws -> (fields: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        #expect(lines.first == "---")
        let close = try #require(lines.dropFirst().firstIndex(of: "---"))
        var fields: [String: String] = [:]
        for line in lines[1..<close] {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return (fields, lines[(close + 1)...].joined(separator: "\n"))
    }

    @Test func thePluginIsTheManifestOneSkillAndTheAskStyleAndNothingElse() throws {
        let (root, files) = try installed()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(files == [".claude-plugin/plugin.json", "output-styles/ask.md", "skills/open-session/SKILL.md"], "\(files)")
        // Nothing that would register an agent, a command, a hook, an MCP server or settings for the session.
        for forbidden in ["agents", "commands", "hooks", ".mcp.json", "settings.json"] {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(forbidden).path), "\(forbidden)")
            #expect(!files.contains { $0.split(separator: "/").contains(Substring(forbidden)) }, "\(forbidden)")
        }
        let manifest = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(".claude-plugin/plugin.json"))) as? [String: Any])
        #expect(Set(manifest.keys).isSubset(of: ["name", "version", "description", "author"]), "\(manifest.keys.sorted())")
        #expect(manifest["name"] as? String == "loom")
    }

    @Test func theSkillAndTheStyleStayWithinTheirBudgets() throws {
        let (root, _) = try installed()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try parse(String(contentsOf: root.appendingPathComponent("skills/open-session/SKILL.md"), encoding: .utf8))
        #expect(skill.fields["name"] == "open-session")
        // Today's text, character for character: a change to what every session lists is a decision, and changes this line.
        // It says first where the session runs (C5c, D-85), then what Sphyrna can do and when to use it.
        let description = "This session runs inside Sphyrna, the desktop app that hosts it. Sphyrna can list the user's other "
            + "sessions (read-only, no content) and open a new top-level Claude session with a first message the user approves. "
            + "Use it to find a session, or when work should go on in its own session."
        #expect(skill.fields["description"] == description)
        #expect(description.count <= 300, "the description is in every session's context: \(description.count) characters")
        #expect(skill.body.count <= 1_500, "the skill's body: \(skill.body.count) characters")
        // One skill, both verbs, named in the app's name; the manifest says Sphyrna too.
        #expect(description.hasPrefix("This session runs inside Sphyrna") && !description.contains("Loom"))
        #expect(skill.body.contains("\"$LOOM_CLI\" sessions") && skill.body.contains("\"$LOOM_CLI\" open"))
        #expect(skill.body.contains("no session content"))
        let manifest = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(".claude-plugin/plugin.json"))) as? [String: Any])
        #expect((manifest["description"] as? String)?.contains("Sphyrna") == true)

        let style = try parse(String(contentsOf: root.appendingPathComponent("output-styles/ask.md"), encoding: .utf8))
        #expect(style.fields["name"] == "Ask")
        #expect(style.body.count <= 500, "the Ask style's body: \(style.body.count) characters")
    }
}
