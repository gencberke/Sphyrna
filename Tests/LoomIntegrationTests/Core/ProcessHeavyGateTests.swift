import Darwin
import Foundation
import Testing
import LoomTestSupport

/// The process-heavy suites of a test target run one at a time (`ProcessHeavy`): each test runs inside its suite's gate, a
/// lock on the test process's lock file. If a test ran outside it, the heavy suites ran side by side and loaded the machine
/// until the timing of stop, launch and hook tests failed at random.
@Suite(.processHeavy)
struct ProcessHeavyGateTests {
    /// Whether another descriptor of the lock file can take the lock now (and lets it go again).
    private static func gateIsFree() -> Bool {
        let descriptor = open(ProcessHeavyGate.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }

    @Test func aTestOfAProcessHeavySuiteRunsInsideItsSuitesGate() {
        #expect(ProcessHeavyGate.held, "the suite's scope ran around the test")
        #expect(!Self.gateIsFree(), "the lock file is locked while the test runs")
    }

    @Test(arguments: [1, 2])
    func eachCaseOfAParameterizedTestRunsInsideTheGateToo(_ value: Int) {
        #expect(ProcessHeavyGate.held && !Self.gateIsFree(), "case \(value)")
    }

    @Suite struct Nested {
        @Test func aNestedSuitesTestRunsInsideTheOuterSuitesGate() {
            #expect(ProcessHeavyGate.held && !ProcessHeavyGateTests.gateIsFree())
        }
    }
}
