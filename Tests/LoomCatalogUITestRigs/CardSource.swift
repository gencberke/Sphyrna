import AppKit
import Foundation
import LoomCore
import SwiftUI
import Synchronization
import Testing
@testable import LoomChat
@testable import LoomCatalogUI
import LoomTestSupport

/// A live source that records the answers the cards send, and can be made to fail or to take its time.
actor CardSource: ChatLiveSource {
    private(set) var answers: [(requestID: String, answer: ChatRequestAnswer)] = []
    private(set) var resumes = 0
    var failure: Error?
    var delay: Duration?

    func modelChanges() -> ChatModelChanges { ChatModelChanges(changes: AsyncStream { $0.finish() }) }
    func snapshotChange() -> ModelChange { TurnModel(source: .live).snapshot(sequence: 0, hasOlder: false) }
    func liveState() -> ChatLiveState { ChatLiveState(sessionID: UUID()) }
    func updates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    func answer(requestID: String, _ answer: ChatRequestAnswer) async throws {
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        answers.append((requestID, answer))
    }

    func resume() async throws { resumes += 1 }

    func fail(with error: Error?) { failure = error }
    func slow(_ value: Duration?) { delay = value }
}
