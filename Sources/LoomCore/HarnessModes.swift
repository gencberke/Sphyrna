import Foundation

/// Product mode identities. A descriptor lists only the modes whose harness mapping is known.
public enum HarnessMode: String, CaseIterable, Codable, Sendable {
    case ask
    case askBeforeEdits = "default"
    case acceptEdits
    case plan
    case auto
    case fullAccess = "bypassPermissions"

    public var title: String { ClaudePermissionMode(rawValue: rawValue)?.title ?? rawValue }

    public static func fromStored(_ raw: String?) -> HarnessMode? {
        guard let raw else { return nil }
        return raw == ClaudePermissionMode.ask.cliValue ? .ask : HarnessMode(rawValue: raw)
    }

    /// Recognize common spellings before checking a descriptor, so no alias can give an agent Full access.
    public static func isFullAccessAlias(_ raw: String) -> Bool {
        let folded = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["bypasspermissions", "fullaccess", "dangerfullaccess", "dangerouslyskippermissions", "yolo"].contains(folded)
    }
}
