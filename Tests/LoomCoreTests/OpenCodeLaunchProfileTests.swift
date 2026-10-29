import Foundation
import Testing
@testable import LoomCore

@Suite struct OpenCodeLaunchProfileTests {
    @Test func ownedForegroundAndExactResumeUseSeparateSecretEnvironment() throws {
        let server = try OpenCodeLaunchProfile.server(environment: ["PATH": "/usr/bin"], password: "fixture-secret")
        #expect(server.arguments == ["serve", "--hostname", "127.0.0.1", "--port", "0"])
        #expect(server.environment["OPENCODE_PASSWORD"] == "fixture-secret")
        #expect(!server.arguments.contains("fixture-secret"))
        let terminal = try OpenCodeLaunchProfile.terminal(
            serverURL: URL(string: "http://127.0.0.1:43123")!, sessionID: "ses_fixture", directory: "/tmp/project",
            environment: ["PATH": "/usr/bin"], password: "fixture-secret")
        #expect(terminal.arguments == ["--server", "http://127.0.0.1:43123", "--session", "ses_fixture", "/tmp/project"])
        #expect(terminal.environment["OPENCODE_PASSWORD"] == "fixture-secret")
        #expect(!terminal.arguments.contains("--prompt"))
        #expect(!terminal.arguments.contains("fixture-secret"))
        #expect(throws: (any Error).self) {
            try OpenCodeLaunchProfile.terminal(serverURL: URL(string: "http://localhost:43123")!, sessionID: "ses_fixture",
                                               directory: "/tmp/project", environment: [:], password: "fixture-secret")
        }
        #expect(throws: (any Error).self) {
            try OpenCodeLaunchProfile.terminal(serverURL: URL(string: "http://127.0.0.1:43123")!, sessionID: "wrong",
                                               directory: "/tmp/project", environment: [:], password: "fixture-secret")
        }
    }
    @Test func observerCapabilityNeverEntersTheServerOrItsToolEnvironment() throws {
        let server = try OpenCodeLaunchProfile.server(environment: [
            "PATH": "/usr/bin",
            "SPHYRNA_OPENCODE_TUI_SOCKET": "/private/tmp/fixture.sock",
            "SPHYRNA_OPENCODE_TUI_TOKEN": "fixture-secret",
            "SPHYRNA_OPENCODE_TUI_APP_SESSION_ID": UUID().uuidString,
            "SPHYRNA_OPENCODE_TUI_RUN_ID": UUID().uuidString,
            "SPHYRNA_OPENCODE_TUI_INSTANCE_ID": UUID().uuidString
        ], password: "server-fixture")
        #expect(server.environment["PATH"] == "/usr/bin")
        #expect(!server.environment.keys.contains { $0.hasPrefix("SPHYRNA_OPENCODE_TUI_") })
    }

}
