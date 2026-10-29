import Foundation
import Testing
@testable import LoomCore

private actor OpenCodeLiveClientPeer {
    var paths: [String] = []
    func reply(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        paths.append(url.path)
        let body: [String: Any]
        switch url.path {
        case "/api/info":
            body = ["pid": 1234, "version": "2.2.0", "urls": ["http://127.0.0.1:43123"],
                    "paths": ["tmp": "/tmp/profile"]]
        case "/api/session":
            body = ["data": ["id": "ses_fixture", "location": ["directory": "/tmp/project"]]]
        case "/api/session/ses_fixture/prompt":
            let input = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            body = ["data": ["id": input["id"]!, "sessionID": "ses_fixture", "type": "user",
                             "payload": ["text": input["text"]!], "delivery": "steer"]]
        case "/api/session/ses_fixture/interrupt":
            body = ["interrupted": true]
        default: throw OpenCodeError.invalidTarget
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}

@Suite struct OpenCodeLiveClientTests {
    @Test func createCannotRunWithoutAnAuthenticatedLiveSubscription() async throws {
        let peer = OpenCodeLiveClientPeer()
        let client = OpenCodeClient(base: URL(string: "http://127.0.0.1:43123")!, password: "fixture") {
            try await peer.reply($0)
        }
        try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/tmp/profile")
        await #expect(throws: OpenCodeError.unavailable) {
            _ = try await client.create(directory: "/tmp/project", model: nil)
        }
        #expect(await peer.paths == ["/api/info"])
    }

    @Test func newSessionAttachmentAndFirstInputNeedTheExactObservedCreationEvent() async throws {
        let peer = OpenCodeLiveClientPeer()
        let feed = OpenCodeLiveFeed(appSessionID: UUID(), runID: UUID())
        feed.didConnect()
        let client = OpenCodeClient(base: URL(string: "http://127.0.0.1:43123")!, password: "fixture", liveFeed: feed) {
            try await peer.reply($0)
        }
        try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/tmp/profile")
        _ = try await client.create(directory: "/tmp/project", model: nil)
        await #expect(throws: OpenCodeError.unavailable) {
            _ = try await client.terminalProfile(directory: "/tmp/project", environment: [:])
        }
        let roundID = UUID()
        await #expect(throws: OpenCodeError.unavailable) {
            _ = try await client.firstInput(sessionID: "ses_fixture", messageID: "msg_one", roundID: roundID, text: "approved")
        }
        #expect(await peer.paths == ["/api/info", "/api/session"])
        #expect(feed.receive(OpenCodeEvent(id: "evt_created", type: "session.created",
                                          sessionID: "ses_fixture", sequence: 1, inboxID: nil, version: 1)))
        let terminal = try await client.terminalProfile(directory: "/tmp/project", environment: [:])
        #expect(terminal.arguments.contains("ses_fixture"))
        await #expect(throws: OpenCodeError.unavailable) {
            _ = try await client.firstInput(sessionID: "ses_fixture", messageID: "msg_one",
                                            roundID: roundID, text: "approved")
        }
        #expect(feed.snapshot?.input == nil)
        #expect(await peer.paths == ["/api/info", "/api/session"])
        feed.didDisconnect()
        await #expect(throws: OpenCodeError.unavailable) {
            _ = try await client.submitInput(sessionID: "ses_fixture", messageID: "msg_two",
                                             roundID: UUID(), text: "another")
        }
        #expect(await peer.paths == ["/api/info", "/api/session"])
    }
    @Test func passiveObservationCannotAuthorizeAnyAPIInput() async throws {
        let peer = OpenCodeLiveClientPeer()
        let feed = OpenCodeLiveFeed(appSessionID: UUID(), runID: UUID())
        feed.didConnect()
        let client = OpenCodeClient(base: URL(string: "http://127.0.0.1:43123")!, password: "fixture", liveFeed: feed) {
            try await peer.reply($0)
        }
        try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/tmp/profile")
        _ = try await client.create(directory: "/tmp/project", model: nil)
        #expect(feed.receive(OpenCodeEvent(id: "evt_created", type: "session.created",
                                          sessionID: "ses_fixture", sequence: 1, inboxID: nil, version: 1)))
        await #expect(throws: OpenCodeError.unavailable) {
            _ = try await client.firstInput(sessionID: "ses_fixture", messageID: "msg_one", roundID: UUID(), text: "approved")
        }
        await #expect(throws: OpenCodeError.unavailable) {
            _ = try await client.submitInput(sessionID: "ses_fixture", messageID: "msg_two", roundID: UUID(), text: "approved")
        }
        #expect(await peer.paths == ["/api/info", "/api/session"])
    }

    @Test func selectedSessionInterruptRequiresAnActionTimeRouteFence() async throws {
        let peer = OpenCodeLiveClientPeer()
        let feed = OpenCodeLiveFeed(appSessionID: UUID(), runID: UUID())
        feed.didConnect()
        let client = OpenCodeClient(base: URL(string: "http://127.0.0.1:43123")!, password: "fixture", liveFeed: feed) {
            try await peer.reply($0)
        }
        try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/tmp/profile")
        _ = try await client.create(directory: "/tmp/project", model: nil)
        await #expect(throws: OpenCodeError.unavailable) {
            _ = try await client.interruptForStoppedInput(sessionID: "ses_fixture")
        }
        #expect(await peer.paths == ["/api/info", "/api/session"])
    }

}
