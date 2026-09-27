#!/usr/bin/env python3
"""Exercise prebuilt CP1 probes; write sanitized, independently checked A9 evidence.

Run from any directory: python3 plans/experiments/verify-coalition.py
Requires the existing .build/LoomProbe.app and .build/debug/loom-probe.
No Swift build or provider command is run. Each probe launch has a 15s deadline.
Evidence is saved beneath $LOOM_PROBE_ROOT/evidence/coalition, defaulting to
~/Library/Application Support/Loom-Dev/probe/evidence/coalition.
"""
import ctypes as C
import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[2]


class Process(C.Structure):
    _fields_ = [("pid", C.c_int), ("ppid", C.c_int), ("pgid", C.c_int),
                ("sid", C.c_int), ("uid", C.c_uint), ("status", C.c_int),
                ("sec", C.c_int64), ("usec", C.c_int64)]


def identity(record):
    return (record["pid"], record["startSeconds"], record["startMicroseconds"])


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def read_json(path):
    return json.loads(path.read_text())


class Audit:
    def __init__(self, directory):
        library = directory / "libaudit.dylib"
        subprocess.run(["clang", "-Wall", "-Wextra", "-Werror", "-dynamiclib",
                        "-I", str(REPO / "Sources/CLoomPOSIX/include"),
                        str(REPO / "Sources/CLoomPOSIX/CLoomPOSIX.c"), "-o", str(library)], check=True)
        self.lib = C.CDLL(str(library), use_errno=True)
        self.lib.loom_processes.argtypes = [C.POINTER(C.POINTER(Process)), C.POINTER(C.c_size_t)]
        self.lib.loom_free_processes.argtypes = [C.POINTER(Process)]
        self.lib.loom_signal_if_matches.argtypes = [C.c_int, C.c_int64, C.c_int64, C.c_int]
        self.lib.loom_resource_coalition.argtypes = [C.c_int, C.POINTER(C.c_uint64)]
        self.lib.loom_process_path.argtypes = [C.c_int, C.c_char_p, C.c_size_t]
        self.lib.loom_read_run_id.argtypes = [C.c_int, C.c_char_p, C.c_size_t]

    def snapshot(self):
        pointer = C.POINTER(Process)()
        count = C.c_size_t()
        if self.lib.loom_processes(C.byref(pointer), C.byref(count)) != 0:
            raise OSError(C.get_errno(), "process snapshot failed")
        try:
            return {p.pid: {"identity": {"pid": p.pid, "startSeconds": p.sec,
                                       "startMicroseconds": p.usec},
                            "parentPID": p.ppid, "sessionID": p.sid,
                            "userID": p.uid, "zombie": p.status == 5}
                    for p in pointer[:count.value]}
        finally:
            self.lib.loom_free_processes(pointer)

    def enrich(self, record):
        pid = record["identity"]["pid"]
        coalition = C.c_uint64()
        if self.lib.loom_resource_coalition(pid, C.byref(coalition)) == 0:
            record["resourceCoalition"] = coalition.value
        path = C.create_string_buffer(4096)
        if self.lib.loom_process_path(pid, path, len(path)) == 0:
            record["executable"] = path.value.decode(errors="replace")
        marker = C.create_string_buffer(128)
        record["runMarkerReadResult"] = self.lib.loom_read_run_id(pid, marker, len(marker))
        # Deliberately do not retain or serialize environment values.
        return record

    def signal(self, record, number):
        pid, sec, usec = identity(record)
        result = self.lib.loom_signal_if_matches(pid, sec, usec, number)
        return {"identity": record, "signal": number, "result": result,
                "errno": C.get_errno() if result != 0 else 0}


def fixture(run):
    path = run / "terminal.txt"
    if not path.exists():
        return {}
    for line in path.read_text(errors="replace").splitlines():
        try:
            raw = json.loads(line)
            return {key: raw[key] for key in ("pid", "descendantPID", "mode", "tty") if key in raw}
        except (ValueError, TypeError):
            pass
    return {}


