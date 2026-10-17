import AppKit
import Foundation
import SwiftUI
import Testing
import LoomChat
import LoomCore
@testable import LoomCatalogUI

/// Pictures of the chat view for the user's eye check, drawn from the isolated test profile (never the real `~/.claude`).
/// Skipped unless `LOOM_CHAT_EVIDENCE_OUT` names a folder. `LOOM_CHAT_EVIDENCE_PROFILE` is the profile's config directory and
/// `LOOM_CHAT_EVIDENCE_SESSIONS` lists `label=<session id>` pairs separated by commas.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ChatEvidenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOOM_CHAT_EVIDENCE_OUT"] != nil))
    func picturesOfRealTranscripts() async throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(env["LOOM_CHAT_EVIDENCE_OUT"]), isDirectory: true)
        let profile = URL(fileURLWithPath: try #require(env["LOOM_CHAT_EVIDENCE_PROFILE"]), isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let sessions = (env["LOOM_CHAT_EVIDENCE_SESSIONS"] ?? "").split(separator: ",").map { $0.split(separator: "=").map(String.init) }
        let size = CGSize(width: 980, height: 760)
        for pair in sessions where pair.count == 2 {
            ChatSessionMemoryStore.removeAll()
            let model = ChatTranscriptModel(sessionID: pair[1], configDirectory: profile, workingDirectory: Self.workingDirectory(of: pair[1], in: profile))
            let hosting = NSHostingView(rootView: ChatTranscriptContent(model: model, isWorking: false, onOpenSubagent: nil) { Color.red })
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosting.frame = NSRect(origin: .zero, size: size)
            model.setOnScreen(true)
            for _ in 0..<200 where model.phase == .resolving { try await Task.sleep(for: .milliseconds(25)) }
            #expect(model.phase == .ready, "\(pair[0]) opened")
            for mode in ChatViewMode.allCases {
                model.setViewMode(mode)
                for _ in 0..<12 {
                    hosting.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                }
                // The end, then the top, of the view.
                for (name, atEnd) in [("end", true), ("top", false)] {
                    if atEnd { model.controller.jumpToLatest() } else {
                        model.controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: -model.controller.topInset))
                        model.controller.scrollView.reflectScrolledClipView(model.controller.scrollView.contentView)
                    }
                    for _ in 0..<8 {
                        hosting.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(30))
                    }
                    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    let png = try #require(rep.representation(using: .png, properties: [:]))
                    try png.write(to: out.appendingPathComponent("\(pair[0])-\(mode.rawValue)-\(name).png"))
                }
            }
            model.close()
        }
    }

    /// The folder the session ran in, from its first records (the transcript names it in `cwd`).
    private static func workingDirectory(of sessionID: String, in profile: URL) -> String? {
        guard let file = ClaudeTranscriptLocator.locate(sessionID: sessionID, configDirectory: profile),
              let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 64 * 1024), as: UTF8.self)
        for line in head.split(separator: "\n") {
            if let data = line.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
               let cwd = value["cwd"]?.string { return cwd }
        }
        return nil
    }
}
