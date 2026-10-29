import Foundation
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

struct SessionTaskRequestCardTests {
    @Test func delegationCardDisclosesTheActualGrant() {
        let grant = OpenSessionTaskRequest(taskID: UUID(), childID: UUID(), operationID: UUID())
        let request = OpenSessionRequest(requesterID: UUID(), projectID: UUID(), projectName: "Project",
            title: "Review", message: "Review the change", choices: HarnessLaunchChoices(harness: .codex), task: grant)
        let content = OpenRequestBoxContent(request)
        #expect(content.heading == "Delegate a task?")
        #expect(content.taskBounds == "Up to 3 child inputs, 6 parent wakes, for 1 hour.")
        #expect(content.actions == [.deny, .openSession])
    }
}
