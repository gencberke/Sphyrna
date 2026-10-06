import AppKit
import Foundation
import Testing
import SwiftTerm
@testable import LoomTerminal

@MainActor
struct TerminalProductTests {
    @Test func fontUpdatesEngineAndClamps() {
        let surface = TerminalSurface(fontSize: 18)
        #expect(surface.view.font.pointSize == 18)
        surface.setFontSize(20)
        #expect(surface.view.font.pointSize == 20)
        surface.setFontSize(1)
        #expect(surface.view.font.pointSize == 11)
        surface.setFontSize(.nan)
        #expect(surface.view.font.pointSize == 14)
    }

    @Test func multipleDroppedPathsAreShellQuotedWithoutEnter() throws {
        let urls = [URL(fileURLWithPath: "/tmp/çok boşluk 🧵"), URL(fileURLWithPath: "/tmp/a'b\"c"),
                    URL(fileURLWithPath: "/tmp/line\nreturn\rtab\tescape\u{1b}")]
        let text = LoomTerminalView.quotedPaths(urls)
        #expect(text.hasPrefix("'/tmp/çok boşluk 🧵' '/tmp/a'\"'\"'b\"c' "))
        #expect(!text.contains("\r") && !text.contains("\n"))
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-f", "-c", "printf '%s\\0' " + text]
        let output = Pipe()
        shell.standardOutput = output
        try shell.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
        #expect(bytes == Data((urls.map(\.path).joined(separator: "\0") + "\0").utf8))
        #expect(LoomTerminalView.quotedPaths([URL(string: "https://example.com")!]).isEmpty)
    }

    @Test func bufferDiagnosticsExposeExactBoundedCountsWithoutCopyingText() throws {
        let surface = TerminalSurface()
        let initial = surface.statistics
        #expect(try #require(initial.mainBufferLines) == Int(surface.gridSize.rows))
        #expect(try #require(initial.mainBufferCapacity) >= initial.mainBufferLines!)
        surface.outputSink.receive(Data(String(repeating: "line\r\n", count: 3_000).utf8))
        let full = surface.statistics
        #expect(full.mainBufferLines == full.mainBufferCapacity)
        surface.outputSink.receive(Data("\u{1b}[?1049hALT".utf8))
        let alternate = surface.statistics
        #expect(alternate.alternateBufferLines == Int(surface.gridSize.rows))
        #expect(alternate.alternateBufferLines == alternate.alternateBufferCapacity)
        #expect(alternate.mainBufferLines == full.mainBufferLines)
        #expect(alternate.resizePendingJobs == 0)
    }

    @Test func linksAcceptOnlyWebOrExistingLocalTargets() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loom-link boşluk-\(UUID())")
        try Data("local".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(TerminalSurface.openableLink(file.path) == file.standardizedFileURL)
        #expect(TerminalSurface.openableLink(file.absoluteString) == file.standardizedFileURL)
        #expect(TerminalSurface.openableLink("https://example.com/path") != nil)
        #expect(TerminalSurface.openableLink("http://example.com/path") != nil)
        for bad in ["https:invalid", "javascript:alert(1)", "ssh://example.com", "file://remote/tmp/file", "/nonexistent/loom-\(UUID())"] {
            #expect(TerminalSurface.openableLink(bad) == nil)
        }
    }
}
