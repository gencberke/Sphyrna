import Foundation
import Testing
@testable import LoomCore

@Suite struct OpenCodeEventDecoderTests {
    @Test func fragmentedFeedRetainsNativeSessionAndDurableSequence() throws {
        var decoder = OpenCodeEventDecoder()
        let frame = #"data: {"id":"evt_1","type":"session.inbox.delivered","created":1,"durable":{"aggregateID":"ses_one","seq":42,"version":1},"data":{"sessionID":"ses_one","inboxID":"msg_one"}}"# + "\n\n"
        let data = Data(frame.utf8)
        #expect(try decoder.feed(data.prefix(35)).isEmpty)
        let events = try decoder.feed(data.dropFirst(35))
        #expect(events == [OpenCodeEvent(id: "evt_1", type: "session.inbox.delivered", sessionID: "ses_one", sequence: 42, inboxID: "msg_one", version: 1)])
    }

    @Test func malformedAndOversizedFramesFailClosed() throws {
        var malformed = OpenCodeEventDecoder()
        #expect(throws: (any Error).self) { try malformed.feed(Data("data: not-json\n\n".utf8)) }
        var mismatch = OpenCodeEventDecoder()
        let event = #"data: {"id":"evt_1","type":"session.execution.succeeded","created":1,"durable":{"aggregateID":"ses_other","seq":1,"version":1},"data":{"sessionID":"ses_one"}}"# + "\n\n"
        #expect(throws: (any Error).self) { try mismatch.feed(Data(event.utf8)) }
        var huge = OpenCodeEventDecoder()
        #expect(throws: (any Error).self) { try huge.feed(Data(repeating: 65, count: 65_537)) }
    }
}
