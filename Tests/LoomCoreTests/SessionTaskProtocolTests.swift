import Foundation
import Testing
@testable import LoomCore

struct SessionTaskProtocolTests {
    @Test func eventPagesFitTheEncodedBudgetAndKeepEveryExcludedCursor() throws {
        let taskID = UUID()
        let entries = (1...50).map { number in
            SessionTaskEventEntry(cursor: Int64(number), event: SessionTaskEvent(
                id: UUID(), taskID: taskID, roundID: UUID(), nativeTurnID: nil,
                execution: .providerPrompt("prompt-\(number)"), kind: .completed,
                payload: String(repeating: "\u{1}", count: SessionTaskLimits.payloadBytes), occurredAt: Date()))
        }
        let packed = try SessionTaskWirePacking.page(entries, next: entries.last?.cursor)
        #expect(packed.data.count <= SessionTaskWireLimits.replyBytes)
        let page = try JSONDecoder().decode(SessionTaskWirePage.self, from: packed.data)
        #expect(!page.events.isEmpty && page.events.count < entries.count)
        #expect(page.next == page.events.last?.cursor)
        #expect(packed.returnedIDs == page.events.map(\.id))
        #expect(page.events.allSatisfy { $0.decodedPayload == String(repeating: "\u{1}", count: SessionTaskLimits.payloadBytes) })
        var remaining = entries
        var received: [UUID] = []
        while !remaining.isEmpty {
            let chunk = try SessionTaskWirePacking.page(remaining, next: nil)
            #expect(chunk.data.count <= SessionTaskWireLimits.replyBytes)
            let decoded = try JSONDecoder().decode(SessionTaskWirePage.self, from: chunk.data)
            #expect(!decoded.events.isEmpty)
            received += decoded.events.map(\.id)
            remaining.removeFirst(decoded.events.count)
            #expect(decoded.next == (remaining.isEmpty ? nil : decoded.events.last?.cursor))
        }
        #expect(received == entries.map(\.event.id))
        #expect(throws: SessionTaskWirePackingError.replyTooSmall) {
            _ = try SessionTaskWirePacking.page(entries, next: nil, budget: 20)
        }
    }
}
