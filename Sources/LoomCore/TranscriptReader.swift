import Foundation

/// The bounded backward reads used by transcript consumers, independent of the harness.
public protocol TranscriptReader: AnyObject, Sendable {
    func readBackward(pageBytes: Int, maximumLineBytes: Int) -> TranscriptBackwardPage
    func close()
}

extension ClaudeTranscriptReader: TranscriptReader {}
