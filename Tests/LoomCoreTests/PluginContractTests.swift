import Foundation
import Testing
@testable import LoomCore

/// G1 of the cost-and-context rule (goal 3 of D-83): what Sphyrna's plugin puts into an agent's context is small and does not
/// grow without a test failing. Claude lists a skill's `description` in every session Sphyrna starts; the skill's body is read
/// only when the agent uses the skill, and the style's body only while the session is in Ask.
@Suite struct PluginContractTests {
    @Test func terminalTaskDiscoveryIsSmallAndExplainsHowAChildYields() throws {
        let (root, _) = try installed()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try parse(String(contentsOf: root.appendingPathComponent("skills/open-session/SKILL.md"), encoding: .utf8))
        #expect(skill.fields["description"]?.contains("delegate") == true)
        #expect(skill.body.contains("\"$SPHYRNA_CLI\" task --help"))
        #expect(skill.body.contains("needsParentInput") && skill.body.contains("finish the current turn"))
        #expect(skill.body.contains("Take Over ends parent automation"))
        #expect(skill.body.contains("nested managed parent must wait/read"))
        #expect(skill.body.count <= 1_500)
    }
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
        #expect(manifest["name"] as? String == "sphyrna")
    }

    @Test func theSkillAndTheStyleStayWithinTheirBudgets() throws {
        let (root, _) = try installed()
        defer { try? FileManager.default.removeItem(at: root) }
        let skill = try parse(String(contentsOf: root.appendingPathComponent("skills/open-session/SKILL.md"), encoding: .utf8))
        #expect(skill.fields["name"] == "open-session")
        // Today's text, character for character: a change to what every session lists is a decision, and changes this line.
        // It says first where the session runs (C5c, D-85), then what Sphyrna can do and when to use it.
        let description = "This session runs inside Sphyrna. List or open sessions, send approved messages, "
            + "or delegate work to a reusable managed child agent."
        #expect(skill.fields["description"] == description)
        #expect(description.count <= 300, "the description is in every session's context: \(description.count) characters")
        #expect(skill.body.count <= 1_500, "the skill's body: \(skill.body.count) characters")
        // One skill, both verbs, named in the app's name; the manifest says Sphyrna too.
        #expect(description.hasPrefix("This session runs inside Sphyrna") && !description.contains("Loom"))
        #expect(skill.body.contains("\"$SPHYRNA_CLI\" sessions") && skill.body.contains("\"$SPHYRNA_CLI\" open"))
        #expect(skill.body.contains("no session content"))
        let manifest = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(".claude-plugin/plugin.json"))) as? [String: Any])
        #expect((manifest["description"] as? String)?.contains("Sphyrna") == true)

        let style = try parse(String(contentsOf: root.appendingPathComponent("output-styles/ask.md"), encoding: .utf8))
        #expect(style.fields["name"] == "Ask")
        #expect(style.body.count <= 500, "the Ask style's body: \(style.body.count) characters")
    }
}
