import LoomCore
import SwiftUI

/// The draft's two independent 28 pt controls share the window's one InkHost.
struct DraftModelPickers: View {
    let model: CatalogModel
    let projectID: UUID?
    let restoreFocus: () -> Void
    private let openState = InkOpenState.shared
    @State private var modelCursor = ModelPickerController()
    @State private var effortCursor = EffortPickerController()

    init(model: CatalogModel, projectID: UUID?, restoreFocus: @escaping () -> Void,
         modelCursor: ModelPickerController? = nil, effortCursor: EffortPickerController? = nil) {
        self.model = model
        self.projectID = projectID
        self.restoreFocus = restoreFocus
        _modelCursor = State(initialValue: modelCursor ?? ModelPickerController())
        _effortCursor = State(initialValue: effortCursor ?? EffortPickerController())
    }

    var body: some View {
        let resolved = model.resolvedStart(for: projectID)
        let choices = resolved.choices
        let selected = choices.model.map { ModelPickerChoice.model(ModelPickerKey(harness: choices.harness, id: $0)) }
            ?? .defaultModel(choices.harness)
        let title = choices.model == nil ? "Default" : resolved.modelTitle(in: model.modelCatalog)
        let options = ModelPickerDraft.options(model: model, projectID: projectID)
        let owner = ModelPickerDraft.owner(model: model, projectID: projectID)
        HStack(spacing: 0) {
            ModelPickerChip(model: model, selected: selected, title: title, identifier: "draft-model",
                            isOpen: openState.draftBinding(.model, projectID: projectID), cursor: modelCursor,
                            restoreFocus: restoreFocus) { choice in
                switch choice {
                case let .model(key): ModelPickerDraft.choose(key, model: model, projectID: projectID)
                case let .defaultModel(harness): ModelPickerDraft.chooseDefault(harness: harness, model: model, projectID: projectID)
                }
            }
            if !options.levels.isEmpty {
                EffortPickerChip(modelTitle: title, options: options, owner: owner, identifier: "draft-effort",
                                 isOpen: openState.draftBinding(.effort, projectID: projectID), cursor: effortCursor,
                                 restoreFocus: restoreFocus) { choice, expected in
                    switch choice {
                    case .default: ModelPickerDraft.resetEffort(expected: expected, model: model, projectID: projectID)
                    case let .level(level): ModelPickerDraft.chooseEffort(level, expected: expected, model: model, projectID: projectID)
                    }
                }
            }
        }
    }
}

struct ModelPickerChip: View {
    let model: CatalogModel
    let selected: ModelPickerChoice
    let title: String
    let identifier: String
    @Binding var isOpen: Bool
    let cursor: ModelPickerController
    let restoreFocus: (() -> Void)?
    let choose: (ModelPickerChoice) -> Bool

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: LoomTheme.ModelPicker.chipGap) {
                ProviderIcon(harness: selected.harness, size: LoomTheme.ModelPicker.chipMark)
                Text(title).font(LoomTheme.ModelPicker.chipFont).lineLimit(1)
                InkIcon(.chevronDown, size: LoomTheme.Icon.tiny).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
        }
        .buttonStyle(ControlButtonStyle(kind: .ghost, size: .regular))
        .background {
            if isOpen { RoundedRectangle(cornerRadius: LoomTheme.Control.Size.regular.radius).fill(LoomTheme.Highlight.selected) }
        }
        .help("Model").accessibilityLabel("Model, \(title)").accessibilityIdentifier(identifier)
        .inkPopover(isPresented: $isOpen, id: identifier, label: "Choose model", side: .below, alignment: .trailing,
                    keys: handle, restoreFocus: restoreFocus) {
            ModelPickerAccessibility(role: .menu, label: "Model menu",
                                     size: CGSize(width: LoomTheme.ModelPicker.width, height: LoomTheme.ModelPicker.height)) {
                ModelPickerPanel(model: model, selected: selected, cursor: cursor, identifier: identifier,
                                 handle: handle, choose: commit, close: { isOpen = false })
            }
        }
        .onChange(of: isOpen) { _, open in
            if open {
                let data = ModelPickerDraft.projection(model: model)
                cursor.prepare(selected: selected, rows: data.rows(defaultFor: selected.harness))
            }
        }
    }

    private func commit(_ choice: ModelPickerChoice) {
        if choose(choice) { isOpen = false }
    }

    private func handle(_ key: InkKey) -> Bool {
        let data = ModelPickerDraft.projection(model: model, query: cursor.query)
        switch cursor.handle(key, rows: data.rows(defaultFor: selected.harness)) {
        case .ignored: return key == .return
        case .moved: return true
        case let .choose(choice): commit(choice); return true
        case .dismiss: isOpen = false; return true
        }
    }
}

struct EffortPickerChip: View {
    let modelTitle: String
    let options: EffortPickerOptions
    let owner: EffortPickerOwner
    let identifier: String
    @Binding var isOpen: Bool
    let cursor: EffortPickerController
    let restoreFocus: (() -> Void)?
    let choose: (EffortPickerController.Choice, EffortPickerOwner) -> Bool

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: LoomTheme.ModelPicker.chipGap) {
                InkIcon(.effort, size: LoomTheme.Icon.body)
                Text(options.title).font(LoomTheme.ModelPicker.chipFont).lineLimit(1)
                InkIcon(.chevronDown, size: LoomTheme.Icon.tiny).foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
        }
        .buttonStyle(ControlButtonStyle(kind: .ghost, size: .regular))
        .background {
            if isOpen { RoundedRectangle(cornerRadius: LoomTheme.Control.Size.regular.radius).fill(LoomTheme.Highlight.selected) }
        }
        .help("Effort").accessibilityLabel("Effort, \(options.title)").accessibilityIdentifier(identifier)
        .inkPopover(isPresented: $isOpen, id: identifier, label: "Effort for \(modelTitle)", side: .below, alignment: .trailing,
                    keys: handle, restoreFocus: restoreFocus) {
            ModelPickerAccessibility(role: .menu, label: "Effort for \(modelTitle)",
                                     size: LoomTheme.ModelPicker.effortLayout(levelCount: options.levels.count).size) {
                EffortPickerMenu(modelTitle: modelTitle, options: options, cursor: cursor, identifier: identifier, choose: commit)
            }
        }
        .onChange(of: isOpen) { _, open in if open { cursor.prepare(owner: owner, options: options) } }
        .onChange(of: owner) { _, newOwner in
            if isOpen, cursor.owner != nil, cursor.owner != newOwner { isOpen = false }
        }
    }

    private func commit(_ choice: EffortPickerController.Choice) {
        guard let expected = cursor.owner else { return }
        if choose(choice, expected) { isOpen = false }
    }

    private func handle(_ key: InkKey) -> Bool {
        switch cursor.handle(key, options: options) {
        case .ignored: return key == .return
        case .moved: return true
        case let .choose(choice): commit(choice); return true
        case .dismiss: isOpen = false; return true
        }
    }
}
