import Foundation

/// Inspects only the ordered plugin/policy projection returned by the owned
/// server. It does not load profile files or retain the rest of the response.
enum OpenCodeTUIPolicy {
    private struct Entry: Decodable {
        struct Info: Decodable {
            struct Plugin: Decodable {
                let target: String
                init(from decoder: Decoder) throws {
                    let single = try decoder.singleValueContainer()
                    if let value = try? single.decode(String.self) { target = value; return }
                    let object = try decoder.container(keyedBy: Keys.self)
                    target = try object.decode(String.self, forKey: .package)
                    if object.contains(.options) {
                        _ = try object.superDecoder(forKey: .options).container(keyedBy: AnyKey.self)
                    }
                }
                enum Keys: String, CodingKey { case package, options }
                struct AnyKey: CodingKey {
                    let stringValue: String
                    let intValue: Int?
                    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
                    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
                }
            }
            struct Policy: Decodable { let action: String; let resource: String; let effect: String }
            let plugins: [Plugin]?
            let policies: [Policy]?
            enum Keys: String, CodingKey { case plugins, policies }
            init(from decoder: Decoder) throws {
                let object = try decoder.container(keyedBy: Keys.self)
                plugins = object.contains(.plugins) ? try object.decode([Plugin].self, forKey: .plugins) : nil
                policies = object.contains(.policies) ? try object.decode([Policy].self, forKey: .policies) : nil
            }
        }
        let type: String
        let path: String?
        let info: Info?
    }

    static func permits(config: Data, pluginDirectory: String) -> Bool {
        guard config.count <= 256 * 1024, valid(pluginDirectory), pluginDirectory.hasPrefix("/"),
              let entries = try? JSONDecoder().decode([Entry].self, from: config), entries.count <= 256 else {
            return false
        }
        var hasCarrier = false
        var operations = 0
        var budget = 1_000_000
        for entry in entries {
            if entry.type == "directory" {
                guard let path = entry.path, valid(path), path.hasPrefix("/"), entry.info == nil else { return false }
                continue
            }
            guard entry.type == "document", let info = entry.info,
                  entry.path.map({ valid($0) && $0.hasPrefix("/") }) ?? true else { return false }
            for plugin in info.plugins ?? [] {
                operations += 1
                let value = plugin.target
                guard operations <= 512, valid(value), value != "-" else { return false }
                if value.hasPrefix("-") {
                    let selector = String(value.dropFirst())
                    if matchesSelector(selector, id: OpenCodeTUIPlugin.id) || selector == pluginDirectory { return false }
                } else if value == pluginDirectory {
                    hasCarrier = true
                }
            }
            for policy in info.policies ?? [] {
                operations += 1
                guard operations <= 512, valid(policy.action), valid(policy.resource),
                      policy.effect == "allow" || policy.effect == "deny" else { return false }
                if policy.action == "integration.use", policy.effect == "deny" {
                    // Native matches `plugin:<target>` with * and ? wildcards.
                    // Exhausting the work budget is uncertain, so fail closed.
                    guard let pathMatch = wildcard(policy.resource, "plugin:\(pluginDirectory)", budget: &budget),
                          let idMatch = wildcard(policy.resource, "plugin:\(OpenCodeTUIPlugin.id)", budget: &budget),
                          !pathMatch, !idMatch else { return false }
                }
            }
        }
        return hasCarrier
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.contains("\0")
    }

    private static func matchesSelector(_ selector: String, id: String) -> Bool {
        if selector == "*" { return true }
        if selector.hasSuffix(".*") { return id.hasPrefix(String(selector.dropLast())) }
        return selector == id
    }

    private static func wildcard(_ pattern: String, _ text: String, budget: inout Int) -> Bool? {
        let normalized = pattern.replacingOccurrences(of: "\\", with: "/")
        let target = text.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasSuffix(" *") {
            guard let prefixMatch = wildcardCore(String(normalized.dropLast(2)), target, budget: &budget) else { return nil }
            if prefixMatch { return true }
        }
        return wildcardCore(normalized, target, budget: &budget)
    }

    // Glob matching on UTF-16 units matches the native JS regular-expression
    // alphabet without constructing a potentially expensive regular expression.
    private static func wildcardCore(_ pattern: String, _ text: String, budget: inout Int) -> Bool? {
        let p = Array(pattern.utf16), t = Array(text.utf16)
        var i = 0, j = 0, star: Int?, fallback = 0
        while j < t.count {
            budget -= 1
            guard budget >= 0 else { return nil }
            if i < p.count, p[i] == 63 || p[i] == t[j] { i += 1; j += 1; continue }
            if i < p.count, p[i] == 42 { star = i; i += 1; fallback = j; continue }
            if let star { fallback += 1; j = fallback; i = star + 1; continue }
            return false
        }
        while i < p.count, p[i] == 42 { i += 1 }
        return i == p.count
    }
}

/// A volatile, single-bridge proof. Config and plugin events or feed loss
/// revoke it; this authorizes passive observation only, never a mutation.
public final class OpenCodeTUIPolicyProof: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var onInvalidate: (@Sendable () -> Void)?
    let appSessionID: UUID
    let runID: UUID
    let serverURL: URL
    let directory: String
    let pluginDirectory: String

    init(appSessionID: UUID, runID: UUID, serverURL: URL, directory: String, pluginDirectory: String) {
        self.appSessionID = appSessionID; self.runID = runID; self.serverURL = serverURL
        self.directory = directory; self.pluginDirectory = pluginDirectory
    }

    public var isValid: Bool { lock.withLock { valid } }
    func attach(_ callback: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard valid, onInvalidate == nil else { return false }
            onInvalidate = callback
            return true
        }
    }
    func invalidate() {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            guard valid else { return nil }
            valid = false
            let callback = onInvalidate
            onInvalidate = nil
            return callback
        }
        callback?()
    }
}
