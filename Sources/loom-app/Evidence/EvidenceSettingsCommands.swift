#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore

/// Settings window and usage commands (U1): the same calls the gear, Cmd+, and the usage chip make.
///
/// - `open-settings[:general|usage|about]`, `close-settings`
/// - `screenshot-settings:<label>`: the Settings content view as `screenshot-settings-<label>.png`
///   (and the titled frame as `….window.png`); not written for real-provider runs.
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
