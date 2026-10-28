import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

/// FB3-2 (D-53): the detail header row of "A with the branch": the state pill, the project chip that ends
/// with the Git branch, the hairline and the control group. Pure rules first, then the real `DetailHeader`
/// hosted in a window that is never ordered front, measured through its accessibility frames.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct SessionHeaderTests {
    typealias RGB = LoomTheme.RGB
    private static let panel = LoomTheme.Surface.greys(.dark, tone: .neutral).canvas
    private static let white = RGB(red: 1, green: 1, blue: 1)

    // MARK: Contrast

    /// A tone as drawn over the panel.
    private func over(_ tone: LoomTheme.Tone, _ backdrop: RGB = SessionHeaderTests.panel) -> RGB {
        tone.rgb.composited(over: backdrop, opacity: tone.opacity)
    }

    private let allStates: [SessionIndicator] = [
        .working, .waitingForApproval, .waitingForInput, .unknown, .failed(nil), .stopUnverified("x"), .problem("x"),
        .identityUnclear, .unviewedCompletion, .ready, .idle, .stale,
    ]

    /// Every pill label on its own wash over the panel keeps the secondary tier (4.5:1), and the working
    /// label, in primary text, the primary tier (7:1). Plain secondary text on the 5 % wash is 4.1:1 and the
    /// plain failure and unviewed colours are 4.3 to 4.4:1 on theirs, hence the lifted label tokens.
    @Test func everyPillLabelKeepsItsContrastTierOnItsWash() throws {
        for state in allStates {
            let style = try #require(StatePillStyle(state))
            let wash = over(style.wash)
            for contrast in [ColorSchemeContrast.standard, .increased] {
                let label = style.text.tone(for: contrast).rgb
                let floor = state == .working ? 7.0 : 4.5
                #expect(label.contrast(with: wash) >= floor, "\(style.label) (\(contrast)): \(label.contrast(with: wash))")
            }
        }
        // Plain secondary holds on the neutral wash.
        let neutralWash = over(LoomTheme.Tone(rgb: Self.white, opacity: LoomTheme.Header.pillNeutralWash))
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: neutralWash) >= 4.5)
    }

    @Test func pillWashesAndLabelsFollowTheSpec() throws {
        #expect(StatePillStyle(.ended) == nil, "no label, no pill")
        // Ready, Idle, Stale and State unknown draw no mark (DESIGN §4), so the pill has none either.
        for state in allStates {
            #expect(StatePillStyle(state)?.showsIndicator == ![.ready, .idle, .stale, .unknown].contains(state), "\(state)")
        }
        let working = try #require(StatePillStyle(.working))
        #expect(working.wash.opacity == LoomTheme.Surface.selectedOpacity && working.text.standard.rgb == LoomTheme.Text.primaryRGB)
        for state in [SessionIndicator.ready, .idle, .stale, .unknown] {
            let style = try #require(StatePillStyle(state))
            #expect(style.wash.opacity == LoomTheme.Surface.hoverOpacity && style.wash.rgb == Self.white, "\(state)")
            #expect(style.text.standard.rgb == LoomTheme.Text.secondaryOnTintRGB)
            #expect(style.text.increased.rgb == LoomTheme.Text.secondaryIncreasedRGB)
        }
        for (state, status) in [(SessionIndicator.waitingForApproval, LoomTheme.Status.attentionRGB),
                                (.waitingForInput, LoomTheme.Status.attentionRGB),
                                (.identityUnclear, LoomTheme.Status.attentionRGB),
                                (.failed(nil), LoomTheme.Status.failureRGB), (.stopUnverified("x"), LoomTheme.Status.failureRGB),
                                (.problem("x"), LoomTheme.Status.failureRGB),
                                (.unviewedCompletion, LoomTheme.Status.unviewedRGB)] {
            let style = try #require(StatePillStyle(state))
            #expect(style.wash == LoomTheme.Tone(rgb: status, opacity: 0.13), "\(state): a low wash of its own colour")
            #expect(style.label == state.label)
        }
    }

    /// Primary text on the neutral chip and on every tone's wash (the chip's 10 %) keeps 7:1, the branch and its glyph in
    /// `secondaryOnTint` 4.5:1; the group rests on the canvas: its ⋯ glyph is a glyph (3:1) and "Stop" is primary.
    @Test func chipAndGroupTextKeepTheThemeTiers() {
        let neutral = over(LoomTheme.Tone(rgb: Self.white, opacity: LoomTheme.Header.chipNeutralWash))
        #expect(LoomTheme.Text.primaryRGB.contrast(with: neutral) >= 7)
        #expect(LoomTheme.Text.secondaryOnTintRGB.contrast(with: neutral) >= 4.5)
        #expect(LoomTheme.Text.secondaryIncreasedRGB.contrast(with: neutral) >= 4.5)
        for tone in ProjectTone.allCases {
            let wash = over(LoomTheme.Tone(rgb: LoomTheme.ProjectColor.baseRGB(tone), opacity: LoomTheme.ProjectColor.chipWash))
            #expect(LoomTheme.Text.primaryRGB.contrast(with: wash) >= 7, "\(tone) name")
            #expect(LoomTheme.Text.secondaryOnTintRGB.contrast(with: wash) >= 4.5, "\(tone) branch")
            #expect(LoomTheme.Text.secondaryIncreasedRGB.contrast(with: wash) >= 4.5, "\(tone) branch, Increase Contrast")
        }
        let group = Self.panel
        #expect(LoomTheme.Text.primaryRGB.contrast(with: group) >= 7, "Stop")
        #expect(LoomTheme.Text.secondaryRGB.contrast(with: group) >= 3, "the ⋯ glyph")
        let hover = Self.white.composited(over: group, opacity: LoomTheme.Surface.hoverOpacity)
        #expect(LoomTheme.Text.primaryRGB.contrast(with: hover) >= 7, "Stop while hovered")
    }

    // MARK: The chip's content

    private let tone = ProjectMark(name: "edd-backend", tone: .rose)
    private let none = ProjectMark(name: "scratch", tone: nil)

    @Test func theChipShowsProjectAndBranchAndHidesWhatIsNotThere() throws {
        let both = try #require(SessionHeaderChip(project: tone, branch: .named("al-audit")))
        #expect(both.project == "edd-backend" && both.tone == .rose && both.branch == "al-audit" && both.dropsBranch)
        #expect(both.accessibilityLabel == "Project: edd-backend, branch al-audit")
        // A detached HEAD reads as the card reads it.
        #expect(SessionHeaderChip(project: tone, branch: .detached)?.branch == "Detached HEAD")
        #expect(SessionHeaderChip(project: tone, branch: .detached)?.accessibilityLabel
                == "Project: edd-backend, branch Detached HEAD")
        // Unavailable (not a Git folder) and not read yet: the project alone.
        for branch in [GitBranch.unavailable, nil] {
            let alone = try #require(SessionHeaderChip(project: tone, branch: branch))
            #expect(alone.branch == nil && !alone.dropsBranch)
            #expect(alone.accessibilityLabel == "Project: edd-backend")
        }
        // A project set to None, or colours off, is the same name without a tone.
        let neutral = try #require(SessionHeaderChip(project: none, branch: .named("main")))
        #expect(neutral.tone == nil && neutral.project == "scratch" && neutral.branch == "main")
        // No project: a neutral chip with only the branch; with no branch either, no chip.
        let branchOnly = try #require(SessionHeaderChip(project: nil, branch: .named("main")))
        #expect(branchOnly.project == nil && branchOnly.tone == nil && !branchOnly.dropsBranch)
        #expect(branchOnly.accessibilityLabel == "branch main")
        #expect(SessionHeaderChip(project: nil, branch: .detached)?.accessibilityLabel == "branch Detached HEAD")
        #expect(SessionHeaderChip(project: nil, branch: .unavailable) == nil)
        #expect(SessionHeaderChip(project: nil, branch: nil) == nil)
    }

    // MARK: The row's width rules (pure)

    private func plan(_ width: CGFloat, title: CGFloat = 235, status: CGFloat? = 109, branchy: Bool = true,
                      shrinks: Bool = false, chipFull: CGFloat = 174) -> HeaderFlowPlan {
        HeaderFlowPlan.make(
            width: width, title: title, status: status.map { HeaderFlowPlan.Status(ideal: $0, shrinks: shrinks) },
            chip: HeaderFlowPlan.Chip(full: chipFull, compact: branchy ? 96 : chipFull), rule: 5, group: 87, spacing: 8)
    }

    /// FB4-6: the branch may be 320 pt wide, so a chip with a long name is about 470 pt. It gives way in the
    /// same order, also at the width the minimum window leaves the detail (780 minus the sidebar's minimum).
    @Test func aLongBranchNameGivesWayInTheSameOrder() {
        #expect(LoomTheme.Header.branchMaxWidth == 320)
        let long: CGFloat = 470
        let wide = plan(1_000, chipFull: long)
        #expect(wide.showsBranch && wide.chip == long && wide.title == 235, "room for everything: the long name shows")
        // The title shortens first, down to 100 pt, while the long branch stays.
        let edge: CGFloat = 100 + 8 + 109 + 8 + long + 8 + 5 + 8 + 87
        #expect(plan(edge, chipFull: long).showsBranch && plan(edge, chipFull: long).title == 100)
        // One point less and the branch goes; the title takes its room back, the name keeps its full width.
        let gone = plan(edge - 1, chipFull: long)
        #expect(!gone.showsBranch && gone.chip == 96 && gone.title >= 100)
        // The minimum window: the branch is dropped, the title keeps its floor and the pill never shortens.
        for width in stride(from: 560 as CGFloat, through: 420, by: -10) {
            let result = plan(width, chipFull: long)
            #expect(!result.showsBranch && result.title >= 100 && result.status == 109, "width \(width)")
        }
    }

    @Test func theTitleGivesWayFirstThenTheBranchThenTheProjectName() {
        // Everything fits: nothing gives way, and the title keeps its own width.
        let wide = plan(900)
        #expect(wide.title == 235 && wide.chip == 174 && wide.showsBranch && wide.status == 109)
        // Narrower: the title shortens while the branch stays, down to 100 pt.
        let narrow = plan(600)
        #expect(narrow.title < 235 && narrow.title >= 100 && narrow.showsBranch && narrow.chip == 174)
        // At the edge of that rule the branch is still there, one point less and it goes.
        let edge: CGFloat = 100 + 8 + 109 + 8 + 174 + 8 + 5 + 8 + 87
        #expect(plan(edge).showsBranch && plan(edge).title == 100)
        let gone = plan(edge - 1)
        #expect(!gone.showsBranch && gone.chip == 96 && gone.title >= 100, "the title gets the branch's room back")
        // Narrower still: the title holds at 100 and the project name shortens.
        let squeezedWidth: CGFloat = 100 + 8 + 109 + 8 + 80 + 8 + 5 + 8 + 87
        let squeezed = plan(squeezedWidth)
        #expect(squeezed.title == 100 && squeezed.chip == 80 && !squeezed.showsBranch)
        // The pill and the group are never reduced: the row is always their width plus the rest.
        for width in stride(from: 900 as CGFloat, through: 300, by: -7) {
            let result = plan(width)
            #expect(result.status == 109, "the pill never shortens (width \(width))")
            let chipWidth: CGFloat = result.chip ?? 0
            let used: CGFloat = result.title + 8 + 109 + 8 + chipWidth + 8 + 5 + 8 + 87
            #expect(used <= width + 0.001 || result.title == 0, "width \(width): everything fits in the row")
        }
    }

    @Test func aShortTitleAndAChipWithoutABranchFollowTheSameRules() {
        let short = plan(500, title: 60)
        #expect(short.title == 60 && short.showsBranch, "a title under 100 pt is never cut for the branch")
        let noBranch = plan(400, branchy: false)
        #expect(!noBranch.showsBranch && noBranch.chip! <= 174 && noBranch.title >= 100 || noBranch.title < 100)
        // No state at all (a run that ended) leaves its room to the title.
        #expect(plan(600, status: nil).title > plan(600).title)
        // A transient text shortens only after the title is gone.
        let transient = plan(250, status: 400, shrinks: true)
        #expect(transient.title == 0 && transient.status! < 400)
        let fixedPill = plan(250, status: 400)
        #expect(fixedPill.status == 400)
    }

    // MARK: Fixture

    private struct Rig {
        let model: CatalogModel
        let root: URL
        let repo: URL
        let bare: URL
        /// In the project and in the repository (branch "al-audit").
        let inProject: UUID
        /// Not in a project, in the repository.
        let branchOnly: UUID
        /// Not in a project, not in a repository.
        let neither: UUID
        /// `CatalogModel.intents` is weak: the rig holds the object.
        let intents: HeaderIntents
    }

    private let longTitle = "AL contract denetimi ve tam review"

    private func rig(colors: Bool = true) async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-header-\(UUID())")
        let repo = root.appendingPathComponent("edd-backend", isDirectory: true)
        let bare = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try Data("ref: refs/heads/al-audit\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let project = try await catalog.addProject(path: repo.path).project
        func insert(_ folder: URL, _ title: String, project: UUID?, at seconds: Double) async throws -> UUID {
            let session = ManagedSession(provider: .claude, workingDirectory: folder.path)
            try await catalog.insertSession(
                session, title: title, createdAt: Date(timeIntervalSince1970: seconds),
                lastUsedAt: Date(timeIntervalSince1970: seconds), lifecycle: .idle, projectID: project)
            return session.id
        }
        let inProject = try await insert(repo, longTitle, project: project.id, at: 3_000)
        let branchOnly = try await insert(repo, "Loose in the repository", project: nil, at: 2_000)
        let neither = try await insert(bare, "Loose in a folder", project: nil, at: 1_000)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        let intents = HeaderIntents()
        model.intents = intents
        await model.start()
        await model.stopAndWait()
        await model.settle()
        model.setProjectColors(colors)
        return Rig(model: model, root: root, repo: repo, bare: bare, inProject: inProject, branchOnly: branchOnly,
                   neither: neither, intents: intents)
    }

    private func cleanup(_ rig: Rig) { try? FileManager.default.removeItem(at: rig.root) }

    /// Selects a session and gives it the live state, or none.
    private func show(_ id: UUID, in rig: Rig, _ live: SessionViewState?) async throws {
        rig.model.select(id)
        await rig.model.settle()
        let row = try #require(rig.model.selectedRow)
        row.apply(live: live)
    }

    /// A live run in an activity.
    private func run(_ activity: AgentActivity) -> SessionViewState {
        SessionViewState(status: ProviderWorkState(activity: activity), runID: UUID())
    }

    // MARK: Hosting and measuring

    /// The frames of the header's labelled parts, in points from the row's leading edge.
    struct Frames {
        var title: CGRect?
        var pill: CGRect?
        var chip: CGRect?
        var stop: CGRect?
        var menu: CGRect?
        var toggle: CGRect?
        var width: CGFloat
        var group: CGRect? {
            guard let menu else { return nil }
            return stop.map { $0.union(menu) } ?? menu
        }
    }

    private func host<Content: View>(_ content: Content, width: CGFloat) -> (NSWindow, NSHostingController<some View>) {
        let size = NSSize(width: width, height: LoomTheme.Layout.headerHeight)
        let hosting = NSHostingController(rootView: content
            .frame(width: width, height: LoomTheme.Layout.headerHeight, alignment: .top)
            .background(LoomTheme.Surface.panel)
            .preferredColorScheme(.dark))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = hosting
        window.setContentSize(size)
        // Never ordered front: the layout runs against a window nobody sees.
        window.isReleasedWhenClosed = false
        return (window, hosting)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func frames<Content: View>(of content: Content, width: CGFloat, title: String) async throws -> Frames {
        enableAccessibilityTree()
        let (window, hosting) = host(content, width: width)
        defer { window.close() }
        try await settle(window)
        let origin = window.frame.minX
        var result = Frames(width: width)
        for element in accessibilityElements(in: hosting.view) {
            let role: Any? = element.accessibilityRole?()
            guard let frame = element.accessibilityFrame?(), frame.width > 0 else { continue }
            let local = CGRect(x: frame.minX - origin, y: frame.minY, width: frame.width, height: frame.height)
            // The menu button's label is an attributed string: it is found by its role.
            if (role as? NSAccessibility.Role) == .menuButton { result.menu = result.menu ?? local; continue }
            let label: Any? = element.accessibilityLabel?()
            let value: Any? = element.accessibilityValue?()
            guard let text = (label as? String) ?? (value as? String) else { continue }
            switch text {
            case title: result.title = result.title ?? local
            case "Stop session": result.stop = result.stop ?? local
            case "Show inspector", "Hide inspector": result.toggle = result.toggle ?? local
            default:
                if text.hasPrefix("Project:") || text.hasPrefix("branch ") { result.chip = result.chip ?? local }
                else if StatePillLabels.all.contains(text) { result.pill = result.pill ?? local }
            }
        }
        return result
    }

    private enum StatePillLabels {
        static let all = Set(["Working", "Needs approval", "Waiting for you", "Ready", "Idle", "Stale", "State unknown",
                              "Failed", "Stop not verified", "Problem", "Identity unclear", "Finished"])
    }

    private func headerFrames(_ rig: Rig, width: CGFloat, title: String? = nil) async throws -> Frames {
        let row = try #require(rig.model.selectedRow)
        return try await frames(of: DetailHeader(model: rig.model), width: width, title: title ?? rig.model.title(of: row))
    }

    private func fullChipWidth(_ chip: SessionHeaderChip) -> CGFloat {
        NSHostingView(rootView: ProjectBranchChip(chip: chip)).fittingSize.width
    }

    /// What breaks the design's rules in one measured row (the tests use titles of 100 pt and more); empty when it holds.
    private func violations(_ frames: Frames) -> [String] {
        var found: [String] = []
        let inset = LoomTheme.Header.trailingInset
        let bounds = CGRect(x: 0, y: -10_000, width: frames.width, height: 20_000)
        for (name, frame) in [("pill", frames.pill), ("chip", frames.chip), ("group", frames.group)] {
            if let frame, frame.minX < 0 || frame.maxX > bounds.maxX { found.append("\(name) leaves the row: \(frame)") }
        }
        if let group = frames.group, abs(group.maxX - (frames.width - inset)) > 1 {
            found.append("the group is not at the trailing edge: \(group.maxX)")
        }
        if let title = frames.title, let pill = frames.pill, title.maxX > pill.minX {
            found.append("the title runs into the pill")
        }
        // The title gives way first, down to about 100 pt (the text ends at a whole glyph); only then do the
        // branch and the name.
        if let title = frames.title, title.width < LoomTheme.Header.titleMinWidth - 6 {
            found.append("the title (\(title.width)) is below 100 pt")
        }
        return found
    }

    // MARK: The real row

    @Test func theRowKeepsItsPlacesAtWideAndNarrowWidths() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        try await show(rig.inProject, in: rig, run(.waitingForApproval))
        let record = try #require(rig.model.selectedRow?.record)
        let chip = try #require(rig.model.headerChip(of: record))
        let full = fullChipWidth(chip)
        let compact = fullChipWidth(try #require(SessionHeaderChip(project: ProjectMark(name: "edd-backend", tone: .rose), branch: nil)))
        #expect(full > compact + 40)

        var seen: [CGFloat: Frames] = [:]
        for width in [900, 700, 650, 520] as [CGFloat] {
            let frames = try await headerFrames(rig, width: width)
            seen[width] = frames
            #expect(frames.pill != nil && frames.chip != nil && frames.stop != nil && frames.menu != nil && frames.title != nil,
                    "width \(width): \(frames)")
            #expect(violations(frames).isEmpty,
                    "width \(width): \(violations(frames))")
            // The hit areas answer over at least 24 x 24.
            for hit in [frames.stop, frames.menu].compactMap({ $0 }) {
                #expect(hit.width >= 24 && hit.height >= 24, "width \(width): hit area \(hit)")
            }
        }
        let wide = try #require(seen[900]), narrow = try #require(seen[520])
        // The pill and the control group never change size, and nothing moves with the title.
        #expect(abs(try #require(wide.pill).width - (try #require(narrow.pill).width)) < 0.5, "the pill never truncates")
        #expect(abs(try #require(wide.group).width - (try #require(narrow.group).width)) < 0.5)
        // Wide: the full chip, the title whole. Narrow: the title gave way, and the branch went.
        #expect(try #require(wide.chip).width > (full + compact) / 2, "900: the branch shows")
        #expect(try #require(narrow.chip).width < (full + compact) / 2 + 0.5, "520: the branch is gone")
        #expect(try #require(narrow.title).width < (try #require(wide.title).width) - 40, "the title gives way")
        // The title shortens first: at 650 the branch is still there with the title above 100 pt. (The toggle's 26 pt and its
        // 8 pt gap, with the mark in the chip, ask for about 30 pt more than the Night Fleece row did: it was 620.)
        let mid = try #require(seen[650])
        let midChip = try #require(mid.chip), midTitle = try #require(mid.title)
        #expect(midChip.width > (full + compact) / 2 && midTitle.width >= 99)
        // The least pane the window leaves (480): the pill, the toggle and the group keep their sizes and the chip its floor; the
        // row's fixed parts leave the title about 90 pt there (DESIGN gives the title 100 pt down to the chip's floor only).
        let least = try await headerFrames(rig, width: 480)
        #expect(abs(try #require(least.pill).width - (try #require(wide.pill).width)) < 0.5)
        #expect(abs(try #require(least.group).width - (try #require(wide.group).width)) < 0.5)
        #expect(try #require(least.chip).width >= 50 && (try #require(least.title).width) >= 80, "480: \(least)")
        #expect(try #require(least.group).maxX <= 480 - LoomTheme.Header.trailingInset + 1)
        // The pill follows the title, 8 apart, whatever the width; the chip, the toggle and the group keep the trailing edge.
        for (width, frames) in seen {
            let title = try #require(frames.title), pill = try #require(frames.pill), chipFrame = try #require(frames.chip)
            #expect(abs(pill.minX - title.maxX - LoomTheme.Space.detailSpacing) < 1.5, "\(width): the pill follows the title")
            #expect(pill.maxX <= chipFrame.minX + 0.5, "\(width): the pill is before the chip")
        }
        #expect(try #require(wide.chip).minX - (try #require(wide.pill).maxX) > 40, "wide: the room opens between the pill and the chip")
    }

    /// DESIGN §0 Header: 52 pt, its content centred on one line; the inspector toggle and control group are 28 pt.
    @Test func theHeaderIs52WithItsPartsOnOneLineAndTheToggleIsAnIconButton() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        try await show(rig.inProject, in: rig, run(.working))
        let block = NSHostingView(rootView: DetailHeader(model: rig.model).frame(width: 800))
        block.layoutSubtreeIfNeeded()
        #expect(block.fittingSize.height == LoomTheme.Layout.headerHeight && LoomTheme.Layout.headerHeight == 52)

        var toggleSizes: Set<CGFloat> = []
        for width in [900, 620, 480] as [CGFloat] {
            let frames = try await headerFrames(rig, width: width)
            let toggle = try #require(frames.toggle, "\(width): the toggle"), group = try #require(frames.group)
            toggleSizes.insert(toggle.width)
            #expect(toggle.width == 28 && toggle.height == 28, "\(width): a 28 pt icon button, \(toggle)")
            #expect(abs(group.minX - toggle.maxX - LoomTheme.Space.detailSpacing) < 1.5, "\(width): 8 before the group")
            #expect(group.height >= 28 - 0.5 && group.height <= 28 + 0.5, "\(width): the group is 28 high, \(group)")
            // One centre line for the title, the pill, the chip, the toggle and the group.
            let centres = [frames.title, frames.pill, frames.chip, frames.toggle, frames.group].compactMap { $0?.midY }
            #expect((centres.max() ?? 0) - (centres.min() ?? 0) < 1.5, "\(width): one line, \(centres)")
        }
        #expect(toggleSizes == [28])
    }

    @Test func aNaiveRowFailsTheSameMeasurements() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        try await show(rig.inProject, in: rig, run(.waitingForApproval))
        let row = try #require(rig.model.selectedRow)
        let chip = try #require(rig.model.headerChip(of: row.record))
        let style = try #require(StatePillStyle(row.indicator))
        // The same parts in a plain HStack with a spacer: no plan, so nothing gives way in the right order.
        let naive = HStack(spacing: LoomTheme.Space.detailSpacing) {
            ProviderIcon(provider: .claude, size: LoomTheme.Layout.providerIconHeader)
            Text(rig.model.title(of: row)).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            StatePill(indicator: row.indicator, style: style)
            ProjectBranchChip(chip: chip)
            HeaderRule()
            HeaderControlGroup(canStop: true, stop: {}) { Button("Rename…") {} }
        }
        .font(LoomTheme.Typography.body)
        .padding(.horizontal, LoomTheme.Space.detailInset)
        .frame(height: LoomTheme.Layout.headerHeight)
        let frames = try await frames(of: naive, width: 480, title: rig.model.title(of: row))
        let broken = violations(frames)
        #expect(!broken.isEmpty, "a naive row at 480 pt must trip the measurements: \(frames)")
    }

    @Test func whenTheRunEndsStopGoesAndTheMenuStaysAtTheTrailingEdge() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        try await show(rig.inProject, in: rig, run(.working))
        let running = try await headerFrames(rig, width: 900)
        #expect(running.stop != nil && running.pill != nil)
        let runningMenu = try #require(running.menu)

        try await show(rig.inProject, in: rig, nil)
        #expect(rig.model.selectedRow?.indicator == .idle)
        let idle = try await headerFrames(rig, width: 900)
        #expect(idle.stop == nil, "no run, no Stop segment")
        #expect(idle.pill != nil, "an idle session still has its state")
        let idleMenu = try #require(idle.menu)
        #expect(abs(idleMenu.maxX - runningMenu.maxX) < 0.5, "⋯ stays where it was")
        #expect(abs(idleMenu.maxX - (900 - LoomTheme.Header.trailingInset)) < 1)

        // A run that ended has no label and therefore no pill.
        rig.model.selectedRow?.apply(live: SessionViewState(lifecycle: .active))
        #expect(rig.model.selectedRow?.indicator == .ended)
        let ended = try await headerFrames(rig, width: 900)
        #expect(ended.pill == nil && ended.stop == nil && ended.menu != nil)
    }

    @Test func theChipFollowsTheSessionsProjectAndFolder() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        try await show(rig.branchOnly, in: rig, run(.atPrompt))
        let record = try #require(rig.model.selectedRow?.record)
        let chip = try #require(rig.model.headerChip(of: record))
        #expect(chip.project == nil && chip.branch == "al-audit", "no project: a neutral chip with only the branch")
        let withBranchOnly = try await headerFrames(rig, width: 900)
        #expect(withBranchOnly.chip != nil)

        try await show(rig.neither, in: rig, run(.atPrompt))
        #expect(rig.model.headerChip(of: try #require(rig.model.selectedRow?.record)) == nil)
        let bare = try await headerFrames(rig, width: 900)
        #expect(bare.chip == nil, "no project and no branch: no chip")
        #expect(violations(bare).isEmpty)

        // Project colours off: the name stays, the chip is neutral (no tone).
        rig.model.setProjectColors(false)
        try await show(rig.inProject, in: rig, run(.working))
        let selectedRecord = try #require(rig.model.selectedRow?.record)
        let named = try #require(rig.model.headerProjectMark(of: selectedRecord))
        #expect(named == ProjectMark(name: "edd-backend", tone: nil))
        rig.model.setProjectColors(true)
        try await show(rig.inProject, in: rig, run(.working))
        #expect(rig.model.headerChip(of: try #require(rig.model.selectedRow?.record))?.tone == .rose)
    }

    @Test func withTheSidebarCollapsedTheRowStillKeepsItsPlaces() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        rig.model.setSidebarCollapsed(true)
        try await show(rig.inProject, in: rig, run(.failed("boom")))
        // The window's smallest detail width with the sidebar collapsed is 780 - 16; 640 is below it.
        for width in [780 - 16, 640] as [CGFloat] {
            let frames = try await headerFrames(rig, width: width)
            #expect(violations(frames).isEmpty,
                    "width \(width): \(violations(frames)) \(frames)")
            #expect(frames.pill != nil && frames.stop != nil)
        }
        rig.model.setSidebarCollapsed(false)
    }

    // MARK: Branch data for the header

    /// A session opened by another one, in another repository than the loaded cards.
    private struct BranchRig {
        let model: CatalogModel
        let root: URL
        let alpha: URL
        let beta: URL
        let alphaSession: UUID
        let child: UUID
    }

    private func branchRig() async throws -> BranchRig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-header-branch-\(UUID())")
        func repo(_ name: String, _ branch: String) throws -> URL {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try Data("ref: refs/heads/\(branch)\n".utf8).write(to: folder.appendingPathComponent(".git/HEAD"))
            return folder
        }
        let alpha = try repo("alpha", "main"), beta = try repo("beta", "develop")
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        func insert(_ folder: URL, _ title: String, at seconds: Double, openedBy: UUID? = nil) async throws -> UUID {
            let session = ManagedSession(provider: .claude, workingDirectory: folder.path)
            try await catalog.insertSession(session, title: title, createdAt: Date(timeIntervalSince1970: seconds),
                                            lastUsedAt: Date(timeIntervalSince1970: seconds), lifecycle: .idle,
                                            openedBy: openedBy)
            return session.id
        }
        let planner = try await insert(alpha, "Planner", at: 1_000)
        let alphaSession = try await insert(alpha, "Alpha work", at: 2_000)
        let child = try await insert(beta, "Beta child", at: 3_000, openedBy: planner)
        let model = CatalogModel(catalog: catalog, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        await model.start()
        await model.stopAndWait()
        await model.settle()
        return BranchRig(model: model, root: root, alpha: alpha, beta: beta, alphaSession: alphaSession, child: child)
    }

    private func waitUntil(_ seconds: TimeInterval = 6, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }

    /// The header reads `CatalogModel.branches`, like the card. A session selected through a search that
    /// does not list its card has its folder's branch read and kept, also when a prune runs while its
    /// requester is still being read. (Without the read-last order in `ensureSelectedRow` the prune
    /// drops the branch just published, because no row holds the folder yet.)
    @Test func theSelectedSessionKeepsItsBranchWithoutALoadedCard() async throws {
        let rig = try await branchRig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let model = rig.model
        model.setSearchText("Alpha")
        await model.settle()
        #expect(await waitUntil { Set(model.branches.keys) == [rig.alpha.path] }, "the cards of the other repository left")
        #expect(model.list(for: .activity).rows.map(\.id) == [rig.alphaSession])

        // A prune on every turn of the main actor while the selection is read.
        let pruning = Task { @MainActor in
            while !Task.isCancelled { model.pruneRowModels(); await Task.yield() }
        }
        model.select(rig.child)
        let selected = await waitUntil { model.selectedRow?.id == rig.child }
        pruning.cancel()
        await pruning.value
        #expect(selected)
        #expect(model.branches[rig.beta.path] == .named("develop"), "the header has its branch")
        let record = try #require(model.selectedRow?.record)
        #expect(model.headerChip(of: record)?.branch == "develop")

        // And it stays through later prunes and reloads.
        model.scheduleRefresh()
        await model.settle()
        model.pruneRowModels()
        #expect(model.branches[rig.beta.path] == .named("develop"))
    }

    @Test func aPinnedTabKeepsItsFoldersBranchWhenItsCardIsNotLoaded() async throws {
        let rig = try await branchRig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let model = rig.model
        model.setSearchText("Alpha")
        await model.settle()
        _ = model.openTab(rig.child)
        #expect(await waitUntil { model.selectedRow?.id == rig.child && model.branches[rig.beta.path] != nil })
        // Another session is shown; the tab keeps its row and with it its folder's branch.
        model.select(rig.alphaSession)
        await model.settle()
        model.pruneRowModels()
        #expect(model.tabs.isPinned(rig.child))
        #expect(model.branches[rig.beta.path] == .named("develop"))
        #expect(model.branches[rig.alpha.path] == .named("main"))
    }

    // MARK: Ink

    /// The width in points of the brightest ink (primary text; the branch and its glyph are dimmer) inside
    /// a region of a view's rendering, `region` in points from the top left. The window is never shown.
    private func brightInkWidth(of rep: NSBitmapImageRep, width: CGFloat, region: CGRect) -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / width
        var first = Int.max, last = -1
        for y in Int(region.minY * scale)..<min(rep.pixelsHigh, Int(region.maxY * scale)) {
            for x in Int(region.minX * scale)..<min(rep.pixelsWide, Int(region.maxX * scale)) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                if luminance > 0.72 { first = min(first, x); last = max(last, x) }
            }
        }
        return last < first ? 0 : CGFloat(last - first + 1) / scale
    }

    private func render<Content: View>(_ content: Content, width: CGFloat) async throws -> NSBitmapImageRep {
        let (window, hosting) = host(content, width: width)
        defer { window.close() }
        try await settle(window)
        let view = hosting.view
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The project name is drawn whole whenever the chip has room for the branch too: the branch's capped
    /// frame once took more than its text and left "edd-back…" in a chip with space to spare.
    @Test func theProjectNameIsWholeWhileTheBranchShows() async throws {
        let rig = try await rig()
        defer { cleanup(rig) }
        try await show(rig.inProject, in: rig, run(.waitingForApproval))
        let name = Text("edd-backend").font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary)
        let alone = try await render(name.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), width: 300)
        let whole = brightInkWidth(of: alone, width: 300, region: CGRect(x: 0, y: 0, width: 300, height: 30))
        #expect(whole > 40)
        for width in [900, 600] as [CGFloat] {
            let frames = try await headerFrames(rig, width: width)
            let chip = try #require(frames.chip)
            let rep = try await render(DetailHeader(model: rig.model), width: width)
            let top = LoomTheme.Layout.headerHeight - chip.maxY
            let region = CGRect(x: chip.minX, y: top, width: chip.width, height: chip.height)
            let ink = brightInkWidth(of: rep, width: width, region: region)
            #expect(abs(ink - whole) <= 1.5, "width \(width): the name is \(ink) pt wide, whole it is \(whole)")
        }
    }

    // MARK: Evidence renders

    /// Writes the PNGs for the planner when `LOOM_HEADER_RENDER_DIR` is set; otherwise only checks that a
    /// render of the header draws something. Nothing opens on screen: the window is never ordered front.
    @Test func rendersTheHeaderOffscreen() async throws {
        let directory = ProcessInfo.processInfo.environment["LOOM_HEADER_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let rig = try await rig()
        defer { cleanup(rig) }

        func render(_ name: String, width: CGFloat) async throws {
            let (window, hosting) = host(DetailHeader(model: rig.model), width: width)
            defer { window.close() }
            try await settle(window)
            let view = hosting.view
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            // Something other than the panel colour was drawn.
            let panel = Self.panel
            var drawn = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if abs(Double(color.redComponent) - panel.red) > 0.04 { drawn += 1 }
                }
            }
            #expect(drawn > 200, "\(name): the header drew nothing")
            if let directory, let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }

        try await show(rig.inProject, in: rig, run(.working))
        try await render("1-working-with-branch-900", width: 900)
        try await show(rig.inProject, in: rig, run(.waitingForApproval))
        try await render("2-needs-approval-900", width: 900)
        try await show(rig.inProject, in: rig, run(.atPrompt))
        try await render("3-ready-520", width: 520)
        rig.model.setProjectColors(false)
        try await show(rig.inProject, in: rig, run(.working))
        try await render("4-project-colors-off-900", width: 900)
        rig.model.setProjectColors(true)
        try await show(rig.branchOnly, in: rig, run(.waitingForInput))
        try await render("5-no-project-900", width: 900)
        try await show(rig.neither, in: rig, run(.failed("boom")))
        try await render("6-no-project-no-branch-failed-900", width: 900)
        try await show(rig.inProject, in: rig, SessionViewState(status: ProviderWorkState(activity: .turnComplete), runID: UUID(), unviewedCompletion: true))
        try await render("7-finished-narrow-480", width: 480)
    }
}

/// Intents that only say a run exists, so the header offers Stop.
@MainActor
final class HeaderIntents: ConversationIntents {
    func start(provider: ManagedSession.Provider, projectID: UUID?) {}
    func resume(sessionID: UUID) {}
    func stop(sessionID: UUID) {}
    func answer(sessionID: UUID, requestID: String, accept: Bool) {}
    func viewed(sessionID: UUID) {}
    func terminalView(sessionID: UUID) -> NSView? { nil }
}
