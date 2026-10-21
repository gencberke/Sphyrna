import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// I4c, the edges, drawn offscreen (nothing here is ordered onto the screen): the top stack's fitting (one box, "+N", opened), the
/// ended line's 40 pt, and the record's order and facts card.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct EdgesViewTests {
    private struct Fixture {
        let root: URL
        let hub: SessionEventHub
        let model: CatalogModel
        let sessionID: UUID

        @MainActor func cleanup() {
            model.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-edges-view-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("c.sqlite3"))
        let session = ManagedSession(provider: .claude, providerConversationID: "3f2a9c1e-5b7d-4e08-9a61-c2d4f0b8e715", workingDirectory: root.path)
        try await catalog.insertSession(session, title: "Stopped", lifecycle: .idle)
        let hub = SessionEventHub()
        let model = CatalogModel(catalog: catalog, events: hub, preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        model.select(session.id)
        return Fixture(root: root, hub: hub, model: model, sessionID: session.id)
    }

    private func fitting<V: View>(_ view: V, width: CGFloat = 700) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func hosted<V: View>(_ view: V, width: CGFloat, height: CGFloat = 800) -> (NSWindow, NSHostingView<V>) {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return (window, hosting)
    }

    private func settle(_ window: NSWindow, rounds: Int = 10) async {
        for _ in 0..<rounds {
            try? await Task.sleep(for: .milliseconds(80))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func texts(in hosting: NSView) -> [String] {
        accessibilityElements(in: hosting).flatMap { element -> [String] in
            let value: Any? = element.accessibilityValue?()
            return [element.accessibilityLabel?(), value as? String].compactMap { $0 }
        }
    }

    // MARK: The stack

    private func sources(_ count: Int) -> BannerSources {
        var sources = BannerSources()
        if count > 0 { sources.error = "Claude could not be started." }
        if count > 1 { sources.ownership = "New sessions are turned off." }
        if count > 2 { sources.info = "“loom” is already in Loom." }
        return sources
    }

    @Test func theStackIsNothingWithoutBannersOneBoxWithManyAndGrowsWhenOpened() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let model = fixture.model
        func stack(_ count: Int, open: Bool = false) -> CGSize {
            let state = BannerStackState()
            state.open = open
            return fitting(Banners(model: model, items: BannerItems.make(sources(count)), state: state))
        }
        let box = LoomTheme.ChatBanner.minHeight
        let top = LoomTheme.Edges.stackPaddingTop
        #expect(stack(0).height == 0, "the stack takes no layout space without a banner")
        let one = stack(1)
        #expect(abs(one.height - (top + box)) < 1, "one box: 8 above it and 36 high: \(one.height)")
        let closed = stack(3)
        #expect(abs(closed.height - one.height) < 1, "three banners, one box: the rest wait behind +N")
        let opened = stack(3, open: true)
        #expect(abs(opened.height - (top + 3 * box + 2 * LoomTheme.Edges.stackGap)) < 1, "opened: three boxes, 6 apart: \(opened.height)")
    }

    @Test func thePeekShowsOnlyWhileOthersWaitAndOnlyTheFailureAndTheNoteCarryACross() async throws {
        enableAccessibilityTree()
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        func ids(_ count: Int, open: Bool) async -> [String] {
            let state = BannerStackState()
            state.open = open
            let (window, hosting) = hosted(Banners(model: fixture.model, items: BannerItems.make(sources(count)), state: state), width: 700, height: 400)
            defer { window.contentView = nil; window.close() }
            await settle(window)
            return accessibilityElements(in: hosting).compactMap { $0.accessibilityIdentifier?() }
        }
        let one = await ids(1, open: false)
        #expect(!one.contains("banner-stack-peek") && one.contains("error-message"), "\(one)")
        let many = await ids(3, open: false)
        #expect(many.contains("banner-stack-peek") && many.contains("error-message") && !many.contains("ownership-notice"), "\(many)")
        let opened = await ids(3, open: true)
        #expect(opened.contains("ownership-notice") && opened.contains("info-message") && opened.contains("banner-stack-peek"))
    }

    // MARK: The ended line

    @Test func theEndedLineIsFortyHighAndGetsEightAndAHairlineAfterAStack() async throws {
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let row = try #require(fixture.model.selectedRow)
        let line = fitting(EndedScreenNotice(model: fixture.model, row: row))
        #expect(abs(line.height - 40) < 0.5 && LoomTheme.Edges.endedHeight == 40, "\(line.height)")
        let afterStack = fitting(EndedScreenNotice(model: fixture.model, row: row).environment(\.bannerStackShown, true))
        #expect(abs(afterStack.height - (40 + LoomTheme.Edges.endedAfterStackTop + LoomTheme.Line.hairline)) < 0.5, "\(afterStack.height)")
        let chat = fitting(EndedScreenNotice(model: fixture.model, row: row, showsDetails: false))
        #expect(abs(chat.height - 40) < 0.5, "the chat's read-only view keeps the same line")
    }

    @Test func theEndedLinesButtonsRunShowDetailsThenResumeAtTheTrailingEdge() async throws {
        enableAccessibilityTree()
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let row = try #require(fixture.model.selectedRow)
        let (window, hosting) = hosted(EndedScreenNotice(model: fixture.model, row: row), width: 700, height: 60)
        defer { window.contentView = nil; window.close() }
        await settle(window)
        let labels = texts(in: hosting)
        let details = try #require(labels.firstIndex(of: "Show Details"))
        let resume = try #require(labels.firstIndex(of: "Resume"))
        #expect(details < resume, "Show Details first, Resume last: \(labels)")
        #expect(labels.contains("This session is not running."))
        let ids = accessibilityElements(in: hosting).compactMap { $0.accessibilityIdentifier?() }
        #expect(ids.contains("ended-screen-notice"))
    }

    // MARK: The record

    @Test func theRecordIsTheNoticeFirstThenNotRunningThenTheFactsCard() async throws {
        enableAccessibilityTree()
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        await fixture.hub.publish(sessionID: fixture.sessionID, change: .runStarted(UUID()))
        await fixture.hub.publish(sessionID: fixture.sessionID, change: .status(ProviderWorkState(activity: .failed("rate_limit"))))
        for _ in 0..<100 {
            if case .failed = fixture.model.selectedRow?.indicator { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let row = try #require(fixture.model.selectedRow)
        guard case .failed = row.indicator else { Issue.record("the row did not fail: \(row.indicator)"); return }
        let (window, hosting) = hosted(ConversationDetail(model: fixture.model, row: row), width: 700)
        defer { window.contentView = nil; window.close() }
        await settle(window)
        let labels = texts(in: hosting)
        let notice = try #require(labels.firstIndex(of: "Claude reported a failure"), "\(labels)")
        let heading = try #require(labels.firstIndex { $0 == "Running" || $0 == "Not running" || $0 == "Not available right now" })
        let facts = try #require(labels.firstIndex(of: "Claude session ID"))
        #expect(notice < heading && heading < facts, "the notice, then the state, then the facts: \(labels)")
        #expect(labels.firstIndex(of: "Working directory").map { $0 > heading } == true)
        #expect(!labels.contains("Stopped"), "no title block: the header holds the title")
    }

    @Test func theFactsCardIsOneRaisedColumnAtMostSixHundredTwentyWide() async throws {
        enableAccessibilityTree()
        let fixture = try await fixture()
        defer { fixture.cleanup() }
        let row = try #require(fixture.model.selectedRow)
        let (window, hosting) = hosted(ConversationDetail(model: fixture.model, row: row), width: 900)
        defer { window.contentView = nil; window.close() }
        await settle(window)
        let elements = accessibilityElements(in: hosting)
        let card = try #require(elements.first { ($0.accessibilityIdentifier?() ?? "") == "record-facts" })
        let frame = try #require(card.accessibilityFrame?())
        #expect(abs(frame.width - LoomTheme.Edges.recordColumn) <= 1, "centred column of 620: \(frame)")
        // Seven rows (no origin): each 9 + a line + 9 inside, the rules between.
        #expect(frame.height >= 7 * 30 && frame.height < 7 * 60, "\(frame)")
        let ids = elements.compactMap { $0.accessibilityIdentifier?() }
        #expect(!ids.contains("record-stop"))
        let labels = texts(in: hosting)
        for name in ["Status", "Project", "Working directory", "Claude session ID", "Created", "Last activity", "Last used"] {
            #expect(labels.contains(name), "\(name): \(labels)")
        }
    }
}
