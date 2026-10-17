import AppKit
import SwiftUI

/// What the stream remembers about where the reader was (CHAT-SPEC → Scrolling → Memory).
struct ChatScrollMemory: Equatable {
    var anchorRowID: String?
    var offset: CGFloat = 0
    var atEnd = true
}

/// The stream: a view-based `NSTableView` of rows in Loom's own `NSScrollView`. It owns the follow latch (measured from
/// the true content bottom), the row heights (cached by id and width; unmeasured rows use an estimate until they are drawn),
/// the anchor that holds the reader's place when rows appear above, and "Jump to latest". Rows arrive as a list
/// (`apply`); only the rows that changed are inserted, removed or reconfigured.
@MainActor
final class ChatStreamController: NSObject {
    let scrollView = ChatScrollView()
    let table = ChatTableView()
    let context: ChatRowContext

    // MARK: Callbacks (set by the owner)

    var onNeedOlder: (() -> Void)?
    var onCycleView: (() -> Void)?
    /// Following changed, or "Jump to latest" should show or hide.
    var onLatchChange: ((_ following: Bool, _ showsJump: Bool) -> Void)?

    // MARK: State

    private(set) var rows: [ChatRow] = []
    private var rowIndex: [String: Int] = [:]
    private(set) var heights = ChatHeightCache()
    private(set) var latch = ChatScrollLatch()
    private var measurer: ChatRowMeasurer
    private(set) var fresh: Set<String> = []
    static let freshLimit = 128
    private var hasOlder = false
    private var olderRequested = false
    private var positioned = false
    private var pendingInitial: ChatScrollMemory?
    private var lastWidth: CGFloat = 0
    private var lastOffset: CGFloat = 0
    /// Counts nested programmatic scrolls: the latch ignores bounds changes while it is above zero.
    private var programmatic = 0
    private var wheelUntil: TimeInterval = 0
    private var scrollerDragging = false
    private var keyScrolling = false
    private var scrollToken = 0
    private var heightFlushScheduled = false
    private var pendingHeightRows = Set<String>()
    private var jumpTask: Task<Void, Never>?
    private var jumpShown = false
    /// The row of a message that just went out: the view holds it near the top until the turn's first activity.
    private var holdRowID: String?
    private var observers: [NSObjectProtocol] = []

    var topInset: CGFloat { LoomTheme.Chat.streamTopInset }
    var bottomInset: CGFloat { scrollView.contentInsets.bottom }
    private var clip: NSClipView { scrollView.contentView }

