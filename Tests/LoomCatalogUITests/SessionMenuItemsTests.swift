import AppKit
import Foundation
@testable import LoomCore
import Testing
@testable import LoomCatalogUI

/// W3-f: the session menu's Open Folder in Editor, Open in Terminal and Copy Transcript Path: when each applies, and the path the
/// copy puts on a pasteboard.
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct SessionMenuItemsTests {
    private struct Fixture {
        let root: URL
        let config: URL
        let claude: SessionRowModel
        let noTranscript: SessionRowModel
        let goneFolder: SessionRowModel
        let codex: SessionRowModel
        let transcript: URL

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-session-menu-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("claude-config", isDirectory: true)
        let projects = config.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(ClaudeTranscriptLocator.folderName(forWorkingDirectory: folder.path), isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let transcript = projects.appendingPathComponent("conv-1.jsonl")
        try Data("{}\n".utf8).write(to: transcript)

        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        func row(_ session: ManagedSession) async throws -> SessionRowModel {
            try await catalog.insertSession(session, title: "S", createdAt: Date(timeIntervalSince1970: 1_000),
                                            lastUsedAt: Date(timeIntervalSince1970: 2_000), lifecycle: .idle)
            let record = try #require(try await catalog.session(id: session.id))
            return SessionRowModel(record: record, live: nil)
        }
        return Fixture(
            root: root, config: config,
            claude: try await row(ManagedSession(provider: .claude, providerConversationID: "conv-1", workingDirectory: folder.path)),
            noTranscript: try await row(ManagedSession(provider: .claude, providerConversationID: nil, workingDirectory: folder.path)),
            goneFolder: try await row(ManagedSession(provider: .claude, providerConversationID: "conv-1",
                                                     workingDirectory: root.appendingPathComponent("gone").path)),
            codex: try await row(ManagedSession(provider: .codex, providerConversationID: "c-1", workingDirectory: folder.path)),
            transcript: transcript)
    }

    @Test func eachItemAppliesOnlyWhereItCan() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        typealias Availability = SessionLocationActions.Availability
        #expect(SessionLocationActions.availability(of: fixture.claude, configDirectory: fixture.config)
                == Availability(revealFolder: true, openFolder: true, openTerminal: true, copyTranscriptPath: true))
        #expect(SessionLocationActions.availability(of: fixture.noTranscript, configDirectory: fixture.config)
                == Availability(revealFolder: true, openFolder: true, openTerminal: true, copyTranscriptPath: false),
                "no conversation id, no transcript")
        #expect(SessionLocationActions.availability(of: fixture.codex, configDirectory: fixture.config).copyTranscriptPath == false)
        #expect(SessionLocationActions.availability(of: fixture.claude, configDirectory: nil).copyTranscriptPath == false,
                "no Claude profile to look in")
        #expect(SessionLocationActions.availability(of: fixture.goneFolder, configDirectory: fixture.config)
                == Availability(revealFolder: false, openFolder: false, openTerminal: false, copyTranscriptPath: false),
                "a session whose folder is gone gets none of them")
    }

    @Test func copyTranscriptPathPutsTheFilesPathOnThePasteboard() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("loom-session-menu-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let copied = await SessionLocationActions.copyTranscriptPath(of: fixture.claude, configDirectory: fixture.config,
                                                                     to: pasteboard)
        // The locator answers with the real path (`realpath`: /private/var, not /var).
        let expected = try #require(realpath(fixture.transcript.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(copied == expected)
        #expect(pasteboard.string(forType: .string) == expected)

        // A file that is not there copies nothing.
        try FileManager.default.removeItem(at: fixture.transcript)
        pasteboard.clearContents()
        #expect(await SessionLocationActions.copyTranscriptPath(of: fixture.claude, configDirectory: fixture.config,
                                                                to: pasteboard) == nil)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func terminalIsTheSystemTerminalApp() {
        #expect(SessionLocationActions.terminalBundleID == "com.apple.Terminal")
        #expect(NSWorkspace.shared.urlForApplication(withBundleIdentifier: SessionLocationActions.terminalBundleID) != nil)
    }
}
