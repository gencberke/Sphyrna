import CryptoKit
import Foundation

public struct OpenCodeModel: Codable, Equatable, Sendable {
    public let providerID: String
    public let id: String
    public let variant: String?
    public init(providerID: String, id: String, variant: String? = nil) {
        self.providerID = providerID; self.id = id; self.variant = variant
    }

    fileprivate var valid: Bool {
        [providerID, id].allSatisfy(Self.validPart) && (variant.map(Self.validPart) ?? true)
    }
    private static func validPart(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
    }
}

/// Native rules only. A caller must supply rules explicitly authorized by the
/// user; this type does not claim any product mode is an OS sandbox.
public struct OpenCodePermissionRule: Codable, Equatable, Sendable {
    public enum Effect: String, Codable, Sendable { case ask, deny, allow }
    public let action: String
    public let resource: String
    public let effect: Effect
    public init(action: String, resource: String, effect: Effect) {
        self.action = action; self.resource = resource; self.effect = effect
    }
    fileprivate var valid: Bool {
        !action.isEmpty && !resource.isEmpty && action.utf8.count <= 256 && resource.utf8.count <= 4096 &&
            !action.contains("\0") && !resource.contains("\0")
    }
}

public struct OpenCodeSession: Equatable, Sendable {
    public let id: String
    public let directory: String
    public let model: OpenCodeModel?
    public let permissions: [OpenCodePermissionRule]?
}

