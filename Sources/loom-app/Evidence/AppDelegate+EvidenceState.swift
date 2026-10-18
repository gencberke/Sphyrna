#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore
import LoomTerminal

/// Development flavor only: the state snapshot and window probes behind the evidence commands.
extension AppDelegate {
    // MARK: Development evidence

    /// Real providers (no `--fake-providers`): evidence carries no terminal
    /// text, titles or request text; only expected tokens' presence
    /// (`--evidence-tokens A,B`). Fixture runs keep the raw screen.
    var redactsContent: Bool { value(after: "--fake-providers") == nil }
    var evidenceTokens: [String] {
        value(after: "--evidence-tokens")?.split(separator: ",").map(String.init) ?? []
    }

    var evidenceState: [String: Any] {
        var state: [String: Any] = [
            "pid": Int(getpid()),
            "uptime": ProcessInfo.processInfo.systemUptime,
            "windowVisible": window?.isVisible ?? false,
            "windowOcclusionVisible": window?.occlusionState.contains(.visible) ?? false,
            "windowCount": NSApp.windows.filter { $0.identifier?.rawValue == "loom-main" }.count,
            "visibilityEvents": visibilityEvents,
            "ownershipNoticeShown": model?.ownershipNotice != nil && window?.isVisible == true,
            "terminalState": controller.map { String(describing: $0.state) } ?? NSNull(),
            "quitState": shutdownCoordinator.map { String(describing: $0.state) } ?? NSNull(),
            "quitAlert": quitAlert.map { [
                "message": $0.messageText, "attachedAsSheet": window?.attachedSheet === $0.window,
                "buttons": $0.buttons.map(\.title),
            ] as [String: Any] } ?? NSNull(),
            "renderer": evidenceMode && arguments.contains("--metal") ? "metal" : "coregraphics",
            // The setting on its own (Settings → General → Sidebar), the system's Reduce Transparency on its own,
            // and what the sidebar draws: opaque in Solid or under Reduce Transparency, else glass (D-57).
            "sidebarStyle": model?.sidebarStyle.rawValue ?? "unknown",
            "systemReduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "sidebarMaterial": model.map {
                $0.sidebarStyle == .solid || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                    ? "opaque" : "glass"
            } ?? "unknown",
            // Settings → Theme (D-63): the settings, what the main window resolves them to, and the terminal's background.
            "appearance": model?.appearance.rawValue ?? "unknown",
            "effectiveAppearance": window.map {
                $0.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
            } ?? "unknown",
            "paneTone": model?.paneTone.rawValue ?? "unknown",
            "terminalBackground": {
                let rgb = TerminalTheme.backgroundRGB
                return String(format: "#%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
            }(),
            "chaseIndicators": window?.contentView.map { IndicatorEvidence.chases(in: $0) } ?? [:],
            "systemReduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            "runDirectory": runDirectory?.path ?? NSNull(),
        ]
        if let model {
            let statistics = model.statistics
            state["catalog"] = [
                "ready": model.isReady, "startupError": model.startupError ?? NSNull(),
                "viewMode": model.viewMode.rawValue, "search": model.searchText,
                "selectedSessionID": model.selectedSessionID?.uuidString ?? NSNull(),
                "selectedTitle": redactsContent ? NSNull() : (model.selectedRow.map { model.title(of: $0) } ?? NSNull()),
                "projects": model.projects.map {
                    ["id": $0.id.uuidString, "name": $0.name, "collapsed": $0.collapsed,
                     "count": model.sessionCounts[$0.id] ?? 0] as [String: Any]
                },
                "unassignedCount": model.sessionCounts[nil] ?? 0,
                "activityRows": model.list(for: .activity).rows.count,
                "activityFirstTitles": redactsContent ? [] : model.list(for: .activity).rows.prefix(3).map { model.title(of: $0) },
                "activityHasMore": model.list(for: .activity).hasMore,
                "projectRows": model.projects.map { model.list(for: .project($0.id)).rows.count },
                "errorMessage": model.errorMessage ?? NSNull(), "infoMessage": model.infoMessage ?? NSNull(),
                "windowIsActive": model.windowIsActive, "windowIsVisible": model.windowIsVisible,
                "modelNow": model.now.timeIntervalSince1970, "sidebarCollapsed": model.sidebarCollapsed,
                "sidebarItemCollapsed": splitController?.sidebarIsCollapsed ?? NSNull(),
                "actionsAvailable": model.actionsAvailable, "quitting": model.quitting,
                "awaitingOpenApproval": model.awaitingOpenApproval.map(\.uuidString).sorted(),
                "activeSessionIDs": model.activeIDs.map(\.uuidString).sorted(),
                "busy": model.busy.map { ["id": $0.key.uuidString, "state": String(describing: $0.value)] },
                "startingKeys": model.startingKeys.map { "\($0.provider.rawValue):\($0.projectID?.uuidString ?? "none")" },
                "preparingNotice": model.preparingNotice ?? NSNull(),
                "selectedIndicator": model.selectedRow?.indicator.label ?? NSNull(),
                "selectedProvider": model.selectedRow?.record.session.provider.rawValue ?? NSNull(),
                "selectedProjectID": model.selectedRow?.record.projectID?.uuidString ?? NSNull(),
                "selectedLifecycle": model.selectedRow?.record.lifecycle.rawValue ?? NSNull(),
                "selectedRunID": model.selectedRow?.live?.runID?.uuidString ?? NSNull(),
                "selectedIssue": model.selectedRow?.live?.issue ?? NSNull(),
                "selectedStopFailure": model.selectedRow?.live?.stopFailure ?? NSNull(),
                "selectedRequests": (model.selectedRow?.live?.userRequests ?? []).map {
                    ["id": $0.id, "summary": redactsContent ? "" : $0.summary, "answerable": $0.isAnswerable,
                     "failure": $0.failure ?? ""] as [String: Any]
                },
                "selectedHasTerminalView": model.selectedSessionID.flatMap { model.terminalView(for: $0) } != nil,
                "activityRowDetails": model.list(for: .activity).rows.prefix(12).map { row in
                    ["id": row.id.uuidString, "provider": row.record.session.provider.rawValue,
                     "title": redactsContent ? "" : model.title(of: row), "indicator": row.indicator.label ?? "",
                     "live": row.live?.runID != nil, "lifecycle": row.record.lifecycle.rawValue,
                     "conversationID": row.record.session.providerConversationID ?? "",
                     "lastUsed": row.record.lastUsedAt.timeIntervalSince1970,
                     "lastActivity": row.record.lastActivityAt.timeIntervalSince1970,
                     "issue": row.live?.issue ?? "",
                     // Whether a reason line exists, never its text: it is built from commands, paths and replies.
                     "hasReason": row.reason != nil,
                     "openedBy": row.record.openedBy?.uuidString ?? "",
                     "origin": redactsContent ? "" : (model.origin(of: row)?.cardLabel ?? ""),
                     "originReplacesBranch": model.origin(of: row)?.replacesBranch ?? false] as [String: Any]
                },
                "showsDevTerminal": model.showsDevTerminal,
                "route": model.detailRouteKind, "readOnlyChat": model.readOnlyChatEnabled,
                "faceChoices": model.faces.choices.map { "\($0.key.uuidString):\($0.value.rawValue)" }.sorted(),
                "searchesSessionText": model.searchesSessionText,
                "newSessionFace": model.newSessionFace.rawValue,
                "owningFaces": model.activityOwningFaces,
                "handovers": model.handovers.map { "\($0.key.uuidString):\($0.value.target.rawValue):\($0.value.phase)" }.sorted(),
                "renderProbe": RenderEvidence.counts,
                "selectedCanResume": model.selectedRow.map { model.canResume($0) } ?? NSNull(),
                "selectedResumeUnavailable": model.selectedRow.flatMap { model.resumeUnavailableReason($0) } ?? NSNull(),
                "selectedDeleteDisabledReason": model.selectedRow.flatMap { model.deletionDisabledReason(for: $0) } ?? NSNull(),
                "drafts": model.visibleDrafts.map { ["project": $0.projectID?.uuidString ?? "none", "chars": $0.trimmedText.count] as [String: Any] },
                "pageQueries": statistics.pageQueries, "framesApplied": statistics.framesApplied,
                "fastPathFrames": statistics.fastPathFrames, "fullReconciles": statistics.fullReconciles,
                "rowModels": statistics.rowModels, "loadedRows": statistics.loadedRows,
                "startMilliseconds": statistics.startMilliseconds,
                "preferences": [
                    "viewMode": model.preferencesSnapshot.viewMode.rawValue,
                    "selectedSessionID": model.preferencesSnapshot.selectedSessionID?.uuidString ?? NSNull(),
                    "sidebarWidth": model.preferencesSnapshot.sidebarWidth,
                    "sidebarCollapsed": model.preferencesSnapshot.sidebarCollapsed,
                    "openTabs": model.preferencesSnapshot.openTabs.map(\.uuidString),
                    "windowFrame": model.preferencesSnapshot.windowFrame.map {
                        [$0.x, $0.y, $0.width, $0.height] as [Double]
                    } ?? NSNull(),
                ] as [String: Any],
            ] as [String: Any]
        }
        state["settings"] = settingsEvidence
        state["tabs"] = tabsEvidence
        state["subagentPanel"] = subagentPanelEvidence
        state["deletions"] = deletionsEvidence
        state["openRequests"] = openRequestsEvidence
        state["usage"] = usageEvidence
        state["home"] = homeEvidence
        state.merge(systemEvidence) { _, new in new }
        if let window {
            state["windowFrame"] = [window.frame.origin.x, window.frame.origin.y, window.frame.width, window.frame.height]
            state["windowContentSize"] = [Double(window.contentLayoutRect.width), Double(window.contentLayoutRect.height)]
            state["sidebarWidth"] = splitController?.sidebarWidth ?? NSNull()
            state["attachedSheet"] = window.attachedSheet.map { String(describing: type(of: $0)) } ?? NSNull()
            state["appActive"] = NSApp.isActive
            state["windowIsKey"] = window.isKeyWindow
            state["windowFrameSize"] = [Double(window.frame.width), Double(window.frame.height)]
            state["openPanelVisible"] = NSApp.windows.contains { $0 is NSOpenPanel && $0.isVisible }
            state["renameDraftText"] = model?.renameDraft?.text ?? NSNull()
        }
        state["terminalSurfaceExists"] = controller?.surface != nil
        state["endedScreens"] = conversations?.endedScreenCount ?? 0
        state["attentionCount"] = model?.attentionCount ?? 0
        state["dockBadge"] = NSApp.dockTile.badgeLabel ?? NSNull()
        state["conversationTerminals"] = (conversations?.terminalEvidence(
            redacted: redactsContent, tokens: evidenceTokens
        ) ?? []).map {
            ["runID": $0.runID.uuidString, "owner": $0.owner.uuidString,
             "screenTail": $0.screenTail ?? NSNull(), "tokenPresence": $0.tokenPresence,
             "outputBytes": $0.outputBytes, "pendingInputBytes": $0.pendingInputBytes,
             "inputErrors": $0.inputErrors] as [String: Any]
        }
        if let surface = controller?.surface, let data = try? JSONEncoder().encode(surface.statistics),
           let object = try? JSONSerialization.jsonObject(with: data) {
            state["terminal"] = object
        }
        return state
    }

