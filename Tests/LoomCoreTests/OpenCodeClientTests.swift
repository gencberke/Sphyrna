import Foundation
import Testing
@testable import LoomCore

private actor OpenCodeHTTPFixture {
    var requests: [URLRequest] = []
    var infoPID = 1234
    var infoVersion = "2.2.0"
    var infoTmp = "/tmp/owned/opencode"
    var status = 200
    var sessionID = "ses_fixture"
    var sessionDirectory = "/tmp/project"
    var wrongReceipt = false

    func setInfo(pid: Int? = nil, version: String? = nil, tmp: String? = nil, status: Int? = nil) {
        if let pid { infoPID = pid }
        if let version { infoVersion = version }
        if let tmp { infoTmp = tmp }
        if let status { self.status = status }
    }
    func setSession(id: String? = nil, directory: String? = nil) {
        if let id { sessionID = id }
        if let directory { sessionDirectory = directory }
    }
    func allRequests() -> [URLRequest] { requests }
    func setWrongReceipt() { wrongReceipt = true }

    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        if status != 200 { return (Data(), response) }
        let payload: [String: Any]
        switch url.path {
        case "/api/info":
            payload = ["pid": infoPID, "version": infoVersion, "urls": ["http://127.0.0.1:43123"],
                       "paths": ["tmp": infoTmp]]
        case "/api/session":
            let requestBody = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            payload = ["data": ["id": sessionID, "location": ["directory": sessionDirectory],
                                "model": requestBody["model"] ?? NSNull(),
                                "permissions": requestBody["permissions"] ?? NSNull()]]
        case "/api/session/ses_fixture":
            payload = ["data": ["id": sessionID, "location": ["directory": sessionDirectory]]]
        case "/api/session/ses_fixture/prompt":
            let requestBody = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            payload = ["data": ["id": requestBody["id"]!, "sessionID": sessionID, "type": "user",
                                "payload": ["text": wrongReceipt ? "other payload" : requestBody["text"]!], "delivery": "steer"]]
        default: throw OpenCodeError.invalidTarget
        }
        return (try JSONSerialization.data(withJSONObject: payload), response)
    }
}

@Suite struct OpenCodeClientTests {
    private func client(_ fixture: OpenCodeHTTPFixture) -> OpenCodeClient {
        OpenCodeClient(base: URL(string: "http://127.0.0.1:43123")!, password: "fixture-secret") {
            try await fixture.respond($0)
        }
    }

