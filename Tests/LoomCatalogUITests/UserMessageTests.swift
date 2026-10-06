import Foundation
import Testing
@testable import LoomCatalogUI

/// `CatalogModel.userMessage(for:context:)`: what the banner says when an action fails.
struct UserMessageTests {
    private struct Opaque: Error {
        let code = 7
    }

    private struct Described: Error, CustomStringConvertible {
        var description: String { "The working directory no longer exists: /tmp/x" }
    }

    @Test func aFoundationErrorBecomesItsOwnSentenceWithoutTheRawDump() {
        let error = CocoaError(.fileWriteNoPermission)
        let text = CatalogModel.userMessage(for: error, context: "The project could not be added")
        #expect(text.hasPrefix("The project could not be added. "))
        #expect(text.contains(error.localizedDescription))
        #expect(!text.contains("Error Domain"))
        #expect(!text.contains("CocoaError"))
        #expect(text.hasSuffix("."))
    }

    @Test func aLoomErrorKeepsItsOwnReadableDescription() {
        let text = CatalogModel.userMessage(for: Described(), context: "Claude could not be started")
        #expect(text == "Claude could not be started. The working directory no longer exists: /tmp/x.")
    }

    @Test func anUnknownErrorGetsAGenericSentenceAndThenTheTechnicalDetail() {
        let text = CatalogModel.userMessage(for: Opaque(), context: "The title could not be saved")
        #expect(text.hasPrefix("The title could not be saved. Something unexpected went wrong."))
        #expect(text.contains("Details: "))
        #expect(text.contains("Opaque"))
    }

    @Test func noErrorLeavesJustTheContextSentence() {
        #expect(CatalogModel.userMessage(for: nil, context: "Only an empty project can be removed.")
                == "Only an empty project can be removed.")
    }

    @Test func aDescriptionThatAlreadyEndsInAPeriodIsNotDoubled() {
        struct Sentence: Error, CustomStringConvertible { var description: String { "Nothing was changed." } }
        #expect(CatalogModel.userMessage(for: Sentence(), context: "Stop failed") == "Stop failed. Nothing was changed.")
    }

    @Test func otherSentenceEndingsGetNoExtraPeriod() {
        struct Ending: Error, CustomStringConvertible { let description: String }
        for detail in ["Try again later…", "Is the disk full?", "Not allowed!"] {
            #expect(CatalogModel.userMessage(for: Ending(description: detail), context: "Stop failed") == "Stop failed. \(detail)")
        }
        #expect(CatalogModel.userMessage(for: nil, context: "Wait…") == "Wait…")
        #expect(CatalogModel.userMessage(for: Ending(description: "x"), context: "Really?") == "Really? x.")
    }
}

/// The state line of a conversation record without a live terminal. It must not
/// claim "Working" for a conversation that is not running (the indicator says otherwise).
struct RunStateHeadingTests {
    @Test func theHeadingNamesOnlyWhatLoomKnows() {
        #expect(ConversationDetail.runStateHeading(busy: .starting, canResume: false, isRunning: false) == "Starting…")
        #expect(ConversationDetail.runStateHeading(busy: .resuming, canResume: false, isRunning: false) == "Resuming…")
        #expect(ConversationDetail.runStateHeading(busy: .stopping, canResume: false, isRunning: true) == "Stopping…")
        #expect(ConversationDetail.runStateHeading(busy: nil, canResume: true, isRunning: false) == "Not running")
        #expect(ConversationDetail.runStateHeading(busy: nil, canResume: false, isRunning: true) == "Running")
        #expect(ConversationDetail.runStateHeading(busy: nil, canResume: false, isRunning: false) == "Not available right now")
    }
}
