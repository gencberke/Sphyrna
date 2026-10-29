import Foundation
import Testing
@testable import LoomCore
@testable import LoomRemora
import LoomTestSupport
@testable import LoomRemoraTestRigs

/// L3a2 (item 5): the brief's language. It is one line in the brief's request (the dynamic part of the pack, stdin), never in
/// the cached system prompt; a set language wins, else the last question's, else none. Questions are not affected.
@MainActor
@Suite(.serialized, .processHeavy, .timeLimit(.minutes(3)))
struct RemoraBriefLanguageTests {
    private static let turkish = "Bugün hangi oturumlar değişti ve hangisi beni bekliyor?"
    private static let english = "Which sessions changed today and which of them is waiting for me?"

    // MARK: The setting

    @Test func theLanguageDefaultsToNilIsDecodedLenientlyAndRoundTrips() throws {
        #expect(RemoraPreferences().language == nil && RemoraPreferences.defaultLanguage == nil)
        func decode(_ json: String) throws -> RemoraPreferences { try JSONDecoder().decode(RemoraPreferences.self, from: Data(json.utf8)) }
        #expect(try decode("{}").language == nil)
        #expect(try decode(#"{"language":"tr"}"#).language == "tr")
        #expect(try decode(#"{"language":" zh-Hans "}"#).language == "zh-Hans")
        for unreadable in ["3", "true", "[]", #""""#, #""not a language""#, #""x""#, #""en_US""#, "null"] {
            #expect(try decode(#"{"language":\#(unreadable),"model":"haiku"}"#).language == nil, "\(unreadable) was taken as a language")
            #expect(try decode(#"{"language":\#(unreadable),"model":"haiku"}"#).model == "haiku", "a bad language cost another field")
        }
        let custom = RemoraPreferences(model: "haiku", language: "pt-BR")
        #expect(try JSONDecoder().decode(RemoraPreferences.self, from: JSONEncoder().encode(custom)) == custom)
        #expect(!String(decoding: try JSONEncoder().encode(RemoraPreferences()), as: UTF8.self).contains("language"))
    }

    // MARK: The pack

