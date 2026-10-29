import SwiftUI
import LoomCore

/// Search and scroll read the catalogue's cache only. A result is rechecked by its owner when chosen.
struct ModelPickerPanel: View {
    let model: CatalogModel
    let selected: ModelPickerChoice
    let cursor: ModelPickerController
    let identifier: String
    let handle: (InkKey) -> Bool
    let choose: (ModelPickerChoice) -> Void
    let close: () -> Void
    @FocusState private var searchFocused: Bool
    private let space = "model-picker-scroll"

    private var data: ModelPickerProjection {
        ModelPickerDraft.projection(model: model, query: cursor.query)
    }

    var body: some View {
        let snapshot = data
        VStack(spacing: 0) {
            search
            Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(height: LoomTheme.Line.hairline)
            HStack(spacing: 0) {
                ModelPickerAccessibility(role: .list, label: "Model sources",
                                         size: CGSize(width: LoomTheme.ModelPicker.railWidth, height: LoomTheme.ModelPicker.bodyHeight)) {
                    rail(snapshot)
                }
                Rectangle().fill(LoomTheme.Surface.hairlineStyle).frame(width: LoomTheme.Line.hairline)
                ModelPickerAccessibility(role: .list, label: "Models",
                                         size: CGSize(width: LoomTheme.ModelPicker.listWidth, height: LoomTheme.ModelPicker.bodyHeight)) {
                    list(snapshot)
                }
            }
        }
        .frame(width: LoomTheme.ModelPicker.width, height: LoomTheme.ModelPicker.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model menu")
        .accessibilityIdentifier("\(identifier)-list")
    }

    private var search: some View {
        HStack(spacing: LoomTheme.ModelPicker.searchGap) {
            InkIcon(.search, size: LoomTheme.Icon.body)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle).accessibilityHidden(true)
            TextField("", text: Binding(get: { cursor.query }, set: { text in
                let next = ModelPickerDraft.projection(model: model, query: text)
                cursor.search(text, rows: next.rows(defaultFor: selected.harness))
            }), prompt: Text("Search models").foregroundStyle(LoomTheme.Text.tertiaryStyle))
                .textFieldStyle(.plain).font(LoomTheme.ModelPicker.searchFont).foregroundStyle(LoomTheme.Text.primary)
                .focused($searchFocused).onAppear { searchFocused = true }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    let key: InkKey? = switch press.key {
                    case .upArrow: .up
                    case .downArrow: .down
                    case .return: .return
                    case .escape: .escape
                    default: nil
                    }
                    guard let key else { return .ignored }
                    return handle(key) ? .handled : .ignored
                }
                .accessibilityLabel("Search models")
                .accessibilityIdentifier("\(identifier)-search")
        }
        .padding(.horizontal, LoomTheme.ModelPicker.searchInset)
        .frame(height: LoomTheme.ModelPicker.searchHeight)
    }

    private func rail(_ data: ModelPickerProjection) -> some View {
        VStack(spacing: LoomTheme.ModelPicker.railGap) {
            Button { jump(.recent) } label: { InkIcon(.clock) }
                .buttonStyle(ChromeButtonStyle(selected: cursor.activeSection == .recent, size: LoomTheme.ModelPicker.railButton))
                .help("Recent").accessibilityLabel("Recent models").disabled(data.recent.isEmpty)
            railDivider
            ForEach(data.groups.filter { $0.state == .on }) { group in railButton(group) }
            if data.groups.contains(where: { $0.state != .on }) {
                railDivider
                ForEach(data.groups.filter { $0.state != .on }) { group in railButton(group) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, LoomTheme.ModelPicker.railInset)
        .frame(width: LoomTheme.ModelPicker.railWidth).frame(maxHeight: .infinity)
        .background(LoomTheme.ModelPicker.railFill)
        .accessibilityElement(children: .contain).accessibilityLabel("Model sources")
    }

    private var railDivider: some View {
        Rectangle().fill(LoomTheme.Surface.hairlineStyle)
            .frame(width: LoomTheme.ModelPicker.railDividerWidth, height: LoomTheme.Line.hairline)
            .padding(.vertical, LoomTheme.ModelPicker.railGap).accessibilityHidden(true)
    }

    private func railButton(_ group: ModelPickerProjection.Group) -> some View {
        let label = group.descriptor.displayName + stateSuffix(group.state)
        return Button { jump(.harness(group.id)) } label: {
            ProviderIcon(harness: group.id, size: LoomTheme.ModelPicker.mark)
                .opacity(group.state == .on ? 1 : LoomTheme.Opacity.disabled)
                .overlay(alignment: .bottomTrailing) {
                    if group.state != .on {
                        Circle().fill(LoomTheme.Text.faint).frame(width: LoomTheme.ModelPicker.dot, height: LoomTheme.ModelPicker.dot)
                    }
                }
        }
        .buttonStyle(ChromeButtonStyle(selected: cursor.activeSection == .harness(group.id), size: LoomTheme.ModelPicker.railButton))
        .help(label).accessibilityLabel(label)
    }

    private func stateSuffix(_ state: HarnessAvailabilityState) -> String {
        switch state {
        case .on: " · On"
        case .off: " · Off"
        case .notFound: " · Not found"
        }
    }

    private func jump(_ section: ModelPickerController.Section) {
        let next = ModelPickerDraft.projection(model: model)
        let rows = next.rows(defaultFor: selected.harness)
        if !cursor.query.isEmpty {
            cursor.search("", rows: rows)
        }
        cursor.jump(section, rows: rows)
    }

    private func list(_ data: ModelPickerProjection) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !data.recent.isEmpty {
                        sectionHeader("Recent", harness: nil, count: data.recent.count)
                            .id(ModelPickerController.Section.recent)
                            .background(position(.recent))
                        ForEach(data.recent, id: \.pickerKey) { entry in modelRow(entry, section: .recent, showsMark: true) }
                    }
                    ForEach(data.groups.filter { $0.state == .on }) { group in
                        let defaultChoice = ModelPickerChoice.defaultModel(group.id)
                        let showDefault = data.choices(defaultFor: selected.harness).contains(defaultChoice)
                        if cursor.query.isEmpty || !group.models.isEmpty || showDefault {
                            sectionHeader(group.descriptor.displayName, harness: group.id, count: group.models.count)
                                .id(ModelPickerController.Section.harness(group.id))
                                .background(position(.harness(group.id)))
                            if showDefault { defaultRow(defaultChoice) }
                            ForEach(group.models, id: \.pickerKey) { entry in
                                modelRow(entry, section: .harness(group.id), showsMark: !cursor.query.isEmpty)
                            }
                            if group.models.isEmpty && cursor.query.isEmpty { empty("No models reported") }
                        }
                    }
                    if cursor.query.isEmpty {
                        ForEach(data.groups.filter { $0.state != .on }) { group in
                            unavailable(group)
                                .id(ModelPickerController.Section.harness(group.id))
                                .background(position(.harness(group.id)))
                        }
                    } else {
                        if data.choices(defaultFor: selected.harness).isEmpty { empty("No matching models") }
                        if !data.notSearched.isEmpty {
                            empty("Not searched: \(data.notSearched.joined(separator: ", ")).")
                        }
                    }
                }
                .padding(.horizontal, LoomTheme.ModelPicker.listInset)
                .padding(.vertical, LoomTheme.ModelPicker.listVertical)
            }
            .coordinateSpace(name: space)
            .onPreferenceChange(ModelPickerPositions.self) { positions in
                if let active = Self.visibleSection(positions), cursor.activeSection != active { cursor.activeSection = active }
            }
            .onChange(of: cursor.jumpSerial) { _, _ in
                if let target = cursor.jumpTarget { proxy.scrollTo(target, anchor: .top) }
            }
            .onChange(of: cursor.cursor) { _, current in
                if let current { proxy.scrollTo(current) }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Models")
    }

    static func visibleSection(_ positions: [ModelPickerController.Section: CGFloat]) -> ModelPickerController.Section? {
        let above = positions.filter { $0.value <= 0 }
        if let nearest = above.max(by: { $0.value < $1.value }) { return nearest.key }
        return positions.min(by: { $0.value < $1.value })?.key
    }

    private func position(_ section: ModelPickerController.Section) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ModelPickerPositions.self, value: [section: proxy.frame(in: .named(space)).minY])
        }
    }

    private func sectionHeader(_ title: String, harness: HarnessID?, count: Int) -> some View {
        HStack(spacing: LoomTheme.ModelPicker.rowGap) {
            if let harness { ProviderIcon(harness: harness, size: LoomTheme.ModelPicker.groupMark) }
            Text(title).font(LoomTheme.ModelPicker.groupFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
            Spacer(minLength: 0)
            Text("\(count)").font(LoomTheme.ModelPicker.countFont).foregroundStyle(LoomTheme.Text.tertiaryStyle)
        }
        .padding(.horizontal, LoomTheme.ModelPicker.rowInset).frame(height: LoomTheme.ModelPicker.groupHeight)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
    }

    private func defaultRow(_ choice: ModelPickerChoice) -> some View {
        let identity = ModelPickerRow(section: .harness(choice.harness), choice: choice)
        return row(identity: identity, title: "Default", description: "Let the harness choose", showsMark: false)
            .id(identity)
    }

    private func modelRow(_ entry: ModelCatalogEntry, section: ModelPickerController.Section, showsMark: Bool) -> some View {
        let choice = ModelPickerChoice.model(ModelPickerKey(entry))
        let identity = ModelPickerRow(section: section, choice: choice)
        return row(identity: identity, title: entry.title, description: entry.description ?? entry.note, showsMark: showsMark)
            .id(identity)
    }

    private func row(identity: ModelPickerRow, title: String, description: String?, showsMark: Bool) -> some View {
        let choice = identity.choice
        let value = switch choice {
        case let .model(key): "model-\(key.id)"
        case .defaultModel: "default"
        }
        return Button { cursor.cursor = identity; choose(choice) } label: {
            HStack(spacing: LoomTheme.ModelPicker.rowGap) {
                if showsMark { ProviderIcon(harness: choice.harness, size: LoomTheme.ModelPicker.rowMark) }
                Text(title).font(LoomTheme.ModelPicker.rowFont).foregroundStyle(LoomTheme.Text.primary).lineLimit(1)
                if let description, !description.isEmpty {
                    Text(description).font(LoomTheme.ModelPicker.descriptionFont).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Group {
                    if selected == choice {
                        InkIcon(.check, size: LoomTheme.Icon.body).foregroundStyle(LoomTheme.Accent.base)
                    }
                }
                .frame(width: LoomTheme.ModelPicker.checkWidth).accessibilityHidden(true)
            }
            .padding(.horizontal, LoomTheme.ModelPicker.rowInset).frame(height: LoomTheme.ModelPicker.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RowHighlight(state: cursor.cursor == identity ? .selected : .none, radius: LoomTheme.ModelPicker.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { cursor.cursor = identity } }
        .accessibilityLabel(description.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected == choice ? .isSelected : [])
        .accessibilityIdentifier("\(identifier)-choice-\(identity.section == .recent ? "recent" : "group")-\(choice.harness.rawValue)-\(value)")
    }

    private func unavailable(_ group: ModelPickerProjection.Group) -> some View {
        HStack(spacing: LoomTheme.ModelPicker.rowGap) {
            ProviderIcon(harness: group.id, size: LoomTheme.ModelPicker.rowMark).opacity(LoomTheme.Opacity.disabled)
            Text(group.descriptor.displayName).font(LoomTheme.ModelPicker.rowFont).foregroundStyle(LoomTheme.Text.secondaryStyle)
            Text(group.state == .off ? "Off" : "Not found")
                .font(LoomTheme.ModelPicker.descriptionFont).foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
            Spacer(minLength: 0)
            Button(group.state == .off ? "Turn On…" : "Install…") { close(); model.showConnections() }
                .buttonStyle(ControlButtonStyle(kind: .ghost, size: .small))
        }
        .padding(.horizontal, LoomTheme.ModelPicker.rowInset).frame(height: LoomTheme.ModelPicker.rowHeight)
        .accessibilityElement(children: .contain)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(LoomTheme.ModelPicker.emptyFont).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            .fixedSize(horizontal: false, vertical: true).padding(LoomTheme.ModelPicker.emptyInset)
    }
}

private struct ModelPickerPositions: PreferenceKey {
    static var defaultValue: [ModelPickerController.Section: CGFloat] { [:] }
    static func reduce(value: inout [ModelPickerController.Section: CGFloat],
                       nextValue: () -> [ModelPickerController.Section: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
    }
}
