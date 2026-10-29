import CryptoKit
import Foundation
import JavaScriptCore
import Testing
@testable import LoomCore

@Suite struct OpenCodeTUIPluginTests {
    private func installFakeRuntime(_ context: JSContext) {
        let hmac: @convention(block) (String, String) -> String = { key, value in
            HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: Data(key.utf8)))
                .map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(hmac, forKeyedSubscript: "__hmac" as NSString)
        context.evaluateScript(#"""
            var Buffer = {
              byteLength(value) { return unescape(encodeURIComponent(value)).length; },
              from(value) { return { value }; }
            };
            function createHmac(algorithm, key) {
              return { update(value) { return { digest() { return __hmac(key, value); } }; } };
            }
            function randomBytes() { return { toString() { return "c".repeat(64); } }; }
            function timingSafeEqual(a, b) { return a.value === b.value; }
            function setTimeout() { return 1; }
            function clearTimeout() {}
            var __aborts = 0;
            function AbortController() { this.signal = {}; this.abort = () => { __aborts++; }; }
            function __welcome() {
              const hello = JSON.parse(__socket.writes[0]);
              const env = process.env;
              const input = ["sphyrna.opencode.tui.v1", "welcome", hello.nonce,
                env.SPHYRNA_OPENCODE_TUI_APP_SESSION_ID, env.SPHYRNA_OPENCODE_TUI_RUN_ID,
                env.SPHYRNA_OPENCODE_TUI_INSTANCE_ID, String(hello.generation)].join("\n");
              const proof = createHmac("sha256", env.SPHYRNA_OPENCODE_TUI_TOKEN).update(input).digest("hex");
              __socket.handlers.data(JSON.stringify({ version: 1, type: "welcome", nonce: hello.nonce, proof }) + "\n");
            }
            """#)
    }

    private func executable(_ source: String) -> String {
        source.replacingOccurrences(of: #"import { createRoot, createEffect, untrack } from "solid-js";"#, with: "")
            .replacingOccurrences(of: #"import { createConnection } from "node:net";"#, with: "")
            .replacingOccurrences(of: #"import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";"#, with: "")
            .replacingOccurrences(of: "export default", with: "globalThis.__plugin =")
    }

    @Test func promptDispatchRereadsTheActualRouteSynchronously() throws {
        let context = try #require(JSContext())
        installFakeRuntime(context)
        context.evaluateScript(#"""
            var __route = { type: "session", sessionID: "ses_one" };
            var __calls = [];
            var __resolve;
            var __memory = { value: 0 };
            var __socket = {
              handlers: {}, writes: [],
              setEncoding() { return this; },
              on(name, callback) { this.handlers[name] = callback; return this; },
              write(value, callback) { this.writes.push(value); if (callback) callback(); return true; },
              destroy() {}
            };
            var process = { env: {
              SPHYRNA_OPENCODE_TUI_SOCKET: "/private/tmp/fixture.sock",
              SPHYRNA_OPENCODE_TUI_TOKEN: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              SPHYRNA_OPENCODE_TUI_APP_SESSION_ID: "00000000-0000-4000-8000-000000000001",
              SPHYRNA_OPENCODE_TUI_RUN_ID: "00000000-0000-4000-8000-000000000002",
              SPHYRNA_OPENCODE_TUI_INSTANCE_ID: "00000000-0000-4000-8000-000000000003"
            } };
            function createRoot(fn) { fn(() => {}); }
            function createEffect(fn) { fn(); }
            function untrack(fn) { return fn(); }
            function createConnection() { return __socket; }
            var __context = {
              ui: { router: { current() { return __route; } } },
              storage: { memory() { return [__memory, (fn) => fn(__memory)]; } },
              client: { session: { prompt(input) {
                __calls.push(input);
                return new Promise((resolve) => { __resolve = resolve; });
              } } }
            };
            """#)
        context.evaluateScript(executable(OpenCodeTUIPlugin.tuiModule))
        context.evaluateScript(#"""
            __plugin.setup(__context);
            if (__socket.handlers.connect) __socket.handlers.connect();
            var __helloLeaked = JSON.stringify(__socket.writes).includes(process.env.SPHYRNA_OPENCODE_TUI_TOKEN);
            __welcome();
            function command(request, session, message = "msg_one") {
              return JSON.stringify({ version: 1, type: "prompt", requestID: request,
                appSessionID: process.env.SPHYRNA_OPENCODE_TUI_APP_SESSION_ID,
                runID: process.env.SPHYRNA_OPENCODE_TUI_RUN_ID,
                instanceID: process.env.SPHYRNA_OPENCODE_TUI_INSTANCE_ID, roundID: "00000000-0000-4000-8000-000000000006",
                nativeSessionID: session, messageID: message, text: "approved" }) + "\n";
            }
            __route = { type: "session", sessionID: "ses_other" };
            if (__socket.handlers.data) __socket.handlers.data(command("00000000-0000-4000-8000-000000000004", "ses_one"));
            var __before = __calls.length;
            __route = { type: "session", sessionID: "ses_one" };
            if (__socket.handlers.data) __socket.handlers.data(command("00000000-0000-4000-8000-000000000005", "ses_one"));
            var __immediate = __calls.length;
            __route = { type: "home" };
            if (__resolve) __resolve({ id:"msg_one", sessionID:"ses_one", type:"user", payload:{text:"approved"} });
            """#)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("__helloLeaked")?.toBool() == false,
                "The per-TUI capability must never be sent to an unauthenticated socket server")
        #expect(context.evaluateScript("__before")?.toInt32() == 0)
        #expect(context.evaluateScript("__socket.writes.map(JSON.parse).some(x => x.type === 'rejected')")?.toBool() == true)
        #expect(context.evaluateScript("__immediate")?.toInt32() == 1,
                "The SDK call must start in the same callback as the final route check")
        #expect(context.evaluateScript("__calls[0]?.sessionID")?.toString() == "ses_one")
        #expect(context.evaluateScript("__calls[0]?.id")?.toString() == "msg_one")
        #expect(context.evaluateScript("__calls[0]?.text")?.toString() == "approved")
        #expect(context.evaluateScript("__socket.writes.map(JSON.parse).some(x => x.type === 'receipt' && x.text === 'approved')")?.toBool() == true,
                "A route change after dispatch does not revoke a native receipt")
        context.evaluateScript(#"""
            __route = { type: "session", sessionID: "ses_one" };
            __socket.handlers.data(command("00000000-0000-4000-8000-000000000007", "ses_one"));
            var __afterDuplicate = __calls.length;
            __context.client.session.prompt = (input) => {
              __calls.push(input);
              return Promise.resolve({ id:"msg_other", sessionID:input.sessionID, type:"user", payload:{text:input.text} });
            };
            __socket.handlers.data(command("00000000-0000-4000-8000-000000000008", "ses_one", "msg_two"));
            """#)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("__afterDuplicate")?.toInt32() == 1)
        #expect(context.evaluateScript("__socket.writes.map(JSON.parse).some(x => x.type === 'indeterminate' && x.requestID === '00000000-0000-4000-8000-000000000007')")?.toBool() == true,
                "A previously dispatched native message cannot be treated as a definite non-dispatch")
        #expect(context.evaluateScript("__calls.length")?.toInt32() == 2)
        #expect(context.evaluateScript("__socket.writes.map(JSON.parse).some(x => x.type === 'indeterminate' && x.requestID === '00000000-0000-4000-8000-000000000008')")?.toBool() == true,
                "A mismatched native receipt cannot be reported as accepted")
        context.evaluateScript(#"""
            var __originalAbortController = AbortController;
            AbortController = function() { throw new Error(); };
            __context.client.session.prompt = (input) => {
              __calls.push(input);
              return Promise.resolve({id:input.id, sessionID:input.sessionID, type:"user", payload:{text:input.text}});
            };
            __socket.handlers.data(command("00000000-0000-4000-8000-000000000010", "ses_one", "msg_four"));
            var __beforeRetry = __calls.length;
            AbortController = __originalAbortController;
            __socket.handlers.data(command("00000000-0000-4000-8000-000000000011", "ses_one", "msg_four"));
            var __afterRetry = __calls.length;
            """#)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("__beforeRetry")?.toInt32() == 2)
        #expect(context.evaluateScript("__afterRetry")?.toInt32() == 3,
                "Failure before dispatch must not consume the native message ID")
        context.evaluateScript(#"""
            var __resolveLate;
            __context.client.session.prompt = (input) => new Promise(resolve => { __resolveLate = resolve; });
            __socket.handlers.data(command("00000000-0000-4000-8000-000000000009", "ses_one", "msg_three"));
            var __beforeCloseWrites = __socket.writes.length;
            __socket.handlers.close();
            if (__resolveLate) __resolveLate({id:"msg_three", sessionID:"ses_one", type:"user", payload:{text:"approved"}});
            """#)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("__aborts")?.toInt32() == 1)
        #expect(context.evaluateScript("__socket.writes.length === __beforeCloseWrites")?.toBool() == true,
                "Late completion after disconnect cannot publish a receipt")
    }

    @Test func untrustedServerAndWrongCommandIdentityCannotIssueSDKInput() throws {
        for fault in ["beforeWelcome", "badWelcome", "app", "run", "instance", "request", "message", "oversize"] {
            let context = try #require(JSContext())
            installFakeRuntime(context)
            context.setObject(fault, forKeyedSubscript: "__fault" as NSString)
            context.evaluateScript(#"""
                var __route = { type: "session", sessionID: "ses_one" }, __calls = 0, __memory = { value: 0 };
                var __socket = {
                  handlers: {}, writes: [], destroyed: false,
                  setEncoding() { return this; },
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
                function createRoot(fn) { fn(() => {}); }
                function createEffect(fn) { fn(); }
                function untrack(fn) { return fn(); }
                function createConnection() { return __socket; }
                var __context = {
                  ui: { router: { current() { return __route; } } },
                  storage: { memory() { return [__memory, (fn) => fn(__memory)]; } },
                  client: { session: { prompt() { __calls++; return Promise.resolve({}); } } }
                };
                """#)
            context.evaluateScript(executable(OpenCodeTUIPlugin.tuiModule))
            context.evaluateScript(#"""
                __plugin.setup(__context);
                __socket.handlers.connect();
                if (__fault === "badWelcome") {
                  const hello = JSON.parse(__socket.writes[0]);
                  __socket.handlers.data(JSON.stringify({version:1, type:"welcome", nonce:hello.nonce,
                                                         proof:"0".repeat(64)}) + "\n");
                } else if (__fault !== "beforeWelcome") __welcome();
                const command = { version:1, type:"prompt", requestID:"00000000-0000-4000-8000-000000000004",
                  appSessionID:process.env.SPHYRNA_OPENCODE_TUI_APP_SESSION_ID,
                  runID:process.env.SPHYRNA_OPENCODE_TUI_RUN_ID,
                  instanceID:process.env.SPHYRNA_OPENCODE_TUI_INSTANCE_ID,
                  roundID:"00000000-0000-4000-8000-000000000005", nativeSessionID:"ses_one",
                  messageID:"msg_one", text:"approved" };
                if (__fault === "app") command.appSessionID = "00000000-0000-4000-8000-000000000099";
                if (__fault === "run") command.runID = "00000000-0000-4000-8000-000000000099";
                if (__fault === "instance") command.instanceID = "00000000-0000-4000-8000-000000000099";
                if (__fault === "request") command.requestID = "invalid";
                if (__fault === "message") command.messageID = "not-a-native-id";
                if (__fault === "oversize") command.text = "a".repeat(49 * 1024);
                __socket.handlers.data(JSON.stringify(command) + "\n");
                """#)
            #expect(context.exception == nil, "Fixture case: \(fault)")
            #expect(context.evaluateScript("__calls")?.toInt32() == 0, "Fixture case: \(fault)")
            #expect(context.evaluateScript("__socket.destroyed")?.toBool() == true, "Fixture case: \(fault)")
        }
    }

    @Test func socketConfigurationFailureClosesTheCreatedConnection() throws {
        let context = try #require(JSContext())
        installFakeRuntime(context)
        context.evaluateScript(#"""
            var __socket = { destroyed:false, setEncoding() { throw new Error(); }, destroy() { this.destroyed = true; } };
            var __memory = { value: 0 };
            var process = { env: {
              SPHYRNA_OPENCODE_TUI_SOCKET: "/private/tmp/fixture.sock",
              SPHYRNA_OPENCODE_TUI_TOKEN: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              SPHYRNA_OPENCODE_TUI_APP_SESSION_ID: "00000000-0000-4000-8000-000000000001",
              SPHYRNA_OPENCODE_TUI_RUN_ID: "00000000-0000-4000-8000-000000000002",
              SPHYRNA_OPENCODE_TUI_INSTANCE_ID: "00000000-0000-4000-8000-000000000003"
            } };
            function createRoot(fn) { fn(() => {}); }
            function createEffect(fn) { fn(); }
            function untrack(fn) { return fn(); }
            function createConnection() { return __socket; }
            var __context = { storage: { memory() { return [__memory, fn => fn(__memory)]; } } };
            """#)
        context.evaluateScript(executable(OpenCodeTUIPlugin.tuiModule))
        context.evaluateScript("__plugin.setup(__context)")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("__socket.destroyed")?.toBool() == true)
    }

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
        installFakeRuntime(context)
        context.evaluateScript(#"""
            var __route = { type: "home" };
            var __effect;
            var __disposed = false;
            var __memory = { value: 0 };
            var __socket = {
              handlers: {}, writes: [], destroyed: false,
              setEncoding() { return this; },
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
        context.evaluateScript(executable(source))
        #expect(context.exception == nil)
        context.evaluateScript(#"""
            var __cleanup = __plugin.setup(__context);
            if (__socket.handlers.connect) __socket.handlers.connect();
            __welcome();
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
              setEncoding() { return this; },
              on(name, callback) { this.handlers[name] = callback; return this; },
              write(value, callback) { this.writes.push(value); if (callback) callback(); return true; },
              destroy() { this.destroyed = true; }
            };
            __route = { type: "session", sessionID: "ses_reloaded" };
            var __secondCleanup = __plugin.setup(__context);
            if (__socket.handlers.connect) __socket.handlers.connect();
            __welcome();
            if (__secondCleanup) __secondCleanup();
            """#)
        #expect(context.exception == nil)
        let reloadJSON = try #require(context.evaluateScript("JSON.stringify(__socket.writes.map(JSON.parse))")?.toString())
        let reload = try #require(JSONSerialization.jsonObject(with: Data(reloadJSON.utf8)) as? [[String: Any]])
        #expect(reload.compactMap { $0["generation"] as? Int } == [6, 7])
        #expect(reload.last?["nativeSessionID"] as? String == "ses_reloaded")
    }
}
