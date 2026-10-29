import Darwin
import Foundation
import Testing
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

// V24: the Ask mode (D-63, spikes S9 and S9b) on the fake provider's mirror of the CLI's rules, and the follow-ups of the
// checkpoint review that live in the driver. Ask is the CLI's `dontAsk` plus deny rules for the edit tools plus an output style,
// all set by control requests; the fake keeps the launch layer and the live layer apart, the way the CLI does. Nothing here
// talks to a real Claude.

// MARK: Pure parts

struct ChatAskModePureTests {
    @Test func theCliTakesAskAsDontAskAndKeepsEveryOtherWord() {
        #expect(ChatAskMode.mode.rawValue == "dontAsk" && ClaudePermissionMode.ask.cliValue == "dontAsk")
        #expect(ClaudePermissionMode.allCases.filter { $0 != .ask }.allSatisfy { $0.cliValue == $0.rawValue })
    }
}

// MARK: On the fake provider
