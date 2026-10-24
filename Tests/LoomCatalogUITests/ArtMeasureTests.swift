import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// I5's spike, the measurement (DESIGN §17 The budget, O-01): what a frame costs off screen, at Home's band size and the
/// new-session page's. It runs only with `LOOM_ART_MEASURE_DIR` set and writes `measure.md` and `measure.json` there.
///
/// What it measures is the calling thread's CPU time per frame (`CLOCK_THREAD_CPUTIME_ID`), off screen: working a frame out
/// (the engine), drawing it with Core Text into a bitmap, and drawing it through each view (`cacheDisplay`). It is a proxy:
/// it leaves out Core Animation's compositing, the render server and the display, so the app's CPU % on screen is for the
/// on-screen cells to say. It runs in the debug build `check.sh --suite` makes, so the engine's numbers are an upper bound.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(10)))
struct ArtMeasureTests {
    private static var directory: URL? {
        ProcessInfo.processInfo.environment["LOOM_ART_MEASURE_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private struct Row: Codable {
        let name: String
        let size: String
        let frames: Int
        let cpuMsPerFrame: Double
        let wallMsPerFrame: Double
        let litCells: Int
        var at12: Double { cpuMsPerFrame * 12 / 10 }
        var at24: Double { cpuMsPerFrame * 24 / 10 }
    }

    private static func cpu() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
    private static func wall() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// Runs `body` `frames` times after a few warm-up runs, and returns its CPU and wall time per run in ms.
    private static func time(frames: Int, warmUp: Int = 4, _ body: (Int) -> Void) -> (cpu: Double, wall: Double) {
        for k in 0..<warmUp { body(k) }
        let c0 = cpu(), w0 = wall()
        for k in 0..<frames { body(warmUp + k) }
        let c1 = cpu(), w1 = wall()
        return (Double(c1 - c0) / 1e6 / Double(frames), Double(w1 - w0) / 1e6 / Double(frames))
    }

    private static func label(_ size: CGSize) -> String { "\(Int(size.width))x\(Int(size.height))" }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOM_ART_MEASURE_DIR"] != nil))
    func whatAFrameCostsOffScreen() async throws {
        let frames = 96
        var rows: [Row] = []
        var notes: [String] = []
        let band = ArtEngineTests.band, draft = ArtEngineTests.draft
        let bandMetrics = ArtMetrics.mono(cell: LoomTheme.Art.bandCell)
        let draftMetrics = ArtMetrics.mono(cell: LoomTheme.Art.ambientCell)
        notes.append("cell: band \(bandMetrics.cellWidth) x \(bandMetrics.cellHeight) pt; draft \(draftMetrics.cellWidth) x \(draftMetrics.cellHeight) pt")
        let raster = ArtRaster()

        // MARK: The engine: working a frame out

        func seaRow(_ name: String, plankton: Int, wake: Bool) -> (Row, ArtSea) {
            var sea = ArtSea(size: draft, metrics: draftMetrics, options: .init(alpha: LoomTheme.Art.draftAlpha, plankton: plankton, wake: wake),
                             specs: ArtScenes.draft, seed: 3)
            var lit = 0
            let t = Self.time(frames: frames) { _ in
                sea.advance(by: 1 / 24)
                lit += sea.frame(raster: raster).packed.count
            }
            return (Row(name: name, size: Self.label(draft), frames: frames, cpuMsPerFrame: t.cpu, wallMsPerFrame: t.wall,
                        litCells: lit / (frames + 4)), sea)
        }
        let (full, draftSea) = seaRow("engine: new-session sea, plankton and wake on", plankton: 26, wake: true)
        rows.append(full)
        rows.append(seaRow("engine: new-session sea, plankton and wake off", plankton: 0, wake: false).0)

        let loop = ArtHomeLoop(size: band, metrics: bandMetrics)
        var loopLit = 0
        let live = Self.time(frames: frames) { k in loopLit += loop.frame(at: Double(k) / 12, raster: raster).packed.count }
        rows.append(Row(name: "engine: Home's loop, live", size: Self.label(band), frames: frames, cpuMsPerFrame: live.cpu,
                        wallMsPerFrame: live.wall, litCells: loopLit / (frames + 4)))

        // MARK: Home's loop worked out once

        let c0 = Self.cpu(), w0 = Self.wall()
        let precomputed = ArtLoopFrames(loop: loop)
        let buildCPU = Double(Self.cpu() - c0) / 1e9, buildWall = Double(Self.wall() - w0) / 1e9
        var lookupCount = 0
        let lookup = Self.time(frames: frames) { k in lookupCount += precomputed.cells(at: Double(k) / 12).count }
        rows.append(Row(name: "engine: Home's loop, precomputed (lookup)", size: Self.label(band), frames: frames,
                        cpuMsPerFrame: lookup.cpu, wallMsPerFrame: lookup.wall, litCells: lookupCount / (frames + 4)))
        notes.append(String(format: "precomputed loop: %d frames at 12 fps, %.2f MB, built in %.2f s CPU (%.2f s wall), again on every resize of the band",
                            precomputed.frameCount, Double(precomputed.bytes) / 1_048_576, buildCPU, buildWall))

        // MARK: Drawing: Core Text into a bitmap at 2x

        func bitmapRow(_ name: String, size: CGSize, cell: CGFloat, mask: ArtMask, cells: (Int) -> [UInt32]) -> Row {
            let painter = ArtPainter(cell: cell)
            let metrics = painter.metrics
            let factors = mask.factors(columns: metrics.columns(size), rows: metrics.rows(size), metrics: metrics, size: size)
            let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: 2, y: 2)
            let prepared = (0..<(frames + 4)).map(cells)
            let t = Self.time(frames: frames) { k in
                context.clear(CGRect(origin: .zero, size: size))
                painter.paint(prepared[k], columns: metrics.columns(size), height: size.height, mask: factors,
                              color: LoomTheme.Art.colorPair.dark, in: context)
            }
            return Row(name: name, size: Self.label(size), frames: frames, cpuMsPerFrame: t.cpu, wallMsPerFrame: t.wall,
                       litCells: prepared.map(\.count).reduce(0, +) / prepared.count)
        }
        var sea2 = draftSea
        rows.append(bitmapRow("draw: Core Text bitmap, new-session sea", size: draft, cell: LoomTheme.Art.ambientCell, mask: .calm) { _ in
            sea2.advance(by: 1 / 24)
            return sea2.frame(raster: raster).packed
        })
        rows.append(bitmapRow("draw: Core Text bitmap, Home's loop", size: band, cell: LoomTheme.Art.bandCell, mask: .band) { k in
            Array(precomputed.cells(at: Double(k) / 12))
        })

        // MARK: Drawing through the views, off screen (cacheDisplay)

        func viewRow(_ name: String, view: NSView, size: CGSize, step: (Int) -> Void) throws -> Row {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            let t = Self.time(frames: frames) { k in
                step(k)
                view.layoutSubtreeIfNeeded()
                view.cacheDisplay(in: view.bounds, to: rep)
            }
            notes.append("\(name): backing \(rep.pixelsWide) x \(rep.pixelsHigh) px")
            return Row(name: name, size: Self.label(size), frames: frames, cpuMsPerFrame: t.cpu, wallMsPerFrame: t.wall, litCells: 0)
        }

        let layerLive = ArtLayerView(scene: .homeLoop(precomputed: false, seed: 1), cell: LoomTheme.Art.bandCell, kind: .homeLoop, mask: .band)
        rows.append(try viewRow("view: layer, Home's loop live (engine + draw)", view: layerLive, size: band) { _ in layerLive.advance(by: 1 / 12) })
        let layerFrames = ArtLayerView(scene: .homeLoop(precomputed: true, seed: 1), cell: LoomTheme.Art.bandCell, kind: .homeLoop, mask: .band)
        rows.append(try viewRow("view: layer, Home's loop precomputed (draw)", view: layerFrames, size: band) { _ in layerFrames.advance(by: 1 / 12) })
        let layerSea = ArtLayerView(scene: .sea(specs: ArtScenes.draft, options: .init(alpha: LoomTheme.Art.draftAlpha), seed: 3),
                                    cell: LoomTheme.Art.ambientCell, kind: .ambient, mask: .calm)
        rows.append(try viewRow("view: layer, new-session sea (engine + draw)", view: layerSea, size: draft) { _ in layerSea.advance(by: 1 / 24) })

        // The other surfaces (I5's surfaces slice), through the layer the app draws with.
        func placeView(_ place: ArtPlace) -> ArtLayerView {
            ArtLayerView(scene: place.scene, cell: place.cell, weight: place.weight, kind: place.kind, mask: place.mask)
        }
        let first = placeView(.firstLaunch)
        rows.append(try viewRow("view: layer, first launch (engine + draw)", view: first, size: draft) { _ in first.advance(by: 1 / 24) })
        let about = placeView(.about)
        let aboutSize = CGSize(width: LoomTheme.Settings.width, height: LoomTheme.Art.aboutHeight)
        rows.append(try viewRow("view: layer, About's crossing (engine + draw)", view: about, size: aboutSize) { _ in about.advance(by: 1 / 24) })
        let pane = CGSize(width: 340, height: LoomTheme.Agents.emptyArtHeight)
        let waiting = placeView(.readingBranch)
        rows.append(try viewRow("view: layer, a pane's hammerhead in place (engine + draw)", view: waiting, size: pane) { _ in
            waiting.advance(by: 1 / 12)
        })
        let side = placeView(.emptySide)
        rows.append(try viewRow("view: layer, the Side tab's whale shark in place (engine + draw)", view: side,
                                size: CGSize(width: 340, height: LoomTheme.Art.sideBoxHeight)) { _ in side.advance(by: 1 / 12) })

        // MARK: The report

        let directory = try #require(Self.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var md = "| what | size (pt) | CPU ms / frame | wall ms / frame | CPU % of a core at 12 fps | at 24 fps | lit cells |\n"
        md += "| --- | --- | --- | --- | --- | --- | --- |\n"
        for r in rows {
            md += String(format: "| %@ | %@ | %.3f | %.3f | %.2f | %.2f | %d |\n", r.name, r.size, r.cpuMsPerFrame, r.wallMsPerFrame,
                         r.at12, r.at24, r.litCells)
        }
        md += "\n" + notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
        try md.write(to: directory.appendingPathComponent("measure.md"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: directory.appendingPathComponent("measure.json"))
        #expect(rows.allSatisfy { $0.cpuMsPerFrame > 0 })
    }
}
