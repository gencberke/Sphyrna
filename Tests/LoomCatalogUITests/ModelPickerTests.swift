import Foundation
import AppKit
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

@MainActor @Suite(.serialized) struct ModelPickerTests {
    private func catalog() -> ModelCatalog {
        let catalog = ModelCatalog()
        catalog.apply(HarnessReading(provider: .claude, models: [
            HarnessModel(id: "same", displayName: "Same Claude", isDefault: false, efforts: ["low", "high"]),
            HarnessModel(id: "opus", displayName: "Opus", isDefault: false, efforts: ["low"])
        ], readAt: Date()))
        catalog.apply(HarnessReading(provider: .codex, models: [
            HarnessModel(id: "same", displayName: "Same Codex", isDefault: false, efforts: ["low", "ultra"]),
            HarnessModel(id: "gpt-sol", displayName: "Sol", isDefault: true, efforts: ["high"], defaultEffort: "high")
        ], readAt: Date()))
        return catalog
    }

    private var availability: [HarnessID: HarnessAvailability] {
        Dictionary(uniqueKeysWithValues: HarnessCatalogue.ids.map { id in
            let state: HarnessAvailabilityState = [HarnessID.claude, .codex, .agy].contains(id) ? .on : .notFound
            return (id, HarnessAvailability(id: id, state: state))
        })
    }

