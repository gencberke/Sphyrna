import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI

/// Controlled first-screen measurement: one owned 8 MiB transcript, no provider, profile or shown window.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct B5bFirstScreenTests {
    private struct Fixture: Sendable {
        let root: URL
        let projects: URL
        let file: URL
        let bytes: Int

        static func make() throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("loom-b5b-paint-\(UUID())", isDirectory: true)
            let projects = root.appendingPathComponent("projects", isDirectory: true)
            let folder = projects.appendingPathComponent("-tmp-ws/session-1/subagents", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("agent-a1.jsonl")
            let prose = "I checked the **session surfaces** and the affected controls.\\n\\n"
                + "| Surface | Rule |\\n| --- | --- |\\n| Tabs | Flat at rest |\\n| Inspector | Cards |\\n\\n"
                + String(repeating: "The tested source keeps a bounded stream and its result. ", count: 28)
            let cycle = """
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\(prose)"}]}}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"Sources/Example.swift"}},{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}
            {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Read complete"},{"type":"tool_result","content":"Tests passed"}]}}
            \n
            """
            let head = #"{"type":"user","message":{"role":"user","content":"Inspect the changes"}}"# + "\n"
            let tail = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Final report: the changed rows are ready."}]}}"# + "\n"
            var data = Data(head.utf8)
            let chunk = Data(cycle.utf8)
            while data.count + chunk.count + tail.utf8.count < 8 * 1_024 * 1_024 { data.append(chunk) }
            data.append(Data(tail.utf8))
            try data.write(to: file)
            return Fixture(root: root, projects: projects, file: file, bytes: data.count)
        }
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    @Test func firstScreenOfAnEightMiBSubagentTranscript() async throws {
        let fixture = try await Task.detached(priority: .utility) { try Fixture.make() }.value
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.bytes >= 8 * 1_024 * 1_024 - 4_096 && fixture.bytes <= 8 * 1_024 * 1_024)
        let projects = fixture.projects
        let panel = SubagentTranscriptModel(agentID: "a1", transcriptPath: fixture.file.path, isRunning: false,
                                             windowVisible: true, locate: { path in
            await Task.detached(priority: .utility) {
                SubagentTranscriptLocation.resolve(path: path, agentID: "a1", projectsDirectory: projects)
            }.value
        })
        let content = SubagentTranscriptView(panel: panel, isFinished: true)
            .frame(width: 556, height: 600).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 556, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { panel.close(); window.close() }
        #expect(!window.isVisible && !window.isKeyWindow)
        let before = residentBytes()
        let started = ProcessInfo.processInfo.systemUptime
        panel.setOnScreen(true)
        for _ in 0..<1_000 where panel.phase != .live { try await Task.sleep(for: .milliseconds(5)) }
        try #require(panel.phase == .live, "the first parsed batch arrived")
        try await Task.sleep(for: .milliseconds(25))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        let after = residentBytes()
        print("B5B_FIRST_SCREEN bytes=\(fixture.bytes) entries=\(panel.entryCount) omitted=\(panel.omitsEarlier) elapsed_ms=\(elapsed) rss_before=\(before) rss_after=\(after) rss_delta=\(Int64(after) - Int64(before))")
        #expect(panel.entryCount > 0 && panel.entryCount <= SubagentTranscriptModel.ringLimit && panel.omitsEarlier)
        #expect(bitmap.pixelsWide >= 556 && bitmap.pixelsHigh >= 600)
        if let dir = ProcessInfo.processInfo.environment["LOOM_B5B_RENDER_DIR"],
           let name = ProcessInfo.processInfo.environment["LOOM_B5B_RENDER_NAME"] {
            let destination = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name))
        }
    }
}
