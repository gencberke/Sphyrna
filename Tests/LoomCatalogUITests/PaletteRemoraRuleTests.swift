import Foundation
import Testing
@testable import LoomRemora
@testable import LoomCatalogUI

/// L3c, part A: Ask Remora in the ⌘K palette, as plain values. When the text reads as a question, the scope ⇥ goes through and when
/// This session is offered, and what ⇥, ↵, ⌘↵ and Esc do in the list and over the answer. No model, no window.
struct PaletteRemoraRuleTests {
    // MARK: Reads as a question

    @Test(arguments: [
        // A question mark, in each script's own form.
        ("which session touched the auth middleware?", true), ("auth?", true), ("認証はどこ？", true), ("ما الذي تغير؟", true),
        // An interrogative and at least three words, without case or accents.
        ("what is half done in loom", true), ("Why did the build fail", true), ("how to deploy", true),
        ("Warum ist der Test rot", true), ("pourquoi le test échoue", true), ("Qué sesión tocó auth", true),
        ("perché il build fallisce", true), ("o que mudou ontem", true), ("waarom faalt de build", true),
        ("hangi oturum auth değiştirdi", true), ("ne zaman bitti bu", true),
        // A Turkish particle after the first word.
        ("testler geçti mi", true), ("build bitti mı", true),
        // A Chinese, Japanese or Korean question.
        ("认证改了什么", true), ("どこで止まった", true), ("테스트는 언제 끝났", true), ("終わりましたか", true),
        // Search terms, lone words and two words stay searches.
        ("login flow", false), ("Token rotation", false), ("auth middleware", false), ("what", false), ("how to", false),
        ("Rate limiter tests", false), ("README.md", false), ("?", false), ("", false), ("   ", false),
        ("Remember the webhook secret rotates", false), ("is", false), ("mi casa", false),
    ])
    func theTextReadsAsAQuestionOnlyWhenItIsOne(text: String, question: Bool) {
        #expect(PaletteRemoraQuestion.readsAsQuestion(text) == question, "\(text)")
    }

    // MARK: The scope

    private let project = UUID()
    private let session = UUID()

    @Test func tabGoesFromAllProjectsToThisProjectToThisSessionAndBack() {
        let place = PaletteRemoraPlace(project: (project, "loom"), session: session)
        let choices = PaletteRemoraScope.choices(place, excluded: [])
        #expect(choices == [.allProjects, .project(project, name: "loom"), .session(session)])
        #expect(choices.map(\.label) == ["All projects", "loom", "This session"])
        #expect(choices.map(\.scope) == [.allProjects, .project(project), .session(session)])
        var index = 0
        var seen: [String] = []
        for _ in 0..<4 {
            index = PaletteRemoraScope.next(after: index, count: choices.count)
            seen.append(choices[index].label)
        }
        #expect(seen == ["loom", "This session", "All projects", "loom"])
    }

    @Test func thisSessionIsForAnEndedOrTerminalSessionNotOneRunningInChat() {
        let inChat = PaletteRemoraPlace(project: (project, "loom"), session: session, sessionRunsInChat: true)
        #expect(PaletteRemoraScope.choices(inChat, excluded: []) == [.allProjects, .project(project, name: "loom")],
                "a live Chat session has the quick question")
        let ended = PaletteRemoraPlace(project: (project, "loom"), session: session, sessionRunsInChat: false)
        #expect(PaletteRemoraScope.choices(ended, excluded: []).last == .session(session))
    }

    @Test func anExcludedProjectAndItsSessionsAreNeverOffered() {
        let place = PaletteRemoraPlace(project: (project, "loom"), session: session)
        #expect(PaletteRemoraScope.choices(place, excluded: [project]) == [.allProjects])
    }

    @Test func homeOffersAllProjectsOnlyAndAProjectPageItsProject() {
        #expect(PaletteRemoraScope.choices(PaletteRemoraPlace(), excluded: []) == [.allProjects])
        #expect(PaletteRemoraScope.choices(PaletteRemoraPlace(project: (project, "api")), excluded: [])
            == [.allProjects, .project(project, name: "api")])
        #expect(PaletteRemoraScope.next(after: 0, count: 1) == 0)
    }

    // MARK: Keys

    typealias K = PaletteRemoraKeys

    @Test func inTheListTabScopesReturnAsksAndTheRestIsThePalettes() {
        let offered = K.Stage.typing(offered: true, askSelected: true, busy: false)
        #expect(K.resolve(.tab, offered) == .cycleScope)
        #expect(K.resolve(.return, offered) == .ask)
        #expect(K.resolve(.commandReturn, offered) == .nothing, "⌘↵ pins a session in a tab; Ask Remora has no tab")
        #expect(K.resolve(.escape, offered) == .passThrough)
        #expect(K.resolve(.arrow, offered) == .passThrough)
        // Another row selected: ↵ opens it as before, and ⇥ still sets the scope.
        let other = K.Stage.typing(offered: true, askSelected: false, busy: false)
        #expect(K.resolve(.return, other) == .passThrough && K.resolve(.commandReturn, other) == .passThrough)
        #expect(K.resolve(.tab, other) == .cycleScope)
    }

    @Test func withRemoraOffOrNotAQuestionThePaletteIsAsItWas() {
        let plain = K.Stage.typing(offered: false, askSelected: false, busy: false)
        for key in [K.Key.tab, .return, .commandReturn, .escape, .arrow] { #expect(K.resolve(key, plain) == .passThrough, "\(key)") }
    }

    @Test func whileRemoraAnswersSomethingElseReturnDoesNothing() {
        #expect(K.resolve(.return, .typing(offered: true, askSelected: true, busy: true)) == .nothing)
    }

    @Test func overTheAnswerReturnOpensTheChipCommandReturnOpensHomeAndEscapeStopsFirst() {
        #expect(K.resolve(.return, .answer(inFlight: false, hasChip: true)) == .openFirstChip)
        #expect(K.resolve(.return, .answer(inFlight: false, hasChip: false)) == .nothing)
        #expect(K.resolve(.commandReturn, .answer(inFlight: false, hasChip: false)) == .openOnHome)
        #expect(K.resolve(.commandReturn, .answer(inFlight: true, hasChip: false)) == .nothing, "Home takes an answer that has ended")
        #expect(K.resolve(.escape, .answer(inFlight: true, hasChip: false)) == .stopAndClose)
        #expect(K.resolve(.escape, .answer(inFlight: false, hasChip: true)) == .close)
        #expect(K.resolve(.tab, .answer(inFlight: false, hasChip: true)) == .nothing && K.resolve(.arrow, .answer(inFlight: true, hasChip: true)) == .nothing)
    }
}
