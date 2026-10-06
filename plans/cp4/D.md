# CP4-D — delete UI

[Checkpoint 4](../CHECKPOINT-4.md) · wave 4 · protocol: [RUN-1](../RUN-1.md#protocol-for-every-implementer-slice). Depends on CP4-C, U3 (tabs forget), I2 (copy and tokens).

## Goal

The user can delete a conversation from the sidebar or the detail menu, sees exactly what will be removed, sees progress and failures, and can retry.

## Design (identity A voice; DESIGN status language)

- Entry points: card context menu "Delete Conversation…", detail actions menu, File menu item with Cmd+Delete on the selected row. Disabled with a reason for Codex/synthetic rows and while starting.
- Confirm (sheet/alert on the main window): title "Delete this conversation?" Body: "Loom stops it if it's running, then removes it from Loom and deletes Claude's local files for it: the transcript, subagent transcripts, file snapshots and session folders (N files, X MB, in <config dir>). This can't be undone. Not removed: your prompts in Claude's shared prompt history, project files and worktrees, and anything already sent to Anthropic." Buttons "Delete Conversation" (destructive) and "Cancel".
- During: the row shows "Deleting…" (detail header status label; the card keeps the existing indicator set — failure uses the red dot). Selection moves away (`select(nil)` persisted).
- Failure: banner "Deleting this conversation isn't finished. <What failed, plain>. Nothing else was touched." with "Try Again"; the card menu offers "Retry Deleting".
- On success the row disappears from every list and tab; no toast.

## Scope

Write: new `Sources/LoomCatalogUI/CatalogModel+Deletion.swift` (pending deletion, plan summary, state per row from runtime frames), `ConversationController.swift` (delete/retry intents), `SidebarView.swift` and `DetailView.swift` (menu items, banner, confirm), `AppDelegate.swift` (File menu item and validation), evidence file under `Sources/loom-app/Evidence/` (`delete:<id>`, `delete-confirm`, `delete-retry:<id>`, snapshot `deletions`), tests `Tests/LoomCatalogUITests/DeletionModelTests.swift`, `design/UI-MAP.md` (new states and menu items). Out of scope: cleanup review (CP4-G).

## Done when

Model tests: confirm → runtime call; selected row deleted clears `selectedSessionID` on disk; tab and usage forget hooks called; failure state and retry. Evidence run (fake providers, isolated data root, synthetic Claude config tree): delete a stopped and a live conversation; screenshots of the confirm sheet (sheet capture), the deleting state and the failure banner (induce with a read-only file in the synthetic tree).

## Checks

`swift build`; `LoomCatalogUITests`; evidence run on a `run1-CP4D` package; `git diff --check`.
