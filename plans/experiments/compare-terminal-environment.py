#!/usr/bin/env python3
"""Compare private probe/Terminal exports; persist names and equality, never values."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
loom = json.loads((args.directory / "loom-environment.json").read_text())
terminal = dict(entry.decode().split("=", 1) for entry in
                (args.directory / "terminal-environment.nul").read_bytes().split(b"\0") if b"=" in entry)
# App/session identity changes are expected; user configuration and PATH must agree.
allowed = {"TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "SHLVL", "PWD", "OLDPWD", "_",
           "__CFBundleIdentifier", "SHELL_SESSION_ID", "COLORTERM",
           "OSLogRateLimit", "XPC_FLAGS", "XPC_SERVICE_NAME"}
# These belong to the terminal/GUI launcher, not user rc configuration. Keep the
# explanation in the artifact so exclusions remain reviewable.
reasons = {"COLORTERM": "Terminal color capability hint",
           "OSLogRateLimit": "macOS application launcher logging throttle",
           "XPC_FLAGS": "macOS application launcher IPC flags",
           "XPC_SERVICE_NAME": "macOS application launcher service identity"}
differences = [{"key": key, "loomPresent": key in loom, "terminalPresent": key in terminal,
                "allowed": key in allowed or key.startswith("LOOM_"),
                "reason": reasons.get(key, "Terminal/session identity" if key in allowed else
                                      "Loom ownership marker" if key.startswith("LOOM_") else "Unexpected user environment difference")}
               for key in sorted(loom.keys() | terminal.keys()) if loom.get(key) != terminal.get(key)]
result = {"status": "verified" if all(item["allowed"] for item in differences) else "failed",
          "pathEqual": loom.get("PATH") == terminal.get("PATH"), "differences": differences,
          "environmentChecks": json.loads((args.directory / "environment-checks.json").read_text())}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
raise SystemExit(0 if result["status"] == "verified" and result["pathEqual"] else 1)
