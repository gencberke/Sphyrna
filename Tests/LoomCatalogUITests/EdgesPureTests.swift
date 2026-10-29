import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// I4c, the edges, in plain values (DESIGN §19): the banner mapper and its stack, the ended line's buttons, the record's order
/// per state, the draft page's notes, the menu bar menu's row dot and the symbol colour. What draws is in `EdgesViewTests`.
@MainActor
@Suite
struct EdgesPureTests {
    typealias Appearance = LoomTheme.Appearance

    // MARK: The banner mapper

    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func everything() -> BannerSources {
        BannerSources(
            error: "Claude could not be started.", sessionIssue: "Sphyrna is not receiving events from Claude.",
            recoveryFailure: "A deletion record could not be read.",
            deletions: [
                BannerDeletion(id: first, title: "Port the sidebar", isDeleting: false, lastFailure: "files", canRetry: true, canRemove: true),
                BannerDeletion(id: second, title: "Weekly vault", isDeleting: true, lastFailure: nil, canRetry: false, canRemove: false),
            ],
            ownership: "New sessions are turned off.", info: "“loom” is already in Sphyrna.", status: "Stopping sessions before quitting…")
    }

    @Test func bannersAreWeighedFailureThenAttentionThenNoteWithAFixedOrderInsideATone() {
        let items = BannerItems.make(everything())
        #expect(items.map(\.kind) == [.error, .sessionIssue, .deletionRecovery, .deletionFailure(first),
                                      .ownership, .info, .progress, .deleting(second)])
        #expect(items.map(\.tone) == [.failure, .failure, .failure, .failure, .attention, .note, .note, .note])
        #expect(items.map(\.tone) == items.map(\.tone).sorted())
        #expect(BannerItems.make(BannerSources()).isEmpty)
    }

    @Test func eachToneHasItsSymbolAndProgressRowsTakeTheSpinnerInstead() {
        let items = BannerItems.make(everything())
        #expect(items.filter { $0.leading == .spinner }.map(\.kind) == [.progress, .deleting(second)])
        for item in items where item.leading == .tone {
            #expect(item.tone.symbol == [ChatBannerTone.failure: "exclamationmark.triangle", .attention: "exclamationmark.circle",
                                         .note: "info.circle"][item.tone])
        }
        for item in items where item.leading == .spinner { #expect(item.tone == .note, "progress is quiet") }
    }

    @Test func aCrossClosesAFailureAndANoteButNotWhatHoldsWhileItsCauseHolds() {
        let items = BannerItems.make(everything())
        #expect(items.filter(\.isDismissible).map(\.kind) == [.error, .info])
        // The missing helper, the live issue, progress and a deletion that is pending or failed stay.
        for kind in [BannerKind.ownership, .sessionIssue, .progress, .deletionRecovery, .deletionFailure(first), .deleting(second)] {
            #expect(items.first { $0.kind == kind }?.isDismissible == false, "\(kind)")
        }
    }

    @Test func oneBoxShowsAndPlusNOpensTheOthersInPlace() {
        let items = BannerItems.make(everything())
        #expect(BannerItems.visible(items, open: false).map(\.kind) == [.error])
        #expect(BannerItems.visible(items, open: true) == items)
        let alone = Array(items.prefix(1))
        #expect(BannerItems.visible(alone, open: true) == alone, "one box has nothing to open")
        #expect(BannerItems.visible([], open: true).isEmpty)

        let closed = BannerPeek(hidden: items.count - 1, open: false, identifier: "p", toggle: {})
        let opened = BannerPeek(hidden: items.count - 1, open: true, identifier: "p", toggle: {})
        #expect(closed.text == "+7" && closed.label == "Show 7 more notices" && closed.help == "Show all")
        // The reference's words while open (`edge.js` drawStack); the AX label stays a sentence.
        #expect(opened.text == "Show Fewer" && opened.label == "Show fewer notices" && opened.help == "Show one")
        #expect(closed.showsTab && !opened.showsTab, "the second card peeks above a closed stack only")
    }

    @Test func thePeekClosesByItselfWhenFewerThanTwoBoxesAreLeft() {
        let state = BannerStackState()
        state.open = true
        state.closeIfAlone(3)
        state.closeIfAlone(2)
        #expect(state.open)
        state.closeIfAlone(1)
        #expect(!state.open)
    }

    @Test func aFailedDeletionCarriesItsTitleAndWhatItsButtonsMayDo() throws {
        let items = BannerItems.make(everything())
        let failed = try #require(items.first { $0.kind == .deletionFailure(first) })
        #expect(failed.text == DeletionCopy.bannerText(lastFailure: "files") && failed.detail == "Port the sidebar")
        #expect(failed.canRetry && failed.canRemove && failed.deletion == first)
        let running = try #require(items.first { $0.kind == .deleting(second) })
        #expect(running.text == "Deleting Weekly vault…" && running.detail == nil)
        let unnamed = BannerItems.make(BannerSources(deletions: [
            BannerDeletion(id: first, title: "", isDeleting: true, lastFailure: nil, canRetry: false, canRemove: false)]))
        #expect(unnamed.first?.text == "Deleting a session…")
        let untitled = BannerItems.make(BannerSources(deletions: [
            BannerDeletion(id: first, title: "", isDeleting: false, lastFailure: nil, canRetry: true, canRemove: false)]))
        #expect(untitled.first?.detail == nil)
    }

    @Test func theStackReadsTheModelsSlotsAndACrossClearsTheSlotItClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-edges-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        #expect(Banners.isEmpty(for: model))
        model.reportFailure("failed")
        model.showInfo("noted")
        model.ownershipNotice = "limits"
        model.statusMessage = "Stopping…"
        let items = Banners.items(for: model)
        #expect(items.map(\.kind) == [.error, .ownership, .info, .progress])
        model.dismissError()
        model.dismissInfo()
        #expect(Banners.items(for: model).map(\.kind) == [.ownership, .progress], "× clears the model's own slot")
    }

    @Test func theLiveIssueRidesTheStackOnlyOnTheRoutesThatShowTheSessionLive() {
        let issue = SessionIssueNotice.message(for: SessionViewState(runID: UUID(), issue: "watchdog"))
        #expect(issue == "watchdog")
        let items = BannerItems.make(BannerSources(sessionIssue: issue, ownership: "limits"))
        #expect(items.map(\.kind) == [.sessionIssue, .ownership], "the failure comes before the attention notice")
        #expect(items.first?.identifier == "session-issue-notice" && items.last?.identifier == "ownership-notice")
    }

    @Test func theEvidenceSeamRaisesEachKindThroughTheAppsOwnSlot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-edges-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        for kind in CatalogModel.evidenceBannerKinds { #expect(model.raiseBannerForEvidence(kind), Comment(rawValue: kind)) }
        #expect(!model.raiseBannerForEvidence("unknown"))
        #expect(model.bannerStackForEvidence == ["error-message:failure:x", "ownership-notice:attention",
                                                 "info-message:note:x", "status-message:note"])
        model.clearBannersForEvidence()
        #expect(model.bannerStackForEvidence.isEmpty)
    }

    // MARK: The ended line

    @Test func theEndedLineHasShowDetailsFirstAndResumeLast() {
        #expect(EndedScreenNotice.buttons(showsDetails: true) == [.showDetails, .resume])
        #expect(EndedScreenNotice.buttons(showsDetails: false) == [.resume], "the chat's read-only view has no screen to let go of")
        #expect(EndedScreenNotice.text(busy: nil) == "This session is not running.")
        #expect(EndedScreenNotice.text(busy: .resuming) == "Resuming…")
        #expect(EndedScreenNotice.resumeTitle(stale: true) == "Reactivate and Resume")
        #expect(EndedScreenNotice.resumeTitle(stale: false) == "Resume")
    }

    @Test func theEdgesKeepTheirNumbers() {
        typealias Edges = LoomTheme.Edges
        #expect(Edges.endedHeight == 40 && Edges.endedPaddingLeading == 20 && Edges.endedPaddingTrailing == 12)
        #expect(Edges.recordColumn == 620 && Edges.recordPaddingTop == 34 && Edges.recordPaddingH == 32 && Edges.recordPaddingBottom == 40)
        #expect(Edges.noticeRadius == 12 && Edges.noticeWashOpacity == 0.10 && Edges.noticeEdgeOpacity == 0.30)
        #expect(Edges.factLabelWidth == 150 && Edges.factsRadius == 12 && Edges.factRowPaddingV == 9 && Edges.factRowPaddingH == 16)
        #expect(Edges.stackPaddingTop == 8 && Edges.stackPaddingH == 12 && Edges.stackGap == 6)
    }

    // MARK: The record

    @Test func theRecordIsTheNoticeFirstWhenTheStateHasOneThenTheStateThenTheFacts() {
        typealias Detail = ConversationDetail
        let withNotice: [(SessionIndicator, RecordNotice.Tone, String)] = [
            (.unviewedCompletion, .unviewed, "Finished while you were away"),
            (.failed("API Error: 529"), .failure, "Claude reported a failure"),
            (.stopUnverified("1 remaining"), .failure, "Stop could not be verified"),
            (.problem("No events"), .failure, "This session has a problem"),
            (.identityUnclear, .attention, "Session identity is not certain"),
        ]
        for (indicator, tone, title) in withNotice {
            let notice = Detail.notice(for: indicator, provider: "Claude")
            #expect(notice?.tone == tone && notice?.title == title, "\(indicator)")
            #expect(Detail.sections(for: indicator) == [.notice, .state, .facts], "\(indicator)")
        }
        // A state with nothing to say starts at "Not running".
        for indicator in [SessionIndicator.unknown, .ended, .stale, .idle] {
            #expect(Detail.notice(for: indicator, provider: "Claude") == nil)
            #expect(Detail.sections(for: indicator) == [.state, .facts], "\(indicator)")
        }
        #expect(Detail.notice(for: .failed(nil), provider: "Claude")?.text == "No details were provided.")
        #expect(Detail.notice(for: .identityUnclear, provider: "Claude")?.text
            == "Sphyrna could not tell which Claude session this is, so it changed nothing.")
        #expect(Set(withNotice.compactMap { Detail.notice(for: $0.0, provider: "Claude")?.symbol }).count == 3,
                "the triangle, the question diamond and the check")
    }

    @Test func theStatusFactDrawsItsMarkOnlyForAStateThatHasOne() {
        for indicator in [SessionIndicator.ready, .idle, .stale, .ended, .working] {
            #expect(!ConversationDetail.statusDrawsMark(indicator), "\(indicator)")
        }
        for indicator in [SessionIndicator.unknown, .failed(nil), .stopUnverified("x"), .problem("x"), .identityUnclear, .unviewedCompletion] {
            #expect(ConversationDetail.statusDrawsMark(indicator), "\(indicator)")
        }
    }

    // MARK: The draft page's notes

    @Test func theDraftPagesTwoNotesAreBannersAndEachGoesWithItsCause() {
        #expect(DraftNotes.make(sendBlock: nil, storeNotice: nil).isEmpty)
        let both = DraftNotes.make(sendBlock: "This message is too long.", storeNotice: "This draft could not be saved.")
        #expect(both.map(\.identifier) == ["draft-store-notice", "draft-send-block"])
        #expect(both.map(\.tone) == [.attention, .note], "a draft that is not kept limits the page; a long message is a note")
        #expect(DraftNotes.make(sendBlock: "This message is too long.", storeNotice: nil).map(\.tone) == [.note])
        #expect(DraftNotes.make(sendBlock: nil, storeNotice: "This draft could not be saved.").map(\.tone) == [.attention])
    }

    // MARK: The menu bar menu

    @Test func theMenuRowsDotIsSevenPointsAndNewClaudeSessionHasClaudesMark() {
        #expect(LoomTheme.MenuBar.rowDot == 7 && LoomTheme.MenuBar.rowGlyph == 12)
        #expect(MenuBarArt.rowDotImage(.attention).size == NSSize(width: 12, height: 12))
        // The build under test carries no harness image; where it does, the mark is 14.
        if let mark = MenuBarArt.newSessionImage() { #expect(mark.size == NSSize(width: 14, height: 14)) }
        #expect(MenuBarMenu.items(for: MenuBarState.derive([])).contains { $0.kind == .newSession && $0.title == "New Claude Session" })
    }

    // MARK: The symbol colour

    /// The banner symbol's text variants (`fail-text`, `attn-text`) read on every raised surface. That the symbol takes the
    /// variant, not the hue, is a source rule: `scripts/check-source-guards.py` (banner-symbol).
    @Test func theBannerSymbolsTextVariantsReadOnEveryRaisedSurface() {
        for appearance in Appearance.allCases {
            for tone in PaneTone.allCases {
                let greys = LoomTheme.Surface.greys(appearance, tone: tone)
                for pair in [LoomTheme.Status.failureLightPair, LoomTheme.Status.attentionLightPair] {
                    #expect(pair[appearance].contrast(with: greys.raised2) >= 4.5, "\(appearance) \(tone)")
                }
            }
        }
    }
}