    init(context: ChatRowContext, bottomInset: CGFloat = LoomTheme.Chat.streamBottomInset) {
        ChatRenderProbe.controllerCreated()
        self.context = context
        measurer = ChatRowMeasurer(context: context)
        super.init()

        scrollView.controller = self
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        let scroller = ChatScroller()
        scroller.controller = self
        scrollView.verticalScroller = scroller

        table.controller = self
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = false
        table.allowsColumnSelection = false
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 100
        column.width = 700
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Session transcript")
        scrollView.documentView = table

        clip.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipBoundsChanged() }
        })
        observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewResized() }
        })
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        jumpTask?.cancel()
    }

    // MARK: Geometry

    private var width: CGFloat {
        let measured = scrollView.contentSize.width
        return measured > 1 ? measured : (lastWidth > 1 ? lastWidth : LoomTheme.Chat.column)
    }

    private var viewportHeight: CGFloat { clip.bounds.height }
    private var minOffset: CGFloat { -scrollView.contentInsets.top }
    private var maxOffset: CGFloat { max(minOffset, table.frame.height + bottomInset - viewportHeight) }
    private var overflows: Bool { table.frame.height + topInset + bottomInset > viewportHeight + 0.5 }

    /// The distance from the true content bottom, with the composer inset taken off.
    var distanceFromBottom: CGFloat {
        ChatScrollLatch.distanceFromBottom(contentHeight: table.frame.height, visibleMaxY: clip.bounds.maxY, bottomInset: bottomInset)
    }

    var isFollowing: Bool { latch.isFollowing }

    /// The inset under the stream (the composer's height, later). Keeps the end where it was.
    func setBottomInset(_ inset: CGFloat) {
        guard abs(inset - bottomInset) > 0.5 else { return }
        let following = latch.isFollowing
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: inset, right: 0)
        if following { scrollToEnd() }
    }

    // MARK: Applying rows

    /// Replaces the rows. Only the rows that differ are inserted, removed or reconfigured; the reader's place is held.
    /// - Parameters:
    ///   - fresh: ids of rows that appear because the file grew; they fade in (unless Reduce Motion is on).
    ///   - hasOlder: older turns can still be loaded when the top comes within a screen.
    ///   - initial: where to open (the remembered place); nil opens at the end.
    func apply(_ newRows: [ChatRow], fresh: Set<String> = [], hasOlder: Bool, initial: ChatScrollMemory? = nil) {
        self.hasOlder = hasOlder
        self.fresh.formUnion(fresh)
        let old = rows
        let anchor = (!old.isEmpty && positioned && !latch.isFollowing) ? captureAnchor() : nil
        let wasFollowing = latch.isFollowing

        let plan = Self.plan(from: old, to: newRows)
        rows = newRows
        rowIndex = Dictionary(newRows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Rows that fade in are marked fresh until drawn; a mark for a row that is gone, or too many of them, are dropped.
        if !self.fresh.isEmpty {
            self.fresh = self.fresh.filter { rowIndex[$0] != nil }
            if self.fresh.count > Self.freshLimit { self.fresh.removeAll() }
        }
        for index in plan.updated { heights.invalidate(newRows[index].id) }
        if heights.count > newRows.count * 2 + 64 { heights.removeAll(except: Set(rowIndex.keys)) }

        if old.isEmpty || plan.reloadAll {
            table.reloadData()
        } else if !plan.removed.isEmpty || !plan.inserted.isEmpty || !plan.updated.isEmpty {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0
                animation.allowsImplicitAnimation = false
                table.beginUpdates()
                table.removeRows(at: plan.removed, withAnimation: [])
                table.insertRows(at: plan.inserted, withAnimation: [])
                table.endUpdates()
                if !plan.updated.isEmpty {
                    table.reloadData(forRowIndexes: plan.updated, columnIndexes: IndexSet(integer: 0))
                    table.noteHeightOfRows(withIndexesChanged: plan.updated)
                }
            }
        }

        if !positioned {
            if pendingInitial == nil { pendingInitial = initial ?? ChatScrollMemory() }
            positionInitially()
        } else {
            reposition(anchor: anchor, wasFollowing: wasFollowing, inserted: plan.inserted)
        }
        syncClock()
        refreshVisibleHeights()
        checkOlder()
    }

    struct Plan {
        var removed = IndexSet()
        var inserted = IndexSet()
        var updated = IndexSet()
        var reloadAll = false
    }

    /// The structural difference by id (after trimming the common ends) and the rows that stayed but changed.
    static func plan(from old: [ChatRow], to new: [ChatRow]) -> Plan {
        var plan = Plan()
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].id == new[prefix].id { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix, old[old.count - 1 - suffix].id == new[new.count - 1 - suffix].id {
            suffix += 1
        }
        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        if oldMiddle.count * newMiddle.count > 30_000_000 {
            plan.reloadAll = true
            return plan
        }
        if !oldMiddle.isEmpty || !newMiddle.isEmpty {
            for change in newMiddle.difference(from: oldMiddle, by: { $0.id == $1.id }) {
                switch change {
                case let .remove(offset, _, _): plan.removed.insert(prefix + offset)
                case let .insert(offset, _, _): plan.inserted.insert(prefix + offset)
                }
            }
        }
        // Rows that stayed: same id, different content.
        var oldByID: [String: ChatRow] = [:]
        oldByID.reserveCapacity(old.count)
        for row in old { oldByID[row.id] = row }
        for (index, row) in new.enumerated() where !plan.inserted.contains(index) {
            if let before = oldByID[row.id], before != row { plan.updated.insert(index) }
        }
        return plan
    }

    // MARK: Positioning

    private func positionInitially() {
        guard scrollView.contentSize.width > 1, viewportHeight > 1 else { return } // laid out later (`viewResized`)
        let memory = pendingInitial ?? ChatScrollMemory()
        pendingInitial = nil
        positioned = true
        lastWidth = width
        premeasureEnd()
        if !memory.atEnd, let id = memory.anchorRowID, let index = rowIndex[id] {
            latch.leaveFollowing()
            setOffset(table.rect(ofRow: index).minY - memory.offset)
            lastOffset = clip.bounds.origin.y
        } else {
            latch.followAgain()
            scrollToEnd()
        }
        publishLatch()
    }

    /// Measures the rows nearest the end before the first draw, so the opening position does not jump.
    private func premeasureEnd() {
        var total: CGFloat = 0
        var changed = IndexSet()
        for index in rows.indices.reversed() {
            let row = rows[index]
            if heights.measured(row.id, width: width) == nil {
                let height = measurer.height(of: row, width: width)
                heights.store(row.id, width: width, height: height)
                changed.insert(index)
            }
            total += heights.known(row.id) ?? 0
            if total > viewportHeight * 2 || changed.count >= 60 { break }
        }
        if !changed.isEmpty {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
        }
    }

    private func reposition(anchor: Anchor?, wasFollowing: Bool, inserted: IndexSet) {
        // A message that just appeared at the end while following goes near the top, once, animated.
        if wasFollowing, let index = inserted.last(where: { if case .user = rows[$0].kind { true } else { false } }),
           index >= rows.count - 3, fresh.contains(rows[index].id) {
            holdRowID = rows[index].id
            scrollRowNearTop(index)
            return
        }
        if let hold = holdRowID {
            guard let holdIndex = rowIndex[hold] else {
                holdRowID = nil
                return reposition(anchor: anchor, wasFollowing: wasFollowing, inserted: inserted)
            }
            // Following resumes with the turn's first activity.
            guard inserted.contains(where: { $0 > holdIndex && Self.isActivity(rows[$0]) }) else { return }
            holdRowID = nil
            latch.followAgain()
        }
        if latch.isFollowing {
            scrollToEnd()
            scheduleScrollToEnd()
        } else if let anchor {
            restore(anchor)
        }
    }

    /// Tool or answer activity of a turn: what ends the hold on a message that just went out.
    static func isActivity(_ row: ChatRow) -> Bool {
        switch row.kind {
        case .tool, .group, .subagent, .prose, .plan, .turnFold: true
        default: false
        }
    }

    // MARK: Scrolling

    func scrollToEnd() {
        setOffset(maxOffset)
    }

    /// Scrolls to the end again on the next turn of the run loop, unless the reader left Following by then.
    private func scheduleScrollToEnd() {
        scrollToken += 1
        let mine = scrollToken
        DispatchQueue.main.async { [weak self] in
            guard let self, mine == scrollToken, latch.isFollowing, holdRowID == nil else { return }
            scrollToEnd()
        }
    }

    /// Anything queued is dropped: the reader took over.
    private func cancelQueuedScroll() { scrollToken += 1 }

    private func setOffset(_ y: CGFloat) {
        let target = min(max(y, minOffset), maxOffset)
        programmatic += 1
        defer { programmatic -= 1 }
        if abs(clip.bounds.origin.y - target) > 0.01 {
            clip.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(clip)
        }
        lastOffset = clip.bounds.origin.y
    }

    private func scrollRowNearTop(_ index: Int) {
        let target = min(max(table.rect(ofRow: index).minY - LoomTheme.Chat.sendAnchorOffset, minOffset), maxOffset)
        programmatic += 1
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setOffset(target)
            programmatic -= 1
            return
        }
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0.25
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.programmatic -= 1
                self.scrollView.reflectScrolledClipView(self.clip)
                self.lastOffset = self.clip.bounds.origin.y
            }
        }
    }

    // MARK: Anchor

    struct Anchor {
        var rowID: String
        var offset: CGFloat
    }

    /// The row at the top of the view and how far its top is below the view's top.
    func captureAnchor() -> Anchor? {
        guard !rows.isEmpty, viewportHeight > 1 else { return nil }
        let top = clip.bounds.origin.y
        let index = max(0, min(table.row(at: NSPoint(x: 1, y: max(top, 0))), rows.count - 1))
        guard index >= 0 else { return nil }
        return Anchor(rowID: rows[index].id, offset: table.rect(ofRow: index).minY - top)
    }

    func restore(_ anchor: Anchor) {
        guard let index = rowIndex[anchor.rowID] else { return }
        setOffset(table.rect(ofRow: index).minY - anchor.offset)
    }

    /// Where the reader is, for the session's memory.
    var memory: ChatScrollMemory {
        guard positioned, let anchor = captureAnchor() else { return ChatScrollMemory() }
        return ChatScrollMemory(anchorRowID: anchor.rowID, offset: anchor.offset, atEnd: latch.isFollowing)
    }

    // MARK: Heights

    /// Measures the visible rows that are not measured at this width and lets the table know about the ones that changed.
    func refreshVisibleHeights() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        var changed = IndexSet()
        for index in visible.location..<(visible.location + visible.length) where index < rows.count {
            let row = rows[index]
            var height = heights.measured(row.id, width: width)
            if height == nil {
                let measured = measurer.height(of: row, width: width)
                heights.store(row.id, width: width, height: measured)
                height = measured
            }
            if let height, abs(table.rect(ofRow: index).height - height) > 0.5 { changed.insert(index) }
        }
        if !changed.isEmpty { applyHeightChanges(changed) }
    }

    private func applyHeightChanges(_ indexes: IndexSet) {
        let anchor = latch.isFollowing ? nil : captureAnchor()
        let following = latch.isFollowing && holdRowID == nil
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0
            animation.allowsImplicitAnimation = false
            table.noteHeightOfRows(withIndexesChanged: indexes)
        }
        if following {
            scrollToEnd()
        } else if let anchor {
            restore(anchor)
        }
    }

    /// A cell was drawn at a height other than the one the table uses: remeasure after the layout pass is done.
    fileprivate func scheduleHeightFlush(for id: String) {
        pendingHeightRows.insert(id)
        guard !heightFlushScheduled else { return }
        heightFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            heightFlushScheduled = false
            let ids = pendingHeightRows
            pendingHeightRows = []
            var changed = IndexSet()
            for id in ids {
                guard let index = rowIndex[id] else { continue }
                if abs(table.rect(ofRow: index).height - (heights.known(id) ?? 0)) > 0.5 { changed.insert(index) }
            }
            if !changed.isEmpty { applyHeightChanges(changed) }
        }
    }

    // MARK: Events

    private var userInteracting: Bool { scrollerDragging || keyScrolling || ProcessInfo.processInfo.systemUptime < wheelUntil }

    func noteWheel(_ event: NSEvent) {
        wheelUntil = ProcessInfo.processInfo.systemUptime + 0.3
    }

    func scrollerDragBegan() {
        scrollerDragging = true
        if latch.scrollerDragged(overflows: overflows) {
            cancelQueuedScroll()
            holdRowID = nil
        }
        publishLatch()
    }

    func scrollerDragEnded() {
        scrollerDragging = false
        evaluateUserMove(direction: .down)
    }

    func handleKey(_ key: ChatScrollLatch.Key) {
        if latch.key(key, overflows: overflows) {
            cancelQueuedScroll()
            holdRowID = nil
        }
        let current = clip.bounds.origin.y
        let page = max(viewportHeight - 40, 80)
        let target: CGFloat
        let direction: ChatScrollLatch.Direction
        switch key {
        case .up: target = current - LoomTheme.Chat.lineStep; direction = .up
        case .pageUp: target = current - page; direction = .up
        case .home: target = minOffset; direction = .up
        case .down: target = current + LoomTheme.Chat.lineStep; direction = .down
        case .pageDown: target = current + page; direction = .down
        case .end: target = maxOffset; direction = .down
        }
        keyScrolling = true
        defer { keyScrolling = false }
        // The move is the reader's own, so the latch sees it (a programmatic move is ignored).
        let clamped = min(max(target, minOffset), maxOffset)
        if abs(clamped - current) > 0.01 {
            clip.scroll(to: NSPoint(x: 0, y: clamped))
            scrollView.reflectScrolledClipView(clip)
        }
        lastOffset = clip.bounds.origin.y
        evaluateUserMove(direction: direction, moved: abs(clamped - current) > 0.01)
        checkOlder()
    }

    private func clipBoundsChanged() {
        let y = clip.bounds.origin.y
        defer { lastOffset = y }
        guard programmatic == 0 else { return }
        guard userInteracting, abs(y - lastOffset) > 0.01 else { return }
        evaluateUserMove(direction: y < lastOffset ? .up : .down)
        checkOlder()
    }

    private func evaluateUserMove(direction: ChatScrollLatch.Direction, moved: Bool = true) {
        guard moved else { return }
        if latch.userScrolled(direction, distanceFromBottom: distanceFromBottom, overflows: overflows) {
            cancelQueuedScroll()
            if !latch.isFollowing { holdRowID = nil }
        }
        if latch.isFollowing { holdRowID = nil }
        publishLatch()
    }

    private func viewResized() {
        let newWidth = scrollView.contentSize.width
        guard newWidth > 1 else { return }
        if !positioned {
            if pendingInitial != nil || !rows.isEmpty { positionInitially() }
            return
        }
        guard abs(newWidth - lastWidth) > 0.5 else {
            if latch.isFollowing { scrollToEnd() }
            return
        }
        lastWidth = newWidth
        // Heights depend on the width: unmeasured rows keep their last height until drawn.
        let anchor = latch.isFollowing ? nil : captureAnchor()
        for row in rows { heights.invalidate(row.id) }
        NSAnimationContext.runAnimationGroup { animation in
            animation.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        }
        if latch.isFollowing { scrollToEnd() } else if let anchor { restore(anchor) }
        refreshVisibleHeights()
        publishLatch()
    }

    // MARK: Older turns

    private func checkOlder() {
        guard positioned, hasOlder, !olderRequested else { return }
        let top = clip.bounds.origin.y
        if top < viewportHeight * LoomTheme.Chat.olderTriggerViewports {
            olderRequested = true
            onNeedOlder?()
        }
    }

    /// The owner finished loading older turns (or found none).
    func olderLoadFinished() {
        olderRequested = false
        DispatchQueue.main.async { [weak self] in self?.checkOlder() }
    }

    // MARK: Jump to latest

    /// "Jump to latest": back to the end, and Following again.
    func jumpToLatest() {
        latch.followAgain()
        holdRowID = nil
        scrollToEnd()
        publishLatch()
    }

    private func publishLatch() {
        if latch.showsJump(distanceFromBottom: distanceFromBottom) {
            // "Jump to latest" appears 150 ms after the reader leaves the end.
            if !jumpShown, jumpTask == nil {
                jumpTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(LoomTheme.Chat.jumpDelay))
                    guard let self, !Task.isCancelled else { return }
                    jumpTask = nil
                    if latch.showsJump(distanceFromBottom: distanceFromBottom) {
                        jumpShown = true
                        onLatchChange?(latch.isFollowing, true)
                    }
                }
            }
        } else {
            // It hides at once when the reader is back.
            jumpTask?.cancel()
            jumpTask = nil
            jumpShown = false
        }
        onLatchChange?(latch.isFollowing, jumpShown)
    }

    // MARK: Animation and clock

    /// Rows that animate (the live row's chase, a running tool) redraw when the stream starts or stops being visible.
    func setAnimates(_ value: Bool) {
        guard context.animates != value else { return }
        context.animates = value
        let visible = table.rows(in: table.visibleRect)
        var indexes = IndexSet()
        for index in visible.location..<(visible.location + visible.length) where index < rows.count && Self.animatesWhileVisible(rows[index]) {
            indexes.insert(index)
        }
        if !indexes.isEmpty { table.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: 0)) }
        syncClock()
    }

    static func animatesWhileVisible(_ row: ChatRow) -> Bool {
        switch row.kind {
        case .live: true
        case let .tool(entry): if case let .tool(call) = entry.body { call.status == .running } else { false }
        case let .subagent(entry): if case let .subagent(run) = entry.body { run.status == .running } else { false }
        case let .group(group): group.status == .running
        default: false
        }
    }

    /// The one-second clock runs only while a live row or a running subagent is on a stream that can be seen.
    func syncClock() {
        let needs = context.animates && rows.contains {
            if case .live = $0.kind { return true }
            if case let .subagent(entry) = $0.kind, case let .subagent(run) = entry.body { return run.status == .running }
            return false
        }
        context.clock.setActive(needs)
    }

    /// Stops the timers for good (the view is going away).
    func stop() {
        jumpTask?.cancel()
        jumpTask = nil
        context.clock.setActive(false)
    }
}

// MARK: Table

extension ChatStreamController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 1 }
        let item = rows[row]
        return heights.measured(item.id, width: width) ?? heights.known(item.id) ?? ChatRowEstimate.height(item, width: width)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let cell = (tableView.makeView(withIdentifier: ChatRowCell.identifier, owner: nil) as? ChatRowCell) ?? ChatRowCell(context: context)
        cell.configure(item, context: context, fadeIn: fresh.remove(item.id) != nil)
        if heights.measured(item.id, width: width) == nil {
            let height = measurer.height(of: item, width: width)
            heights.store(item.id, width: width, height: height)
            if abs(height - tableView.rect(ofRow: row).height) > 0.5 { scheduleHeightFlush(for: item.id) }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}
