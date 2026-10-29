import Foundation
import LoomCore
import Testing
@testable import LoomChat
import LoomTestSupport

/// `TranscriptModelTests`'s fixtures, for both halves of the suite.
protocol TranscriptModelFixtures {}

extension TranscriptModelFixtures {
    func build(_ lines: [String], source: TurnModel.Source = .sessionTranscript) -> TurnModel {
        var model = TurnModel(source: source)
        var offset: UInt64 = 0
        for line in lines {
            let bytes = Data(line.utf8)
            model.apply(record: TranscriptLineRecord(offset: offset, length: bytes.count, bytes: bytes))
            offset += UInt64(bytes.count + 1)
        }
        return model
    }
}
