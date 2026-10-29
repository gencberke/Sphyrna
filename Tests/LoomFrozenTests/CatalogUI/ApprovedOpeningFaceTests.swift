import AppKit
import Foundation
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport
@testable import LoomCatalogUITestRigs

// C5b: an approved opening follows "Sessions run in" like every other start (D-69 (1)). An agent's open request, approved
// through the model, starts the new session in the Chat face when the switch says Chat and the app has its Chat host; in the
// terminal otherwise. Real runs on the fake provider (its chat engine; `LOOM_FAKE_CHAT_REQUEST_LOG` records its control
// requests).

@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(5)))
struct ApprovedOpeningFaceTests: ApprovedOpeningFaceFixtures {
    /// The text of the first user record in the fake engine's transcript of the session (what its engine received), once
    /// it is there.
    private func firstUserMessage(_ fixture: Fixture, of id: UUID) async -> String? {
        var found: String?
        _ = await waitUntil(30) {
            let projects = fixture.rig.profile.appendingPathComponent("projects", isDirectory: true)
            let files = (try? FileManager.default.subpathsOfDirectory(atPath: projects.path)) ?? []
            guard let name = files.first(where: { $0.lowercased().hasSuffix("/\(id.uuidString.lowercased()).jsonl") }),
                  let text = try? String(contentsOf: projects.appendingPathComponent(name), encoding: .utf8) else { return false }
            for line in text.split(separator: "\n") {
                guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                      record["type"] as? String == "user", let message = record["message"] as? [String: Any] else { continue }
                if let content = message["content"] as? String { found = content }
                else if let blocks = message["content"] as? [[String: Any]] {
                    found = blocks.compactMap { $0["text"] as? String }.joined()
                }
                return found != nil
            }
            return false
        }
        return found
    }

    @Test func withTheSwitchOnChatAnApprovedOpeningStartsInTheChatFaceWithItsTitleItsLinkAndItsFirstMessage() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model
        model.setNewSessionFace(.chat)
        let selected = model.selectedSessionID

        let opened = try await approvedOpening(fixture)

        #expect(await liveEndpoint(fixture, opened) == .pipe)
        let row = try #require(try await fixture.rig.runtime.catalog.session(id: opened))
        #expect(row.title == ApprovedOpeningFaceShared.title)
        #expect(row.openedBy == fixture.requester)
        // The fake engine got the request's message, as the first user message, over stdin.
        #expect(await firstUserMessage(fixture, of: opened) == ApprovedOpeningFaceShared.message)
        // The selection does not move, and the new session has a Chat driver and no terminal.
        #expect(model.selectedSessionID == selected)
        #expect(model.chatSessions?.existingDriver(for: opened) != nil)
        #expect(model.terminalView(for: opened) == nil)
        // The card has its title, so Sphyrna asks no model to name it: no title request, in a session that ran a turn.
        let driver = try #require(model.chatSessions?.existingDriver(for: opened))
        #expect(await waitUntil { let s = await driver.snapshot(); return s.phase == .ready && !s.turnRunning })
        try await Task.sleep(for: .milliseconds(600))
        let requests = lines(fixture.requestLog)
        #expect(requests.contains("initialize"), "the log saw the session: \(requests)")
        #expect(!requests.contains("generate_session_title"), "\(requests)")
        await fixture.cleanup()
    }
}
