import Foundation

/// The face of a session's run, decided in one place. The inputs are the app-wide switch ("Sessions run in", D-69) and
/// whether the app's structured (Chat) host exists (a test or a runtime-less window has none); a harness enters as its
/// `HarnessCapabilities`. Pure: no state, no UI type.
public struct FacePolicy: Equatable, Sendable {
    /// The switch: the face a start and a resume use when the harness has it.
    public let runsIn: SessionLiveFace
    /// The app's structured host exists, so the structured face can run.
    public let structuredHostAvailable: Bool

    public init(runsIn: SessionLiveFace, structuredHostAvailable: Bool) {
        self.runsIn = runsIn
        self.structuredHostAvailable = structuredHostAvailable
    }

    /// The face of a new session of a harness: the switch's, when the harness has the structured face and the host exists;
    /// the terminal's otherwise.
    public func faceOfStart(_ harness: HarnessCapabilities) -> SessionLiveFace {
        runsIn == .chat && structuredHostAvailable && harness.structuredFace ? .chat : .terminal
    }

    /// The face of a resumed session: the switch's, not the endpoint of its last run (that only says how the run was driven).
    /// Same rule as a start.
    public func faceOfResume(_ harness: HarnessCapabilities) -> SessionLiveFace {
        faceOfStart(harness)
    }

    /// The face of a session an agent's approved open request starts: an approved opening follows the switch like every
    /// other start (D-69 (1)), so it is a start's answer.
    public func faceOfApprovedOpening(_ harness: HarnessCapabilities) -> SessionLiveFace {
        faceOfStart(harness)
    }

    /// Whether a stopped session of a harness shows its structured face (the live chat, composer included) rather than the
    /// terminal face's stopped screen: while the switch says Chat, with the host present.
    public func showsStructuredFaceWhenStopped(_ harness: HarnessCapabilities) -> Bool {
        faceOfStart(harness) == .chat
    }
}
