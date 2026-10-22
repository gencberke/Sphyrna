import Foundation
import LoomCore
import LoomRemora
import Observation
import SwiftUI

/// What Home's Remora section keeps for itself while Home is on screen: the field's text and scope, the question it sent and the one
/// before it, which popover is open, and what Put in Draft did. The user's own words and choices, not Remora's data; the view drops
/// it when Home goes.
@MainActor @Observable
final class HomeRemoraUI {
    struct Asked: Equatable {
        let question: String
        let scope: RemoraScope
        let at: Date
    }

    enum Popover: Equatable {
        case more
        case scope
        case sources
        case answerSources
    }

    var text = ""
    var scope: RemoraScope = .allProjects
    /// The question the field sent last (the answer under the field is to it).
    var asked: Asked?
    /// The question before it: the Earlier line.
    var earlier: Asked?
    /// The × on the answer closed it.
    var answerClosed = false
    /// Show Brief brought the whole brief back over the fold.
    var expanded = false
    var open: Popover?
    /// The session whose Put in Draft the pointer is on (the popover shows its line).
    var hoveredDraft: UUID?
    var placed: [UUID: RemoraDraftResult] = [:]
    /// The field's menu or popover cursor.
    var cursor: Int?

    func binding(_ popover: Popover) -> Binding<Bool> {
        Binding(get: { self.open == popover }, set: { shown in
            if shown { self.open = popover; self.cursor = nil } else if self.open == popover { self.open = nil }
        })
    }

    func hoverBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { self.hoveredDraft == id }, set: { shown in
            if shown { self.hoveredDraft = id } else if self.hoveredDraft == id { self.hoveredDraft = nil }
        })
    }
}

private struct OpenRemoraMemoryKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens the memory sheet (`remoraMemoryDoor(model:navigation:)` sets it). While it is nil, Home draws neither of its two doors
    /// (⋯ → Memory… and the footer's Memory…).
    var openRemoraMemory: (@MainActor () -> Void)? {
        get { self[OpenRemoraMemoryKey.self] }
        set { self[OpenRemoraMemoryKey.self] = newValue }
    }
}

/// Home's door to Remora's memory: Settings → Remora with the memory sheet over it, on the journal. The same path as the evidence
/// command `remora-memory:open`: the window shows (`showSettings(.remora)`, which the app answers), then its navigation opens the
/// sheet. Opening a sheet is not a model call.
enum HomeRemoraMemoryDoor {
    static func action(model: CatalogModel, navigation: @escaping @MainActor () -> SettingsNavigation?) -> @MainActor () -> Void {
        {
            model.showSettings(.remora)
            navigation()?.openRemoraMemory(tab: .journal)
        }
    }
}

extension View {
    /// Gives Home its two memory doors. `navigation` is the Settings window's, read each time a door is used.
    public func remoraMemoryDoor(model: CatalogModel, navigation: @escaping @MainActor () -> SettingsNavigation?) -> some View {
        environment(\.openRemoraMemory, HomeRemoraMemoryDoor.action(model: model, navigation: navigation))
    }
}

// MARK: A menu

/// One row of Home's small menus (the scope menu and ⋯).
struct HomeRemoraMenuItem: Identifiable {
    enum Mark {
        case none
        case project(name: String, tone: ProjectTone?)
        case symbol(String)
    }

    let id: String
    let title: String
    var mark: Mark = .none
    var checked = false
    /// A hairline above this row.
    var dividerAbove = false
    let action: @MainActor () -> Void
}

/// The rows of a menu, drawn on the popover host's surface with the project menu's rows (28 high, the pill under the cursor). The host
/// reads the keys; `cursor` is the row ↑ ↓ are on.
struct HomeRemoraMenuView: View {
    let items: [HomeRemoraMenuItem]
    let width: CGFloat
    let cursor: Int?
    let hover: (Int?) -> Void
    let close: () -> Void
    private typealias H = LoomTheme.Host

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if item.dividerAbove {
                    Rectangle().fill(LoomTheme.Surface.hairline).frame(height: LoomTheme.Line.hairline)
                        .padding(.vertical, H.separatorGap).padding(.horizontal, -H.menuInset)
                }
                row(item, index: index)
            }
        }
        .padding(H.menuInset)
        .frame(width: width)
        .accessibilityElement(children: .contain)
    }

    private func row(_ item: HomeRemoraMenuItem, index: Int) -> some View {
        let lit = cursor == index
        return Button {
            item.action()
            close()
        } label: {
            HStack(spacing: H.rowGap) {
                mark(item.mark).frame(width: H.iconColumn).accessibilityHidden(true)
                Text(item.title).font(H.rowFont).lineLimit(1).foregroundStyle(LoomTheme.Text.primary)
                Spacer(minLength: 0)
                if item.checked {
                    Image(systemName: "checkmark").font(LoomTheme.Remora.checkGlyph.font).foregroundStyle(LoomTheme.Text.primary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, H.rowPaddingH)
            .frame(height: H.rowHeight)
            .background(RowHighlight(state: .resolve(selected: false, hovering: lit), radius: H.rowRadius))
            .contentShape(RoundedRectangle(cornerRadius: H.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { inside in hover(inside ? index : nil) }
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.checked ? .isSelected : [])
    }

    @ViewBuilder
    private func mark(_ mark: HomeRemoraMenuItem.Mark) -> some View {
        switch mark {
        case .none: Color.clear
        case .project(let name, let tone): ProjectMarkView(name: name, tone: tone, size: .chip)
        case .symbol(let name): Image(systemName: name).font(H.iconFont).foregroundStyle(LoomTheme.OnPopover.secondary(lit: false))
        }
    }
}

/// The keys of a menu: ↑ ↓ move the cursor (wrapping), ↵ and Space use the row. Pure.
enum HomeRemoraMenuKeys {
    struct Outcome: Equatable {
        var cursor: Int?
        var use: Int?
        var handled: Bool
    }

    static func resolve(_ key: InkKey, cursor: Int?, count: Int) -> Outcome {
        switch key {
        case .down, .up:
            return Outcome(cursor: ComposerPopoverKeys.cursor(from: cursor, delta: key == .down ? 1 : -1, count: count), use: nil, handled: true)
        case .return, .space:
            guard let cursor, cursor >= 0, cursor < count else { return Outcome(cursor: cursor, use: nil, handled: false) }
            return Outcome(cursor: cursor, use: cursor, handled: true)
        case .left, .right, .escape:
            return Outcome(cursor: cursor, use: nil, handled: false)
        }
    }
}
