import Foundation
import JavaScriptCore
import Testing
@testable import LoomCore

@Suite struct OpenCodeTUIPluginTests {
    @Test func generatedModulesObserveRoutesAndDisposeInTheHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sphyrna-observer-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try OpenCodeTUIPlugin.install(in: root)
        let manifestData = try Data(contentsOf: root.appendingPathComponent("package.json"))
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let exports = try #require(manifest["exports"] as? [String: String])
        #expect(exports["./server"] == "./server.mjs")
        #expect(exports["./tui"] == "./tui.mjs")
        let source = try String(contentsOf: root.appendingPathComponent("tui.mjs"), encoding: .utf8)
        #expect(!source.contains("fixture-secret"))
        let context = try #require(JSContext())
        context.evaluateScript(#"""
            var __route = { type: "home" };
            var __effect;
            var __disposed = false;
            var __memory = { value: 0 };
            var __socket = {
              handlers: {}, writes: [], destroyed: false,
              on(name, callback) { this.handlers[name] = callback; return this; },
              write(value, callback) { this.writes.push(value); if (callback) callback(); return true; },
              destroy() { this.destroyed = true; }
            };
            var process = { env: {
              SPHYRNA_OPENCODE_TUI_SOCKET: "/private/tmp/fixture.sock",
              SPHYRNA_OPENCODE_TUI_TOKEN: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              SPHYRNA_OPENCODE_TUI_APP_SESSION_ID: "00000000-0000-4000-8000-000000000001",
              SPHYRNA_OPENCODE_TUI_RUN_ID: "00000000-0000-4000-8000-000000000002",
              SPHYRNA_OPENCODE_TUI_INSTANCE_ID: "00000000-0000-4000-8000-000000000003"
            } };
            function createRoot(fn) { fn(() => { __disposed = true; }); }
            function createEffect(fn) { __effect = fn; fn(); }
            function untrack(fn) { return fn(); }
            function createConnection() { return __socket; }
            var __context = {
              ui: { router: { current() { return __route; } } },
              storage: { memory() { return [__memory, (fn) => fn(__memory)]; } }
            };
            """#)
        let executable = source
            .replacingOccurrences(of: #"import { createRoot, createEffect, untrack } from "solid-js";"#, with: "")
            .replacingOccurrences(of: #"import { createConnection } from "node:net";"#, with: "")
            .replacingOccurrences(of: "export default", with: "globalThis.__plugin =")
        context.evaluateScript(executable)
        #expect(context.exception == nil)
        context.evaluateScript(#"""
            var __cleanup = __plugin.setup(__context);
            if (__socket.handlers.connect) __socket.handlers.connect();
            __route = { type: "session", sessionID: "ses_one" };
            if (__effect) __effect();
            __route = { type: "home" };
            if (__effect) __effect();
            __route = { type: "session", sessionID: "ses_other" };
            if (__effect) __effect();
            if (__cleanup) __cleanup();
            __route = { type: "session", sessionID: "ses_late" };
            if (__effect) __effect();
            """#)
        #expect(context.exception == nil)
        let json = try #require(context.evaluateScript("JSON.stringify(__socket.writes.map(JSON.parse))")?.toString())
        let frames = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        #expect(frames.map { $0["type"] as? String } == ["hello", "route", "route", "route", "route"])
        #expect(frames.compactMap { $0["kind"] as? String } == ["home", "session", "home", "session"])
        #expect(frames.last?["nativeSessionID"] as? String == "ses_other")
        #expect(frames.compactMap { $0["generation"] as? Int } == [1, 2, 3, 4, 5])
        #expect(context.evaluateScript("__disposed && __socket.destroyed")?.toBool() == true)
        context.evaluateScript(#"""
            __socket = {
              handlers: {}, writes: [], destroyed: false,
              on(name, callback) { this.handlers[name] = callback; return this; },
              write(value, callback) { this.writes.push(value); if (callback) callback(); return true; },
              destroy() { this.destroyed = true; }
            };
            __route = { type: "session", sessionID: "ses_reloaded" };
            var __secondCleanup = __plugin.setup(__context);
            if (__socket.handlers.connect) __socket.handlers.connect();
            if (__secondCleanup) __secondCleanup();
            """#)
        #expect(context.exception == nil)
        let reloadJSON = try #require(context.evaluateScript("JSON.stringify(__socket.writes.map(JSON.parse))")?.toString())
        let reload = try #require(JSONSerialization.jsonObject(with: Data(reloadJSON.utf8)) as? [[String: Any]])
        #expect(reload.compactMap { $0["generation"] as? Int } == [6, 7])
        #expect(reload.last?["nativeSessionID"] as? String == "ses_reloaded")
    }
}
