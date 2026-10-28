import AppKit
import LoomCore
import SwiftUI

/// One strip under both panes. Each leaf observes only the state it displays.
public struct StatusBarView: View {
    let model: CatalogModel

    public init(model: CatalogModel) { self.model = model }

    public var body: some View {
        #if DEBUG
        let _ = StatusBarRenderProbe.root(model)
        #endif
        // Removing the controls also closes their host popovers on entry to full screen.
        if !model.isFullScreen {
            HStack(spacing: LoomTheme.StatusBar.gap) {
                StatusBarUtilities(model: model)
                if let usage = model.usage {
                    ScrollView(.horizontal) {
                        HStack(spacing: LoomTheme.StatusBar.gap) { StatusBarUsageSegments(usage: usage, model: model) }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                StatusBarWorking(model: model)
                StatusBarKeepAwake(integration: model.integration)
                StatusBarRemora(remora: model.remora)
                if let health = model.harnessHealth { StatusBarUpdates(health: health, model: model) }
            }
            .font(LoomTheme.StatusBar.caption)
            .foregroundStyle(LoomTheme.Text.secondary)
            .padding(.horizontal, LoomTheme.StatusBar.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(LoomTheme.StatusBar.fill)
            .overlay(alignment: .top) {
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .focusEffectDisabled()
        }
    }
}

private struct StatusBarUsageSegments: View {
    let usage: UsageModel
    let model: CatalogModel

    var body: some View {
        ForEach(usage.statusSegments.filter { usage.isConnected($0.harness) }, id: \.harness) { segment in
            StatusBarUsageSegment(segment: segment, usage: usage, model: model)
        }
    }
}

private struct StatusBarUsageSegment: View {
    let segment: StatusBarUsage
    let usage: UsageModel
    let model: CatalogModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: LoomTheme.StatusBar.segmentGap) {
                ProviderIcon(provider: segment.harness, size: LoomTheme.StatusBar.mark)
                if let tightest = segment.tightest {
                    StatusBarMeter(remaining: tightest.remainingPercent)
                    ForEach(segment.windows) { window in
                        HStack(spacing: LoomTheme.StatusBar.gap) {
                            Text("\(window.remainingPercent)% left")
                                .font(LoomTheme.StatusBar.figures)
                                .foregroundStyle(Double(window.remainingPercent) / 100 < LoomTheme.PlanPaceLine.lowBelow
                                                 ? LoomTheme.Status.attentionLight : LoomTheme.Text.secondary)
                            if let reset = window.reset {
                                Text("· \(reset)").font(LoomTheme.StatusBar.reset).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                            }
                        }
                    }
                } else {
                    Text("No limits read")
                }
            }
            .font(LoomTheme.StatusBar.caption)
            .fixedSize()
        }
        .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
        .accessibilityLabel(segment.accessibilityLabel)
        .accessibilityHint("Opens plan limits")
        .inkPopover(isPresented: $showing, id: "status-limits-\(segment.harness.rawValue)",
                    label: "\(ProviderName.title(segment.harness)) plan limits", side: .above, alignment: .leading) {
            StatusBarUsagePopover(harness: segment.harness, usage: usage, model: model, showing: $showing)
        }
    }
}

private struct StatusBarMeter: View {
    let remaining: Int

    var body: some View {
        let fraction = CGFloat(min(max(remaining, 0), 100)) / 100
        RoundedRectangle(cornerRadius: LoomTheme.StatusBar.meterRadius)
            .fill(LoomTheme.Surface.chipMeterTrack)
            .frame(width: LoomTheme.StatusBar.meter.width, height: LoomTheme.StatusBar.meter.height)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: LoomTheme.StatusBar.meterRadius)
                    .fill(Double(remaining) / 100 < LoomTheme.PlanPaceLine.lowBelow ? LoomTheme.Status.attention : LoomTheme.Text.secondary)
                    .frame(width: LoomTheme.StatusBar.meter.width * fraction)
            }
            .accessibilityHidden(true)
    }
}

private struct StatusBarUsagePopover: View {
    let harness: ManagedSession.Provider
    let usage: UsageModel
    let model: CatalogModel
    @Binding var showing: Bool
    @State private var checking = false

    var body: some View {
        let reading = usage.readings[harness]
        let lines = usage.statusPaces(of: harness, at: model.now)
        VStack(alignment: .leading, spacing: LoomTheme.StatusBar.popoverGap) {
            HStack(spacing: LoomTheme.StatusBar.segmentGap) {
                ProviderIcon(provider: harness, size: LoomTheme.StatusBar.mark)
                Text(ProviderName.title(harness)).font(LoomTheme.StatusBar.popoverTitle).foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: 0)
                if let reading {
                    Text("Read \(UsageText.time(reading.readAt, usage.timeZone))")
                        .font(LoomTheme.StatusBar.figures).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                }
                Button { showing = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(ChromeButtonStyle(size: LoomTheme.StatusBar.utilitySize))
                    .help("Close").accessibilityLabel("Close")
            }
            if lines.isEmpty {
                Text("No limits read").foregroundStyle(LoomTheme.Text.secondaryStyle)
            } else if lines.count > LoomTheme.StatusBar.popoverPacesBeforeScrolling {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: LoomTheme.StatusBar.popoverGap) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in PlanPaceLine(content: line) }
                    }
                }
                .frame(height: LoomTheme.StatusBar.popoverPacesMaxHeight)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    PlanPaceLine(content: line)
                }
            }
            Text("Read from \(ProviderName.title(harness)) usage. No model call.")
                .font(LoomTheme.StatusBar.caption).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: LoomTheme.StatusBar.segmentGap) {
                Button("Check Again") {
                    checking = true
                    Task { @MainActor in
                        await usage.checkStatusLimits(of: harness)
                        checking = false
                    }
                }
                .buttonStyle(ControlButtonStyle(kind: .outline, size: .small))
                .disabled(checking)
                Button("Open Usage") { showing = false; model.showSettings(.usage) }
                    .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, LoomTheme.StatusBar.popoverInset)
        .padding(.vertical, LoomTheme.StatusBar.popoverVertical)
        .frame(width: LoomTheme.StatusBar.popoverWidth, alignment: .leading)
    }
}