    @Test func verifiedCreateAndReceiptAreSingleAdmission() async throws {
        let fixture = OpenCodeHTTPFixture()
        let client = client(fixture)
        try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/tmp/owned/opencode")
        let model = OpenCodeModel(providerID: "fixture", id: "small", variant: "medium")
        let rules = [OpenCodePermissionRule(action: "*", resource: "*", effect: .ask)]
        let created = try await client.create(directory: "/tmp/project", model: model, permissions: rules)
        #expect(created.id == "ses_fixture")
        #expect(created.model == model)
        #expect(created.permissions == rules)
        let terminal = try await client.terminalProfile(directory: "/tmp/project", environment: [:])
        #expect(terminal.arguments == ["--server", "http://127.0.0.1:43123", "--session", "ses_fixture", "/tmp/project"])
        #expect(!terminal.arguments.contains("--prompt"))
        await #expect(throws: (any Error).self) { _ = try await client.terminalProfile(directory: "/tmp/other", environment: [:]) }
        await #expect(throws: OpenCodeError.conflict) { _ = try await client.create(directory: "/tmp/project", model: model) }
        let receipt = try await client.firstInput(sessionID: created.id, messageID: "msg_one", text: "first input")
        #expect(receipt == "msg_one")
        #expect(try await client.firstInput(sessionID: created.id, messageID: "msg_one", text: "first input") == receipt)
        await #expect(throws: OpenCodeError.conflict) {
            _ = try await client.firstInput(sessionID: created.id, messageID: "msg_one", text: "different input")
        }
        let requests = await fixture.allRequests()
        #expect(requests.map { $0.url!.path } == ["/api/info", "/api/session", "/api/session/ses_fixture/prompt"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Basic b3BlbmNvZGU6Zml4dHVyZS1zZWNyZXQ=" })
        let create = try #require(requests.first { $0.url!.path == "/api/session" })
        let bytes = try #require(create.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(body["id"] == nil)
        #expect((body["location"] as? [String: String])?["directory"] == "/tmp/project")
        #expect((body["model"] as? [String: String]) == ["providerID": "fixture", "id": "small", "variant": "medium"])
        #expect((body["permissions"] as? [[String: String]])?.first == ["action": "*", "resource": "*", "effect": "ask"])
    }

    @Test func wrongServerOrResumeIdentityNeverAttaches() async throws {
        for mismatch in 0..<4 {
            let fixture = OpenCodeHTTPFixture()
            switch mismatch {
            case 0: await fixture.setInfo(pid: 99)
            case 1: await fixture.setInfo(version: "2.1.0")
            case 2: await fixture.setInfo(tmp: "/tmp/wrong")
            default: await fixture.setInfo(status: 401)
            }
            let client = client(fixture)
            await #expect(throws: (any Error).self) {
                try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/tmp/owned/opencode")
            }
            await #expect(throws: (any Error).self) { _ = try await client.resume(id: "ses_fixture", directory: "/tmp/project") }
        }
        for mismatch in 0..<2 {
            let fixture = OpenCodeHTTPFixture()
            let client = client(fixture)
            try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/tmp/owned/opencode")
            if mismatch == 0 { await fixture.setSession(id: "ses_other") }
            else { await fixture.setSession(directory: "/tmp/other") }
            await #expect(throws: (any Error).self) { _ = try await client.resume(id: "ses_fixture", directory: "/tmp/project") }
        }
    }
    @Test func unknownAdmissionIsNotReplayedAndResumeOnlyReads() async throws {
        let fixture = OpenCodeHTTPFixture()
        let client = client(fixture)
        try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/tmp/owned/opencode")
        let resumed = try await client.resume(id: "ses_fixture", directory: "/tmp/project")
        #expect(resumed.id == "ses_fixture")
        let resumeRequests = await fixture.allRequests()
        #expect(resumeRequests.map { $0.httpMethod } == ["GET", "GET"])
        #expect(resumeRequests.last?.httpBody == nil)
        await fixture.setInfo(status: 500)
        await #expect(throws: (any Error).self) {
            _ = try await client.firstInput(sessionID: "ses_fixture", messageID: "msg_one", text: "first input")
        }
        await fixture.setInfo(status: 200)
        await #expect(throws: OpenCodeError.indeterminate) {
            _ = try await client.firstInput(sessionID: "ses_fixture", messageID: "msg_one", text: "first input")
        }
        let requests = await fixture.allRequests()
        #expect(requests.filter { $0.url!.path.hasSuffix("/prompt") }.count == 1)
    }

    @Test func mismatchedNativeReceiptNeverCountsAsAuthorizedInput() async throws {
        let fixture = OpenCodeHTTPFixture()
        let client = client(fixture)
        try await client.verify(pid: 1234, version: "2.2.0", temporaryDirectory: "/tmp/owned/opencode")
        _ = try await client.resume(id: "ses_fixture", directory: "/tmp/project")
        await fixture.setWrongReceipt()
        await #expect(throws: OpenCodeError.invalidResponse) {
            _ = try await client.firstInput(sessionID: "ses_fixture", messageID: "msg_one", text: "approved input")
        }
        await #expect(throws: OpenCodeError.indeterminate) {
            _ = try await client.firstInput(sessionID: "ses_fixture", messageID: "msg_one", text: "approved input")
        }
        let requests = await fixture.allRequests()
        #expect(requests.filter { $0.url!.path.hasSuffix("/prompt") }.count == 1)
    }

}
