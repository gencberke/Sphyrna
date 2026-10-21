import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

/// Project colours (D-48): the setting, what each surface decides to draw while it is on or off, the tab
/// tint per state, and the contrast of every tone on the surfaces it sits on.
@MainActor
struct ProjectColorUITests {
    typealias RGB = LoomTheme.RGB

    // MARK: Setting

    @Test func projectColorsDefaultOnAndAFileWithoutTheKeyReadsAsOn() throws {
        #expect(UIPreferences().projectColors)
        let old = Data(#"{"sidebarWidth": 320, "viewMode": "projects"}"#.utf8)
        let decoded = try JSONDecoder().decode(UIPreferences.self, from: old)
        #expect(decoded.projectColors && decoded.sidebarWidth == 320)

        var off = UIPreferences()
        off.projectColors = false
        let again = try JSONDecoder().decode(UIPreferences.self, from: JSONEncoder().encode(off))
        #expect(!again.projectColors)
        // An unreadable value falls back to on, like every other key.
        let odd = Data(#"{"projectColors": "maybe"}"#.utf8)
        #expect(try JSONDecoder().decode(UIPreferences.self, from: odd).projectColors)
    }

    private func fixture() async throws -> (CatalogModel, URL, CatalogProject, CatalogProject) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-colors-ui-\(UUID())")
        var projects: [CatalogProject] = []
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        for name in ["enmusait", "edd-backend"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            projects.append(try await catalog.addProject(path: folder.path).project)
        }
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait()
        await model.settle()
        return (model, root, projects[0], projects[1])
    }

    private func record(in project: CatalogProject?) -> CatalogSession {
        CatalogSession(
            session: ManagedSession(provider: .claude, workingDirectory: "/tmp"), title: "Playlist import",
            createdAt: Date(timeIntervalSince1970: 0), lastUsedAt: Date(timeIntervalSince1970: 0),
            lifecycle: .idle, pinned: false, projectID: project?.id)
    }

    @Test func withColorsOnEachSurfaceGetsTheProjectsToneAndName() async throws {
        let (model, root, first, second) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.projectColorsEnabled)
        #expect(model.projectTone(forProject: first.id) == .rose)
        #expect(model.projectTone(forProject: second.id) == .orchid)
        #expect(model.projectTone(forProject: nil) == nil, "the projectless group stays neutral")
        #expect(model.projectMark(of: record(in: first)) == ProjectMark(name: "enmusait", tone: .rose))
        #expect(model.projectMark(of: record(in: nil)) == nil)
    }

    @Test func settingATonePersistsAndShowsAtOnceAndNoneKeepsTheNameWithoutAStripe() async throws {
        let (model, root, first, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.setProjectTone(first.id, .lemon)
        #expect(model.projectTone(forProject: first.id) == .lemon)
        #expect(model.projects.first { $0.id == first.id }?.tone == .lemon)
        await model.setProjectTone(first.id, nil)
        #expect(model.projectTone(forProject: first.id) == nil)
        #expect(model.projects.first { $0.id == first.id }?.colorIsNone == true)
        #expect(model.projectMark(of: record(in: first)) == ProjectMark(name: "enmusait", tone: nil),
                "None: the header and tab still name the project, with no stripe or tint")
        #expect(model.errorMessage == nil)
    }

