import Foundation
import LoomCore

// The quick question (V22), on the driver: one `side_question` control request, answered from the session's context. Spike S6
// Q3 has the wire: the CLI answers with one `control_response` (a `system/control_request_progress{started}` before it), and
// writes nothing else: no `result`, no usage, no tool, no transcript record. It works while the session is idle, while a card
// waits and while a tool runs, and costs one model call over the parent's cached context. So the driver changes nothing for
// it (no phase, queue, mode, model or request) and only awaits the reply; the text is never journaled.

/// Whether a quick question can be asked of this session now. The rule is one: Loom owns a live process (ready, working or
/// waiting for the user) and no handover to the terminal holds the session.
public enum SideQuestionAvailability: Equatable, Sendable {
    case available
    /// The child is spawning or has not answered `initialize` yet.
    case launching
    /// A Stop, Quit or face switch is under way.
    case stopping
    /// No process: a quick question never resumes a session by itself.
    case stopped
    /// The session is moving to the terminal.
    case handover

    /// Why the action is off; nil when it is on.
    public var reason: String? {
        switch self {
        case .available: nil
        case .launching: "The session is starting"
        case .stopping: "The session is stopping"
        case .stopped: "Quick questions need a running Chat session"
        case .handover: "The session is moving to the terminal"
        }
    }

    public static func of(phase: ChatDriverPhase, handoverHolds: Bool) -> SideQuestionAvailability {
        switch phase {
        case .stopped, .failed: .stopped
        case .starting: .launching
        case .stopping: .stopping
        case .ready, .working, .needsYou: handoverHolds ? .handover : .available
        }
    }
}

public enum SideQuestionError: Error, Equatable, Sendable {
    /// The session cannot take a question now (nothing was sent).
    case notAvailable(SideQuestionAvailability)
    /// Nothing to ask (nothing was sent).
    case emptyQuestion
    /// The CLI did not answer within `ChatSessionDriver.sideQuestionTimeout` (120 s); it was told to drop the request.
    case noAnswer
    /// This CLI does not know `side_question` ("Unsupported control request subtype").
    case unsupported
    /// The CLI answered an error frame; the text is its own.
    case failed(String)

    /// What the panel says, in one quiet line.
    public var text: String {
        switch self {
        case let .notAvailable(availability): availability.reason ?? "Quick questions are not available now"
        case .emptyQuestion: "Type a question first"
        case .noAnswer: "No answer came back. Try again."
        case .unsupported: "This Claude version has no quick questions"
        case let .failed(message): message.isEmpty ? "Claude could not answer" : message
        }
    }
}

extension ChatSessionDriver {
    /// Whether a quick question can be asked now (the model's menu, palette and panel read it).
    public func sideQuestionAvailability() -> SideQuestionAvailability {
        let availability = SideQuestionAvailability.of(phase: phase, handoverHolds: handover.isHolding)
        return availability == .available && run == nil ? .stopped : availability
    }

    /// Tests shorten the wait (a timeout test must not take 120 s).
    func setSideQuestionTimeout(_ timeout: Duration) { sideQuestionWait = timeout }

    /// Asks the CLI the question and returns its answer, in the CLI's own words. Changes nothing in the session. Throws
    /// `notAvailable` and `emptyQuestion` before anything is sent, and one error each for no answer in time, an error frame
    /// and a CLI that does not know the request. The journal gets the outcome and the latency, never the text.
    public func sideQuestion(_ question: String) async throws -> String {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SideQuestionError.emptyQuestion }
        let availability = sideQuestionAvailability()
        guard availability == .available, let channel = run?.channel else { throw SideQuestionError.notAvailable(availability) }
        let started = ContinuousClock.now
        func record(_ outcome: String) {
            let elapsed = started.duration(to: .now)
            let millis = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            journal?.record("chat.sideQuestion", ["outcome": .string(outcome), "ms": .int(millis)])
        }
        do {
            let reply = try await channel.request(.sideQuestion(text), timeout: sideQuestionWait)
            guard let answer = reply.sideQuestionResponse else {
                record("failed")
                throw SideQuestionError.failed("")
            }
            record("answered")
            return answer
        } catch let error as SideQuestionError {
            throw error
        } catch ControlError.timedOut {
            record("timeout")
            throw SideQuestionError.noAnswer
        } catch let ControlError.rejected(_, message) {
            let unsupported = message.hasPrefix("Unsupported control request subtype")
            record(unsupported ? "unsupported" : "failed")
            throw unsupported ? SideQuestionError.unsupported : SideQuestionError.failed(message)
        } catch ControlError.unsupported {
            record("unsupported")
            throw SideQuestionError.unsupported
        } catch ControlError.closed {
            record("ended")
            throw SideQuestionError.notAvailable(.stopped)
        } catch ControlError.outputFull {
            record("timeout")
            throw SideQuestionError.noAnswer
        } catch ControlError.cancelled {
            // The asker stopped waiting (the panel closed): the channel told the CLI to drop the request.
            record("cancelled")
            throw CancellationError()
        } catch {
            record("failed")
            throw error
        }
    }
}