    @Test func theLanguageIsOneLineInTheBriefsRequestAndTheCachedPrefixDoesNotChange() async throws {
        let world = try RemoraPackWorld()
        defer { world.remove() }
        try world.add(title: "Billing", project: (UUID(), "loom"), minutesAgo: 10, lines: RemoraPackWorld.conversation(turns: 2))
        let since = world.base.addingTimeInterval(-3_600)
        let plain = try await world.build(.brief(since: since))
        let turkish = try await world.build(.brief(since: since), settings: RemoraPackSettings(language: "tr"))
        let english = try await world.build(.brief(since: since), settings: RemoraPackSettings(language: "en"))

        #expect(!plain.text.contains("Write the brief in"))
        #expect(plain.text.contains("Two short sentences, about 35 words: only what moved, what needs me and the next step."),
                "the brief's length is a number in its request")
        #expect(!plain.text.contains("Keep it short."))
        #expect(turkish.text.contains("Write the brief in Turkish (tr).\n</request>"))
        #expect(english.text.contains("Write the brief in English (en).\n</request>"))
        #expect(turkish.text.components(separatedBy: "Write the brief in").count == 2, "more than one line")
        // The stable prefix, and so the system prompt of the call, are the same whatever the language is.
        #expect(turkish.stablePrefix == plain.stablePrefix && english.stablePrefix == plain.stablePrefix)
        #expect(turkish.request().systemSuffix == plain.request().systemSuffix)
        #expect(!turkish.request().systemSuffix.contains("Turkish") && turkish.request().pack.contains("Turkish (tr)"))
        #expect(turkish.afterStablePrefix.count - plain.afterStablePrefix.count == "Write the brief in Turkish (tr).\n".count)
        // The rules are one text for everyone.
        #expect(!RemoraRules.text.contains("Turkish"))
    }

    @Test func aQuestionIgnoresTheLanguage() async throws {
        let world = try RemoraPackWorld()
        defer { world.remove() }
        try world.add(title: "Billing", project: (UUID(), "loom"), minutesAgo: 10, lines: RemoraPackWorld.conversation(turns: 2))
        let request = RemoraPackRequest.question("What moved?", scope: .allProjects, previous: nil)
        let plain = try await world.build(request)
        let withLanguage = try await world.build(request, settings: RemoraPackSettings(language: "tr"))
        #expect(plain.text == withLanguage.text)
    }

    // MARK: The host's choice

    /// The stdin and the system prompt of a brief the host runs, with the preferences and the journal it is given.
    private func capture(language: String?, lastQuestion: String?) async throws -> (stdin: String, system: String) {
        let rig = try RemoraHostRig()
        if let lastQuestion {
            let seed = try RemoraMemory(directory: rig.remora, timeZone: rig.zone, clock: { [clock = rig.clock] in clock.now })
            try await seed.appendJournal(RemoraJournalEntry.make(
                kind: .question, question: lastQuestion, answerText: "An answer.", sessions: [], model: nil, tokens: 1, summary: nil,
                date: rig.clock.now.addingTimeInterval(-600)))
        }
        let host = rig.makeHost(settings: RemoraPreferences(language: language), withTranscript: true, executable: try rig.captureExecutable())
        _ = await host.brief()
        let captured = (rig.capturedStdin(), rig.capturedSystemPrompt())
        await rig.finish()
        return captured
    }

    @Test func aSetLanguageReachesTheBriefsStdinAndNotTheSystemPrompt() async throws {
        // Even with an English last question, the setting wins.
        let (stdin, system) = try await capture(language: "tr", lastQuestion: Self.english)
        #expect(stdin.contains("Write the brief in Turkish (tr).\n</request>"))
        #expect(!system.isEmpty && system.contains("<sessions>") && !system.contains("Turkish") && !system.contains("Write the brief in"))
    }

    @Test func noLanguageFollowsTheLastQuestionsLanguage() async throws {
        let turkish = try await capture(language: nil, lastQuestion: Self.turkish)
        #expect(turkish.stdin.contains("Write the brief in Turkish (tr).\n</request>"))
        #expect(!turkish.system.contains("Turkish"))
        let english = try await capture(language: nil, lastQuestion: Self.english)
        #expect(english.stdin.contains("Write the brief in English (en).\n</request>"))
    }

    @Test func noLanguageAndNoQuestionGivesNoLine() async throws {
        let none = try await capture(language: nil, lastQuestion: nil)
        #expect(none.stdin.contains("<request>") && !none.stdin.contains("Write the brief in"))
        // A question too short to tell is no guess either.
        let short = try await capture(language: nil, lastQuestion: "ok?")
        #expect(short.stdin.contains("<request>") && !short.stdin.contains("Write the brief in"))
    }

    @Test func theNewestQuestionLineDecidesAndALaterQuestionChangesIt() async throws {
        let rig = try RemoraHostRig()
        let seed = try RemoraMemory(directory: rig.remora, timeZone: rig.zone, clock: { [clock = rig.clock] in clock.now })
        for (question, minutes) in [(Self.english, -3_000.0), (Self.turkish, -2_000.0)] {
            try await seed.appendJournal(RemoraJournalEntry.make(
                kind: .question, question: question, answerText: "An answer.", sessions: [], model: nil, tokens: 1, summary: nil,
                date: rig.clock.now.addingTimeInterval(minutes)))
        }
        #expect(await RemoraLanguage.ofLastQuestion(in: seed) == "tr")
        try await seed.appendJournal(RemoraJournalEntry.make(
            kind: .question, question: Self.english, answerText: "An answer.", sessions: [], model: nil, tokens: 1, summary: nil,
            date: rig.clock.now.addingTimeInterval(-100)))
        #expect(await RemoraLanguage.ofLastQuestion(in: seed) == "en")
        // A brief's own line is not a question.
        try await seed.appendJournal(RemoraJournalEntry.make(
            kind: .brief, question: nil, answerText: "Un resumen del día de hoy para ti.", sessions: [], model: nil, tokens: 1, summary: nil,
            date: rig.clock.now))
        #expect(await RemoraLanguage.ofLastQuestion(in: seed) == "en")
        await rig.finish()
    }

    @Test func aQuestionTheHostRunsGetsNoLanguageLine() async throws {
        let rig = try RemoraHostRig()
        let host = rig.makeHost(settings: RemoraPreferences(language: "tr"), executable: try rig.captureExecutable())
        _ = await host.ask("What moved?")
        #expect(rig.capturedStdin().contains("<question>") && !rig.capturedStdin().contains("Write the brief in"))
        await rig.finish()
    }
}
