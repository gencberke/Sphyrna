import Foundation
import Testing
@testable import LoomCore

@Suite struct OpenCodeTUIPolicyTests {
    private let plugin = "/private/tmp/app-owned/plugin"
    private func config(_ text: String) -> Data { Data(text.utf8) }

    @Test func orderedNativeDocumentsDoNotLetAnInlineCarrierOverrideNegatives() {
        let safe = config(#"[{"type":"document","path":"/config/global","info":{"plugins":["other.plugin",{"package":"other.package","options":{"value":1}}]}},{"type":"document","info":{"plugins":["/private/tmp/app-owned/plugin","-unrelated"]}}]"#)
        #expect(OpenCodeTUIPolicy.permits(config: safe, pluginDirectory: plugin))
        for negative in ["-*", "-sphyrna.*", "-sphyrna.native-selection"] {
            let text = #"[{"type":"document","path":"/config/global","info":{"plugins":["NEG"]}},{"type":"document","info":{"plugins":["/private/tmp/app-owned/plugin"]}}]"#.replacingOccurrences(of: "NEG", with: negative)
            #expect(!OpenCodeTUIPolicy.permits(config: config(text), pluginDirectory: plugin))
        }
    }

    @Test func unavailableOrDenyingPolicyNeverAuthorizesObserver() {
        let denied = config(#"[{"type":"document","info":{"plugins":["/private/tmp/app-owned/plugin"],"policies":[{"action":"integration.use","resource":"plugin:*","effect":"deny"}]}}]"#)
        #expect(!OpenCodeTUIPolicy.permits(config: denied, pluginDirectory: plugin))
        #expect(!OpenCodeTUIPolicy.permits(config: config("not-json"), pluginDirectory: plugin))
        #expect(!OpenCodeTUIPolicy.permits(config: config(#"[{"type":"future","info":{}}]"#), pluginDirectory: plugin))
        #expect(!OpenCodeTUIPolicy.permits(config: config(#"[{"type":"document","info":{"plugins":[42]}}]"#), pluginDirectory: plugin))
        #expect(!OpenCodeTUIPolicy.permits(config: config(#"[{"type":"document","info":{"plugins":["other.plugin"]}}]"#), pluginDirectory: plugin))
        let unrelated = config(#"[{"type":"directory","path":"/private/tmp/plugins"},{"type":"document","info":{"plugins":["/private/tmp/app-owned/plugin"],"policies":[{"action":"integration.use","resource":"mcp:*","effect":"deny"}]}}]"#)
        #expect(OpenCodeTUIPolicy.permits(config: unrelated, pluginDirectory: plugin))
        let wildcard = config(#"[{"type":"document","info":{"plugins":["/private/tmp/app-owned/plugin"],"policies":[{"action":"integration.use","resource":"plugin:/private/*/app-owned/?lugin","effect":"deny"}]}}]"#)
        #expect(!OpenCodeTUIPolicy.permits(config: wildcard, pluginDirectory: plugin))
    }

    @Test func inlineMergePreservesUserOptionsAndNegativeOrder() throws {
        let input = #"{"model":"provider/model","plugins":["user.plugin",{"package":"other.plugin","options":{"x":1}},"-sphyrna.*","-old.plugin"]}"#
        let result = try OpenCodeTUIPlugin.addingOwnedPlugin(to: ["OPENCODE_CONFIG_CONTENT": input, "SENTINEL": "keep"],
                                                              directory: URL(fileURLWithPath: plugin))
        #expect(result["SENTINEL"] == "keep")
        let text = try #require(result["OPENCODE_CONFIG_CONTENT"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let entries = try #require(object["plugins"] as? [Any])
        #expect(entries.count == 5)
        guard entries.count == 5 else { return }
        #expect(entries.first as? String == plugin)
        #expect(entries[1] as? String == "user.plugin")
        #expect((entries[2] as? [String: Any])?["package"] as? String == "other.plugin")
        #expect((entries[2] as? [String: Any])?["options"] as? [String: Int] == ["x": 1])
        #expect(entries[3] as? String == "-sphyrna.*")
        #expect(entries[4] as? String == "-old.plugin")
        #expect(object["model"] as? String == "provider/model")
        #expect(throws: (any Error).self) {
            try OpenCodeTUIPlugin.addingOwnedPlugin(to: ["OPENCODE_CONFIG_CONTENT": "not-json"],
                                                    directory: URL(fileURLWithPath: plugin))
        }
        let repeated = try OpenCodeTUIPlugin.addingOwnedPlugin(to: result, directory: URL(fileURLWithPath: plugin))
        #expect(repeated["OPENCODE_CONFIG_CONTENT"] == result["OPENCODE_CONFIG_CONTENT"])
    }
}
