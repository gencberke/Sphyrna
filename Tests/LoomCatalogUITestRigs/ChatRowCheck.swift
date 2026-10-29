import Testing
@testable import LoomCatalogUI

/// One test's own row check (`ChatRowVerifier`): every rebuild of the presentations it watches is compared with a full
/// rebuild, and it keeps what differed. A test running beside it has its own, so neither turns the other's off. A release
/// build checks nothing (the verifier is debug only), and `expectClean` then asks only that nothing differed.
@MainActor
final class ChatRowCheck {
    private(set) var mismatches: [String] = []
    #if DEBUG
    private var verifier: ChatRowVerifier!
    #endif

    init() {
        #if DEBUG
        verifier = ChatRowVerifier { [weak self] in self?.mismatches.append($0) }
        #endif
    }

    /// Checks the feed's presentation, and the one a new card brings.
    convenience init(_ feed: LiveChatFeed) {
        self.init()
        watch(feed)
    }

    func watch(_ feed: LiveChatFeed) {
        #if DEBUG
        feed.rowVerifier = verifier
        #endif
    }

    func watch(_ presentation: ChatPresentation) {
        #if DEBUG
        presentation.verifier = verifier
        #endif
    }

    #if DEBUG
    /// For a view that makes its presentation itself (`ChatTranscriptView`): `.environment(\.chatRowVerifier, …)`.
    var environmentValue: ChatRowVerifier { verifier }
    #endif

    /// Rebuilds checked so far (0 in a release build).
    var checks: Int {
        #if DEBUG
        verifier.checks
        #else
        0
        #endif
    }

    /// Nothing differed, and (a debug build) the rebuilds were checked at all: a presentation the check never reached fails
    /// here instead of passing unchecked.
    func expectClean(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(mismatches.isEmpty, "\(what): \(mismatches)", sourceLocation: sourceLocation)
        #if DEBUG
        #expect(checks > 0, "\(what): the rebuilds were checked against a full rebuild (\(checks) checks)", sourceLocation: sourceLocation)
        #endif
    }
}
