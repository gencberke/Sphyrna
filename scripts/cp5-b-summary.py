#!/usr/bin/env python3
"""Turns <run>/checks.json into <run>/summary.json, prints the verdict and exits
0 only when every check passed (otherwise 1). Raw evidence and the summary are
kept in both cases. `--selftest` proves the exit-status distinction."""
import json, os, subprocess, sys, tempfile


def summarize(base):
    data = json.load(open(os.path.join(base, "checks.json")))
    checks = data["checks"]
    data["allPassed"] = bool(checks) and all(x["ok"] for x in checks)
    json.dump(data, open(os.path.join(base, "summary.json"), "w"), indent=2)
    for x in checks:
        print(("PASS " if x["ok"] else "FAIL ") + x["id"] + " " + x["check"]
              + ("  [" + x["detail"] + "]" if x.get("detail") and not x["ok"] else ""))
    failed = sum(1 for x in checks if not x["ok"])
    print("ALL PASSED (%d checks)" % len(checks) if data["allPassed"]
          else "SOME FAILED (%d of %d)" % (failed, len(checks)))
    print(base)
    return 0 if data["allPassed"] else 1


def selftest():
    for name, oks, expected in [("all-pass", [True, True], 0), ("one-fails", [True, False], 1), ("empty", [], 1)]:
        with tempfile.TemporaryDirectory() as base:
            json.dump({"checks": [{"id": "T", "check": "c%d" % i, "ok": ok, "detail": ""} for i, ok in enumerate(oks)]},
                      open(os.path.join(base, "checks.json"), "w"))
            result = subprocess.run([sys.executable, __file__, base], capture_output=True, text=True)
            summary = json.load(open(os.path.join(base, "summary.json")))
            assert result.returncode == expected, (name, result.returncode, result.stdout)
            assert summary["allPassed"] == (expected == 0), name
            print("selftest %-9s exit=%d allPassed=%s" % (name, result.returncode, summary["allPassed"]))
    print("SELFTEST OK")
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:] == ["--selftest"] else summarize(sys.argv[1]))