    func runtimeEvidence() async -> [String: Any] { await conversations?.runtimeEvidence() ?? [:] }
    func typeForEvidence(_ text: String, intoSession id: UUID) -> Bool {
        conversations?.typeForEvidence(text, intoSession: id) ?? false
    }
    func closeWindowForEvidence() {
        traceWindowCall("evidence-close-before")
        window?.performClose(nil)
        traceWindowCall("evidence-close-after")
    }
    /// The folder panel, whether attached as a sheet or standalone.
    var openPanelForEvidence: NSOpenPanel? {
        if let panel = window?.attachedSheet as? NSOpenPanel { return panel }
        return NSApp.windows.compactMap { $0 as? NSOpenPanel }.first { $0.isVisible }
    }
    func closeSheetForEvidence() {
        if let panel = openPanelForEvidence { panel.cancel(nil); return }
        guard let window, let sheet = window.attachedSheet else { return }
        window.endSheet(sheet, returnCode: .cancel)
    }
    /// Ends the real folder panel and hands the chosen folder to the same
    /// handler its completion uses. NSOpenPanel's `ok:` must not be called
    /// directly (AppKit raises), and no key events can be synthesized here, so
    /// the URL AppKit itself would return is not exercised.
    func chooseFolderInPanelForEvidence(_ path: String) {
        closeSheetForEvidence()
        model?.folderPanelFinished(accepted: true, url: URL(fileURLWithPath: path, isDirectory: true))
    }
    // The same path as the Hide and Show buttons.
    func toggleSidebarForEvidence() { model?.onToggleSidebar?() }
    func setSidebarWidthForEvidence(_ width: Double) { splitController?.setSidebarWidth(width) }
    func resizeForEvidence(width: Double, height: Double) {
        window?.setContentSize(NSSize(width: width, height: height))
    }