private struct StatusBarWorking: View {
    let model: CatalogModel

    var body: some View {
        #if DEBUG
        let _ = StatusBarRenderProbe.working(model)
        #endif
        let count = model.workingSessionCount
        if count > 0 {
            Menu {
                StatusBarWorkingMenu(model: model)
            } label: {
                HStack(spacing: LoomTheme.StatusBar.gap) {
                    BrailleSpinner(animating: model.windowIsActive && model.windowIsVisible)
                        .frame(width: LoomTheme.StatusBar.mark, height: LoomTheme.StatusBar.mark).accessibilityHidden(true)
                    Text("\(count) working")
                }
                .font(LoomTheme.StatusBar.caption)
            }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
            .accessibilityLabel("\(count) \(count == 1 ? "session" : "sessions") working")
        }
    }
}

/// Evaluated when the menu is opened, from all known live records rather than paged sidebar rows.
struct StatusBarWorkingMenu: View {
    let model: CatalogModel

    var body: some View {
        #if DEBUG
        let _ = StatusBarRenderProbe.menu(model)
        #endif
        let state = Self.state(model: model)
        ForEach(state.working, id: \.id) { row in
            Button(row.project.map { "\(row.title) · \($0)" } ?? row.title) { Self.select(row.id, model: model) }
        }
        if state.workingMore > 0 {
            Button(MenuBarMenu.moreTitle(state.workingMore)) { Self.showMore(model: model) }
        }
    }

    static func state(model: CatalogModel) -> MenuBarState { model.menuBarState() }

    static func select(_ id: UUID, model: CatalogModel) { model.select(id) }

    static func showMore(model: CatalogModel) {
        model.setSearchText("")
        model.setViewMode(.activity)
        if model.sidebarCollapsed { model.onToggleSidebar?() }
    }
}

#if DEBUG
/// A test can watch one hosted bar without counting any other window.
@MainActor enum StatusBarRenderProbe {
    private(set) static weak var watchedModel: CatalogModel?
    private(set) static var rootBodies = 0
    private(set) static var workingBodies = 0
    private(set) static var menuBodies = 0

    static func watch(_ model: CatalogModel?) {
        watchedModel = model
        rootBodies = 0
        workingBodies = 0
        menuBodies = 0
    }

    static func root(_ model: CatalogModel) { if watchedModel === model { rootBodies += 1 } }
    static func working(_ model: CatalogModel) { if watchedModel === model { workingBodies += 1 } }
    static func menu(_ model: CatalogModel) { if watchedModel === model { menuBodies += 1 } }
}
#endif

private struct StatusBarKeepAwake: View {
    let integration: SystemIntegration

    var body: some View {
        let on = integration.keepAwake == .whileWorking
        Button { integration.setKeepAwake(on ? .off : .whileWorking) } label: {
            HStack(spacing: LoomTheme.StatusBar.segmentGap) {
                Capsule().fill(on ? LoomTheme.Control.switchOnFill : LoomTheme.Control.switchOffFill)
                    .frame(width: LoomTheme.StatusBar.switchSize.width, height: LoomTheme.StatusBar.switchSize.height)
                    .overlay(alignment: .leading) {
                        Circle().fill(LoomTheme.Control.switchThumbFill)
                            .frame(width: LoomTheme.StatusBar.switchThumb, height: LoomTheme.StatusBar.switchThumb)
                            .offset(x: LoomTheme.StatusBar.switchInset + (on
                                ? LoomTheme.StatusBar.switchSize.width - LoomTheme.StatusBar.switchThumb - 2 * LoomTheme.StatusBar.switchInset : 0))
                    }
                Text("Keep Mac Awake")
            }
            .font(LoomTheme.StatusBar.caption)
        }
        .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
        .accessibilityRepresentation {
            Toggle("Keep Mac awake", isOn: Binding(get: { integration.keepAwake == .whileWorking },
                                                    set: { integration.setKeepAwake($0 ? .whileWorking : .off) }))
        }
    }
}

private struct StatusBarRemora: View {
    let remora: RemoraModelState

    var body: some View {
        if remora.phase == .briefing {
            Text("Remora reading").foregroundStyle(LoomTheme.Text.tertiaryStyle)
                .accessibilityLabel("Remora is reading a brief")
        }
    }
}

struct StatusBarUpdates: View {
    let health: HarnessHealthModel
    let model: CatalogModel

    var body: some View {
        ForEach(Self.recommendations(health.healths), id: \.provider) { item in
            Button { model.showConnections() } label: {
                Label("\(ProviderName.title(item.provider)) update", systemImage: "arrow.down.circle")
                    .font(LoomTheme.StatusBar.caption).foregroundStyle(LoomTheme.Status.attentionLight)
            }
            .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
            .help(item.versionStatus == .belowMinimum ? "Update needed in Connections" : "Update recommended in Connections")
        }
    }

    static func recommendations(_ healths: [HarnessHealth]) -> [HarnessHealth] {
        healths.filter { item in
            item.state != .disabled && item.version != nil
                && (item.versionStatus == .belowRecommended || item.versionStatus == .belowMinimum)
        }
    }
}