    @Test func searchCrossesEnabledHarnessesUsesCompositeKeysAndNamesSkipped() {
        let c = catalog()
        c.connections.setOn(.pi, true)
        var states = availability
        states[.pi] = HarnessAvailability(id: .pi, state: .on)
        let data = ModelPickerProjection(catalog: c, availability: states, query: "same")
        #expect(data.choices(defaultFor: .claude) == [
            .model(ModelPickerKey(harness: .claude, id: "same")),
            .model(ModelPickerKey(harness: .codex, id: "same"))
        ])
        #expect(data.notSearched.contains("agy (off)"))
        #expect(data.notSearched.contains("opencode (not found)"))
        #expect(data.notSearched.contains("pi (no models reported)"))
        #expect(data.groups.first { $0.id == .agy }?.models.isEmpty == true)
    }

    @Test func recentIsBoundedDeduplicatedAndRespectsTheLiveSwitch() {
        let recent = ModelPickerState()
        for index in 0..<6 { recent.record(ModelPickerKey(harness: .claude, id: "m\(index)")) }
        #expect(recent.recent.count == 5 && recent.recent.first?.id == "m5" && recent.recent.last?.id == "m1")
        recent.record(ModelPickerKey(harness: .claude, id: "m3"))
        #expect(recent.recent.first?.id == "m3" && recent.recent.count == 5)
        let c = catalog()
        c.connections.setConnected(.codex, false)
        let data = ModelPickerProjection(catalog: c, availability: availability,
            recentKeys: [ModelPickerKey(harness: .codex, id: "same"), ModelPickerKey(harness: .claude, id: "same")])
        #expect(data.recent.map(ModelPickerKey.init) == [ModelPickerKey(harness: .claude, id: "same")])
        #expect(data.groups.first { $0.id == .codex }?.state == .off)
    }

    @Test func keyboardChoiceUsesTheRealEntryAndAStaleDisabledRowCannotApply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b4-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        defer { model.stop() }
        model.modelCatalog = catalog()
        model.harnessAvailability = availability
        model.showDraft(projectID: nil)
        model.setDraftMode(.value("bypassPermissions"), projectID: nil)
        model.setDraftModel(.value("same"), projectID: nil)
        model.setDraftEffort(.value("high"), projectID: nil)
        let cursor = ModelPickerController()
        let initial = ModelPickerDraft.projection(model: model)
        cursor.prepare(selected: .model(ModelPickerKey(harness: .claude, id: "same")),
                       rows: initial.rows(defaultFor: .claude))
        let filtered = ModelPickerDraft.projection(model: model, query: "sol")
        cursor.search("sol", rows: filtered.rows(defaultFor: .claude))
        model.modelCatalog.connections.setConnected(.codex, false)
        let disconnected = ModelPickerDraft.projection(model: model, query: "sol")
        #expect(cursor.handle(.return, rows: disconnected.rows(defaultFor: .claude)) == .ignored)
        model.modelCatalog.connections.setConnected(.codex, true)
        let result = cursor.handle(.return, rows: filtered.rows(defaultFor: .claude))
        guard case let .choose(.model(key)) = result else { Issue.record("Return did not choose a real model"); return }
        #expect(key == ModelPickerKey(harness: .codex, id: "gpt-sol"))
        #expect(ModelPickerDraft.choose(key, model: model, projectID: nil))
        #expect(model.resolvedStart(for: nil).choices == HarnessLaunchChoices(harness: .codex, model: "gpt-sol", effort: "high"))
        #expect(!model.canSendDraft(projectID: nil), "choosing a model never enables the frozen start")
        #expect(model.modelPickerState.recent.first == key)
        let before = model.resolvedStart(for: nil).choices
        model.modelCatalog.connections.setConnected(.codex, false)
        #expect(!ModelPickerDraft.choose(key, model: model, projectID: nil))
        #expect(model.resolvedStart(for: nil).choices.harness == before.harness)
        #expect(model.newSession.draft(for: nil)?.choices.model == before.model)
    }

    @Test func defaultIsAnActionForTheCurrentHarnessAndRevalidatesEffort() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b4-default-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        defer { model.stop() }
        model.modelCatalog = catalog()
        model.harnessAvailability = availability
        model.showDraft(projectID: nil)
        #expect(ModelPickerDraft.choose(ModelPickerKey(harness: .codex, id: "same"), model: model, projectID: nil))
        model.setDraftEffort(.value("ultra"), projectID: nil)
        #expect(ModelPickerDraft.chooseDefault(harness: .codex, model: model, projectID: nil))
        #expect(model.resolvedStart(for: nil).choices == HarnessLaunchChoices(harness: .codex, effort: "high"))
        let owner = ModelPickerDraft.owner(model: model, projectID: nil)
        #expect(ModelPickerDraft.resetEffort(expected: owner, model: model, projectID: nil))
        #expect(model.resolvedStart(for: nil).choices.effort == nil)
        #expect(!ModelPickerDraft.chooseDefault(harness: .claude, model: model, projectID: nil))
    }

    @Test func railAndKeyboardFollowTheVisibleRecentAndHarnessRows() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b4-rail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        defer { model.stop(); InkOpenState.shared.draft = nil }
        model.modelCatalog = catalog()
        model.modelCatalog.apply(HarnessReading(provider: .claude, models: (0..<24).map { index in
            HarnessModel(id: "model-\(index)", displayName: "Model \(index)", isDefault: false, efforts: ["high"])
        }, readAt: Date()))
        model.harnessAvailability = availability
        model.showDraft(projectID: nil)
        let same = ModelPickerKey(harness: .codex, id: "same")
        let sol = ModelPickerKey(harness: .codex, id: "gpt-sol")
        model.modelPickerState.record(same)
        #expect(ModelPickerDraft.choose(sol, model: model, projectID: nil))

        let host = InkHost()
        let chips = NSHostingView(rootView: DraftModelPickers(model: model, projectID: nil, restoreFocus: {}).inkHost(host))
        chips.frame = NSRect(x: 20, y: 400, width: 500, height: 40)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        content.addSubview(chips)
        host.view.frame = content.bounds
        content.addSubview(host.view)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { host.state.dismiss(); window.close() }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        func open() async throws {
            let button = try #require(accessibilityElements(in: chips).first { InkAX.label($0).hasPrefix("Model, ") })
            #expect(button.accessibilityPerformPress?() == true)
            try await settle()
            #expect(host.state.active?.id == "draft-model")
        }
        func rail(_ name: String) async throws {
            let button = try #require(accessibilityElements(in: host.view).first { InkAX.label($0) == name })
            #expect(button.accessibilityPerformPress?() == true)
            try await settle()
        }

        try await settle()
        try await open()
        let list = try #require(descendants(host.view).compactMap { $0 as? NSScrollView }.first { scroll in
            guard let document = scroll.documentView else { return false }
            return document.bounds.height > scroll.contentView.bounds.height + 1
        })
        try await rail("Recent models")
        let top = list.contentView.bounds.minY
        #expect(host.state.handle(.up))
        try await settle()
        let bottom = list.contentView.bounds.minY
        #expect(abs(bottom - top) > LoomTheme.ModelPicker.bodyHeight)
        #expect(host.state.handle(.down))
        try await settle()
        #expect(abs(list.contentView.bounds.minY - top) <= 2 * LoomTheme.ModelPicker.rowHeight,
                "wrapping returns to the Recent row, not its duplicate in the harness group")
        #expect(host.state.handle(.down) && host.state.handle(.return))
        try await settle()
        #expect(model.resolvedStart(for: nil).choices.harness == .codex)
        #expect(model.resolvedStart(for: nil).choices.model == "same")

        #expect(ModelPickerDraft.choose(sol, model: model, projectID: nil))
        try await settle()
        try await open()
        try await rail("Claude · On")
        #expect(host.state.handle(.return))
        try await settle()
        #expect(model.resolvedStart(for: nil).choices.harness == .claude)
        #expect(model.resolvedStart(for: nil).choices.model == "model-0")

        try await open()
        let before = model.resolvedStart(for: nil).choices
        try await rail("agy · Off")
        _ = host.state.handle(.down)
        #expect(host.state.handle(.return))
        try await settle()
        #expect(host.state.active?.id == "draft-model")
        #expect(model.resolvedStart(for: nil).choices == before)
        #expect(!window.isVisible)
    }

    @Test func draftPickersUseTheSharedHostAndKeyboardReducerWithoutStartingAProvider() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b4-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        defer { model.stop(); InkOpenState.shared.draft = nil }
        model.modelCatalog = catalog()
        model.harnessAvailability = availability
        model.showDraft(projectID: nil)
        model.setDraftText("draft work", projectID: nil)
        let host = InkHost()
        let cursor = ModelPickerController()
        let chips = NSHostingView(rootView: DraftModelPickers(model: model, projectID: nil, restoreFocus: {},
                                                               modelCursor: cursor).inkHost(host))
        chips.frame = NSRect(x: 20, y: 400, width: 500, height: 40)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let background = NSHostingView(rootView: Rectangle().fill(LoomTheme.Surface.canvas))
        background.frame = content.bounds
        content.addSubview(background)
        content.addSubview(chips)
        host.view.frame = content.bounds
        content.addSubview(host.view)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = content
        defer { window.close() }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func picture(_ name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["LOOM_B4_RENDER_DIR"], !path.isEmpty else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let image = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: image)
            try #require(image.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("b4-\(name)-fixture.png"))
        }
        try await settle()
        #expect(!window.isVisible)
        let modelButton = try #require(accessibilityElements(in: chips).first { InkAX.label($0) == "Model, Default" })
        #expect(modelButton.accessibilityPerformPress?() == true)
        try await settle()
        #expect(host.state.active?.id == "draft-model")
        let panelElements = accessibilityElements(in: host.view)
        #expect(panelElements.contains { InkAX.label($0) == "Search models" })
        #expect(panelElements.contains { $0.accessibilityRole?() == .menu && InkAX.label($0) == "Model menu" })
        #expect(panelElements.contains { $0.accessibilityRole?() == .list && InkAX.label($0) == "Model sources" })
        #expect(panelElements.contains { $0.accessibilityRole?() == .list && InkAX.label($0) == "Models" })
        #expect(host.state.contentSize == CGSize(width: LoomTheme.ModelPicker.width, height: LoomTheme.ModelPicker.height))
        try picture("models-paper")
        window.appearance = NSAppearance(named: .darkAqua)
        try await settle()
        try picture("models-ink")
        window.appearance = NSAppearance(named: .aqua)
        try await settle()
        let searched = ModelPickerDraft.projection(model: model, query: "sol")
        cursor.search("sol", rows: searched.rows(defaultFor: .claude))
        try await settle()
        #expect(accessibilityElements(in: host.view).contains {
            $0.accessibilityRole?() == .button && InkAX.label($0).hasPrefix("Sol")
        })
        #expect(host.state.handle(.return))
        try await settle()
        #expect(model.resolvedStart(for: nil).choices == HarnessLaunchChoices(harness: .codex, model: "gpt-sol", effort: "high"))
        #expect(host.state.active == nil && !model.canSendDraft(projectID: nil))
        let effort = try #require(accessibilityElements(in: chips).first { InkAX.label($0) == "Effort, High" })
        #expect(effort.accessibilityPerformPress?() == true)
        try await settle()
        #expect(host.state.active?.id == "draft-effort")
        #expect(accessibilityElements(in: host.view).contains {
            $0.accessibilityRole?() == .menu && InkAX.label($0) == "Effort for Sol"
        })
        #expect(host.state.contentSize.width == LoomTheme.ModelPicker.effortWidth)
        try picture("effort-paper")
        window.appearance = NSAppearance(named: .darkAqua)
        try await settle()
        try picture("effort-ink")
        window.appearance = NSAppearance(named: .aqua)
        try await settle()
        #expect(host.state.handle(.down) && host.state.handle(.return))
        try await settle()
        #expect(model.resolvedStart(for: nil).choices.effort == nil && host.state.active == nil)
        #expect(accessibilityElements(in: chips).contains { InkAX.label($0) == "Effort, Default" })
        let current = model.resolvedStart(for: nil).choices
        let modelAgain = try #require(accessibilityElements(in: chips).first { InkAX.label($0).hasPrefix("Model, ") })
        #expect(modelAgain.accessibilityPerformPress?() == true)
        try await settle()
        #expect(host.state.handle(.escape) && model.resolvedStart(for: nil).choices == current)
        #expect(modelAgain.accessibilityPerformPress?() == true)
        try await settle()
        let off = try #require(accessibilityElements(in: host.view).first { InkAX.label($0) == "agy · Off" })
        #expect(off.accessibilityPerformPress?() == true)
        try await settle()
        var openedConnections = false
        model.onShowSettings = { openedConnections = $0 == .connections }
        let turnOn = try #require(accessibilityElements(in: host.view).first { InkAX.label($0) == "Turn On…" })
        #expect(turnOn.accessibilityPerformPress?() == true)
        try await settle()
        #expect(openedConnections && host.state.active == nil)

        // A real hosted scroll moves the rail's active group without a probe or scan.
        model.modelCatalog.apply(HarnessReading(provider: .claude, models: (0..<24).map { index in
            HarnessModel(id: "model-\(index)", displayName: "Model \(index)", isDefault: false, efforts: ["high"])
        }, readAt: Date()))
        let opener = try #require(accessibilityElements(in: chips).first { InkAX.label($0).hasPrefix("Model, ") })
        #expect(opener.accessibilityPerformPress?() == true)
        try await settle()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let list = try #require(descendants(host.view).compactMap { $0 as? NSScrollView }.first { scroll in
            guard let document = scroll.documentView else { return false }
            return document.bounds.height > scroll.contentView.bounds.height + 1
        })
        let document = try #require(list.documentView)
        let limit = document.bounds.height - list.contentView.bounds.height
        func scroll(to y: CGFloat) {
            list.contentView.scroll(to: NSPoint(x: 0, y: y))
            list.reflectScrolledClipView(list.contentView)
        }
        scroll(to: document.isFlipped ? 0 : limit)
        try await settle()
        #expect(cursor.activeSection == .recent)
        scroll(to: document.isFlipped ? limit : 0)
        try await settle()
        #expect(cursor.activeSection != .recent)
        host.state.dismiss()
        #expect(!window.isVisible)
    }

    @Test func effortMenuMeasuresItsRowsAndRemainsUsableAfterTheHostResizes() async throws {
        enableAccessibilityTree()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b4-measure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: directory.appendingPathComponent("p.json")))
        defer { model.stop(); InkOpenState.shared.draft = nil }
        model.modelCatalog = catalog()
        model.harnessAvailability = availability
        model.showDraft(projectID: nil)
        #expect(ModelPickerDraft.choose(ModelPickerKey(harness: .codex, id: "gpt-sol"), model: model, projectID: nil))
        let host = InkHost()
        let chips = NSHostingView(rootView: DraftModelPickers(model: model, projectID: nil, restoreFocus: {}).inkHost(host))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        chips.frame = NSRect(x: 20, y: 400, width: 500, height: 40)
        content.addSubview(chips)
        host.view.frame = content.bounds
        content.addSubview(host.view)
        let window = NSWindow(contentRect: content.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { host.state.dismiss(); window.close() }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(150))
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func openEffort() async throws {
            let button = try #require(accessibilityElements(in: chips).first { InkAX.label($0).hasPrefix("Effort, ") })
            #expect(button.accessibilityPerformPress?() == true)
            try await settle()
            #expect(host.state.active?.id == "draft-effort")
        }

        try await settle()
        try await openEffort()
        let singleLevel = host.state.contentSize
        #expect(singleLevel.width == LoomTheme.ModelPicker.effortWidth && singleLevel.height > 0)
        #expect(accessibilityElements(in: host.view).contains {
            $0.accessibilityRole?() == .menu && InkAX.label($0) == "Effort for Sol"
        })
        host.state.dismiss()
        #expect(ModelPickerDraft.choose(ModelPickerKey(harness: .codex, id: "same"), model: model, projectID: nil))
        content.setFrameSize(NSSize(width: 650, height: 480))
        host.view.frame = content.bounds
        chips.frame.origin.y = 350
        try await settle()
        try await openEffort()
        #expect(host.state.contentSize.width == singleLevel.width)
        #expect(abs(host.state.contentSize.height - singleLevel.height - LoomTheme.ModelPicker.rowHeight) < 1,
                "a second effort row increases the measured menu by one row")
        let menu = try #require(accessibilityElements(in: host.view).first {
            $0.accessibilityRole?() == .menu && InkAX.label($0) == "Effort for Same Codex"
        })
        #expect(InkAX.frame(menu).width > 0 && InkAX.frame(menu).height > 0)
        let ultra = try #require(accessibilityElements(in: host.view).first { InkAX.identifier($0) == "draft-effort-choice-Ultra" })
        #expect(ultra.accessibilityPerformPress?() == true)
        try await settle()
        #expect(host.state.active == nil && model.resolvedStart(for: nil).choices.effort == "ultra")
        #expect(!window.isVisible)
    }

    @Test func effortChipAndModeAreAbsentWhenTheirDescriptorOffersNone() async throws {
        enableAccessibilityTree()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b4-none-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        defer { model.stop() }
        model.modelCatalog = catalog()
        model.modelCatalog.apply(HarnessReading(provider: .codex, models: [
            HarnessModel(id: "plain", displayName: "Plain", isDefault: true, efforts: [])
        ], readAt: Date()))
        model.harnessAvailability = availability
        model.showDraft(projectID: nil)
        #expect(ModelPickerDraft.choose(ModelPickerKey(harness: .codex, id: "plain"), model: model, projectID: nil))
        let hosting = NSHostingView(rootView: NewSessionComposer(model: model, projectID: nil))
        hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 220)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let elements = accessibilityElements(in: hosting)
        #expect(elements.contains { InkAX.label($0) == "Model, Plain" })
        #expect(!elements.contains { InkAX.label($0).hasPrefix("Effort,") })
        #expect(!elements.contains { InkAX.identifier($0) == "draft-mode" })
        #expect(!window.isVisible)
    }
}
