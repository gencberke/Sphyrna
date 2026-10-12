#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore

/// Settings window and usage commands (U1): the same calls the gear, Cmd+, and the usage chip make.
///
/// - `open-settings[:general|usage|about]`, `close-settings`
/// - `screenshot-settings:<label>`: the Settings content view as `screenshot-settings-<label>.png`
///   (and the titled frame as `….window.png`); not written for real-provider runs.
/// - `cleanup-review`, `cleanup-select:<all|none>`, `cleanup-confirm`: Settings → Conversations (CP4-G; the
///   same model calls the section's buttons make; no-ops where the review is not installed).
/// - `pin:<id>`, `unpin:<id>`: the card menu's Pin / Unpin.
/// - `mark-read:<id>`: the card menu's Mark as Read.
/// - `usage-select:<24h|7d|30d|90d>`: the period control.
/// - `usage-refresh[:<label>]`: refreshes now and writes `ack-usage-refresh-<label>.json` when done.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not a settings or usage command.
    func handleSettingsCommand(_ name: String, _ argument: String) async -> Bool {
        guard let app else { return false }
        let label = argument.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        switch name {
        case "open-settings":
            let sections = Dictionary(uniqueKeysWithValues: SettingsSection.allCases.map { ($0.title.lowercased(), $0) })
            app.showSettings(section: sections[argument])
        case "close-settings":
            app.settingsController?.close()
        case "cleanup-review":
            await app.model?.cleanupReview?.open()
        case "cleanup-select":
            if argument == "all" { app.model?.cleanupReview?.selectAll() } else { app.model?.cleanupReview?.clearSelection() }
        case "cleanup-confirm":
            await app.model?.cleanupReview?.confirmDeletion()
        case "pin", "unpin":
            if let id = UUID(uuidString: argument) { await app.model?.setPinned(id, name == "pin") }
        case "mark-read":
            if let id = UUID(uuidString: argument) { app.model?.markRead(id) }
        case "usage-select":
            let periods = Dictionary(uniqueKeysWithValues: UsagePeriod.allCases.map { ($0.title.replacingOccurrences(of: " ", with: ""), $0) })
            if let period = periods[argument] { app.usage?.select(period); await app.usage?.settle() }
        case "usage-refresh":
            await app.usage?.refreshNow(reason: .manual)
            var ack: [String: Any] = app.usageEvidence
            ack["succeeded"] = app.usage?.state == .ready
            write("ack-usage-refresh" + (label.isEmpty ? "" : "-\(label)"), ack)
        case "screenshot-settings":
            guard !app.redactsContent else { return true }
            await app.usage?.settle()
            try? await Task.sleep(for: .milliseconds(300))
            app.saveSettingsScreenshot(to: directory.appendingPathComponent("screenshot-settings-\(label).png"))
        default: return false
        }
        return true
    }
}

extension AppDelegate {
    var settingsEvidence: [String: Any] {
        let window = settingsController?.window
        return [
            "visible": window?.isVisible ?? false,
            "appearance": window?.effectiveAppearance.name.rawValue ?? NSNull(),
            "section": settingsController?.navigation.section.title ?? NSNull(),
            "contentSize": window?.contentView.map { [Double($0.bounds.width), Double($0.bounds.height)] } ?? NSNull(),
            "resizable": window?.styleMask.contains(.resizable) ?? NSNull(),
            "cleanup": cleanupEvidence,
        ]
    }

    /// Settings → Conversations (CP4-G): counts and per-row results by id; no titles.
    var cleanupEvidence: [String: Any] {
        guard let review = model?.cleanupReview else { return ["installed": false] }
        return [
            "installed": true, "phase": String(describing: review.phase),
            "eligible": review.review?.eligible.map(\.id.uuidString) ?? [],
            "excluded": review.review?.excluded.map { ["id": $0.id.uuidString, "reason": String(describing: $0.reason)] } ?? [],
            "selected": review.selection.map(\.uuidString).sorted(),
            "results": Dictionary(uniqueKeysWithValues: review.results.map { ($0.key.uuidString, String(describing: $0.value)) }),
            "due": review.review?.isDue ?? NSNull(),
        ]
    }

    var usageEvidence: [String: Any] {
        guard let usage else { return ["state": "none"] }
        var result: [String: Any] = [
            "state": String(describing: usage.state), "period": usage.period.title,
            "isRefreshing": usage.isRefreshing, "hasHistory": usage.hasHistory,
            "asOf": usage.updatedAt?.timeIntervalSince1970 ?? NSNull(),
            "lastFailure": usage.lastFailure ?? NSNull(),
        ]
        if let chip = usage.chip {
            result["chip"] = ["kind": chip.kind.rawValue, "full": chip.full, "short": chip.short,
                              "tooltip": chip.tooltip, "accessibilityLabel": chip.accessibilityLabel]
        } else { result["chip"] = NSNull() }
        if let report = usage.report {
            let tokens = report.snapshot.tokens
            result["totals"] = [
                "period": report.period.title, "input": tokens.input, "output": tokens.output,
                "cacheWrite5m": tokens.cacheWrite5m, "cacheWrite1h": tokens.cacheWrite1h,
                "cacheRead": tokens.cacheRead, "total": tokens.total,
                "estimatedCostUSD": report.snapshot.estimatedCostUSD, "messages": report.snapshot.messageCount,
                "sessions": report.snapshot.sessionCount, "unknownModels": report.snapshot.unknownModels,
                "priceTableAsOf": report.snapshot.priceTableAsOf,
            ] as [String: Any]
            result["models"] = report.snapshot.models.map {
                ["model": $0.model, "tokens": $0.tokens.total, "cost": $0.estimatedCostUSD ?? NSNull()] as [String: Any]
            }
            result["bars"] = report.bars.map { ["start": $0.start.timeIntervalSince1970, "tokens": $0.tokens, "current": $0.isCurrent] as [String: Any] }
            result["cells"] = report.cells.map { ["start": $0.start.timeIntervalSince1970, "tokens": $0.tokens] as [String: Any] }
        }
        return result
    }

    /// Renders the Settings content view with the app's own pixels, like `saveScreenshot` for the main window.
    func saveSettingsScreenshot(to url: URL) {
        guard let window = settingsController?.window, window.isVisible else { return }
        Self.writePNG(of: window.contentView, to: url)
        Self.writePNG(of: window.contentView?.superview, to: url.deletingPathExtension().appendingPathExtension("window.png"))
    }
}
#endif
