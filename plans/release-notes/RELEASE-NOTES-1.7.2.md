# Sphyrna 1.7.2

26 Oct 2026, a fix to 1.7.1 ([RELEASE-NOTES-1.7.1](RELEASE-NOTES-1.7.1.md)). The push and the GitHub release wait for `@user` ([D-16](../../DECISIONS.md), [D-83](../../DECISIONS.md)).

- **Dragging a project no longer locks the window.** 1.7.1 declared the two in-app drag types (a project, a session) in the app's Info.plist as data. AppKit then offered every such drag as a file promise, `NSFilePromiseReceiver` raised an exception during the drag, AppKit cancelled it, and the window stopped answering clicks until Sphyrna was quit. The declarations are gone, as in 1.7.0, so a drag carries the id as in-app data again. The project head's name is still not a button, so a project drag starts on it (FB6-4).
