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
    @Test func withTheSwitchOnTerminalOrWithoutAChatHostAnApprovedOpeningStartsInTheTerminal() async throws {
        let fixture = try await makeFixture()
        let model = fixture.model

        model.setNewSessionFace(.terminal)
        let terminalOpened = try await approvedOpening(fixture)
        #expect(await liveEndpoint(fixture, terminalOpened) == .terminal)
        #expect(await waitUntil { model.terminalView(for: terminalOpened) != nil })

        model.setNewSessionFace(.chat)
        let host = model.chatSessions
        model.chatSessions = nil
        let hostless = try await approvedOpening(fixture)
        #expect(await liveEndpoint(fixture, hostless) == .terminal)
        #expect(await waitUntil { model.terminalView(for: hostless) != nil })
        model.chatSessions = host

        for id in [terminalOpened, hostless] {
            let row = try #require(try await fixture.rig.runtime.catalog.session(id: id))
            #expect(row.title == ApprovedOpeningFaceShared.title && row.openedBy == fixture.requester)
        }
        #expect(!lines(fixture.requestLog).contains("generate_session_title"))
        await fixture.cleanup()
    }
}
