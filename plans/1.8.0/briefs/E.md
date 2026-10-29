# E1, E2, E3: opencode, agy and pi as terminal sessions

**29Oct scope: E1 opencode and E2 agy only. E3 Pi is deferred from1.8.0 by D-113; do not implement or probe Pi in the current goal.**

One brief for three slices, one harness each: **E1** opencode, **E2** agy, **E3** pi. They can run side by side: each owns its
own descriptor and profile files. They start after P1, C4 and D1. P1's verdict for a harness decides its slice:
- "startable as planned": the full slice;
- "startable without live status": the slice without step 3's hooks;
- "show only": the slice stops after C1's descriptor and reports.

**Goal.** The user can start, watch, stop and resume a `<harness>` session from a draft, in its owned terminal, as plain
sessions (FEEDBACK-7 Q9). Sphyrna does not read its transcript: its surfaces say "Not read for <harness> yet".

**Read.**
- `~/Library/Caches/loom-v2/evidence/r9/p1/SPIKE.md`, your harness's section.
- D1's diff and report (the Codex pattern: launch profile, hook bridge, status mapping, resume, the capability row). Follow it.
- C1's descriptor for your harness; C4's `HarnessLaunchChoices` and modes.

**Write set.**
- New `Sources/LoomCore/<Harness>LaunchProfile.swift` and `<Harness>StatusBridge.swift`;
- your harness's descriptor and capability row;
- `loom-hook` only for your harness's payload mapping, in its own file;
- its tests; SPEC's harness lines.

Not yours: other harnesses' files and shared UI.

**Approach.**
1. **The launch profile** from P1: the first message, the model, the effort and the mode mapping (full access never from an
   agent); the profile folder untouched. Sphyrna's additions come through flags, environment or Sphyrna-owned files only.
2. **Status** from P1's source, mapped to Sphyrna's states:
   - the harness's hooks or plugin events through a Sphyrna-owned file or flag; otherwise OSC titles;
   - with neither, the session reads Running while its process lives, and the descriptor says "No live status", which
     Connections' detail card shows.
3. **Identity and resume:** the id from P1's source; Resume and Copy Resume Command with the harness's own command.
4. **Ownership:** Stop and Quit verify the scope empty. If P1 found a server that outlives the TUI, start it inside the run
   scope or report it as blocked.
5. **Deletion:** "Remove from Sphyrna" only, unless P1 found a delete command (then follow D2's pattern and report it).
6. **The capability row:** `startable` true; the reader false.

**Done when.**
- With a fake provider taught the harness's flags, a session starts from a draft with model and mode, reads its status, stops
  verified and resumes.
- With the real CLI (Q13), one short session does the same in `/private/tmp/loom-real/e*-…` with the isolated profile. Record
  the turns.
- No file in the harness's own config folder changed.

**Checks.** `HarnessRegistryTests`, `HarnessCapabilitiesTests`, `LaunchContractTests`, new `<Harness>LaunchProfileTests` and
status-bridge tests; then `--tests`.
