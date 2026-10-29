import Foundation
import Testing
@testable import LoomCore
import LoomTestSupport
@testable import LoomCoreTestRigs

@Suite(.serialized, .processHeavy, .timeLimit(.minutes(2)))
struct SessionTaskCodexDiscoveryTests {
    @Test func ownedSkillIsAvailableBeforeTheFirstFakeModelInput() async throws {
        let context = try await SessionRuntimeRig.makeContext()
        defer { context.cleanup() }
        let folder = context.root.appendingPathComponent("task-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try await context.catalog.addProject(path: folder.path).project
        let screen = SessionRuntimeRig.Screen()
        let launch = try await context.runtime.startConversation(
            provider: .codex, projectID: project.id, outputSink: screen,
            draft: NewSessionLaunch(firstMessage: "first task input", choices: HarnessLaunchChoices(harness: .codex)))
        screen.attach(launch.terminal)
        #expect(await screen.contains("CODEX-TURN-DONE completed echo first task input"))
        #expect(await context.runtime.codexTaskDiscovery(forSession: launch.sessionID) == .available)

        let methods = (try? String(contentsOf: context.state.appendingPathComponent("codex-methods.log"), encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let registration = methods.firstIndex(of: "skills/extraRoots/set")
        let catalog = methods.firstIndex(of: "skills/list")
        let input = methods.firstIndex(of: "turn/start")
        #expect(registration != nil && catalog != nil && input != nil)
        if let registration, let catalog, let input { #expect(registration < catalog && catalog < input) }

        let root = context.catalog.dataRoot.appendingPathComponent("channel-skills", isDirectory: true)
        let skill = root.appendingPathComponent("sphyrna/SKILL.md")
        let content = try? String(contentsOf: skill, encoding: .utf8)
        let description = content?.split(separator: "\n").first { $0.hasPrefix("description: ") }
        #expect(description != nil && description!.dropFirst("description: ".count).count <= 300)
        let usedRoots = try? String(contentsOf: context.state.appendingPathComponent("codex-turn-skill-roots.log"), encoding: .utf8)
        #expect(usedRoots?.trimmingCharacters(in: .whitespacesAndNewlines) == root.path)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }

    @Test func disabledNativeSkillIsReportedUnavailableWithoutBlockingTheSession() async throws {
        let context = try await SessionRuntimeRig.makeContext(extraEnvironment: ["LOOM_FAKE_CODEX_SKILL_DISABLED": "1"])
        defer { context.cleanup() }
        let screen = SessionRuntimeRig.Screen()
        let launch = try await context.runtime.startConversation(
            provider: .codex, projectID: nil, outputSink: screen,
            draft: NewSessionLaunch(firstMessage: "ordinary input", choices: HarnessLaunchChoices(harness: .codex)))
        screen.attach(launch.terminal)
        #expect(await screen.contains("CODEX-TURN-DONE completed echo ordinary input"))
        #expect(await context.runtime.codexTaskDiscovery(forSession: launch.sessionID) == .unavailable)
        #expect(try await context.runtime.stopConversation(sessionID: launch.sessionID).succeeded)
        #expect((await context.runtime.shutdown()).succeeded)
    }
}
