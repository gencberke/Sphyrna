import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore

// The pinned cards, the chat banner and the asides in Ink (I6p, DESIGN §12, §15, §16, §19; the reference's E1–E4 and F1–F3): the
// values of the card, the banner's order by tone, the words a button says, the contrast of the card's pairs and the live row's
// "Waiting for you". No window and no process; every view here is hosted offscreen or not at all.

struct PinnedInkTests {
    typealias Pinned = LoomTheme.Pinned
    typealias Appearance = LoomTheme.Appearance

    // MARK: Copy

    @Test func aCardsButtonsAreTitleCaseAtTheCallSite() {
        // LoomChat keeps its sentence (its own tests pin it); the card writes the command in Title Case.
        #expect(PinnedCopy.titleCase("Allow for this session") == "Allow for This Session")
        #expect(PinnedCopy.titleCase("Allow all WebFetch this session") == "Allow All WebFetch This Session")
        #expect(PinnedCopy.titleCase("keep planning") == "Keep Planning")
        #expect(PinnedCopy.titleCase("Deny and stop") == "Deny and Stop")
        #expect(PinnedCopy.titleCase("") == "")
    }

    @Test func theMonoHintsSayWhereTheKeysLead() {
        #expect(PinnedCopy.approvalHint == "tab to the request \u{00B7} \u{2190} \u{2192} \u{00B7} space")
        #expect(PinnedCopy.questionHint(optionCount: 3) == "1\u{2013}3 pick \u{00B7} or write your own answer below")
        #expect(PinnedCopy.questionHint(optionCount: 1) == "1 pick \u{00B7} or write your own answer below")
        #expect(PinnedCopy.questionHint(optionCount: 12) == "1\u{2013}9 pick \u{00B7} or write your own answer below", "digits reach 9")
    }

    @Test func aFoldedLineSplitsWhatHappenedFromWhatItWasAbout() {
        let split = PinnedFoldedLine.split("Allowed once: rm -rf build")
        #expect(split?.what == "Allowed once" && split?.subject == "rm -rf build")
        #expect(PinnedFoldedLine.split("Denied: make clean \u{00B7} use the other target")?.subject == "make clean \u{00B7} use the other target")
        #expect(PinnedFoldedLine.split("Cancelled") == nil && PinnedFoldedLine.split(": nothing") == nil && PinnedFoldedLine.split("Allowed: ") == nil)
    }

    // MARK: The card's values

