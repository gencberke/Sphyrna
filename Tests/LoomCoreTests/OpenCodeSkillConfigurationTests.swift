import Foundation
import Testing
@testable import LoomCore

@Suite struct OpenCodeSkillConfigurationTests {
    @Test func addsSkillWithoutChangingTheUsersInlineChoices() throws {
        let original = #"{"skills":["/user/existing"],"model":"provider/model","policies":[{"effect":"ask"}]}"#
        let environment = ["OPENCODE_CONFIG_CONTENT": original, "SPHYRNA_TASK_TOKEN": "fixture"]
        let result = try OpenCodeSkillConfiguration.addingOwnedSkill(to: environment, directory: URL(fileURLWithPath: "/app/skills"))
        let encoded = try #require(result["OPENCODE_CONFIG_CONTENT"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(object["skills"] as? [String] == ["/user/existing", "/app/skills"])
        #expect(object["model"] as? String == "provider/model")
        #expect((object["policies"] as? [[String: String]])?.first?["effect"] == "ask")
        #expect(result["SPHYRNA_TASK_TOKEN"] == "fixture")
        #expect(throws: (any Error).self) {
            _ = try OpenCodeSkillConfiguration.addingOwnedSkill(to: ["OPENCODE_CONFIG_CONTENT": "invalid"], directory: URL(fileURLWithPath: "/app/skills"))
        }
    }
}
