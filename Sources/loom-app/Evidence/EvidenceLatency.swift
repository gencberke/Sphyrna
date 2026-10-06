#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore
import LoomLaunchOptions
import LoomTerminal

/// Input-to-draw latency measurement (`latency:<n>` and `resource:…:latency:<n>`).
@MainActor
extension DevelopmentEvidence {
    /// Input→draw: from handing one key to the engine's input path until the
    /// first completed terminal draw after its PTY echo reached the engine
    /// (CoreGraphics draw return or Metal present callback; not the
    /// compositor or the physical display). `interactive` fixture, canonical
    /// echo, sequential samples. The result is valid only when every sample
    /// was measured and the window stayed visible and unoccluded throughout.
    func measureInputToDisplay(samples: Int, surface: TerminalSurface?) async {
        guard let app, let surface else {
            write("latency", ["valid": false, "invalidReasons": ["no terminal surface"], "samples": samples])
            return
        }
        let renderer = surface.view.isUsingMetalRenderer ? "metal" : "coregraphics"
        let runID = surface.statistics.runID
        let before = app.evidenceState
        let startUptime = ProcessInfo.processInfo.systemUptime
        var latencies: [Double] = []
        var timeouts = 0
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            surface.view.send(data: [UInt8(ascii: "x")][...])
            let deadline = start + 1_000_000_000
            var presented: UInt64?
            while presented == nil, DispatchTime.now().uptimeNanoseconds < deadline {
                try? await Task.sleep(for: .milliseconds(1))
                let echoed = surface.statistics.lastOutputUptimeNanoseconds
                if echoed > start { presented = TerminalPresentationLog.firstPresentation(after: echoed) }
            }
            if let presented { latencies.append(Double(presented - start) / 1_000_000) } else { timeouts += 1 }
            try? await Task.sleep(for: .milliseconds(30))
        }
        surface.view.send(data: [0x15][...]) // Ctrl-U clears the typed line.
        let endUptime = ProcessInfo.processInfo.systemUptime
        let after = app.evidenceState
        let rendererAfter = surface.view.isUsingMetalRenderer ? "metal" : "coregraphics"
        let runIDAfter = surface.statistics.runID
        var invalid: [String] = []
        if renderer != rendererAfter { invalid.append("terminal renderer changed during latency run") }
        if runID == nil || runID != runIDAfter { invalid.append("terminal run identity missing or changed during latency run") }
        if latencies.count != samples { invalid.append("\(samples - latencies.count) of \(samples) samples missing") }
        if timeouts > 0 { invalid.append("\(timeouts) timeouts") }
        for (label, state) in [("start", before), ("end", after)] {
            if state["windowVisible"] as? Bool != true || state["windowOcclusionVisible"] as? Bool != true {
                invalid.append("window not visible/unoccluded at \(label)")
            }
        }
        let events = (after["visibilityEvents"] as? [[String: Any]] ?? []).filter {
            guard let uptime = $0["uptime"] as? Double else { return false }
            return uptime >= startUptime && uptime <= endUptime
        }
        if !events.isEmpty { invalid.append("\(events.count) visibility change(s) during latency run") }
        let sorted = latencies.sorted()
        func percentile(_ p: Double) -> Double {
            sorted.isEmpty ? -1 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        write("latency", [
            "valid": invalid.isEmpty, "invalidReasons": invalid,
            "renderer": rendererAfter, "rendererAtStart": renderer,
            "runID": runIDAfter.map { $0.uuidString as Any } ?? NSNull(),
            "samples": samples, "measured": sorted.count, "timeouts": timeouts,
            "startUptime": startUptime, "endUptime": endUptime,
            "p50Milliseconds": percentile(0.5), "p95Milliseconds": percentile(0.95),
            "maxMilliseconds": sorted.last ?? -1,
            "definition": "key sent to engine input path -> first completed terminal draw after the echo was fed (not compositor/display)",
        ])
    }
}
#endif
