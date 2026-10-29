import Foundation

public enum AgyLaunchError: Error, Equatable, Sendable {
    case invalidTarget, unsupportedChoice, cleanupUnverified
}

/// Arguments for the unmodified interactive CLI. Resume never carries an
/// opening message or changes the native session's saved choices.
public enum AgyLaunchProfile {
    public enum Route: Equatable, Sendable {
        case new(firstMessage: String?)
        case resume(UUID)
    }

    public static func terminal(route: Route, choices: HarnessLaunchChoices,
                                discoveryDirectory: URL, environment: [String: String]) throws -> ProviderLaunchProfile {
        guard choices.harness == .agy, discoveryDirectory.isFileURL,
              discoveryDirectory.path.hasPrefix("/"), !discoveryDirectory.path.contains("\0") else {
            throw AgyLaunchError.invalidTarget
        }
        var arguments = ["--add-dir", discoveryDirectory.standardizedFileURL.path]
        switch route {
        case let .new(firstMessage):
            if let model = choices.model {
                guard ClaudeLaunchChoices.isSafeToken(model) else { throw AgyLaunchError.invalidTarget }
                arguments += ["--model", model]
            }
            if let effort = choices.effort {
                guard ["low", "medium", "high", "xhigh", "max"].contains(effort) else {
                    throw AgyLaunchError.unsupportedChoice
                }
                arguments += ["--effort", effort]
            }
            if let mode = choices.mode {
                let value: String
                switch mode {
                case .acceptEdits: value = "accept-edits"
                case .auto: value = "auto"
                case .plan: value = "plan"
                default: throw AgyLaunchError.unsupportedChoice
                }
                arguments += ["--mode", value]
            }
            if let firstMessage, !firstMessage.isEmpty {
                guard firstMessage.utf8.count <= 48 * 1024, !firstMessage.contains("\0") else {
                    throw AgyLaunchError.invalidTarget
                }
                arguments += ["-i", firstMessage]
            }
        case let .resume(id):
            guard choices.model == nil, choices.effort == nil, choices.mode == nil else {
                throw AgyLaunchError.unsupportedChoice
            }
            arguments += ["--conversation", id.uuidString.lowercased()]
        }
        return ProviderLaunchProfile(arguments: arguments, environment: environment)
    }
}