def report_clean(report):
    return not any(report.get(key) for key in ("remaining", "errors", "outsideOwnership"))


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class Harness:
    def __init__(self, output):
        self.output = output
        self.audit = Audit(output)
        self.seen = {}
        self.first_seen = {}
        self.cleanup = []
        self.results = {}
        self.artifact_hashes = {str(path.relative_to(REPO)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in (REPO / ".build/LoomProbe.app/Contents/MacOS/loom-probe",
                                             REPO / ".build/debug/loom-probe", Path(__file__).resolve())}
        self.runs = []
        self.external = subprocess.Popen(["/bin/sleep", "30"])
        self.external_before = self.audit.enrich(self.audit.snapshot()[self.external.pid])
        self.external_checks = []

    def collect(self):
        snapshot = self.audit.snapshot()
        for record in snapshot.values():
            key = identity(record["identity"])
            if record["userID"] == os.getuid():
                self.first_seen.setdefault(key, time.monotonic())
                # Capture exec/reparent transitions before the short-lived fixture exits.
                if not record["zombie"] and (key not in self.seen or time.monotonic() - self.first_seen[key] < 0.4):
                    self.seen[key] = self.audit.enrich(record)
        return snapshot

    def external_check(self, label):
        now = self.audit.snapshot().get(self.external.pid)
        unchanged = now is not None and now["identity"] == self.external_before["identity"] and not now["zombie"]
        self.external_checks.append({"after": label, "sameLiveIdentity": unchanged})
        require(unchanged, "Unrelated sleep exited or changed identity")

    def launch(self, label, args, app=True, force=False, root=None):
        case = self.output / label
        case.mkdir()
        root = root or case / "probe-root"
        root.mkdir(exist_ok=True)
        stderr_path = case / "stderr.txt"
        if app:
            command = ["/usr/bin/open", "-n", "-W", str(REPO / ".build/LoomProbe.app"),
                       "--stdout", "/dev/null", "--stderr", str(stderr_path),
                       "--env", "LOOM_PROBE_ROOT=" + str(root),
                       "--env", "LOOM_FORCE_COALITION_FAILURE=" + ("1" if force else "0"),
                       "--args", *args]
            process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            environment = os.environ.copy()
            environment["LOOM_PROBE_ROOT"] = str(root)
            environment["LOOM_FORCE_COALITION_FAILURE"] = "1" if force else "0"
            with stderr_path.open("w") as errors:
                process = subprocess.Popen([str(REPO / ".build/debug/loom-probe"), *args],
                                           env=environment, stdout=subprocess.DEVNULL, stderr=errors)
        started = time.monotonic()
        timed_out = False
        pre_readiness_ledger = None
        while process.poll() is None:
            self.collect()
            for candidate in (root / "runs").glob("*"):
                if (candidate / "ledger.json").exists() and not (candidate / "terminal.txt").exists():
                    pre_readiness_ledger = read_json(candidate / "ledger.json")
            if time.monotonic() - started >= 15:
                timed_out = True
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                break
            time.sleep(0.02)
        self.collect()
        runs = sorted((root / "runs").glob("*"))
        for run in runs:
            if run not in self.runs:
                self.runs.append(run)
        metadata = {"launcherExitCode": process.returncode, "timedOut": timed_out,
                    "elapsedSeconds": time.monotonic() - started,
                    "root": str(root), "runs": [str(run) for run in runs],
                    "preReadinessLedger": pre_readiness_ledger}
        write_json(case / "launch.json", metadata)
        self.external_check(label)
        require(not timed_out, label + " exceeded 15-second deadline")
        require(len(runs) == 1, label + " did not produce exactly one run")
        return runs[0], metadata

    def observed_oracle(self, run):
        pid = fixture(run).get("descendantPID")
        matches = [value for key, value in self.seen.items() if key[0] == pid]
        require(len(matches) == 1, "Independent process snapshots did not identify the fixture oracle uniquely")
        oracle = matches[0]
        require(oracle.get("executable") == "/bin/sleep", "Oracle was not observed as Apple /bin/sleep")
        require(oracle["parentPID"] == 1 and oracle["sessionID"] > 0
                and oracle["sessionID"] != fixture(run).get("pid"), "Oracle did not escape parent/session")
        return oracle

    def no_live_oracle(self, oracle):
        now = self.audit.snapshot().get(oracle["identity"]["pid"])
        return now is None or now["identity"] != oracle["identity"] or now["zombie"]

    def synthetic(self, label, mode, app=True, force=False):
        run, metadata = self.launch(label, ["synthetic", mode], app=app, force=force)
        self.results[label] = {"launch": metadata}
        required = ("ledger.json", "shutdown.json", "before-shutdown.json", "oracle-remaining.json")
        missing = [name for name in required if not (run / name).exists()]
        require(not missing, "Missing required evidence: " + ", ".join(missing) + "; inspect " + str(self.output / label / "stderr.txt"))
        ledger = read_json(run / "ledger.json")
        report = read_json(run / "shutdown.json")
        before = read_json(run / "before-shutdown.json")
        remaining = read_json(run / "oracle-remaining.json")
        result = {"launch": metadata, "ledger": ledger, "beforeShutdown": before,
                  "shutdown": report, "oracleRemaining": remaining}
        self.results[label] = result
        require(report_clean(report) and not remaining and (run / "completed").exists(), "Synthetic shutdown evidence failed")
        capability = ledger.get("coalition", {})
        if app and not force:
            require(capability.get("resourceID") is not None, "App coalition was not enabled")
            require("Exclusive" in report["ownershipGuarantee"], "App guarantee was narrowed")
            require(capability["resourceID"] != self.external_before.get("resourceCoalition"), "External control shared the app coalition")
        else:
            require(capability.get("resourceID") is None, "Fallback unexpectedly enabled coalition")
            require("Narrowed" in report["ownershipGuarantee"], "Fallback was not reported")
            require(("forced" if force else "Shared coalition") in capability.get("detail", ""), "Fallback reason did not match scenario")
        if mode == "apple-escape":
            oracle = self.observed_oracle(run)
            result["independentOracle"] = oracle
            early = metadata.get("preReadinessLedger")
            require(early is not None and oracle["identity"] not in early.get("descendants", []),
                    "Oracle was already observed before the delayed ownership scan, or early ledger was unavailable")
            require(oracle["runMarkerReadResult"] != 1, "Apple escape unexpectedly had a readable marker")
            require(any(record["identity"] == oracle["identity"] for record in before), "Coalition scan missed escaped oracle")
            require(self.no_live_oracle(oracle), "Independent oracle survived shutdown")
        result["status"] = "passed"

    def crash_recovery(self):
        run, crash = self.launch("A9e-crash", ["crash-fixture", "apple-escape"])
        oracle = self.observed_oracle(run)
        ledger = read_json(run / "ledger.json")
        require(ledger.get("coalition", {}).get("resourceID") is not None, "Crash fixture coalition disabled")
        require(oracle["identity"] not in ledger.get("descendants", []), "Crash oracle was already in persisted ancestry")
        require(oracle["runMarkerReadResult"] != 1, "Crash oracle had a readable run marker")
        require(not self.no_live_oracle(oracle), "Crash did not leave the independent oracle alive")
        before_identity = self.audit.snapshot()[oracle["identity"]["pid"]]["identity"]
        _, recovery = self.launch("A9e-recover", ["recover-stale"], root=run.parent.parent)
        report = read_json(run / "recovery.json")
        recovered = read_json(run / "recovery-before.json")
        result = {"crashLaunch": crash, "recoveryLaunch": recovery, "persistedLedger": ledger,
                  "independentOracle": oracle, "oracleAfterCrash": before_identity,
                  "recoveryBefore": recovered, "recovery": report}
        self.results["A9e"] = result
        require(any(record["identity"] == oracle["identity"] for record in recovered), "Recovery scan missed oracle")
        require(report_clean(report) and (run / "recovered").exists(), "Recovery report did not establish success")
        require(self.no_live_oracle(oracle), "Independent oracle survived recovery")
        require("Exclusive" in report["ownershipGuarantee"], "Recovery silently narrowed coalition guarantee")
        result["status"] = "passed"

    def cleanup_owned(self):
        # Only exact identities recorded for this harness's fixture or owner qualify.
        for run in self.runs:
            ids = []
            owner = run / "owner.json"
            if owner.exists():
                ids.append(read_json(owner))
            data = fixture(run)
            for pid in (data.get("pid"), data.get("descendantPID")):
                ids.extend(value["identity"] for key, value in self.seen.items() if key[0] == pid)
            for record in ids:
                now = self.audit.snapshot().get(record["pid"])
                if now and now["identity"] == record and not now["zombie"]:
                    self.cleanup.append(self.audit.signal(record, signal.SIGKILL))
            terminal = run / "terminal.txt"
            if terminal.exists():
                # Preserve fixture evidence, excluding all environment values/keys.
                write_json(terminal, data)

    def run(self):
        scenarios = [("A9a", lambda: self.synthetic("A9a", "inspect")),
                     ("A9b", lambda: self.synthetic("A9b", "inspect", app=False)),
                     ("A9c", lambda: self.synthetic("A9c", "apple-escape")),
                     ("A9e", self.crash_recovery),
                     ("A9f", lambda: self.synthetic("A9f", "inspect", force=True))]
        try:
            for label, action in scenarios:
                try:
                    action()
                except Exception as error:
                    self.results.setdefault(label, {}).update(status="failed", error=str(error))
                    self.cleanup_owned()
                print(label + ": " + self.results[label]["status"], flush=True)
            signaled = []
            reports = {}
            for run in self.runs:
                reports[str(run)] = {}
                for name in ("ledger.json", "owner.json", "before-shutdown.json", "shutdown.json",
                             "oracle-remaining.json", "recovery-before.json", "recovery.json"):
                    if (run / name).exists():
                        value = read_json(run / name)
                        reports[str(run)][name] = value
                        if name in ("shutdown.json", "recovery.json"):
                            signaled.extend(attempt["identity"] for attempt in value.get("signals", []))
            self.external_check("all scenarios")
            untouched = self.external_before["identity"] not in signaled
            self.results["A9d"] = {"status": "passed" if untouched else "failed",
                                   "before": self.external_before, "checks": self.external_checks,
                                   "absentFromEverySignalReport": untouched}
            return {"scenarios": self.results, "runReports": reports}
        finally:
            self.cleanup_owned()
            if self.external.poll() is None:
                self.cleanup.append(self.audit.signal(self.external_before["identity"], signal.SIGTERM))
            self.external.wait(timeout=2)


def main():
    probe_root = Path(os.environ.get("LOOM_PROBE_ROOT", str(Path.home() / "Library/Application Support/Loom-Dev/probe"))).expanduser().resolve()
    output = probe_root / "evidence/coalition" / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
    output.mkdir(parents=True)
    harness = Harness(output)
    try:
        results = harness.run()
    except Exception as error:
        results = {"scenarios": harness.results, "harnessError": str(error)}
    results["artifactSHA256"] = harness.artifact_hashes
    results["cleanup"] = harness.cleanup
    results["passed"] = (len(results["scenarios"]) == 6 and
                         all(item.get("status") == "passed" for item in results["scenarios"].values()) and
                         "harnessError" not in results)
    write_json(output / "results.json", results)
    write_json(output / "sha256-manifest.json", {
        "algorithm": "SHA256",
        "files": {str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in sorted(output.rglob("*")) if path.is_file() and path.name != "sha256-manifest.json"},
    })
    print(str(output / "results.json"))
    return 0 if results["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
