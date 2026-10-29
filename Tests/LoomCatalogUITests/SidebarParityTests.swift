import AppKit
import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// The real lazy sidebar, without showing a window. Native appearance still belongs to the visual pool.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SidebarParityTests {
    private struct Rig {
        let model: CatalogModel
        let root: URL
        let parent: UUID
        let reason: UUID
    }

    private func rig() async throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-sidebar-parity-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let catalog = try SessionCatalog(url: root.appendingPathComponent("catalog.sqlite3"))
        let parent = UUID(), reason = UUID()
        for (id, title) in [(parent, "Parent session"), (reason, "Review access"), (UUID(), "First idle"), (UUID(), "Second idle")] {
            try await catalog.insertSession(ManagedSession(id: id, provider: .claude, workingDirectory: root.path),
                                            title: title, lifecycle: .idle, pinned: id == reason,
                                            openedBy: id == reason ? parent : nil)
        }
        let hub = SessionEventHub()
        for id in [parent, reason] {
            await hub.publish(sessionID: id, change: .runStarted(UUID()))
            await hub.publish(sessionID: id, change: .status(ProviderWorkState(activity: .working)))
        }
        await hub.publish(sessionID: reason, change: .reason(StatusReason(.approval(tool: "Bash"), detail: "git status")))
        let children = [
            SubagentRecord(id: "alpha", agentType: "explorer", description: "Trace the card", startedAt: Date()),
            SubagentRecord(id: "beta", agentType: "implementer", description: "Update the card", startedAt: Date())
        ]
        await hub.publish(sessionID: parent, change: .subagents(children))
        let model = CatalogModel(catalog: catalog, events: hub,
                                 preferences: UIPreferencesStore(url: root.appendingPathComponent("preferences.json")))
        model.branchReader = { _ in .named("topic/sidebar") }
        await model.start()
        await model.stopAndWait()
        await model.settle()
        model.setViewMode(.activity)
        model.selectFromList(parent)
        await model.settle()
        return Rig(model: model, root: root, parent: parent, reason: reason)
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func element(_ prefix: String, role: NSAccessibility.Role, in view: NSView) -> AnyObject? {
        accessibilityElements(in: view).first { $0.accessibilityRole?() == role && InkAX.label($0).hasPrefix(prefix) }
    }

    @Test func aPinnedActiveReasonKeepsItsVisiblePinAndSingleAccessibleLabel() async throws {
        enableAccessibilityTree()
        let rig = try await rig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for width in [280, 300] {
                await rig.model.setPinned(rig.reason, true)
                await rig.model.settle()
                let hosting = NSHostingController(rootView: SidebarView(model: rig.model))
                hosting.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 800),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.appearance = NSAppearance(named: appearance)
                window.contentViewController = hosting
                window.setContentSize(NSSize(width: CGFloat(width), height: 800))
                try await settle(window)
                let card = try #require(element("Review access,", role: .button, in: hosting.view))
                let pinnedFrame = InkAX.frame(card)
                let pinnedLabel = InkAX.label(card)
                #expect(abs(pinnedFrame.height - 74) < 1)
                #expect(pinnedLabel.contains("git status") && pinnedLabel.contains("topic/sidebar"))
                #expect(pinnedLabel.components(separatedBy: "pinned").count == 2,
                        "the card announces the pin exactly once: \(pinnedLabel)")
                #expect(!accessibilityElements(in: hosting.view).contains {
                    $0.accessibilityRole?() == .button && ["Pin", "Pinned"].contains(InkAX.label($0))
                }, "the visible pin must not add a duplicate button")
                let pinnedImage = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                hosting.view.cacheDisplay(in: hosting.view.bounds, to: pinnedImage)

                await rig.model.setPinned(rig.reason, false)
                await rig.model.settle()
                try await settle(window)
                let unpinnedCard = try #require(element("Review access,", role: .button, in: hosting.view))
                let unpinnedFrame = InkAX.frame(unpinnedCard)
                let unpinnedLabel = InkAX.label(unpinnedCard)
                #expect(pinnedFrame == unpinnedFrame && !unpinnedLabel.contains("pinned"))
                #expect(unpinnedLabel.contains("git status") && unpinnedLabel.contains("topic/sidebar"))
                let unpinnedImage = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                hosting.view.cacheDisplay(in: hosting.view.bounds, to: unpinnedImage)
                func color(_ image: NSBitmapImageRep, at point: NSPoint) throws -> NSColor {
                    let local = hosting.view.convert(window.convertFromScreen(NSRect(origin: point, size: .zero)), from: nil)
                    let x = Int(local.minX * CGFloat(image.pixelsWide) / hosting.view.bounds.width)
                    let y = hosting.view.isFlipped ? local.minY : hosting.view.bounds.height - local.minY
                    return try #require(image.colorAt(x: x, y: Int(y * CGFloat(image.pixelsHigh) / hosting.view.bounds.height))?
                        .usingColorSpace(.sRGB))
                }
                var changed: [NSPoint] = []
                for dx in 12..<(width - 38) {
                    for dy in 10..<26 {
                        let point = NSPoint(x: pinnedFrame.minX + CGFloat(dx), y: pinnedFrame.minY + CGFloat(dy))
                        let a = try color(pinnedImage, at: point), b = try color(unpinnedImage, at: point)
                        let delta = max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                                        abs(a.blueComponent - b.blueComponent))
                        if delta > 0.03 { changed.append(point) }
                    }
                }
                let xs = changed.map(\.x), ys = changed.map(\.y)
                #expect(changed.count >= 4, "the pinned reason must visibly draw its pin: \(appearance), \(width), \(changed.count)")
                if let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() {
                    #expect(x1 - x0 <= 16 && y1 - y0 <= 16, "only the small pin changes in the bottom line")
                }
                #expect(!window.isVisible && !window.isKeyWindow)
            }
        }
    }

    @Test func childAccessibilityPressInvokesItsActionOnce() async throws {
        enableAccessibilityTree()
        let record = SubagentRecord(id: "alpha", agentType: "explorer", startedAt: Date())
        let row = try #require(SubagentTreeContent(records: [record], now: Date(), finishedExpanded: false,
                                                   runningExpanded: false).rows.first)
        var calls = 0
        let hosting = NSHostingController(rootView: SubagentRowView(row: row) { calls += 1 })
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 24), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 280, height: 24))
        defer { window.close() }
        try await settle(window)
        let button = try #require(element("Subagent explorer,", role: .button, in: hosting.view))
        #expect(button.accessibilityPerformPress?() == true && calls == 1)
        #expect(!window.isVisible && !window.isKeyWindow)
    }

    @Test(.renderProbe) func hoveringAnUnselectedCardIncludesItsChildRows() async throws {
        enableAccessibilityTree()
        let rig = try await rig()
        defer { LookEvidence.setHover(nil); rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        rig.model.showHome()
        LookEvidence.arm()
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let hosting = NSHostingController(rootView: SidebarView(model: rig.model))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 800), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: appearance)
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 300, height: 800))
            LookEvidence.setHover(nil)
            try await settle(window)
            let card = try #require(element("Parent session,", role: .button, in: hosting.view))
            let child = try #require(element("Subagent explorer,", role: .button, in: hosting.view))
            let cardFrame = InkAX.frame(card), childFrame = InkAX.frame(child)

            func samples() throws -> (NSColor, NSColor) {
                let image = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                hosting.view.cacheDisplay(in: hosting.view.bounds, to: image)
                func color(_ frame: NSRect) throws -> NSColor {
                    let point = NSPoint(x: cardFrame.minX + 8, y: frame.midY)
                    let local = hosting.view.convert(window.convertFromScreen(NSRect(origin: point, size: .zero)), from: nil)
                    let x = Int(local.minX * CGFloat(image.pixelsWide) / hosting.view.bounds.width)
                    let y = hosting.view.isFlipped ? local.minY : hosting.view.bounds.height - local.minY
                    return try #require(image.colorAt(x: x, y: Int(y * CGFloat(image.pixelsHigh) / hosting.view.bounds.height))?
                        .usingColorSpace(.sRGB))
                }
                return (try color(cardFrame), try color(childFrame))
            }
            func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
                max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                    abs(a.blueComponent - b.blueComponent))
            }
            let before = try samples()
            LookEvidence.setHover("sidebar-card:\(rig.parent)")
            try await settle(window)
            let after = try samples()
            #expect(difference(before.0, after.0) > 0.015, "the unselected card actually takes its hover fill")
            #expect(difference(after.0, after.1) < 0.006, "the same hover fill continues behind the child")
            #expect(!window.isVisible && !window.isKeyWindow)
        }
    }

    @Test func realSidebarKeepsTheSelectedSurfaceAroundIndependentChildrenAndCompactRows() async throws {
        enableAccessibilityTree()
        let rig = try await rig()
        defer { rig.model.stop(); try? FileManager.default.removeItem(at: rig.root) }
        let selected = try #require(rig.model.list(for: .activity).rows.first { $0.id == rig.parent })
        #expect(selected.isSelected && selected.live?.subagents.count == 2)
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            for width in [280, 300] {
                let hosting = NSHostingController(rootView: SidebarView(model: rig.model))
                hosting.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: CGFloat(width), height: 800), styleMask: [.borderless],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.appearance = NSAppearance(named: appearance)
                window.contentViewController = hosting
                window.setContentSize(NSSize(width: CGFloat(width), height: 800))
                try await settle(window)
                #expect(!window.isVisible && !window.isKeyWindow)
                let card = try #require(element("Parent session,", role: .button, in: hosting.view))
                let review = try #require(element("Review access,", role: .button, in: hosting.view))
                let first = try #require(element("Subagent explorer,", role: .button, in: hosting.view))
                let second = try #require(element("Subagent implementer,", role: .button, in: hosting.view))
                let day = try #require(element("Today", role: NSAccessibility.Role(rawValue: "AXHeading"), in: hosting.view))
                let idle = try #require(element("First idle,", role: .button, in: hosting.view))
                let nextIdle = try #require(element("Second idle,", role: .button, in: hosting.view))
                let search = try #require(element("Search, opens the command palette", role: .button, in: hosting.view))
                let home = try #require(element("Home", role: .button, in: hosting.view))
                let cardFrame = InkAX.frame(card), reviewFrame = InkAX.frame(review)
                let firstFrame = InkAX.frame(first), secondFrame = InkAX.frame(second), dayFrame = InkAX.frame(day)
                #expect(abs(reviewFrame.height - 74) < 1, "the activity reason and harness share the 16 pt bottom line: \(reviewFrame)")
                #expect(InkAX.label(review).contains("topic/sidebar"), "the replaced branch remains in the card's accessible metadata")
                #expect(InkAX.label(review).contains("pinned") && InkAX.label(review).contains("opened by Parent session"),
                        "a compact reason does not erase the pin or session origin")
                let idleFrames = [InkAX.frame(idle), InkAX.frame(nextIdle)].sorted { $0.midY > $1.midY }
                let lastActive = try #require(rig.model.activityLayout().active.last?.id)
                let precedingBottom = lastActive == rig.parent ? secondFrame.minY - 10 : reviewFrame.minY
                #expect(abs(precedingBottom - idleFrames[0].maxY - 24) < 1,
                        "23 pt day line and the preceding 1 pt card gap: \(precedingBottom), \(idleFrames[0]), \(dayFrame)")
                #expect(abs(dayFrame.midY - idleFrames[0].maxY - 11.5) < 1,
                        "the real day line's center is half of 23 pt above its next card: \(dayFrame), \(idleFrames[0])")
                #expect(abs(idleFrames[0].minY - idleFrames[1].maxY - 1) < 0.5,
                        "adjacent cards have a 1 pt gap: \(idleFrames)")
                #expect(abs(firstFrame.height - 24) < 1 && abs(secondFrame.height - 24) < 1)
                #expect(firstFrame.minX >= cardFrame.minX && firstFrame.maxX <= cardFrame.maxX
                        && secondFrame.minX >= cardFrame.minX && secondFrame.maxX <= cardFrame.maxX,
                        "both child hit frames remain inside their card: \(cardFrame), \(firstFrame), \(secondFrame)")
                #expect(abs(cardFrame.minY - firstFrame.maxY - 3) < 0.5,
                        "the first child begins 3 pt below the card's content: \(cardFrame), \(firstFrame)")
                #expect(abs(firstFrame.minY - secondFrame.maxY) < 0.5,
                        "the 24 pt child rows are consecutive: \(firstFrame), \(secondFrame)")
                #expect(!cardFrame.intersects(firstFrame) && !firstFrame.intersects(secondFrame))
                #expect(!reviewFrame.intersects(cardFrame) && !reviewFrame.intersects(firstFrame)
                        && !reviewFrame.intersects(secondFrame) && !dayFrame.intersects(InkAX.frame(idle)))

                let image = try #require(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
                hosting.view.cacheDisplay(in: hosting.view.bounds, to: image)
                func pixel(at point: NSPoint) throws -> NSColor {
                    let local = hosting.view.convert(window.convertFromScreen(NSRect(origin: point, size: .zero)), from: nil)
                    let px = Int(local.minX * CGFloat(image.pixelsWide) / hosting.view.bounds.width)
                    let fy = hosting.view.isFlipped ? local.minY : hosting.view.bounds.height - local.minY
                    let py = Int(fy * CGFloat(image.pixelsHigh) / hosting.view.bounds.height)
                    return try #require(image.colorAt(x: px, y: py)?.usingColorSpace(.sRGB), "sample in \(hosting.view.bounds): \(local)")
                }
                func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
                    max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                        abs(a.blueComponent - b.blueComponent), abs(a.alphaComponent - b.alphaComponent))
                }
                func glyphBounds(_ frame: NSRect, start: CGFloat, backgroundX: CGFloat) throws -> NSRect {
                    let background = try pixel(at: NSPoint(x: backgroundX, y: frame.midY))
                    var points: [NSPoint] = []
                    for dx in -1...16 {
                        for dy in -9...9 {
                            let point = NSPoint(x: start + CGFloat(dx), y: frame.midY + CGFloat(dy))
                            if try difference(pixel(at: point), background) > 0.08 { points.append(point) }
                        }
                    }
                    let xs = points.map(\.x), ys = points.map(\.y)
                    return NSRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                                  width: (xs.max() ?? 0) - (xs.min() ?? 0) + 1,
                                  height: (ys.max() ?? 0) - (ys.min() ?? 0) + 1)
                }
                let searchFrame = InkAX.frame(search), homeFrame = InkAX.frame(home)
                let searchGlyph = try glyphBounds(searchFrame, start: searchFrame.minX + 10, backgroundX: searchFrame.minX + 6)
                let homeGlyph = try glyphBounds(homeFrame, start: homeFrame.minX + 8, backgroundX: homeFrame.minX + 4)
                // Reference paths are inset within the 15 pt box: the search spans 1.7...14.7 units including stroke,
                // and the home spans 1.9...14.1. Allow a pixel for antialiasing in each rendered bound.
                #expect((11...13).contains(searchGlyph.width) && (12...14).contains(searchGlyph.height)
                        && abs(searchGlyph.minX - searchFrame.minX - 12) <= 1,
                        "Search's reference path stays inside its 15 pt box: \(searchFrame), \(searchGlyph)")
                #expect((11...13).contains(homeGlyph.width) && (11...13).contains(homeGlyph.height)
                        && abs(homeGlyph.minX - homeFrame.minX - 10) <= 1,
                        "Home's reference path stays aligned in its 16 pt column: \(homeFrame), \(homeGlyph)")
                let fill = try pixel(at: NSPoint(x: cardFrame.minX + 8, y: cardFrame.midY))
                let childFill = try pixel(at: NSPoint(x: cardFrame.minX + 8, y: firstFrame.midY))
                let lastFill = try pixel(at: NSPoint(x: cardFrame.minX + 8, y: secondFrame.midY))
                #expect(difference(fill, childFill) < 0.006 && difference(fill, lastFill) < 0.006,
                        "the selected surface continues behind both child rows: \(fill), \(childFill), \(lastFill)")
                let gapY = (cardFrame.minY + firstFrame.maxY) / 2
                let branch = try pixel(at: NSPoint(x: cardFrame.minX + 19, y: gapY))
                let besideBranch = try pixel(at: NSPoint(x: cardFrame.minX + 25, y: gapY))
                #expect(difference(branch, besideBranch) > 0.015,
                        "the real branch connects the card to its first child across the gap")
                let lineX = cardFrame.maxX - 20
                let background = try pixel(at: NSPoint(x: lineX, y: dayFrame.midY + 5))
                let lineOffsets: [CGFloat] = [-1, 0, 1]
                let lineContrast = try lineOffsets.map {
                    difference(try pixel(at: NSPoint(x: lineX, y: dayFrame.midY + $0)), background)
                }.max() ?? 0
                #expect(lineContrast > 0.015, "the real day heading draws its trailing hairline")
            }
        }

        // Activate each actual row: child buttons open their own transcript, and the parent returns to the session.
        let hosting = NSHostingController(rootView: SidebarView(model: rig.model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 300, height: 800))
        defer { window.close() }
        try await settle(window)
        let first = try #require(element("Subagent explorer,", role: .button, in: hosting.view))
        let second = try #require(element("Subagent implementer,", role: .button, in: hosting.view))
        let card = try #require(element("Parent session,", role: .button, in: hosting.view))
        let matches = accessibilityElements(in: hosting.view).filter { InkAX.label($0).hasPrefix("Subagent explorer,") }
        #expect(matches.count == 1)
        let firstPress = first.accessibilityPerformPress?()
        #expect(firstPress == true)
        #expect(rig.model.viewedSubagent?.agentID == "alpha")
        let secondPress = second.accessibilityPerformPress?()
        #expect(secondPress == true)
        #expect(rig.model.viewedSubagent?.agentID == "beta")
        #expect(card.accessibilityPerformPress?() == true && rig.model.viewedSubagent == nil && rig.model.selectedSessionID == rig.parent)
    }
}