    @Test func theCardKeepsTheReferencesSizes() {
        #expect(Pinned.cardRadius == 12 && Pinned.cardPadding == 16 && Pinned.sectionSpacing == 12 && Pinned.buttonSpacing == 8)
        #expect(Pinned.edgeOpacity == 0.34, "a 1 pt attention edge at 34 %")
        #expect(Pinned.buttonHeight == 26 && Pinned.buttonRadius == 6, "the control family's button")
        #expect(Pinned.lineHeight == 32 && Pinned.lineRadius == 10, "the folded and the held line")
        // Five lines of 19, 8 above and below: the command's box is 111 high.
        #expect(CGFloat(Pinned.codeLines) * Pinned.codeLineHeight + 2 * Pinned.codePaddingV == 111)
        #expect(Pinned.codeRadius == 8 && Pinned.codePaddingH == 12)
        #expect(Pinned.optionRadius == 8 && Pinned.optionPaddingTop == 8 && Pinned.optionPadding == 12
            && Pinned.optionPaddingBottom == 9 && Pinned.optionPaddingLeading == 9)
        #expect(Pinned.optionNumber == CGSize(width: 20, height: 19) && Pinned.optionNumberRadius == 4)
        #expect(Pinned.segmentGroupRadius == 7 && Pinned.segmentRadius == 5 && Pinned.segmentHeight == 22)
        #expect(Pinned.stackMaxHeightFraction == 0.55 && Pinned.compactStackMaxHeightFraction == 0.68)
    }

    @Test func theCardIsRaisedTwoAndWhatItHoldsRaisedOne() {
        #expect(Pinned.cardFill == LoomTheme.Surface.raised2)
        #expect(Pinned.codeFill == LoomTheme.Surface.raised1 && Pinned.lineFill == LoomTheme.Surface.raised1)
        #expect(Pinned.depth == LoomTheme.Elevation.card)
    }

    @Test func theBannerIsTheChatsBox() {
        typealias Banner = LoomTheme.ChatBanner
        #expect(Banner.radius == 12 && Banner.minHeight == 36)
        #expect(Pinned.edgeOpacity == 0.34)
    }

    @Test func theAsidesAreThePopoverAndTheCardFamilies() {
        #expect(LoomTheme.QuickQuestion.radius == 12, "the popover family; the reference's 14 gives way to DESIGN")
        #expect(LoomTheme.QuickQuestion.fill == LoomTheme.Surface.popover)
        #expect(LoomTheme.Side.composerRadius == 12 && LoomTheme.Side.composerFill == LoomTheme.Surface.raised1)
        #expect(LoomTheme.Control.switchSize == CGSize(width: 32, height: 18) && LoomTheme.Control.switchThumb == 14)
        #expect(LoomTheme.Side.controlSide == 24, "the side bar's ⋯ is the reference's 24 pt icon button")
    }

    // MARK: Contrast

    /// Everything a card says holds its tier on the card (raised 2) and on what it holds (raised 1), in both appearances and every
    /// tone; the selected option's number reads on the accent; the live row's attention text reads on the canvas.
    @Test func theCardsTextHoldsItsFloorsInEveryAppearanceAndTone() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let greys = LoomTheme.Surface.greys(appearance, tone: tone)
                let id = "\(appearance) \(tone)"
                for (name, back) in [("raised 2", greys.raised2), ("raised 1", greys.raised1)] {
                    #expect(LoomTheme.Text.primaryPair[appearance].contrast(with: back) >= 7, "primary on \(name), \(id)")
                    #expect(LoomTheme.Text.secondaryPair[appearance].contrast(with: back) >= 4.5, "secondary on \(name), \(id)")
                    #expect(LoomTheme.Text.tertiaryPair[appearance].contrast(with: back) >= 4.5, "tertiary on \(name), \(id)")
                    #expect(LoomTheme.Success.lightPair[appearance].contrast(with: back) >= 4.5, "the folded line's check on \(name), \(id)")
                }
                #expect(LoomTheme.Status.attentionLightPair[appearance].contrast(with: greys.canvas) >= 4.5, "Waiting for you on \(id)")
                #expect(LoomTheme.Accent.onAccentPair[appearance].contrast(with: LoomTheme.Accent.basePair[appearance]) >= 4.5,
                        "the picked option's number on the accent, \(id)")
            }
        }
    }

    // MARK: The banner

    private func item(_ kind: ChatBannerItem.Kind, _ tone: ChatBannerTone? = nil) -> ChatBannerItem {
        ChatBannerItem(kind: kind, message: "\(kind)", actionTitle: nil, tone: tone)
    }

    @Test func bannersAreOrderedByToneThenAsTheyCame() {
        let note1 = item(.wireDrift), note2 = item(.unknownRecords)
        let limit = item(.policy)
        let failed = ChatBannerItem(kind: .policy, message: "failed", actionTitle: nil, tone: .failure)
        // What did not happen first, then what limits Sphyrna, then notes; first come, first shown within a tone.
        #expect(ChatBanners.ordered([note1, limit, note2, failed]).map(\.message) == ["failed", "\(limit.kind)", "\(note1.kind)", "\(note2.kind)"])
        #expect(ChatBannerTone.allCases == [.failure, .attention, .note])
        // The chat's own banners: the policy signal limits the Chat face (attention), drift is a note.
        #expect(limit.tone == .attention && note1.tone == .note && note2.tone == .note)
        let all = ChatBanners.items(policySignal: true, policyDismissed: false, canContinueInTerminal: true, wireDrift: 1, wireDriftDismissed: false,
                                    unknownRecords: 2, recordsDismissed: false)
        #expect(all.map(\.kind) == [.policy, .wireDrift, .unknownRecords] && all.map(\.tone) == [.attention, .note, .note])
    }

    @Test func eachToneHasItsOwnSymbolSoColourIsNeverAlone() {
        #expect(Set(ChatBannerTone.allCases.map(\.symbol)).count == 3)
        #expect(ChatBannerTone.failure.symbol == "exclamationmark.triangle", "the failure tone is the triangle")
    }

    // MARK: Drawn offscreen

    @MainActor private func fitting<V: View>(_ view: V, width: CGFloat = 700) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @MainActor @Test func theBannerIsNothingWithoutItemsAndOneBoxWithAndGrowsWhenOpened() {
        let none = fitting(ChatBannerView(items: [], dismiss: { _ in }, perform: { _ in }))
        #expect(none.height == 0)
        let one = fitting(ChatBannerView(items: [item(.policy)], dismiss: { _ in }, perform: { _ in }))
        #expect(one.height >= LoomTheme.ChatBanner.minHeight && one.height < 2 * LoomTheme.ChatBanner.minHeight + Pinned.stackPaddingBottom)
        // A second banner waits behind "+1": the second card's tab draws in the room above, so nothing under the stream moves.
        let two = fitting(ChatBannerView(items: [item(.policy), item(.wireDrift)], dismiss: { _ in }, perform: { _ in }))
        #expect(two.height == one.height, "\(two.height) vs \(one.height)")
    }

    // MARK: The live row says Waiting for you

    private func liveRow(waiting: Bool) throws -> LiveRow {
        let lines = ChatFixture.turn(1, tools: [(name: "Bash", input: ["command": "swift test"], output: "ok")]) + [ChatFixture.user("go on", uuid: "u2", at: 10)]
        let input = ChatBuildInput(model: ChatFixture.model(lines), isWorking: true, isWaitingForUser: waiting)
        let rows = ChatRowBuilder.rows(input)
        guard case let .live(live)? = rows.last?.kind else { throw Skip("no live row") }
        return live
    }

    private struct Skip: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

    @Test func theWaitingFlagIsAPlainValueOfTheLiveRowOnly() throws {
        let busy = try liveRow(waiting: false), waiting = try liveRow(waiting: true)
        #expect(!busy.isWaitingForUser && waiting.isWaitingForUser)
        var same = waiting
        same.isWaitingForUser = false
        #expect(same == busy, "the flag is the only difference")
        // The ids of the rows stay; only the live row's value moves.
        let lines = ChatFixture.turn(1) + ChatFixture.turn(2, start: 20)
        let before = ChatRowBuilder.rows(ChatBuildInput(model: ChatFixture.model(lines), isWorking: true))
        let after = ChatRowBuilder.rows(ChatBuildInput(model: ChatFixture.model(lines), isWorking: true, isWaitingForUser: true))
        #expect(before.map(\.id) == after.map(\.id))
        let changed = zip(before, after).filter { $0 != $1 }.map(\.0.id)
        #expect(changed.count == 1 && changed[0].hasPrefix("live:"), "\(changed)")
    }

    @Test func aWaitingRowSaysSoInsteadOfWhatClaudeDoesAndKeepsTheClock() throws {
        var live = try liveRow(waiting: true)
        let now = Date(timeIntervalSince1970: 2_000)
        live.startedAt = now.addingTimeInterval(-14)
        live.lastActivity = now.addingTimeInterval(-300)
        #expect(ChatLiveStatusText.text(live, now: now) == "Waiting for you \u{00B7} 14s", "the user is the cause, so no \"No activity\"")
        live.isWaitingForUser = false
        #expect(ChatLiveStatusText.text(live, now: now) == "No activity for 300s")
        live.startedAt = nil
        live.isWaitingForUser = true
        #expect(ChatLiveStatusText.text(live, now: now) == "Waiting for you")
    }

    @Test func theFlagChangesOnlyTheNewestTurnsRows() {
        let lines = ChatFixture.turn(1) + ChatFixture.turn(2, start: 20) + ChatFixture.turn(3, start: 40)
        let model = ChatFixture.model(lines)
        var store = ChatRowStore()
        _ = store.update(ChatBuildInput(model: model, isWorking: true), cause: .replaced)
        let derived = store.turnsDerived
        let change = store.update(ChatBuildInput(model: model, isWorking: true, isWaitingForUser: true), cause: .state)
        #expect(store.turnsDerived - derived == 1, "only the newest turn is derived again")
        guard case let .patches(patches) = change else { Issue.record("expected patches"); return }
        #expect(patches.count == 1)
        guard case let .live(live)? = store.rows.last?.kind else { Issue.record("no live row"); return }
        #expect(live.isWaitingForUser)
        #expect(store.rows.map(\.id) == ChatRowBuilder.rows(ChatBuildInput(model: model, isWorking: true, isWaitingForUser: true)).map(\.id))
    }

    @MainActor @Test func thePresentationCarriesTheFlagIntoTheBuildInput() {
        let presentation = ChatPresentation(sessionID: "s", workingDirectory: nil, isWorking: true)
        #expect(!presentation.buildInput().isWaitingForUser)
        presentation.setWaitingForUser(true)
        #expect(presentation.isWaitingForUser && presentation.buildInput().isWaitingForUser)
        presentation.setWaitingForUser(false)
        #expect(!presentation.buildInput().isWaitingForUser)
    }

    @MainActor @Test func aRequestOfTheSessionRaisesTheFlagAndItsAnswerLowersIt() async {
        let card = UUID()
        let source = ScriptedLiveSource(card: card, conversationID: nil)
        let feed = LiveChatFeed(source: source, card: card, conversationID: nil, configDirectory: nil, workingDirectory: nil)
        feed.start()
        let fields: [String: JSONValue] = ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "ls"], "tool_use_id": "toolu_a"]
        let pending = ChatPendingRequest(requestID: "a", request: ToolPermissionRequest(json: .object(fields))!,
                                         arrivedAt: Date(timeIntervalSince1970: 1), agent: nil)
        // Sized for a whole-target run's load, not an idle machine (as LiveChatFeedTests' waits).
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
        #expect(!feed.presentation.isWaitingForUser)
        await source.setState { $0.requests = [pending] }
        #expect(await wait { feed.presentation.isWaitingForUser })
        await source.setState { $0.requests = [] }
        #expect(await wait { !feed.presentation.isWaitingForUser })
    }
}