/// One server/run and its admitted input receipts. This client never turns a
/// last outcome or a volatile SSE event into a completed app round.
public actor OpenCodeClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private enum Admission {
        case pending, uncertain, accepted
    }
    private struct Receipt {
        let sessionID: String
        let fingerprint: SHA256.Digest
        var admission: Admission
    }

    public nonisolated let serverURL: URL
    private let transport: Transport
    private let password: String
    private let lease: OpenCodeHTTPLease
    private var verified = false
    private var closed = false
    private var createAttempted = false
    private var selectedID: String?
    private var selectedDirectory: String?
    private var resuming = false
    private var firstMessageID: String?
    private var receipts: [String: Receipt] = [:]
    private static let receiptLimit = 128

    public init(serverURL: URL, password: String, leader: ProcessIdentity, timeout: TimeInterval = 5) throws {
        guard OpenCodeLaunchProfile.validServerURL(serverURL), OpenCodeLaunchProfile.validPassword(password),
              timeout.isFinite, timeout > 0, timeout <= 30 else { throw OpenCodeError.invalidTarget }
        self.serverURL = serverURL; self.password = password
        let lease = OpenCodeHTTPLease()
        self.lease = lease
        transport = { request in try await OpenCodeHTTP.request(request, leader: leader, timeout: timeout, lease: lease) }
    }

    /// Only a test fixture can replace the real, ownership-checked transport.
    init(base: URL, password: String, transport: @escaping Transport) {
        serverURL = base; self.password = password; self.transport = transport; lease = OpenCodeHTTPLease()
    }

    public func close() { closed = true; verified = false; lease.revoke() }

    public func verify(pid: Int32, version: String, temporaryDirectory: String) async throws {
        verified = false
        guard pid > 0, !version.isEmpty, temporaryDirectory.hasPrefix("/"),
              OpenCodeLaunchProfile.validServerURL(serverURL), OpenCodeLaunchProfile.validPassword(password) else {
            throw OpenCodeError.invalidTarget
        }
        let data = try await request(path: "/api/info", method: "GET")
        guard let info = try? JSONDecoder().decode(ServerInfo.self, from: data),
              info.pid == pid, info.version == version, info.urls.contains(serverURL.absoluteString),
              info.paths.tmp == temporaryDirectory, !closed else { throw OpenCodeError.unverifiedServer }
        verified = true
    }

    public func create(directory: String, model: OpenCodeModel?,
                       permissions: [OpenCodePermissionRule]? = nil) async throws -> OpenCodeSession {
        try requireVerified()
        guard selectedID == nil, !createAttempted, !resuming else { throw OpenCodeError.conflict }
        guard validDirectory(directory), model?.valid != false,
              permissions.map({ $0.count <= 128 && $0.allSatisfy(\.valid) }) ?? true else { throw OpenCodeError.invalidTarget }
        // Never retry a create whose response was lost: the server may have made it.
        createAttempted = true
        let data = try JSONEncoder().encode(CreateRequest(location: .init(directory: directory), model: model,
                                                           permissions: permissions))
        let result = try await request(path: "/api/session", method: "POST", body: data)
        guard !closed, let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: result),
              let session = envelope.data.session, session.directory == directory,
              model == nil || session.model == model,
              permissions == nil || session.permissions == permissions else { throw OpenCodeError.invalidResponse }
        selectedID = session.id
        selectedDirectory = session.directory
        return session
    }

    public func resume(id: String, directory: String) async throws -> OpenCodeSession {
        try requireVerified()
        guard OpenCodeLaunchProfile.validID(id, prefix: "ses"), validDirectory(directory), !createAttempted,
              selectedID == nil || selectedID == id, !resuming else { throw OpenCodeError.invalidTarget }
        resuming = true
        defer { resuming = false }
        let result = try await request(path: "/api/session/\(id)", method: "GET")
        guard !closed, let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: result),
              let session = envelope.data.session, session.id == id, session.directory == directory else {
            throw OpenCodeError.invalidResponse
        }
        selectedID = session.id
        selectedDirectory = session.directory
        return session
    }

    /// Sends a new draft's one opening input through the API. The TUI is always
    /// launched without `--prompt`; a lost reply remains indeterminate.
    public func firstInput(sessionID: String, messageID: String, text: String) async throws -> String {
        let body = try inputBody(sessionID: sessionID, messageID: messageID, text: text)
        if let firstMessageID, firstMessageID != messageID { throw OpenCodeError.conflict }
        firstMessageID = messageID
        return try await admitInput(sessionID: sessionID, messageID: messageID, text: text, body: body)
    }

    /// Explicit subsequent input only; repeated IDs with identical accepted
    /// payloads return the recorded receipt without sending. The runtime must
    /// persist its own authorization/receipt fence across process restarts.
    public func submitInput(sessionID: String, messageID: String, text: String) async throws -> String {
        let body = try inputBody(sessionID: sessionID, messageID: messageID, text: text)
        return try await admitInput(sessionID: sessionID, messageID: messageID, text: text, body: body)
    }

    private func inputBody(sessionID: String, messageID: String, text: String) throws -> Data {
        try requireVerified()
        guard selectedID == sessionID, OpenCodeLaunchProfile.validID(messageID, prefix: "msg_"),
              !text.isEmpty, text.utf8.count <= 48 * 1024, !text.contains("\0") else { throw OpenCodeError.invalidTarget }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(PromptRequest(id: messageID, text: text))
        guard body.count <= OpenCodeHTTP.requestLimit else { throw OpenCodeError.invalidTarget }
        return body
    }

    private func admitInput(sessionID: String, messageID: String, text: String, body: Data) async throws -> String {
        let fingerprint = SHA256.hash(data: body)
        if let receipt = receipts[messageID] {
            guard receipt.sessionID == sessionID, receipt.fingerprint == fingerprint else { throw OpenCodeError.conflict }
            switch receipt.admission {
            case .accepted: return messageID
            case .pending, .uncertain: throw OpenCodeError.indeterminate
            }
        }
        guard receipts.count < Self.receiptLimit else { throw OpenCodeError.unavailable }
        receipts[messageID] = Receipt(sessionID: sessionID, fingerprint: fingerprint, admission: .pending)
        do {
            let result = try await request(path: "/api/session/\(sessionID)/prompt", method: "POST", body: body)
            guard !closed, let response = try? JSONDecoder().decode(PromptEnvelope.self, from: result),
                  response.data.id == messageID, response.data.sessionID == sessionID,
                  response.data.type == "user", response.data.payload.text == text else { throw OpenCodeError.invalidResponse }
            receipts[messageID]?.admission = .accepted
            return messageID
        } catch {
            receipts[messageID]?.admission = .uncertain
            throw error
        }
    }

    /// Native interruption covers the whole session, not an exact turn. The
    /// runtime must first fence terminal/API input and establish that no newer
    /// work can be canceled; F1's exact-round interrupt cannot assume this.
    public func interruptForStoppedInput(sessionID: String) async throws -> Bool {
        try requireVerified()
        guard selectedID == sessionID else { throw OpenCodeError.invalidTarget }
        let result = try await request(path: "/api/session/\(sessionID)/interrupt", method: "POST", body: Data("{}".utf8))
        guard !closed, let value = try? JSONDecoder().decode(InterruptAnswer.self, from: result) else {
            throw OpenCodeError.invalidResponse
        }
        return value.interrupted
    }

    /// A verified create/resume must precede any terminal attachment.
    public func terminalProfile(directory: String, environment: [String: String]) throws -> ProviderLaunchProfile {
        try requireVerified()
        guard let selectedID, selectedDirectory == directory else { throw OpenCodeError.invalidTarget }
        return try OpenCodeLaunchProfile.terminal(serverURL: serverURL, sessionID: selectedID,
                                                  directory: directory, environment: environment, password: password)
    }

    private func requireVerified() throws {
        guard !closed else { throw OpenCodeError.closed }
        guard verified else { throw OpenCodeError.unverifiedServer }
    }

    private func validDirectory(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.contains("\0")
    }

    private func request(path: String, method: String, body: Data? = nil) async throws -> Data {
        guard !closed, var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw OpenCodeError.closed
        }
        components.path = path
        guard let url = components.url else { throw OpenCodeError.invalidTarget }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let credential = Data("opencode:\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        guard !closed else { throw OpenCodeError.closed }
        guard response.url == url, (200...299).contains(response.statusCode) else { throw OpenCodeError.unverifiedServer }
        guard data.count <= OpenCodeHTTP.bodyLimit else { throw OpenCodeError.responseTooLarge }
        return data
    }

    private struct ServerInfo: Decodable {
        struct Paths: Decodable { let tmp: String }
        let version: String; let pid: Int32; let urls: [String]; let paths: Paths
    }
    private struct CreateRequest: Encodable {
        struct Location: Encodable { let directory: String }
        let location: Location; let model: OpenCodeModel?; let permissions: [OpenCodePermissionRule]?
    }
    private struct SessionEnvelope: Decodable {
        struct Info: Decodable {
            struct Location: Decodable { let directory: String }
            let id: String; let parentID: String?; let location: Location
            let model: OpenCodeModel?; let permissions: [OpenCodePermissionRule]?
            var session: OpenCodeSession? {
                guard parentID == nil, OpenCodeLaunchProfile.validID(id, prefix: "ses"), location.directory.hasPrefix("/") else { return nil }
                return OpenCodeSession(id: id, directory: location.directory, model: model, permissions: permissions)
            }
        }
        let data: Info
    }
    private struct PromptRequest: Encodable { let id: String; let text: String }
    private struct PromptEnvelope: Decodable {
        struct User: Decodable {
            struct Payload: Decodable { let text: String }
            let id: String; let sessionID: String; let type: String; let payload: Payload
        }
        let data: User
    }
    private struct InterruptAnswer: Decodable { let interrupted: Bool }
}
