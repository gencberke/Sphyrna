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

/// One server/run and its admitted input receipts. Only an exact delivered
/// input correlated with an observed busy period can carry its native outcome;
/// a last outcome or an uncorrelated event never completes an app round.
public actor OpenCodeClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private enum Admission {
        case pending, uncertain, accepted
    }
    private struct Receipt {
        let sessionID: String
        let roundID: UUID
        let fingerprint: SHA256.Digest
        var admission: Admission
    }

    public nonisolated let serverURL: URL
    private let transport: Transport
    private let password: String
    private let lease: OpenCodeHTTPLease
    private let profile: OpenCodeProfileBinding?
    private let expectedPID: Int32?
    private let streamOwner: ProcessIdentity?
    private var feed: OpenCodeLiveFeed?
    private var eventStream: OpenCodeEventStream?
    private var eventOpening: Task<OpenCodeEventStream, any Error>?
    private var eventClosing: Task<Void, Never>?
    private var selectedWasNew = false
    private var verified = false
    private var closed = false
    private var createAttempted = false
    private var selectedID: String?
    private var selectedDirectory: String?
    private var resuming = false
    private var firstMessageID: String?
    private var receipts: [String: Receipt] = [:]
    private static let receiptLimit = 128

    public init(serverURL: URL, password: String, leader: ProcessIdentity, profileProof: OpenCodeProfileProof,
                executable: String, environment: [String: String], workingDirectory: String,
                timeout: TimeInterval = 5) throws {
        guard OpenCodeLaunchProfile.validServerURL(serverURL), OpenCodeLaunchProfile.validPassword(password),
              timeout.isFinite, timeout > 0, timeout <= 30 else { throw OpenCodeError.invalidTarget }
        self.serverURL = serverURL; self.password = password; expectedPID = leader.pid; streamOwner = leader
        profile = OpenCodeProfileBinding(proof: profileProof, executable: executable,
                                         environment: environment, directory: workingDirectory)
        let lease = OpenCodeHTTPLease()
        self.lease = lease
        transport = { request in try await OpenCodeHTTP.request(request, leader: leader, timeout: timeout, lease: lease) }
    }

    /// Only a test fixture can replace the real, ownership-checked transport.
    init(base: URL, password: String, liveFeed: OpenCodeLiveFeed? = nil,
         eventStream: OpenCodeEventStream? = nil, leader: ProcessIdentity? = nil, transport: @escaping Transport) {
        serverURL = base; self.password = password; self.transport = transport; lease = OpenCodeHTTPLease(); profile = nil
        expectedPID = leader?.pid; streamOwner = leader; feed = liveFeed; self.eventStream = eventStream
    }

    /// Test transport with the same profile binding used by the production initializer.
    init(base: URL, password: String, profileProof: OpenCodeProfileProof, executable: String,
         environment: [String: String], workingDirectory: String, liveFeed: OpenCodeLiveFeed? = nil,
         transport: @escaping Transport) {
        serverURL = base; self.password = password; self.transport = transport; lease = OpenCodeHTTPLease()
        expectedPID = nil; streamOwner = nil; feed = liveFeed
        profile = OpenCodeProfileBinding(proof: profileProof, executable: executable,
                                         environment: environment, directory: workingDirectory)
    }

    public func close() async {
        if let eventClosing { await eventClosing.value; return }
        guard !closed else { return }
        closed = true; verified = false; lease.revoke()
        let opening = eventOpening
        opening?.cancel()
        let active = eventStream
        eventStream = nil
        feed?.didDisconnect()
        let closing = Task {
            if let opening, let opened = try? await opening.value { await opened.close() }
            if let active { await active.close() }
        }
        eventClosing = closing
        await closing.value
        eventClosing = nil
    }

    deinit {
        lease.revoke()
        eventOpening?.cancel()
        eventStream?.cancel()
        feed?.didDisconnect()
    }

    public func verify(pid: Int32, version: String, temporaryDirectory: String) async throws {
        guard eventStream == nil, eventOpening == nil else { throw OpenCodeError.conflict }
        verified = false
        try await validateProfile()
        guard pid > 0, expectedPID == nil || expectedPID == pid, !version.isEmpty, temporaryDirectory.hasPrefix("/"),
              profile == nil || profile?.proof.roots.tmp == temporaryDirectory,
              OpenCodeLaunchProfile.validServerURL(serverURL), OpenCodeLaunchProfile.validPassword(password) else {
            throw OpenCodeError.invalidTarget
        }
        let data = try await request(path: "/api/info", method: "GET")
        guard let info = try? JSONDecoder().decode(ServerInfo.self, from: data),
              info.pid == pid, info.version == version, info.urls.contains(serverURL.absoluteString),
              info.paths.tmp == temporaryDirectory, !closed else { throw OpenCodeError.unverifiedServer }
        verified = true
    }

    /// Opens the event subscription before any create/resume or input. The
    /// connected event proves the server installed its volatile subscriber.
    /// The caller supplies the actual application session and run identity.
    public func openLive(appSessionID: UUID, runID: UUID, timeout: TimeInterval = 5) async throws -> OpenCodeLiveFeed {
        try await validateProfile()
        try requireVerified()
        guard let owner = streamOwner, feed == nil, eventOpening == nil, selectedID == nil else {
            throw OpenCodeError.conflict
        }
        let next = OpenCodeLiveFeed(appSessionID: appSessionID, runID: runID)
        let url = serverURL, secret = password, requestLease = lease
        let opening = Task {
            try await OpenCodeEventStream.open(
                serverURL: url, password: secret, owner: owner, timeout: timeout,
                onConnected: { next.didConnect() },
                onEvent: { next.receive($0) },
                onDisconnect: { requestLease.revoke(); next.didDisconnect() }
            )
        }
        eventOpening = opening
        do {
            let stream = try await withTaskCancellationHandler {
                try await opening.value
            } onCancel: { opening.cancel() }
            eventOpening = nil
            if Task.isCancelled {
                await stream.close()
                throw CancellationError()
            }
            guard !closed, next.isConnected else {
                await stream.close()
                throw OpenCodeError.unavailable
            }
            eventStream = stream
            feed = next
            return next
        } catch {
            eventOpening = nil
            throw error
        }
    }

    public func create(directory: String, model: OpenCodeModel?,
                       permissions: [OpenCodePermissionRule]? = nil) async throws -> OpenCodeSession {
        try await validateProfile()
        try requireVerified()
        guard let feed, feed.isConnected else { throw OpenCodeError.unavailable }
        guard selectedID == nil, !createAttempted, !resuming else { throw OpenCodeError.conflict }
        guard validDirectory(directory), profile == nil || profile?.directory == directory, model?.valid != false,
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
        selectedWasNew = true
        if (try? feed.bind(nativeSessionID: session.id)) == nil {
            feed.didDisconnect()
            if let eventStream { await eventStream.close() }
        }
        return session
    }

    public func resume(id: String, directory: String) async throws -> OpenCodeSession {
        try await validateProfile()
        try requireVerified()
        guard let feed, feed.isConnected else { throw OpenCodeError.unavailable }
        guard OpenCodeLaunchProfile.validID(id, prefix: "ses"), validDirectory(directory),
              profile == nil || profile?.directory == directory, !createAttempted,
              selectedID == nil || selectedID == id, !resuming else { throw OpenCodeError.invalidTarget }
        let alreadyBound = selectedID == id
        resuming = true
        defer { resuming = false }
        let result = try await request(path: "/api/session/\(id)", method: "GET")
        guard !closed, let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: result),
              let session = envelope.data.session, session.id == id, session.directory == directory else {
            throw OpenCodeError.invalidResponse
        }
        selectedID = session.id
        selectedDirectory = session.directory
        selectedWasNew = false
        if !alreadyBound, (try? feed.bind(nativeSessionID: session.id)) == nil {
            feed.didDisconnect()
            if let eventStream { await eventStream.close() }
        }
        return session
    }

    /// Sends a new draft's one opening input through the API. The TUI is always
    /// launched without `--prompt`; a lost reply remains indeterminate.
    public func firstInput(sessionID: String, messageID: String, roundID: UUID, text: String) async throws -> String {
        try await validateProfile()
        guard selectedWasNew else { throw OpenCodeError.invalidTarget }
        let body = try inputBody(sessionID: sessionID, messageID: messageID, text: text)
        return try await admitInput(sessionID: sessionID, messageID: messageID, roundID: roundID, text: text,
                                    body: body, first: true)
    }

    /// Explicit subsequent input only; repeated IDs with identical accepted
    /// payloads return the recorded receipt without sending. The runtime must
    /// persist its own authorization/receipt fence across process restarts.
    public func submitInput(sessionID: String, messageID: String, roundID: UUID, text: String) async throws -> String {
        try await validateProfile()
        guard !selectedWasNew || firstMessageID != nil else { throw OpenCodeError.unavailable }
        let body = try inputBody(sessionID: sessionID, messageID: messageID, text: text)
        return try await admitInput(sessionID: sessionID, messageID: messageID, roundID: roundID, text: text,
                                    body: body, first: false)
    }

    private func inputBody(sessionID: String, messageID: String, text: String) throws -> Data {
        try requireVerified()
        guard feed?.isConnected == true else { throw OpenCodeError.unavailable }
        guard selectedID == sessionID, OpenCodeLaunchProfile.validID(messageID, prefix: "msg_"),
              !text.isEmpty, text.utf8.count <= 48 * 1024, !text.contains("\0") else { throw OpenCodeError.invalidTarget }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(PromptRequest(id: messageID, text: text))
        guard body.count <= OpenCodeHTTP.requestLimit else { throw OpenCodeError.invalidTarget }
        return body
    }

    private func admitInput(sessionID: String, messageID: String, roundID: UUID, text: String,
                            body: Data, first: Bool) async throws -> String {
        let fingerprint = SHA256.hash(data: body)
        if let receipt = receipts[messageID] {
            guard receipt.sessionID == sessionID, receipt.roundID == roundID,
                  receipt.fingerprint == fingerprint else { throw OpenCodeError.conflict }
            switch receipt.admission {
            case .accepted: return messageID
            case .pending, .uncertain: throw OpenCodeError.indeterminate
            }
        }
        guard let feed, feed.isConnected else { throw OpenCodeError.unavailable }
        if first, let firstMessageID, firstMessageID != messageID { throw OpenCodeError.conflict }
        guard receipts.count < Self.receiptLimit else { throw OpenCodeError.unavailable }
        try feed.begin(roundID: roundID, inputID: messageID, requireCreation: first)
        if first { firstMessageID = messageID }
        receipts[messageID] = Receipt(sessionID: sessionID, roundID: roundID, fingerprint: fingerprint, admission: .pending)
        do {
            let result = try await request(path: "/api/session/\(sessionID)/prompt", method: "POST", body: body)
            guard !closed, let response = try? JSONDecoder().decode(PromptEnvelope.self, from: result),
                  response.data.id == messageID, response.data.sessionID == sessionID,
                  response.data.type == "user", response.data.payload.text == text else { throw OpenCodeError.invalidResponse }
            receipts[messageID]?.admission = .accepted
            try? feed.receipt(inputID: messageID)
            return messageID
        } catch {
            receipts[messageID]?.admission = .uncertain
            feed.indeterminate(inputID: messageID)
            throw error
        }
    }

    /// Native interruption covers the whole session, not an exact turn. The
    /// runtime must first fence terminal/API input and establish that no newer
    /// work can be canceled; F1's exact-round interrupt cannot assume this.
    public func interruptForStoppedInput(sessionID: String) async throws -> Bool {
        try await validateProfile()
        try requireVerified()
        guard feed?.isConnected == true else { throw OpenCodeError.unavailable }
        guard selectedID == sessionID else { throw OpenCodeError.invalidTarget }
        let result = try await request(path: "/api/session/\(sessionID)/interrupt", method: "POST", body: Data("{}".utf8))
        guard !closed, let value = try? JSONDecoder().decode(InterruptAnswer.self, from: result) else {
            throw OpenCodeError.invalidResponse
        }
        return value.interrupted
    }

    /// A verified create/resume must precede any terminal attachment.
    public func terminalProfile(directory: String, environment: [String: String]) async throws -> ProviderLaunchProfile {
        try await validateProfile(environment: environment)
        try requireVerified()
        guard let feed, feed.isConnected else { throw OpenCodeError.unavailable }
        guard !selectedWasNew || firstMessageID != nil || feed.permitsFirstAttachment else {
            throw OpenCodeError.unavailable
        }
        guard let selectedID, selectedDirectory == directory else { throw OpenCodeError.invalidTarget }
        return try OpenCodeLaunchProfile.terminal(serverURL: serverURL, sessionID: selectedID,
                                                  directory: directory, environment: environment, password: password)
    }

    private func validateProfile(environment: [String: String]? = nil) async throws {
        if let profile {
            try await profile.proof.validate(executable: profile.executable,
                                             environment: environment ?? profile.environment,
                                             workingDirectory: profile.directory)
        }
        try Task.checkCancellation()
    }

    private func requireVerified() throws {
        guard !closed, !lease.isRevoked else { throw OpenCodeError.closed }
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

private struct OpenCodeProfileBinding: Sendable {
    let proof: OpenCodeProfileProof
    let executable: String
    let environment: [String: String]
    let directory: String
}
