import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// I4-0: which routes draw the pane's 52 pt header row and its hairline, the draft's line, the clearance a page keeps while
/// the window's buttons float over it, and the faint grid. Plain values and offscreen renders; nothing opens a window.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct DetailShellTests {
    private let project = UUID()
    private var routes: [DetailRoute] {
        let id = UUID()
        return [.startupError("x"), .devTerminal, .terminal(sessionID: id), .endedScreen(sessionID: id), .record(sessionID: id),
                .chat(sessionID: id), .home, .draft(projectID: project), .draft(projectID: nil), .projectPage(projectID: project),
                .noSelection]
    }

    // MARK: The header row

    @Test func onlyHomeAndTheProjectPageDrawNoHeaderRow() {
        for route in routes {
            let bare: Bool
            switch route {
            case .home, .projectPage: bare = true
            default: bare = false
            }
            #expect(route.drawsHeaderRow == !bare, "\(route)")
        }
    }

    @Test func theHairlineBelongsToASessionAndTheDevelopmentTerminalOnly() {
        for route in routes {
            let hairline = DetailHeader.drawsHairline(showsSessionHeader: route.showsSessionHeader, showsDevTerminal: route == .devTerminal)
            switch route {
            case .terminal, .endedScreen, .record, .chat, .devTerminal: #expect(hairline, "\(route)")
            case .startupError, .home, .draft, .projectPage, .noSelection: #expect(!hairline, "\(route)")
            }
        }
    }

    @Test func onlyTheDraftRouteCarriesADraftLine() {
        #expect(DetailRoute.draft(projectID: project).draftHeader == DraftHeaderTarget(projectID: project))
        #expect(DetailRoute.draft(projectID: nil).draftHeader == DraftHeaderTarget(projectID: nil))
        for route in routes where !{ if case .draft = route { true } else { false } }() {
            #expect(route.draftHeader == nil, "\(route)")
        }
    }

    // MARK: Clearance for the window buttons

    @Test func aPageKeepsClearOfTheFloatingButtonsOnlyWhileTheSidebarIsCollapsed() {
        // 130 = 20 in, the 66 pt clearance for the native buttons and 8, the 28 pt "Show Sidebar" and 8 more.
        #expect(DetailPageChrome.leadingClearance(sidebarCollapsed: false, isFullScreen: false) == 0)
        #expect(DetailPageChrome.leadingClearance(sidebarCollapsed: false, isFullScreen: true) == 0)
        #expect(DetailPageChrome.leadingClearance(sidebarCollapsed: true, isFullScreen: false) == 130)
        // 56 in full screen: the native buttons are gone, "Show Sidebar" is the first thing in the row.
        #expect(DetailPageChrome.leadingClearance(sidebarCollapsed: true, isFullScreen: true) == 56)
    }

    @Test func aBannerOverAPageWithoutARowKeepsTheHeadersHeight() {
        for route in routes {
            let top = DetailPageChrome.bannerTop(route: route, bannersAreEmpty: false)
            #expect(top == (route.drawsHeaderRow ? 0 : 52), "\(route)")
            #expect(DetailPageChrome.bannerTop(route: route, bannersAreEmpty: true) == 0, "\(route)")
        }
    }

    // MARK: The draft's line

    @Test func theCrumbNamesTheProjectOrSaysOnlyNewSession() {
        #expect(DraftHeaderLine.crumbWords(projectName: "loom") == "loom / new session")
        #expect(DraftHeaderLine.crumbWords(projectName: nil) == "new session")
    }

    @Test func theButtonCountsTheProjectsSessionsAndIsLeftOutAtNone() {
        #expect(DraftHeaderLine.sessionsWords(count: 0, projectName: "loom") == nil)
        #expect(DraftHeaderLine.sessionsWords(count: 1, projectName: "loom") == "1 session in loom")
        #expect(DraftHeaderLine.sessionsWords(count: 2, projectName: "loom") == "2 sessions in loom")
        #expect(DraftHeaderLine.sessionsWords(count: 9, projectName: "loom") == "9 sessions in loom")
        #expect(DraftHeaderLine.tooltip == "Opens the project's page")
    }

    private func model(sessions: Int) async throws -> (CatalogModel, UUID, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-detail-shell-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("harbor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let projectID = try await catalog.addProject(path: folder.path).project.id
        for index in 0..<sessions {
            try await catalog.insertSession(
                ManagedSession(provider: .claude, workingDirectory: folder.path), title: "Row \(index)",
                createdAt: Date(timeIntervalSince1970: 1_000 + Double(index)),
                lastUsedAt: Date(timeIntervalSince1970: 10_000 + Double(index)), lifecycle: .idle, projectID: projectID)
        }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("ui-preferences.json")))
        await model.start()
        return (model, projectID, root)
    }

    @Test func theDraftsLineReadsTheModelsProjectAndCounts() async throws {
        let (empty, emptyID, emptyRoot) = try await model(sessions: 0)
        defer { empty.stop(); try? FileManager.default.removeItem(at: emptyRoot) }
        #expect(DraftHeaderLine.words(model: empty, projectID: emptyID)
                == DraftHeaderLine.Words(crumb: "harbor / new session", sessions: nil), "no sessions: no button")
        #expect(DraftHeaderLine.words(model: empty, projectID: nil)
                == DraftHeaderLine.Words(crumb: "new session", sessions: nil), "no project: only new session")

        let (one, oneID, oneRoot) = try await model(sessions: 1)
        defer { one.stop(); try? FileManager.default.removeItem(at: oneRoot) }
        #expect(DraftHeaderLine.words(model: one, projectID: oneID).sessions == "1 session in harbor")

        let (three, threeID, threeRoot) = try await model(sessions: 3)
        defer { three.stop(); try? FileManager.default.removeItem(at: threeRoot) }
        #expect(DraftHeaderLine.words(model: three, projectID: threeID)
                == DraftHeaderLine.Words(crumb: "harbor / new session", sessions: "3 sessions in harbor"))
        // A project the catalog no longer has reads as a draft with no project.
        #expect(DraftHeaderLine.words(model: three, projectID: UUID()).crumb == "new session")
    }

    private func fittingHeight<Content: View>(_ content: Content) -> CGFloat {
        let hosting = NSHostingView(rootView: content.frame(width: 800))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    @Test func theDraftsRowAndThePagesChromeAre52High() async throws {
        let (model, projectID, root) = try await model(sessions: 2)
        defer { model.stop(); try? FileManager.default.removeItem(at: root) }
        let draft = DraftHeaderTarget(projectID: projectID)
        #expect(fittingHeight(DetailHeader(model: model, showsSessionHeader: false, draft: draft)) == 52)
        #expect(fittingHeight(DetailPageChrome(model: model)) == 52)
    }

    // MARK: The grid

    @Test func theGridsGeometryIsTheReferences() {
        typealias C = LoomTheme.Canvas
        #expect(C.cell == 28 && C.line == 1)
        #expect(C.radialCentre == CGPoint(x: 0.5, y: 0.46) && C.radialRadii == CGSize(width: 0.78, height: 0.74))
        #expect(C.radialOpaque == 0.38)
        #expect(C.bandHeight == 300 && C.bandOpaque == 0.30)
        // The pattern is centred: a cell's edge at (length - 28) / 2, repeated every 28.
        #expect(C.lineOffsets(length: 280) == [14, 42, 70, 98, 126, 154, 182, 210, 238, 266])
        #expect(C.lineOffsets(length: 100) == [8, 36, 64, 92])
        #expect(C.lineOffsets(length: 28) == [0])
        #expect(C.lineOffsets(length: 10).isEmpty, "a box narrower than the first line's place has none")
        #expect(C.lineOffsets(length: 0).isEmpty)
        // The colour is the Grid row of DESIGN §3.
        #expect(LoomTheme.Surface.gridTone.dark.opacity == 0.034 && LoomTheme.Surface.gridTone.light.opacity == 0.06)
    }

    /// The alpha channel of an offscreen render, by pixel (column, row from the top), at scale 1.
    private func alphaMap(of view: some View, width: Int, height: Int) throws -> (Int, Int) -> Int {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(width), height: CGFloat(height), alignment: .top)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == width && image.height == height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drawn)
        return { x, y in Int(bytes[(y * width + x) * 4 + 3]) }
    }

    /// The radial grid: a line is Ink's 3.4 % (about 9 of 255) where the mask is opaque, fainter toward the corner (the ellipse
    /// of 78 % by 74 % still reaches a little past it), and nothing between two lines.
    @Test func theRadialGridIsDrawnUnderItsMask() throws {
        // 560 x 400: vertical lines at 14 + 28k, horizontal ones at 18 + 28k.
        let alpha = try alphaMap(of: CanvasGrid(mask: .radial), width: 560, height: 400)
        let centre = alpha(266, 100), corner = alpha(14, 4)
        #expect((8...9).contains(centre), "centre line: \(centre)")
        #expect(alpha(186 + 3, 100) == 0 && alpha(100, 100) == 0, "between the lines: nothing")
        #expect(abs(alpha(100, 186) - centre) <= 1, "a horizontal line is as strong in the opaque part")
        #expect(corner > 0 && corner < centre / 2, "corner line: \(corner)")
        #expect(alpha(266, 186) > centre, "a crossing is brighter: the reference lays two gradients over each other")
    }

    /// Home's band: 300 high, opaque to 30 %, fading to nothing at its foot, and nothing under it.
    @Test func theBandGridFadesDownAndStopsAtItsHeight() throws {
        // 560 x 500: vertical lines at 14 + 28k; the band's horizontal lines at 24 + 28k.
        let alpha = try alphaMap(of: CanvasGrid(mask: .band), width: 560, height: 500)
        let top = alpha(266, 30), middle = alpha(266, 200), foot = alpha(266, 296)
        #expect((8...9).contains(top), "top: \(top)")
        #expect(middle < top && middle > foot, "fading: \(top) \(middle) \(foot)")
        #expect(foot <= 1, "foot: \(foot)")
        #expect(alpha(266, 301) == 0 && alpha(266, 450) == 0 && alpha(14, 499) == 0, "below the band: nothing")
    }
}
