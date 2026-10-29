import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

// V24 fix round (the strict review of 18 Oct): the mode chain, Ask's failure paths, the markers, the effort and the
// withdrawal of a retried message. Everything runs on the fake provider's mirror of the CLI's rules.

// MARK: Pure parts

struct ChatAskFixRoundPureTests {
    /// M2: an effort a model does not offer is clamped to the nearest level below it (else the lowest), and a model without
    /// effort takes none.
    @Test func anEffortTheModelLacksIsClampedOrDropped() {
        let sonnet = ["low", "medium", "high"]
        #expect(ChatEffort.clamped("max", to: sonnet) == "high")
        #expect(ChatEffort.clamped("xhigh", to: sonnet) == "high")
        #expect(ChatEffort.clamped("medium", to: sonnet) == "medium")
        #expect(ChatEffort.clamped("low", to: ["medium", "high"]) == "medium")
        #expect(ChatEffort.clamped("high", to: []) == nil)
        #expect(ChatEffort.clamped("max", to: ["low", "medium", "high", "xhigh", "max"]) == "max")
    }
}

// MARK: On the fake provider