    @Test func withColorsOffNothingIsDrawnAndTheStoredColorsComeBack() async throws {
        let (model, root, first, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setProjectColors(false)
        #expect(!model.projectColorsEnabled)
        #expect(model.projectTone(forProject: first.id) == nil, "no sidebar stripe")
        #expect(model.projectMark(of: record(in: first)) == nil, "no header label, no tab tint, tooltip line or label part")
        let mark = model.projectMark(of: record(in: first))
        #expect(ProjectTabStyle(tone: mark?.tone, selected: true, hovering: false)
                == ProjectTabStyle(tone: nil, selected: true, hovering: false))
        #expect(ConversationTabItem.tooltip(title: "Playlist import", project: mark?.name) == "Playlist import")
        #expect(ConversationTabItem.accessibilityLabel(
            title: "Playlist import", status: "Finished", transient: false, project: mark?.name) == "Playlist import, Finished")
        // The setting is written, and the catalog's tone survived: switching back restores it.
        model.flushPreferences()
        let saved = try JSONDecoder().decode(UIPreferences.self, from: Data(contentsOf: root.appendingPathComponent("p.json")))
        #expect(!saved.projectColors)
        await model.setProjectTone(first.id, .mint)
        model.setProjectColors(true)
        #expect(model.projectTone(forProject: first.id) == .mint)
    }

    @Test func theTabTooltipAndLabelNameTheProjectWhileColorsAreOn() {
        #expect(ConversationTabItem.tooltip(title: "Playlist import", project: "enmusait") == "Playlist import\nProject: enmusait")
        #expect(ConversationTabItem.accessibilityLabel(
            title: "Playlist import", status: "Finished", transient: false, project: "enmusait")
                == "Playlist import, Finished, project enmusait")
        #expect(ConversationTabItem.accessibilityLabel(
            title: "Playlist import", status: nil, transient: true, project: "enmusait")
                == "Playlist import, project enmusait, not pinned")
    }

    // MARK: Tab tint

    @Test func theTabTintStrengthsComeFromTheThemeTokensPerState() throws {
        let tone = ProjectTone.aqua
        let rgb = LoomTheme.ProjectColor.baseRGB(tone)
        let rest = ProjectTabStyle(tone: tone, selected: false, hovering: false)
        let hover = ProjectTabStyle(tone: tone, selected: false, hovering: true)
        let open = ProjectTabStyle(tone: tone, selected: true, hovering: false)
        let openHover = ProjectTabStyle(tone: tone, selected: true, hovering: true)
        #expect(rest.wash == LoomTheme.Tone(rgb: rgb, opacity: LoomTheme.ProjectColor.tabWash))
        #expect(hover.wash == LoomTheme.Tone(rgb: rgb, opacity: LoomTheme.ProjectColor.tabWashHover))
        #expect(open.wash == LoomTheme.Tone(rgb: rgb, opacity: LoomTheme.ProjectColor.tabWashOpen))
        #expect(openHover == open, "the open tab does not change on hover")
        #expect([LoomTheme.ProjectColor.tabWash, LoomTheme.ProjectColor.tabWashHover,
                 LoomTheme.ProjectColor.tabWashOpen, LoomTheme.ProjectColor.tabStrokeOpen] == [0.06, 0.11, 0.16, 0.42])
        #expect(rest.stroke == nil && hover.stroke == nil, "only the open tab carries the tone's stroke")
        let stroke = try #require(open.stroke)
        #expect(stroke.tone(for: .standard) == LoomTheme.Tone(rgb: rgb, opacity: LoomTheme.ProjectColor.tabStrokeOpen))
        // Increase Contrast: the stroke takes the lighter stripe colour; the washes do not change.
        #expect(stroke.tone(for: .increased).rgb == LoomTheme.ProjectColor.increasedRGB(tone))
        #expect(stroke.tone(for: .increased).opacity > stroke.tone(for: .standard).opacity)
        // No tone (None, unknown, projectless, colors off): today's fill and stroke.
        for selected in [false, true] {
            let neutral = ProjectTabStyle(tone: nil, selected: selected, hovering: true)
            #expect(neutral.wash == nil && neutral.stroke == nil)
        }
    }

    @Test func stripesAreFourPointsUnderIncreaseContrast() {
        #expect(LoomTheme.ProjectColor.stripeWidth(for: .standard) == 3)
        #expect(LoomTheme.ProjectColor.stripeWidth(for: .increased) == 4)
        for tone in ProjectTone.allCases {
            #expect(LoomTheme.ProjectColor.stripeRGB(tone, for: .standard) == LoomTheme.ProjectColor.baseRGB(tone))
            #expect(LoomTheme.ProjectColor.stripeRGB(tone, for: .increased) == LoomTheme.ProjectColor.increasedRGB(tone))
        }
    }

    // MARK: The project's mark

    @Test func theMarkIsTheInitialOnASoftSquareOfTheTone() {
        typealias M = LoomTheme.ProjectMarkStyle
        let sizes = M.Size.allCases.map { ($0.side, $0.radius) }
        #expect(sizes.contains { $0 == (16, 5) } && sizes.contains { $0 == (14, 4) } && sizes.contains { $0 == (12, 3.5) }
                && sizes.contains { $0 == (26, 8) } && sizes.count == 4)
        #expect(M.initial(of: "edd-backend") == "E" && M.initial(of: "  loom") == "L" && M.initial(of: "") == "?")
        for tone in ProjectTone.allCases {
            let square = M.square(tone)
            #expect(square.dark == LoomTheme.Tone(rgb: LoomTheme.ProjectColor.baseRGB(tone), opacity: 0.24), "\(tone), Ink")
            #expect(square.light == LoomTheme.Tone(rgb: LoomTheme.ProjectColor.lightBaseRGB(tone), opacity: 0.15), "\(tone), Paper")
            let initial = M.initialStyle(tone)
            #expect(initial.tone(for: .standard, appearance: .dark).rgb == LoomTheme.ProjectColor.baseRGB(tone))
            #expect(initial.tone(for: .increased, appearance: .dark).rgb == LoomTheme.ProjectColor.increasedRGB(tone))
            #expect(initial.tone(for: .increased, appearance: .light).rgb == LoomTheme.ProjectColor.lightIncreasedRGB(tone))
        }
        #expect(M.neutralSquare == LoomTheme.Surface.selectedTone, "no tone: the selected fill")
    }

    /// The initial holds 3:1 on its square over the canvas, in both appearances, the three casts and every tone, also under
    /// Increase Contrast (DESIGN §6 Project colour: Ink 5.5 to 7.6, Paper 3.8 to 4.5). Without a tone the initial is secondary
    /// text on the neutral square (4.5:1).
    @Test func theInitialHoldsThreeToOneOnItsSquareInBothAppearancesAndEveryCast() {
        typealias M = LoomTheme.ProjectMarkStyle
        for appearance in LoomTheme.Appearance.allCases {
            for pane in PaneTone.allCases {
                let canvas = LoomTheme.Surface.greys(appearance, tone: pane).canvas
                for tone in ProjectTone.allCases {
                    let square = M.square(tone)[appearance]
                    let ground = square.rgb.composited(over: canvas, opacity: square.opacity)
                    for contrast in [ColorSchemeContrast.standard, .increased] {
                        let initial = M.initialStyle(tone).tone(for: contrast, appearance: appearance).rgb
                        #expect(initial.contrast(with: ground) >= 3, "\(appearance) \(pane) \(tone) \(contrast): \(initial.contrast(with: ground))")
                    }
                }
                let neutral = M.neutralSquare[appearance]
                let ground = neutral.rgb.composited(over: canvas, opacity: neutral.opacity)
                let secondary = LoomTheme.Text.secondaryPair[appearance]
                #expect(secondary.contrast(with: ground) >= 4.5, "\(appearance) \(pane) neutral")
            }
        }
    }

    /// A rendered mark: the square at the tone's own value and 24 % in Ink, a neutral square without a tone. Offscreen.
    @Test func aRenderedMarkDrawsTheToneOrTheNeutralSquare() throws {
        func edgePixel(_ tone: ProjectTone?, appearance: NSAppearance.Name) throws -> NSColor {
            let view = NSHostingView(rootView: ProjectMarkView(name: "L", tone: tone, size: .head))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            // Left edge, mid-height: square only, the initial sits in the middle.
            let scale = rep.pixelsWide / 16
            return try #require(rep.colorAt(x: 1 * scale, y: 8 * scale)?.usingColorSpace(.sRGB))
        }
        let rose = try edgePixel(.rose, appearance: .darkAqua)
        let tone = LoomTheme.ProjectColor.baseRGB(.rose)
        #expect(abs(Double(rose.alphaComponent) - 0.24) < 0.04, "alpha \(rose.alphaComponent)")
        #expect(abs(Double(rose.redComponent) - tone.red) < 0.06 && abs(Double(rose.blueComponent) - tone.blue) < 0.06)
        let neutral = try edgePixel(nil, appearance: .darkAqua)
        #expect(abs(Double(neutral.alphaComponent) - 0.08) < 0.04 && neutral.redComponent > 0.9, "the selected fill")
        let paper = try edgePixel(.rose, appearance: .aqua)
        #expect(abs(Double(paper.alphaComponent) - 0.15) < 0.04)
        let paperTone = LoomTheme.ProjectColor.lightBaseRGB(.rose)
        #expect(abs(Double(paper.redComponent) - paperTone.red) < 0.06, "Paper uses the deeper tone")
    }

    // MARK: Contrast and hue

    /// The sidebar is the tone's Ink canvas: opaque (Solid), over black, and over the glass's lightest extreme (the worst case,
    /// as in LoomThemeTests). The surfaces a stripe sits on, for each tone.
    private static func sidebarBackdrops(_ tone: PaneTone) -> [RGB] {
        let canvas = LoomTheme.Surface.greys(.dark, tone: tone).canvas
        return [canvas, canvas.composited(over: RGB(red: 0, green: 0, blue: 0), opacity: LoomTheme.Surface.sidebarTintOpacity),
                canvas.composited(over: RGB(red: 0.5, green: 0.5, blue: 0.5), opacity: LoomTheme.Surface.sidebarTintOpacity)]
    }
    private static func panel(_ tone: PaneTone) -> RGB { LoomTheme.Surface.greys(.dark, tone: tone).canvas }
    private static let white = RGB(red: 1, green: 1, blue: 1)

    private func hue(_ c: RGB) -> Double {
        let high = max(c.red, c.green, c.blue), low = min(c.red, c.green, c.blue), delta = high - low
        guard delta > 0 else { return 0 }
        let sector: Double
        if high == c.red { sector = ((c.green - c.blue) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == c.green { sector = (c.blue - c.red) / delta + 2 }
        else { sector = (c.red - c.green) / delta + 4 }
        return (sector * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    private func hueDistance(_ a: RGB, _ b: RGB) -> Double {
        let difference = abs(hue(a) - hue(b)).truncatingRemainder(dividingBy: 360)
        return difference > 180 ? 360 - difference : difference
    }

    @Test func everyStripeIsThreeToOneOnTheSidebarsWorstCaseAndOnItsOtherBackdrops() {
        for tone in ProjectTone.allCases {
            for surface in PaneTone.allCases.flatMap(Self.sidebarBackdrops) {
                #expect(LoomTheme.ProjectColor.baseRGB(tone).contrast(with: surface) >= 3)
                #expect(LoomTheme.ProjectColor.increasedRGB(tone).contrast(with: surface) >= 3)
            }
            // Increase Contrast only lightens.
            #expect(LoomTheme.ProjectColor.increasedRGB(tone).luminance > LoomTheme.ProjectColor.baseRGB(tone).luminance)
        }
    }

    @Test func everyToneStaysThirtyDegreesFromTheStatusHuesAndTheAccent() {
        let reserved = [LoomTheme.Status.attentionRGB, LoomTheme.Status.unviewedRGB, LoomTheme.Status.failureRGB,
                        LoomTheme.Accent.baseRGB]
        for tone in ProjectTone.allCases {
            for other in reserved {
                #expect(hueDistance(LoomTheme.ProjectColor.baseRGB(tone), other) >= 30)
            }
        }
    }

    /// The tab's fills as drawn: the canvas, the selection fill under the open tab, then the wash on top.
    private func tabFill(_ tone: ProjectTone, on pane: PaneTone, selected: Bool, wash: Double) -> RGB {
        let panel = Self.panel(pane)
        let base = selected ? Self.white.composited(over: panel, opacity: LoomTheme.Surface.selectedOpacity) : panel
        return LoomTheme.ProjectColor.baseRGB(tone).composited(over: base, opacity: wash)
    }

    /// The theme's tiers hold on the washed tabs in Ink, on every tone: primary at 7:1 on every tab (the open tab's 16 % wash), and a washed tab's secondary text in `secondaryOnTint`: 4.5 or more on a
    /// resting tab and 3:1 for the close glyph on the open one. (Paper is in `ThemeAppearanceTests`.)
    @Test func textOnTheTintedTabsKeepsTheThemeTiers() {
        for pane in PaneTone.allCases {
            for tone in ProjectTone.allCases {
                let id = "\(pane) \(tone)"
                let open = tabFill(tone, on: pane, selected: true, wash: LoomTheme.ProjectColor.tabWashOpen)
                let hover = tabFill(tone, on: pane, selected: false, wash: LoomTheme.ProjectColor.tabWashHover)
                let rest = tabFill(tone, on: pane, selected: false, wash: LoomTheme.ProjectColor.tabWash)
                #expect(LoomTheme.Text.primaryRGB.contrast(with: open) >= 7, "\(id) open")
                #expect(LoomTheme.Text.primaryRGB.contrast(with: hover) >= 7, "\(id) hover")
                #expect(LoomTheme.Text.primaryRGB.contrast(with: rest) >= 7, "\(id) rest")
                #expect(LoomTheme.Text.secondaryOnTintRGB.contrast(with: rest) >= 4.5, "\(id) rest secondary")
                #expect(LoomTheme.Text.secondaryOnTintRGB.contrast(with: open) >= 3, "\(id) open glyph")
                #expect(LoomTheme.Text.secondaryIncreasedRGB.contrast(with: rest) >= 4.5, "\(id) rest, Increase Contrast")
                #expect(LoomTheme.Text.secondaryIncreasedRGB.contrast(with: open) >= 4, "\(id) open glyph, Increase Contrast")
            }
        }
    }
}
