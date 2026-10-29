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

        const id = "sphyrna.native-selection";
        const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        const nativeID = /^ses[a-zA-Z0-9_-]{1,125}$/;

        export default {
          id,
          setup(context) {
            const env = process.env;
            const path = env.SPHYRNA_OPENCODE_TUI_SOCKET;
            const token = env.SPHYRNA_OPENCODE_TUI_TOKEN;
            const app = env.SPHYRNA_OPENCODE_TUI_APP_SESSION_ID;
            const run = env.SPHYRNA_OPENCODE_TUI_RUN_ID;
            const instance = env.SPHYRNA_OPENCODE_TUI_INSTANCE_ID;
            if (!path || !path.startsWith("/") || path.includes("\0") ||
                !/^[0-9a-f]{64}$/.test(token || "") ||
                !uuid.test(app || "") || !uuid.test(run || "") || !uuid.test(instance || "")) return;

            const [clock, update] = context.storage.memory("generation", { initial: { value: 0 } });
            const next = () => untrack(() => {
              const value = clock.value;
              if (!Number.isSafeInteger(value) || value < 0 || value >= Number.MAX_SAFE_INTEGER) throw new Error();
              update((draft) => { draft.value = value + 1; });
              return value + 1;
            });

            let socket;
            try { socket = createConnection({ path }); } catch { return; }
            let closed = false;
            let connected = false;
            let sending = false;
            let latest;
            let disposeRoot = () => {};
            const stop = () => {
              if (closed) return;
              closed = true;
              latest = undefined;
              disposeRoot();
              socket.destroy();
            };
            const flush = () => {
              if (closed || !connected || sending || latest === undefined) return;
              const frame = latest;
              latest = undefined;
              sending = true;
              try {
                socket.write(frame, (error) => {
                  if (closed) return;
                  sending = false;
                  if (error) { stop(); return; }
                  flush();
                });
              } catch { stop(); }
            };
            let hello;
            try {
              hello = JSON.stringify({ version: 1, type: "hello", token, appSessionID: app,
                                       runID: run, instanceID: instance, generation: next() }) + "\n";
            } catch { stop(); return; }
            socket.on("error", stop);
            socket.on("close", stop);
            socket.on("connect", () => {
              if (closed) return;
              connected = true;
              sending = true;
              try {
                socket.write(hello, (error) => {
                  hello = undefined;
                  if (closed) return;
                  sending = false;
                  if (error) { stop(); return; }
                  flush();
                });
              } catch { stop(); }
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
                    const frame = { version: 1, type: "route", generation: next(), kind };
                    if (kind === "session") frame.nativeSessionID = selected;
                    latest = JSON.stringify(frame) + "\n";
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
