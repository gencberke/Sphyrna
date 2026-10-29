import Darwin
import Foundation

/// The app-owned combined package exposes an inert server entry so OpenCode's
/// own plugin inventory can discover the TUI part. It never supplies tools,
/// permissions, model instructions or a token in generated files.
public enum OpenCodeTUIPlugin {
    public static let id = "sphyrna.native-selection"
    static let manifest = #"""
        {
          "name": "@sphyrna/native-selection-observer",
          "version": "1.0.0",
          "type": "module",
          "exports": { "./server": "./server.mjs", "./tui": "./tui.mjs" }
        }
        """# + "\n"

    static let serverModule = #"""
        export default {
          id: "sphyrna.native-selection",
          setup() {}
        };
        """# + "\n"

    static let tuiModule = #"""
        import { createRoot, createEffect, untrack } from "solid-js";
        import { createConnection } from "node:net";
        import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";

        const id = "sphyrna.native-selection";
        const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        const nativeID = /^ses[a-zA-Z0-9_-]{1,125}$/;
        const messageID = /^msg_[a-zA-Z0-9_-]{1,124}$/;
        const hex = /^[0-9a-f]{64}$/;
        const maxFrame = 72 * 1024;
        const keysEqual = (value, keys) => value && typeof value === "object" && !Array.isArray(value) &&
          Object.keys(value).sort().join(",") === keys.slice().sort().join(",");

