import Testing
@testable import LoomCore
import LoomTestSupport

/// R4: the face policy's table: switch x structured host x harness -> the face of a start, a resume, an approved opening and
/// whether a stopped session shows its structured face. The same cells as the face table of
/// `SessionServiceCharacterizationTests`, without a process.
struct FacePolicyTests {
    private static let claude = HarnessCapabilities.of(.claude, startable: [.claude])
    private static let codex = HarnessCapabilities.of(.codex, startable: [.claude, .codex])
    private static let synthetic = HarnessCapabilities.of(.synthetic, startable: [.claude])

    @Test func theSwitchDecidesAStructuredHarnessWhenTheHostExists() {
        let chat = FacePolicy(runsIn: .chat, structuredHostAvailable: true)
        #expect(chat.faceOfStart(Self.claude) == .chat)
        #expect(chat.faceOfResume(Self.claude) == .chat)
        #expect(chat.showsStructuredFaceWhenStopped(Self.claude))

        let terminal = FacePolicy(runsIn: .terminal, structuredHostAvailable: true)
        #expect(terminal.faceOfStart(Self.claude) == .terminal)
        #expect(terminal.faceOfResume(Self.claude) == .terminal)
        #expect(!terminal.showsStructuredFaceWhenStopped(Self.claude))
    }

    @Test func withoutTheHostEveryFaceIsTheTerminals() {
        for runsIn in [SessionLiveFace.chat, .terminal] {
            let policy = FacePolicy(runsIn: runsIn, structuredHostAvailable: false)
            #expect(policy.faceOfStart(Self.claude) == .terminal)
            #expect(policy.faceOfResume(Self.claude) == .terminal)
            #expect(!policy.showsStructuredFaceWhenStopped(Self.claude))
        }
    }

    @Test func aHarnessWithoutAStructuredFaceStaysInTheTerminal() {
        let policy = FacePolicy(runsIn: .chat, structuredHostAvailable: true)
        for harness in [Self.codex, Self.synthetic] {
            #expect(policy.faceOfStart(harness) == .terminal)
            #expect(policy.faceOfResume(harness) == .terminal)
            #expect(!policy.showsStructuredFaceWhenStopped(harness))
        }
    }

    @Test func anApprovedOpeningFollowsTheSwitchLikeAStart() {
        for runsIn in [SessionLiveFace.chat, .terminal] {
            for host in [true, false] {
                let policy = FacePolicy(runsIn: runsIn, structuredHostAvailable: host)
                for harness in [Self.claude, Self.codex, Self.synthetic] {
                    #expect(policy.faceOfApprovedOpening(harness) == policy.faceOfStart(harness))
                }
            }
        }
        #expect(FacePolicy(runsIn: .chat, structuredHostAvailable: true).faceOfApprovedOpening(Self.claude) == .chat)
        #expect(FacePolicy(runsIn: .terminal, structuredHostAvailable: true).faceOfApprovedOpening(Self.claude) == .terminal)
        #expect(FacePolicy(runsIn: .chat, structuredHostAvailable: false).faceOfApprovedOpening(Self.claude) == .terminal)
        #expect(FacePolicy(runsIn: .chat, structuredHostAvailable: true).faceOfApprovedOpening(Self.codex) == .terminal)
    }
}
