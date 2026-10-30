# Sphyrna 1.8.0

30 Oct 2026, built overnight under [D-120](../../DECISIONS.md): `@user` authorized the local tag, the promote and the in-place install once 1.8.0 was stable ([D-120](../../DECISIONS.md), [D-123](../../DECISIONS.md)); the push and the GitHub release wait for `@user` ([D-16](../../DECISIONS.md), [D-83](../../DECISIONS.md)). The plan is [plans/1.8.0](../1.8.0/README.md).

1.8.0 is Sphyrna's first strong stop ([D-105](../../DECISIONS.md)): Codex beside Claude, the Ink v4 look on every surface, sessions that work together, and the known bugs closed. What it does not do yet, and what was not checked, is at the end.

## Harnesses

- **Codex sessions, from the draft to Delete.** The draft starts Codex with its model, effort and mode. Stop, then Resume, continues the same Codex thread without a new input; the reader shows its transcript. Delete runs Codex's own `thread/delete` on an app-server the deletion starts for itself, shows the thread, its rollout and its index record gone, and keeps Codex's shared prompt history byte for byte ([D-121](../../DECISIONS.md)). A session whose thread was deleted elsewhere resumes as "history unavailable", never as a new conversation.
- **One harness catalogue.** Home, the draft, the File and Dock menus, the sidebar, the menu bar, Connections and the CLI read the same list: each harness's state, its models and the efforts each model supports.
- **opencode and agy are Coming later.** They are on every list with that label and do not start ([D-120](../../DECISIONS.md)): Sphyrna has no plain route for opencode yet, and agy's sign-in is hidden under a home Sphyrna owns. Pi waits ([D-113](../../DECISIONS.md)).
- **A Codex session's header reads Codex.** Its model and its context come from its own data, not Claude's.

## The look: Ink v4

- **Ink v4 on every surface** ([D-106](../../DECISIONS.md)), in Ink and Paper: new tokens, six button roles at four sizes, one focus halo and three elevations, across the sidebar and its cards, Home, the project and the draft, the session surfaces, Settings, the sheets, the palette, the menus and About.
- **One bottom bar.** The footer became a full-width status bar: each connected harness's tightest limit (its popover lists every window, model-scoped weekly ones included), the working sessions, Keep Mac Awake and the sidebar's utilities.
- **The model and effort pickers** offer only the efforts a model supports. A draft starts neutral and keeps what still fits when you switch its harness.
- **Connections and Home's connect cards** say what each harness needs before it can start.

## Sessions that work together

- **A session can hand work to a child session.** With your approval a Claude session starts a managed child, sees its progress, results and questions, and sends follow-up rounds to the same child (by default 3 rounds and 6 parent wakes within an hour). The child's tool approvals are yours, and Take Over gives you its terminal. In 1.8.0 the children are Claude sessions ([D-124](../../DECISIONS.md)).
- **Changes → a terminal session.** The comments of the Changes tab go to a running terminal session through its mailbox; your click is the approval. The tab says Delivered once the session has read them, then clears exactly the comments it sent; "Delivered in part" keeps and names what did not fit.
- **A first message no longer holds automatic input back.** A session started with a first message takes a waiting message, a Changes send or a child's result on its first Ready, as a session whose first message was typed does.
- **Codex sessions are outside the session channel** ([D-124](../../DECISIONS.md)). In every mode Sphyrna starts Codex in, Codex's sandbox blocks Sphyrna's socket, so a Codex session cannot `send`, read its `inbox` or run `task`. Every surface says so: Changes offers no Send to it, and a message to it or a task with a Codex child is refused with the reason before anything is stored.

## Usage

- **Model-scoped weekly windows** show in Usage → Limits, Home's card and the status bar's popover.
- **A limit's reset can notify you** (off by default, Settings → General): one notification at the reset of the window a session waited on, with Continue.
- **Codex's tokens** show in Usage → Tokens by model and by type (input, cached, output, reasoning).

## Reliability and resources

- **No stall from blocking work on Swift's shared threads.** Blocking waits run on their own threads, and so do the recovery after a crash and the task socket's replies, so one slow call no longer holds the rest of the app.
- **An accessibility crash is fixed.** A selectable text with its own accessibility label made SwiftUI recurse while a client (VoiceOver, an automation tool) read the window.
- **Codex costs less to read.** A rollout is found in its day folder, a Codex stop needs no extra process scan, and Storage and the cleanup review read every Codex session from one walk of the Codex home without parsing its index.
- **Bounded memory** for transcripts and the Changes cache.
- **Task rows and an open detail survive updates;** the status bar rebuilds when the window is uncovered.
- **The project drag reorders,** and a project's draft row no longer overlaps the next block.

## Names

- **Activity Monitor says Sphyrna Run Host,** and a Claude session starts under its title (`-n`). Codex has no title at start yet.
- **The app file is still `/Applications/Loom.app`** ([D-123](../../DECISIONS.md)). The rename to `Sphyrna.app` waits for `@user`, with its checks in `evidence/r9/i1/MIGRATION.md`.
- **Remora is unchanged** and runs on Claude ([D-122](../../DECISIONS.md)).

## How it was checked

- **The whole gate** (`scripts/check.sh --full --idle`) on the final commit: 14 steps PASS on `cb73630`, the code of this release (`052954-65955`): the guards, the staged release tree, T1 and T2 in release (1,343 + 1,292 tests and the small targets; the one known issue is a test proving its own detector fires) and the window tests alone in release (37).
- **Real Codex, isolated** (`RealCodexDraftAcceptanceTests`, a cheap model): the first prompt in the owned thread, one approval accepted exactly once, the settings after the first prompt, Stop, a same-thread Resume with no new input, Quit and the cleanup. It passed on the second attempt; in the first the model finished its turn without asking for approval. One real isolated Codex deletion passed earlier (`evidence/r9/d2x/REAL.md`).
- **The closing optimizer** read all code through 1.8.0 (`evidence/r9/optimizer-closing/UI.md`, `CORE.md`) and the late changes (`DELTA.md`). Its Blocking and Should-Fix findings are fixed, each with a test that failed first.

## Not checked yet

- **Claude, live.** The isolated Claude profile's sign-in expired, so no real Claude cell ran tonight: the ordinary session, the child over three rounds, Changes → session. They run once `@user` signs that profile in.
- **Energy, CPU and memory against D-92's budgets,** VoiceOver, a drag with a real pointer, and the full visual pass against the v4 reference.
- **`@user`'s hand checks** on the installed app: the project drag, a day with Claude and Codex side by side, the panel, the status bar, `send`, Remora.

## Known limits

- A Codex session that started native subagent threads, or whose Codex was uninstalled, can be neither deleted nor removed from Sphyrna; the sheet says why.
- A deletion uses the Codex home Codex resolves when you delete. A session that ran under another `CODEX_HOME` is not seen there.
- Keys pressed very fast on a pinned card, before it draws its focus ring, may be lost (seen in a test, not yet confirmed by hand).

## Going back to 1.7.2

1.7.2 is kept in `~/Library/Application Support/Loom-Dev/backups/Loom-1.7.2-10702-Applications.zip`. Quit Sphyrna, move `/Applications/Loom.app` to the Trash, then run `ditto -x -k` with that zip and `/Applications`. 1.8.0 keeps the catalog at schema 3, which 1.7.2 opens; a 1.7.2 launch on a catalog 1.8.0 has used was not tried.
