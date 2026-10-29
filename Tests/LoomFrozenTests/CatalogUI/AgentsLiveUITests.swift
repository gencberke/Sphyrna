import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat

// V23, Agents live, on the catalog side: which subagent the Agents tab and the sidebar tree mark as waiting, what the open
// subagent's notice says in each face, how "Show the request" reaches the pinned card, and a stopped session's list read from
// its folder. Counting seams stand in for the folder read; nothing here opens a window or runs a program.

private func liveState(_ requests: [ProviderPendingRequest] = []) -> SessionViewState {
    SessionViewState(runID: UUID(), pendingRequests: requests)
}

// MARK: Show the request

private actor NoSource: ChatLiveSource {
    func modelChanges() -> ChatModelChanges { ChatModelChanges(changes: AsyncStream { $0.finish() }) }
    func snapshotChange() -> ModelChange { TurnModel(source: .live).snapshot(sequence: 0, hasOlder: false) }
    func liveState() -> ChatLiveState { ChatLiveState(sessionID: UUID()) }
    func updates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func answer(requestID: String, _ answer: ChatRequestAnswer) async throws {}
    func resume() async throws {}
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ShowTheRequestTests {
    private func request(_ id: String, agent: ChatRequestAgent?) -> ChatPendingRequest {
        let fields: [String: JSONValue] = ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"],
                                           "tool_use_id": .string("toolu_" + id)]
        return ChatPendingRequest(requestID: id, request: ToolPermissionRequest(json: .object(fields))!,
                                  arrivedAt: Date(timeIntervalSince1970: 1), agent: agent)
    }

    @Test func showTheRequestMakesTheSubagentsCardTheOneShownAndMovesTheStacksScrollTarget() {
        let cards = PinnedCardsModel(source: NoSource())
        let main = request("r-main", agent: nil)
        let asked = request("r-agent", agent: ChatRequestAgent(id: "a-reviewer", type: "reviewer", description: "Review auth"))
        cards.apply(ChatLiveState(sessionID: UUID(), phase: .needsYou, requests: [main, asked], settled: []))
        #expect(cards.current?.requestID == "r-main" && cards.revealCount == 0)

        // The counting seam: the stack scrolls to `revealedRequestID` each time the count moves.
        #expect(cards.reveal(agentID: "a-reviewer"))
        #expect(cards.current?.requestID == "r-agent" && cards.revealedRequestID == "r-agent" && cards.revealCount == 1)
        // Nothing was answered.
        #expect(cards.requests.count == 2)
        // The same again scrolls again (the card may have been scrolled away since).
        #expect(cards.reveal(agentID: "a-reviewer") && cards.revealCount == 2)
    }

    @Test func aSubagentWithoutAWaitingRequestRevealsNothing() {
        let cards = PinnedCardsModel(source: NoSource())
        cards.apply(ChatLiveState(sessionID: UUID(), phase: .needsYou, requests: [request("r-main", agent: nil)], settled: []))
        #expect(cards.reveal(agentID: "a-reviewer") == false)
        #expect(cards.revealCount == 0 && cards.revealedRequestID == nil && cards.current?.requestID == "r-main")
    }
}
