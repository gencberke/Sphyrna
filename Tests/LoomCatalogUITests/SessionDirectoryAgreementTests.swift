import Foundation
import Testing
@testable import LoomCatalogUI
import LoomCore

/// R2: the session directory's state word and the sidebar's `SessionIndicator` read the same record and live state and must
/// agree. The directory has its own pure mapping in LoomCore (LoomCatalogUI is not imported there); this table holds the two
/// together, case by case.
struct SessionDirectoryAgreementTests {
    struct Case: CustomTestStringConvertible, @unchecked Sendable {
        let name: String
        let record: CatalogSession
        let live: SessionViewState?
        var awaitingOpenApproval = false
        let indicator: SessionIndicator
        let word: SessionStateWord
        var testDescription: String { name }
    }

    private static func record(_ lifecycle: SessionLifecycle = .active) -> CatalogSession {
        CatalogSession(
            session: ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: nil,
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: 0),
            lifecycle: lifecycle, pinned: false)
    }

    private static func live(_ activity: AgentActivity?, pending: Int = 0, lifecycle: SessionLifecycle? = nil,
                             edit: (inout SessionViewState) -> Void = { _ in }) -> SessionViewState {
        var state = SessionViewState(
            status: activity.map { ProviderWorkState(activity: $0, pendingProviderWorkCount: pending) },
            lifecycle: lifecycle, runID: UUID())
        edit(&state)
        return state
    }

    private static let request = ProviderPendingRequest(
        requestID: "r", toolUseID: nil, kind: .approval, toolName: "Bash", summary: "ls", arrivedAt: nil)

    static let cases: [Case] = [
        Case(name: "working", record: record(), live: live(.working), indicator: .working, word: .working),
        Case(name: "background work after a finished turn", record: record(), live: live(.turnComplete, pending: 2),
             indicator: .working, word: .working),
        Case(name: "hook approval", record: record(), live: live(.waitingForApproval),
             indicator: .waitingForApproval, word: .needsApproval),
        Case(name: "open-session request", record: record(), live: live(.working), awaitingOpenApproval: true,
             indicator: .waitingForApproval, word: .needsApproval),
        Case(name: "a card waiting after a result", record: record(), live: live(.turnComplete) { $0.pendingRequests = [request] },
             indicator: .waitingForApproval, word: .needsApproval),
        Case(name: "waiting for you", record: record(), live: live(.waitingForInput),
             indicator: .waitingForInput, word: .waiting),
        Case(name: "waiting acknowledged", record: record(), live: live(.waitingForInput) { $0.waitingAcknowledged = true },
             indicator: .ready, word: .ready),
        Case(name: "state unknown, no status", record: record(), live: live(nil), indicator: .unknown, word: .unknown),
        Case(name: "state unknown, unknown activity", record: record(), live: live(.unknown), indicator: .unknown, word: .unknown),
        Case(name: "failed", record: record(), live: live(.failed("x")), indicator: .failed("x"), word: .failed),
        Case(name: "stop not verified", record: record(), live: live(.working) { $0.stopFailure = "still there" },
             indicator: .stopUnverified("still there"), word: .problem),
        Case(name: "problem", record: record(), live: live(.working) { $0.issue = "lost" },
             indicator: .problem("lost"), word: .problem),
        Case(name: "problem without a run", record: record(.idle), live: SessionViewState(issue: "gone"),
             indicator: .problem("gone"), word: .problem),
        Case(name: "identity unclear", record: record(), live: live(.working) { $0.identity = .ambiguous },
             indicator: .identityUnclear, word: .unknown),
        Case(name: "finished, unviewed, live", record: record(), live: live(.turnComplete) { $0.unviewedCompletion = true },
             indicator: .unviewedCompletion, word: .finished),
        Case(name: "finished, unviewed, run over", record: record(.idle), live: SessionViewState(unviewedCompletion: true),
             indicator: .unviewedCompletion, word: .finished),
        Case(name: "ready after a seen turn", record: record(), live: live(.turnComplete), indicator: .ready, word: .ready),
        Case(name: "ready at the prompt", record: record(), live: live(.atPrompt), indicator: .ready, word: .ready),
        Case(name: "idle from the record", record: record(.idle), live: nil, indicator: .idle, word: .idle),
        Case(name: "idle from the hub", record: record(.active), live: SessionViewState(lifecycle: .idle),
             indicator: .idle, word: .idle),
        Case(name: "stale from the record", record: record(.stale), live: nil, indicator: .stale, word: .stale),
        Case(name: "stale from the hub", record: record(.idle), live: SessionViewState(lifecycle: .stale),
             indicator: .stale, word: .stale),
        Case(name: "ended with the run", record: record(.active), live: nil, indicator: .ended, word: .stopped),
        Case(name: "the provider's session ended", record: record(), live: live(.sessionEnded("bye")),
             indicator: .ended, word: .stopped),
        Case(name: "an open request on a session with no run", record: record(.idle), live: nil, awaitingOpenApproval: true,
             indicator: .idle, word: .idle),
    ]

    @Test(arguments: cases) func theDirectoryWordAndTheIndicatorAgree(_ item: Case) {
        let indicator = SessionIndicator(record: item.record, live: item.live, awaitingOpenApproval: item.awaitingOpenApproval)
        #expect(indicator == item.indicator, "\(item.name): the table's indicator")
        let word = SessionStateWord.of(record: item.record, live: item.live, awaitingOpenApproval: item.awaitingOpenApproval)
        #expect(word == item.word, "\(item.name): the directory's word")
        #expect(Self.word(for: indicator) == word, "\(item.name): the documented mapping")
    }

    /// The table reaches every indicator case and every state word.
    @Test func theTableCoversEveryIndicatorCaseAndEveryWord() {
        func kind(_ indicator: SessionIndicator) -> String {
            switch indicator {
            case .working: "working"
            case .waitingForApproval: "waitingForApproval"
            case .waitingForInput: "waitingForInput"
            case .unknown: "unknown"
            case .failed: "failed"
            case .stopUnverified: "stopUnverified"
            case .problem: "problem"
            case .identityUnclear: "identityUnclear"
            case .unviewedCompletion: "unviewedCompletion"
            case .ready: "ready"
            case .idle: "idle"
            case .stale: "stale"
            case .ended: "ended"
            }
        }
        let all: Set<String> = ["working", "waitingForApproval", "waitingForInput", "unknown", "failed", "stopUnverified",
                                "problem", "identityUnclear", "unviewedCompletion", "ready", "idle", "stale", "ended"]
        #expect(Set(Self.cases.map { kind($0.indicator) }) == all)
        #expect(Set(Self.cases.map(\.word)) == Set(SessionStateWord.allCases))
    }

    /// The mapping the directory's note states: the indicator's `.ended` is `stopped`, `.unviewedCompletion` is `finished`,
    /// `.identityUnclear` and `.unknown` are `unknown`, `.stopUnverified` and `.problem` are `problem`.
    private static func word(for indicator: SessionIndicator) -> SessionStateWord {
        switch indicator {
        case .working: .working
        case .waitingForApproval: .needsApproval
        case .waitingForInput: .waiting
        case .unknown, .identityUnclear: .unknown
        case .failed: .failed
        case .stopUnverified, .problem: .problem
        case .unviewedCompletion: .finished
        case .ready: .ready
        case .idle: .idle
        case .stale: .stale
        case .ended: .stopped
        }
    }
}