    /// Renders the window's content view (the app's own pixels, no screen
    /// recording permission needed).
    func saveScreenshot(to url: URL) {
        Self.writePNG(of: window?.contentView, to: url)
        // The window frame view also holds the titlebar and the traffic lights,
        // which the content view alone never shows.
        let framed = url.deletingPathExtension().appendingPathExtension("window.png")
        Self.writePNG(of: window?.contentView?.superview, to: framed)
        // A popover is a window of its own: it is written beside the window, as `….popover<N>.png` (V17's ring popover).
        for (index, child) in (window?.childWindows ?? []).enumerated() where child.isVisible {
            Self.writePNG(of: child.contentView?.superview,
                          to: url.deletingPathExtension().appendingPathExtension("popover\(index).png"))
        }
    }

    static func writePNG(of view: NSView?, to url: URL) {
        guard let view, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url, options: .atomic)
    }

    /// Evidence only: hands a file's bytes to the development terminal's engine
    /// as if the program had printed them (color and rendering samples).
    func feedForEvidence(path: String) {
        guard let surface = controller?.surface, let data = FileManager.default.contents(atPath: path) else { return }
        surface.outputSink.receive(data)
    }
    /// Evidence: where the window buttons are relative to their container and
    /// whether a real hit test at their center and near their bottom edge lands on them.
    func windowButtonsEvidence() -> [String: Any] {
        guard let window, let frameView = window.contentView?.superview else { return [:] }
        var result: [String: Any] = ["windowContent": "\(window.contentView?.bounds.size ?? .zero)",
                                     "fullScreen": window.styleMask.contains(.fullScreen)]
        for (name, kind) in [("close", NSWindow.ButtonType.closeButton), ("mini", .miniaturizeButton), ("zoom", .zoomButton)] {
            guard let button = window.standardWindowButton(kind), let container = button.superview else { continue }
            func hit(_ y: CGFloat) -> String {
                let point = frameView.convert(NSPoint(x: button.bounds.midX, y: y), from: button)
                let view = frameView.hitTest(point)
                return view === button ? "button" : "\(view.map { String(describing: type(of: $0)) } ?? "nil")"
            }
            let inside = container.bounds.contains(button.frame)
            result[name] = ["frame": "\(button.frame)", "container": "\(type(of: container))",
                            "containerBounds": "\(container.bounds)", "fullyInside": inside,
                            "hitCenter": button.isHidden ? "hidden" : hit(button.bounds.midY),
                            "hitNearBottom": button.isHidden ? "hidden" : hit(button.bounds.minY + 1),
                            "hitNearTop": button.isHidden ? "hidden" : hit(button.bounds.maxY - 1)]
        }
        result["controls"] = controlHitTests(frameView: frameView)
        return result
    }

    /// Hit-tests the center of every header control through the window's frame
    /// view, like a click would; each must land in the SwiftUI hosting view and
    /// not in the toolbar view that spans the titlebar. Centers come from the
    /// header layout (sidebar row 26 pt below the top; 26 pt wide controls, 4 pt
    /// apart, 10 pt padding; detail row padded 8 + 14), then a sweep along the
    /// header center line reports every x range that does not reach a hosting view.
    private func controlHitTests(frameView: NSView) -> [String: Any] {
        guard let window, let model else { return [:] }
        let width = window.frame.width
        let y = window.frame.height - 26
        func hit(_ x: CGFloat) -> (type: String, hosting: Bool, toolbar: Bool) {
            let point = frameView.convert(NSPoint(x: x, y: y), from: nil)
            let view = frameView.hitTest(point)
            var ancestor = view
            var hosting = false, toolbar = false
            while let current = ancestor {
                let name = String(describing: type(of: current))
                if name.contains("HostingView") { hosting = true }
                if name.contains("Toolbar") { toolbar = true }
                ancestor = current.superview
            }
            return (view.map { String(describing: type(of: $0)) } ?? "nil", hosting, toolbar)
        }
        var points: [(String, CGFloat)] = []
        let sidebarWidth = CGFloat(splitController?.sidebarWidth ?? 0)
        if !model.sidebarCollapsed {
            let leading: CGFloat = window.styleMask.contains(.fullScreen) ? 0 : 76
            points += [("sidebar toggle", 10 + leading + 13), ("sidebar ellipsis", sidebarWidth - 10 - 13),
                       ("sidebar activity mode", sidebarWidth - 10 - 26 - 4 - 13),
                       ("sidebar projects mode", sidebarWidth - 10 - 2 * (26 + 4) - 13)]
        } else {
            points.append(("detail toggle", 8 + 14 + 66 + 8 + 13))
        }
        points.append(("detail ellipsis", width - 8 - 14 - 13))
        let controls = points.map { name, x -> [String: Any] in
            let result = hit(x)
            return ["control": name, "x": Double(x), "hit": result.type,
                    "inSwiftUIHostingView": result.hosting, "inToolbarView": result.toolbar]
        }
        // Sweep: every 4 pt along the header center line outside the native buttons.
        var bad: [String] = []
        var x: CGFloat = 84
        while x < width - 2 {
            let result = hit(x)
            if !result.hosting || result.toolbar { bad.append("\(Int(x)):\(result.type)") }
            x += 4
        }
        return ["points": controls, "sweepFrom84NotHosting": bad, "centerLineYFromTop": 26]
    }
    func toggleFullScreenForEvidence() { window?.toggleFullScreen(nil) }
    func newTerminalForEvidence() { newTerminal(fixtureArguments: []) }
    var surfaceForEvidence: TerminalSurface? { controller?.surface }
    /// Clicks a button of the visible quit-failure alert, as the user would.
    func pressQuitAlertButton(_ index: Int) {
        guard let alert = quitAlert, alert.buttons.indices.contains(index) else { return }
        alert.buttons[index].performClick(nil)
    }
}
#endif
