import Foundation

/// Adds an app-owned skill directory only to this invocation's inline native
/// configuration. The caller owns the skill file, metadata budget and enablement.
public enum OpenCodeSkillConfiguration {
    public static func addingOwnedSkill(to environment: [String: String], directory: URL) throws -> [String: String] {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0") else {
            throw OpenCodeError.invalidTarget
        }
        var config: [String: Any] = [:]
        if let content = environment["OPENCODE_CONFIG_CONTENT"] {
            guard content.utf8.count <= 256 * 1024,
                  let value = try? JSONSerialization.jsonObject(with: Data(content.utf8)),
                  let object = value as? [String: Any] else { throw OpenCodeError.invalidTarget }
            config = object
        }
        let previous: [String]
        if let value = config["skills"] {
            guard let skills = value as? [String], skills.count <= 128 else { throw OpenCodeError.invalidTarget }
            previous = skills
        } else { previous = [] }
        let path = directory.standardizedFileURL.path
        if previous.contains(path) { return environment }
        guard previous.count < 128 else { throw OpenCodeError.responseTooLarge }
        config["skills"] = previous + [path]
        guard JSONSerialization.isValidJSONObject(config),
              let bytes = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              bytes.count <= 256 * 1024, let content = String(data: bytes, encoding: .utf8) else {
            throw OpenCodeError.invalidTarget
        }
        var result = environment
        result["OPENCODE_CONFIG_CONTENT"] = content
        return result
    }
}
