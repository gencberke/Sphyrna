import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

/// Offscreen tests of the real controls and card; no native window is shown.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ReferenceIconTests {
    private func makeModel() throws -> (CatalogModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-x2-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = CatalogModel(catalog: nil, events: SessionEventHub(),
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("p.json")))
        return (model, root)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
            abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent))
    }

    @Test func projectsToggleDrawsTheReferenceListOutlineInBothAppearances() async throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setViewMode(.projects)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let hosting = NSHostingController(rootView: ViewPicker(model: model).frame(width: 28, height: 28))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 28, height: 28),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 28, height: 28))
            try await settle(window)
            let image = try bitmap(hosting.view)
            let bg = try #require(image.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
            // The reference list is enclosed by a rounded 11.6 x 10 outline;
            // SF's unboxed list has no continuous right edge.
            let xScale = CGFloat(image.pixelsWide) / hosting.view.bounds.width
            let yScale = CGFloat(image.pixelsHigh) / hosting.view.bounds.height
            var maxEdge = 0
            for x in Int(18 * xScale)...Int(20 * xScale) {
                var ink = 0
                for y in Int(10 * yScale)...Int(18 * yScale) {
                    if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), difference(color, bg) > 0.08 {
                        ink += 1
                    }
                }
                maxEdge = max(maxEdge, ink)
            }
            #expect(CGFloat(maxEdge) / yScale >= 5,
                    "the rendered view toggle has a 5 pt straight outline: \(appearance), edge \(maxEdge), scale \(yScale)")
            #expect(!window.isVisible && !window.isKeyWindow)
        }
    }

    @Test func activityCardShowsItsOwnModelAndUpdatesItsAccessibleLabel() async throws {
        enableAccessibilityTree()
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setViewMode(.activity)
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        let record = CatalogSession(session: session, title: "Main session", createdAt: Date(), lastUsedAt: Date(),
                                    lifecycle: .idle, pinned: false)
        let row = SessionRowModel(record: record, live: nil)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for width in [280, 300] {
                model.cardModels.publish(stored: [row.id: "claude-opus-5-5"], reported: [:])
                let hosting = NSHostingController(rootView: SessionCardView(row: row, model: model).frame(width: CGFloat(width)))
                hosting.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 74),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.appearance = NSAppearance(named: appearance)
                window.contentViewController = hosting
                window.setContentSize(NSSize(width: CGFloat(width), height: 74))
                try await settle(window)
                func cardLabel() -> String {
                    accessibilityElements(in: hosting.view).first {
                        $0.accessibilityRole?() == .button && InkAX.label($0).hasPrefix("Main session,")
                    }.map(InkAX.label) ?? ""
                }
                let card = try #require(accessibilityElements(in: hosting.view).first {
                    $0.accessibilityRole?() == .button && InkAX.label($0).hasPrefix("Main session,")
                })
                let frame = InkAX.frame(card)
                let full = cardLabel()
                #expect(full.contains("Claude, Opus 5.5"), "the accessible main harness and model stay adjacent: \(full)")
                #expect(full.contains("stored model"), "a stored choice is not described as a live report: \(full)")
                let withModel = try bitmap(hosting.view)
                model.cardModels.publish(stored: [row.id: "default"], reported: [:])
                try await settle(window)
                let missing = cardLabel()
                #expect(!missing.contains("Opus 5.5"), "a missing model must not leave an old value")
                let withoutModel = try bitmap(hosting.view)
                func color(_ image: NSBitmapImageRep, at point: NSPoint) throws -> NSColor {
                    let local = hosting.view.convert(window.convertFromScreen(NSRect(origin: point, size: .zero)), from: nil)
                    let x = Int(local.minX * CGFloat(image.pixelsWide) / hosting.view.bounds.width)
                    let y = hosting.view.isFlipped ? local.minY : hosting.view.bounds.height - local.minY
                    return try #require(image.colorAt(x: x, y: Int(y * CGFloat(image.pixelsHigh) / hosting.view.bounds.height))?
                        .usingColorSpace(.sRGB))
                }
                var changed = 0
                for dx in (width / 2)..<(width - 8) {
                    for dy in 8..<26 {
                        let point = NSPoint(x: frame.minX + CGFloat(dx), y: frame.minY + CGFloat(dy))
                        let a = try color(withModel, at: point), b = try color(withoutModel, at: point)
                        if difference(a, b) > 0.08 { changed += 1 }
                    }
                }
                #expect(changed >= 8, "the actual footer changes when this session's model disappears: \(appearance), \(width), \(changed)")
                model.cardModels.publish(stored: [row.id: "opus"], reported: [row.id: "claude-sonnet-4-6"])
                try await settle(window)
                let updated = cardLabel()
                #expect(updated.contains("Claude, Sonnet 4.6") && !updated.contains("Opus 5.5"),
                        "a later reported main model replaces the old value: \(updated)")
                #expect(updated.contains("reported model"), "the actual report keeps its provenance: \(updated)")
                #expect(!window.isVisible && !window.isKeyWindow)
            }
        }
    }

    @Test func claudeIndexCannotAttributeItsModelToAnotherHarness() async throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeID = "shared-native-id"
        let index = ContextFakeIndex()
        index.set([nativeID: SessionContextSample(model: "claude-opus-5-5", timestamp: Date(),
                                                   tokens: UsageTokens(input: 1, output: 1))])
        model.usage = UsageModel(index: index, timeZone: .current)
        let claude = ManagedSession(provider: .claude, providerConversationID: nativeID, workingDirectory: root.path)
        let codex = ManagedSession(provider: .codex, providerConversationID: nativeID, workingDirectory: root.path)
        for session in [claude, codex] {
            let record = CatalogSession(session: session, title: "Session", createdAt: Date(), lastUsedAt: Date(),
                                        lifecycle: .idle, pinned: false)
            _ = model.row(for: record)
        }
        model.refreshCardModels()
        await model.cardModelTask?.value
        #expect(model.cardModels.presentation(of: claude.id, provider: .claude)?.name == "Opus 5.5")
        #expect(model.cardModels.presentation(of: codex.id, provider: .codex) == nil,
                "a shared native ID must not turn Claude's indexed model into the Codex model")
    }

    @Test func activityReasonPinAndModelShareTheCompactCard() async throws {
        enableAccessibilityTree()
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setViewMode(.activity)
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        let record = CatalogSession(session: session, title: "Review access", createdAt: Date(), lastUsedAt: Date(),
                                    lifecycle: .active, pinned: true)
        let live = SessionViewState(status: ProviderWorkState(activity: .waitingForApproval), runID: UUID(),
                                    reason: StatusReason(.approval(tool: "Bash"), detail: "git status"))
        let row = SessionRowModel(record: record, live: live)
        model.cardModels.publish(stored: [row.id: "claude-opus-5-5"], reported: [:])
        for width in [280, 300] {
            let hosting = NSHostingController(rootView: SessionCardView(row: row, model: model).frame(width: CGFloat(width)))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 74),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: CGFloat(width), height: 74))
            try await settle(window)
            let card = try #require(accessibilityElements(in: hosting.view).first {
                $0.accessibilityRole?() == .button && InkAX.label($0).hasPrefix("Review access,")
            })
            let label = InkAX.label(card)
            #expect(abs(InkAX.frame(card).height - 74) < 1)
            #expect(label.contains("Claude, Opus 5.5") && label.contains("git status") && label.contains("pinned"))
            #expect(!window.isVisible && !window.isKeyWindow)
        }
    }

    @Test func reportedDefaultDoesNotPretendToNameAModel() {
        #expect(SidebarCardModels.selection(stored: "default", reported: "default")?.value == nil)
        #expect(SidebarCardModels.selection(stored: nil, reported: "default")?.value == nil)
        #expect(SidebarCardModels.selection(stored: "opus", reported: "default")?.value == "opus")
    }

    @Test func activityDoesNotFormatAnotherHarnessModelAsAClaudeAlias() async throws {
        enableAccessibilityTree()
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setViewMode(.activity)
        let session = ManagedSession(provider: .codex, workingDirectory: root.path)
        let record = CatalogSession(session: session, title: "Other harness", createdAt: Date(), lastUsedAt: Date(),
                                    lifecycle: .idle, pinned: false)
        let row = SessionRowModel(record: record, live: nil)
        // This is a Codex model ID, even though Claude also has an alias of the same spelling.
        model.cardModels.publish(stored: [row.id: "opus"], reported: [:])
        let hosting = NSHostingController(rootView: SessionCardView(row: row, model: model).frame(width: 280))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 74),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 280, height: 74))
        try await settle(window)
        let card = try #require(accessibilityElements(in: hosting.view).first {
            $0.accessibilityRole?() == .button && InkAX.label($0).hasPrefix("Other harness,")
        })
        let label = InkAX.label(card)
        #expect(label.contains("Codex, opus, stored model"), "the model keeps its own harness's spelling: \(label)")
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test func activityDoesNotPromoteAStoredAliasToANewerCatalogRelease() async throws {
        enableAccessibilityTree()
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setViewMode(.activity)
        model.modelCatalog.apply(HarnessReading(provider: .claude, models: [
            HarnessModel(id: "opus", displayName: "Opus", isDefault: false, efforts: [], resolvedModel: "claude-opus-6-0")
        ], readAt: Date()))
        let session = ManagedSession(provider: .claude, workingDirectory: root.path)
        let record = CatalogSession(session: session, title: "Stored alias", createdAt: Date(), lastUsedAt: Date(),
                                    lifecycle: .idle, pinned: false)
        let row = SessionRowModel(record: record, live: nil)
        model.cardModels.publish(stored: [row.id: "opus"], reported: [:])
        let hosting = NSHostingController(rootView: SessionCardView(row: row, model: model).frame(width: 280))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 74),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 280, height: 74))
        try await settle(window)
        let card = try #require(accessibilityElements(in: hosting.view).first {
            $0.accessibilityRole?() == .button && InkAX.label($0).hasPrefix("Stored alias,")
        })
        let label = InkAX.label(card)
        #expect(label.contains("Claude, Opus, stored model") && !label.contains("6.0"),
                "a newer catalog release is not this session's model report: \(label)")
        #expect(!window.isVisible && !window.isKeyWindow)
    }
}