        export default {
          id,
          setup(context) {
            const env = process.env;
            const path = env.SPHYRNA_OPENCODE_TUI_SOCKET;
            const token = env.SPHYRNA_OPENCODE_TUI_TOKEN;
            const app = env.SPHYRNA_OPENCODE_TUI_APP_SESSION_ID;
            const run = env.SPHYRNA_OPENCODE_TUI_RUN_ID;
            const instance = env.SPHYRNA_OPENCODE_TUI_INSTANCE_ID;
            if (!path || !path.startsWith("/") || path.includes("\0") || !hex.test(token || "") ||
                !uuid.test(app || "") || !uuid.test(run || "") || !uuid.test(instance || "")) return;

            const [clock, update] = context.storage.memory("generation", { initial: { value: 0 } });
            const next = () => untrack(() => {
              const value = clock.value;
              if (!Number.isSafeInteger(value) || value < 0 || value >= Number.MAX_SAFE_INTEGER) throw new Error();
              update((draft) => { draft.value = value + 1; });
              return value + 1;
            });
            const mac = (role, nonce, generation) => createHmac("sha256", token)
              .update(["sphyrna.opencode.tui.v1", role, nonce, app, run, instance, String(generation)].join("\n"))
              .digest("hex");

            let socket, nonce, helloGeneration, hello;
            try {
              nonce = randomBytes(32).toString("hex");
              helloGeneration = next();
              hello = JSON.stringify({ version: 1, type: "hello", generation: helloGeneration,
                appSessionID: app, runID: run, instanceID: instance, nonce,
                proof: mac("hello", nonce, helloGeneration) }) + "\n";
              socket = createConnection({ path });
              socket.setEncoding("utf8");
            } catch {
              if (socket) socket.destroy();
              return;
            }
            let closed = false, connected = false, authenticated = false, sending = false;
            let latest, reply, inFlight, incoming = "", incomingBytes = 0;
            let disposeRoot = () => {};
            let handshakeTimer;
            const seenRequests = new Set(), seenMessages = new Set();
            const stop = () => {
              if (closed) return;
              closed = true;
              if (handshakeTimer) clearTimeout(handshakeTimer);
              latest = undefined; reply = undefined; incoming = ""; incomingBytes = 0;
              if (inFlight) {
                inFlight.text = undefined; inFlight.command.text = undefined;
                inFlight.controller.abort(); inFlight = undefined;
              }
              disposeRoot();
              socket.destroy();
            };
            const flush = () => {
              if (closed || !connected || !authenticated || sending || (!latest && !reply)) return;
              const takeReply = reply && (!latest || reply.generation < latest.generation);
              const item = takeReply ? reply : latest;
              if (takeReply) reply = undefined; else latest = undefined;
              sending = true;
              try {
                socket.write(item.bytes, (error) => {
                  if (closed) return;
                  sending = false;
                  if (error) { stop(); return; }
                  flush();
                });
              } catch { stop(); }
            };
            const publishReply = (type, command, actual) => {
              if (closed || reply) { stop(); return; }
              try {
                const generation = next();
                const value = { version: 1, type, generation, requestID: command.requestID,
                  appSessionID: app, runID: run, instanceID: instance, roundID: command.roundID };
                if (actual) {
                  value.nativeSessionID = actual.sessionID;
                  value.messageID = actual.id;
                  value.inputType = actual.type;
                  value.text = actual.payload.text;
                }
                const bytes = JSON.stringify(value) + "\n";
                if (Buffer.byteLength(bytes, "utf8") > maxFrame) { stop(); return; }
                reply = { generation, bytes };
                flush();
              } catch { stop(); }
            };
            const handleCommand = (command) => {
              if (!keysEqual(command, ["version", "type", "requestID", "appSessionID", "runID", "instanceID",
                                       "roundID", "nativeSessionID", "messageID", "text"]) ||
                  command.version !== 1 || command.type !== "prompt" ||
                  command.appSessionID !== app || command.runID !== run || command.instanceID !== instance ||
                  !uuid.test(command.requestID || "") || !uuid.test(command.roundID || "") ||
                  !nativeID.test(command.nativeSessionID || "") || !messageID.test(command.messageID || "") ||
                  typeof command.text !== "string" || !command.text || command.text.includes("\0") ||
                  Buffer.byteLength(command.text, "utf8") > 48 * 1024) { stop(); return; }
              if (inFlight || seenRequests.has(command.requestID) || seenMessages.has(command.messageID)) {
                publishReply("indeterminate", command); return;
              }
              if (seenRequests.size >= 128 || seenMessages.size >= 128) {
                publishReply("rejected", command); return;
              }
              let current;
              try { current = context.ui.router.current(); }
              catch { publishReply("rejected", command); return; }
              if (current?.type !== "session" || current.sessionID !== command.nativeSessionID) {
                publishReply("rejected", command); return;
              }
              let controller;
              try { controller = new AbortController(); }
              catch { publishReply("rejected", command); return; }
              seenRequests.add(command.requestID); seenMessages.add(command.messageID);
              const action = { controller, text: command.text, command };
              inFlight = action;
              let operation;
              try {
                operation = context.client.session.prompt({ sessionID: command.nativeSessionID,
                  id: command.messageID, text: command.text }, { signal: controller.signal });
              } catch {
                inFlight = undefined; action.text = undefined; command.text = undefined;
                publishReply("indeterminate", command); return;
              }
              Promise.resolve(operation).then((actual) => {
                if (closed || inFlight !== action) return;
                inFlight = undefined;
                const valid = actual && actual.id === command.messageID && actual.sessionID === command.nativeSessionID &&
                  actual.type === "user" && actual.payload && actual.payload.text === action.text;
                action.text = undefined; command.text = undefined;
                publishReply(valid ? "receipt" : "indeterminate", command, valid ? actual : undefined);
              }, () => {
                if (closed || inFlight !== action) return;
                inFlight = undefined; action.text = undefined; command.text = undefined;
                publishReply("indeterminate", command);
              });
            };
            const handle = (line) => {
              let value;
              try { value = JSON.parse(line); } catch { stop(); return; }
              if (!authenticated) {
                if (!keysEqual(value, ["version", "type", "nonce", "proof"]) || value.version !== 1 ||
                    value.type !== "welcome" || value.nonce !== nonce || !hex.test(value.proof || "")) { stop(); return; }
                const expected = mac("welcome", nonce, helloGeneration);
                if (!timingSafeEqual(Buffer.from(value.proof, "hex"), Buffer.from(expected, "hex"))) { stop(); return; }
                authenticated = true;
                if (handshakeTimer) clearTimeout(handshakeTimer);
                handshakeTimer = undefined;
                hello = undefined;
                flush();
                return;
              }
              handleCommand(value);
            };
            handshakeTimer = setTimeout(stop, 5000);
            socket.on("error", stop);
            socket.on("close", stop);
            socket.on("data", (chunk) => {
              if (closed || typeof chunk !== "string") { stop(); return; }
              const parts = chunk.split("\n");
              for (let i = 0; i < parts.length; i++) {
                incomingBytes += Buffer.byteLength(parts[i], "utf8");
                if (incomingBytes > maxFrame) { stop(); return; }
                incoming += parts[i];
                if (i < parts.length - 1) {
                  if (!incoming) { stop(); return; }
                  const line = incoming;
                  incoming = ""; incomingBytes = 0;
                  handle(line);
                  if (closed) return;
                }
              }
            });
            socket.on("connect", () => {
              if (closed) return;
              connected = true;
              try { socket.write(hello, (error) => { if (error) stop(); }); }
              catch { stop(); }
            });
            createRoot((dispose) => {
              disposeRoot = dispose;
              createEffect(() => {
                const current = context.ui.router.current();
                const kind = current?.type;
                const selected = kind === "session" ? current.sessionID : undefined;
                untrack(() => {
                  if (closed) return;
                  if ((kind !== "home" && kind !== "plugin" && kind !== "session") ||
                      (kind === "session" && (typeof selected !== "string" || !nativeID.test(selected)))) {
                    stop(); return;
                  }
                  try {
                    const generation = next();
                    const frame = { version: 1, type: "route", generation, kind };
                    if (kind === "session") frame.nativeSessionID = selected;
                    latest = { generation, bytes: JSON.stringify(frame) + "\n" };
                    flush();
                  } catch { stop(); }
                });
              });
            });
            return stop;
          }
        };
        """# + "\n"

    public static func addingOwnedPlugin(to environment: [String: String], directory: URL) throws -> [String: String] {
        let path = directory.standardizedFileURL.path
        guard directory.isFileURL, path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else {
            throw OpenCodeError.invalidTarget
        }
        let existing = environment["OPENCODE_CONFIG_CONTENT"] ?? "{}"
        guard existing.utf8.count <= 256 * 1024,
              var object = (try? JSONSerialization.jsonObject(with: Data(existing.utf8))) as? [String: Any] else {
            throw OpenCodeError.invalidTarget
        }
        let plugins: [Any]
        if let value = object["plugins"] {
            guard let array = value as? [Any], array.count < 512 else { throw OpenCodeError.invalidTarget }
            plugins = array
        } else {
            plugins = []
        }
        var found = false
        for entry in plugins {
            let target: String
            if let value = entry as? String {
                target = value
            } else if let value = entry as? [String: Any], let package = value["package"] as? String,
                      value["options"] == nil || value["options"] is [String: Any] {
                target = package
            } else { throw OpenCodeError.invalidTarget }
            guard !target.isEmpty, target.utf8.count <= 4096, !target.contains("\0"), target != "-" else {
                throw OpenCodeError.invalidTarget
            }
            if target == path { found = true }
        }
        // Keep every user operation in its original order, including removals.
        object["plugins"] = found ? plugins : [path] + plugins
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeError.invalidTarget
        }
        var result = environment
        result["OPENCODE_CONFIG_CONTENT"] = text
        return result
    }

    /// Installs only in an existing owner-only app directory. Call off MainActor.
    @discardableResult
    public static func install(in directory: URL) throws -> URL {
        guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.contains("\0") else {
            throw OpenCodeError.invalidTarget
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw OpenCodeError.invalidTarget }
        for (name, content) in [("package.json", manifest), ("server.mjs", serverModule), ("tui.mjs", tuiModule)] {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            var prior = stat()
            if lstat(file.path, &prior) == 0 {
                guard prior.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), prior.st_uid == geteuid(),
                      prior.st_size <= 64 * 1024 else {
                    throw OpenCodeError.invalidTarget
                }
                if (try? Data(contentsOf: file)) == Data(content.utf8) { continue }
            } else if errno != ENOENT { throw OpenCodeError.unavailable }
            try Data(content.utf8).write(to: file, options: .atomic)
            guard chmod(file.path, 0o600) == 0 else { throw OpenCodeError.unavailable }
        }
        return directory
    }
}
