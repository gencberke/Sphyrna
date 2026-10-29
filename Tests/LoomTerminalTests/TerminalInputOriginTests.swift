import AppKit
import Foundation
@testable import LoomCore
import SwiftTerm
import Testing
@testable import LoomTerminal

private final class TerminalOriginCapture: TerminalDelegate {
    var entries: [(bytes: [UInt8], origin: TerminalInputOrigin)] = []
    var reenterMouse = false
    var onInput: (([UInt8], TerminalInputOrigin) -> Void)?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        entries.append((Array(data), .unclassified))
        onInput?(Array(data), .unclassified)
    }
    func send(source: Terminal, data: ArraySlice<UInt8>, origin: TerminalInputOrigin) {
        entries.append((Array(data), origin))
        onInput?(Array(data), origin)
        if reenterMouse {
            reenterMouse = false
            source.sendEvent(buttonFlags: 0, x: 0, y: 0)
        }
    }
}

private final class TerminalLegacyCapture: TerminalDelegate {
    var bytes: [UInt8] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { bytes += data }
}

@MainActor
private final class ViewOriginCapture: TerminalViewDelegate {
    var entries: [(bytes: [UInt8], origin: TerminalInputOrigin)] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        entries.append((Array(data), .unclassified))
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>, origin: TerminalInputOrigin) {
        entries.append((Array(data), origin))
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@Suite(.serialized)
struct TerminalInputOriginTests {
    @Test func fragmentedQueriesAndUserInputKeepTheirActualOrigins() {
        let capture = TerminalOriginCapture()
        let terminal = Terminal(delegate: capture, options: TerminalSurfaceLimits.options)
        terminal.terminalLock.withLock { terminal.feed(text: "\u{1b}[6") }
        #expect(capture.entries.isEmpty)
        terminal.terminalLock.withLock { terminal.feed(text: "n\u{1b}[") }
        #expect(capture.entries.map(\.origin) == [.protocolResponse])
        terminal.terminalLock.withLock { terminal.feed(text: "c") }
        #expect(capture.entries.map(\.origin) == [.protocolResponse, .protocolResponse])
        terminal.terminalLock.withLock { terminal.sendUserInput(Array("draft".utf8)[...]) }
        terminal.sendResponse("outside parser")
        terminal.terminalLock.withLock { terminal.sendEvent(buttonFlags: 0, x: 0, y: 0) }
        #expect(capture.entries.suffix(3).map(\.origin) == [.unclassified, .unclassified, .unclassified])
    }

    @Test func reentrantMousePacketIsNotAParserReply() {
        let capture = TerminalOriginCapture()
        let terminal = Terminal(delegate: capture, options: TerminalSurfaceLimits.options)
        capture.reenterMouse = true
        terminal.terminalLock.withLock { terminal.feed(text: "\u{1b}[6n") }
        #expect(capture.entries.map(\.origin) == [.protocolResponse, .unclassified])
    }

    @Test func fixedFocusAndVisibilityReportsRemainProtocolInputAfterParserReturns() {
        let capture = TerminalOriginCapture()
        let terminal = Terminal(delegate: capture, options: TerminalSurfaceLimits.options)
        terminal.terminalLock.withLock {
            terminal.feed(text: "\u{1b}[?1004h\u{1b}[?2033h")
            terminal.setTerminalFocus(false)
            terminal.setTerminalVisibility(.notVisible)
        }
        #expect(capture.entries.map(\.origin) == [.protocolResponse, .protocolResponse, .protocolResponse, .protocolResponse])
        #expect(capture.entries.map { String(decoding: $0.bytes, as: UTF8.self) } ==
                ["\u{1b}[I", "\u{1b}[?999;1n", "\u{1b}[O", "\u{1b}[?999;2n"])
    }

    @Test func focusAndVisibilityAfterReadyDoNotDirtyTheComposer() async throws {
        let capture = TerminalOriginCapture()
        let terminal = Terminal(delegate: capture, options: TerminalSurfaceLimits.options)
        let queue = TerminalInputQueue(capacity: 1024, writer: { $0.count },
            automaticWriter: { bytes, transaction in try transaction { bytes.count } }, onError: { _ in })
        capture.onInput = { bytes, origin in
            if origin == .protocolResponse { queue.enqueueTerminalResponse(bytes) }
            else { queue.enqueue(bytes) }
        }
        terminal.terminalLock.withLock { terminal.feed(text: "\u{1b}[?1004h\u{1b}[?2033h") }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while queue.isDraining && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(queue.establishFreshCleanInput())
        terminal.terminalLock.withLock {
            terminal.setTerminalFocus(false)
            terminal.setTerminalVisibility(.notVisible)
        }
        while queue.isDraining && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(queue.enqueueAutomatic(Data("task pointer\r".utf8), transaction: { try $0() }) != nil)
    }

    @Test func legacyDelegateStillReceivesParserReplies() {
        let capture = TerminalLegacyCapture()
        let terminal = Terminal(delegate: capture, options: TerminalSurfaceLimits.options)
        terminal.terminalLock.withLock { terminal.feed(text: "\u{1b}[6n") }
        #expect(String(decoding: capture.bytes, as: UTF8.self).hasSuffix("R"))
    }

    @MainActor
    @Test func parserAndUserCallbacksPreserveTheirOrderAcrossTheMainHop() async throws {
        let view = LoomTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let capture = ViewOriginCapture()
        view.terminalDelegate = capture
        view.feed(text: "\u{1b}[6")
        view.feed(text: "n")
        view.send(data: Array("user".utf8)[...])
        try await Task.sleep(for: .milliseconds(30))
        #expect(capture.entries.map(\.origin) == [.protocolResponse, .unclassified])
        #expect(capture.entries.count == 2)
        if capture.entries.count == 2 {
            #expect(String(decoding: capture.entries[0].bytes, as: UTF8.self).hasSuffix("R"))
            #expect(capture.entries[1].bytes == Array("user".utf8))
        }
    }
}
