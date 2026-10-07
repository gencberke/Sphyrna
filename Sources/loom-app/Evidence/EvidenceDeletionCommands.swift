#if LOOM_EVIDENCE
import AppKit
import LoomCatalogUI
import LoomCore

/// Delete commands (CP4-D): the same model calls the menus, the sheet and the banner make.
///
/// - `delete:<id>`: "Delete Permanently…" (opens the confirm sheet and asks the runtime for the dry run).
/// - `delete-confirm`: the sheet's "Delete Permanently" button (returns at once; the deletion runs on).
/// - `delete-cancel`: the sheet's Cancel.
/// - `delete-retry:<id>`: the banner's "Try Again" (returns at once).
/// - `delete-key`: Cmd+Delete sent through the real main menu; writes `ack-delete-key.json` with whether the menu
///   handled it and whether the item was enabled.
/// - `screenshot-sheet:<label>`: the attached sheet's content view as `screenshot-sheet-<label>.png`
///   (not written for real-provider runs).
///
/// The snapshot gains `deletions{fileMenuItem, confirmation, pending[], inProgress[], recoveryFailure}`.
@MainActor
extension DevelopmentEvidence {
    /// Returns false when `name` is not a delete command.
    func handleDeletionCommand(_ name: String, _ argument: String) -> Bool {
        guard let app, let model = app.model else { return false }
        let id = UUID(uuidString: String(argument.prefix(36)))
        switch name {
        case "delete": if let id { model.requestDeletion(id) }
        case "delete-confirm": Task { await model.confirmDeletion() }
        case "delete-cancel": model.cancelDeletion()
        case "delete-retry": if let id { Task { await model.retryDeletion(id) } }
        case "delete-key": write("ack-delete-key", app.sendDeleteKeyForEvidence())
        case "screenshot-sheet":
            guard !app.redactsContent else { return true }
            let label = argument.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            app.saveSheetScreenshot(to: directory.appendingPathComponent("screenshot-sheet-\(label).png"))
        default: return false
        }
        return true
    }
}

extension AppDelegate {
    /// The File menu's delete item, as the menu would validate it right now.
    private var deleteMenuItem: NSMenuItem? {
        (NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
            .first { $0.action.map(NSStringFromSelector) == "deleteFromMenu:" }
    }

    var deletionsEvidence: [String: Any] {
        guard let model else { return [:] }
        let deletions = model.deletions
        var confirmation: Any = NSNull()
        if let open = deletions.confirmation {
            var phase = "loading"
            var detail: [String: Any] = [:]
            switch open.phase {
            case .loading: break
            case let .ready(preview):
                phase = "ready"
                detail = ["fileCount": preview.fileCount, "byteCount": preview.byteCount,
                          "configDirectory": preview.configDirectory, "isRunning": preview.isRunning,
                          "unreachable": preview.unreachable, "body": DeletionCopy.confirmBody(preview)]
            case let .unavailable(message):
                phase = "unavailable"
                detail = ["message": message]
            }
            confirmation = ["id": open.id.uuidString, "title": redactsContent ? "" : open.title, "phase": phase,
                            "canConfirm": open.canConfirm, "detail": detail,
                            "sheetAttached": window?.attachedSheet != nil] as [String: Any]
        }
        let item = deleteMenuItem
        return [
            "fileMenuItem": item.map { ["title": $0.title, "enabled": validateMenuItem($0),
                                        "keyEquivalent": $0.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) },
                                        "command": $0.keyEquivalentModifierMask.contains(.command)] as [String: Any] } ?? NSNull(),
            "confirmation": confirmation,
            "pending": deletions.pending.values.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                ["id": $0.id.uuidString, "state": String(describing: $0.state), "attempts": $0.attempts,
                 "lastFailure": $0.lastFailure ?? NSNull(), "isRunning": $0.isRunning,
                 "canRetry": model.canRetryDeletion($0.id),
                 "banner": DeletionCopy.bannerText(lastFailure: $0.lastFailure),
                 "title": redactsContent ? "" : (deletions.titles[$0.id] ?? "")] as [String: Any]
            },
            "inProgress": deletions.inProgress.map(\.uuidString).sorted(),
            "recoveryFailure": deletions.recoveryFailure ?? NSNull(),
        ]
    }

    /// Cmd+Delete through `NSApp.mainMenu`, as the key window would after the responder chain passed.
    func sendDeleteKeyForEvidence() -> [String: Any] {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\u{8}",
                                           charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: 51)
        else { return ["handled": false, "error": "no event"] }
        let item = deleteMenuItem
        let enabledBefore = item.map { validateMenuItem($0) } ?? false
        let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        return ["key": "cmd-delete", "handled": handled, "enabledBefore": enabledBefore, "itemPresent": item != nil]
    }

    /// Renders the attached sheet's content view (a sheet is its own window, so the main window's picture lacks it).
    func saveSheetScreenshot(to url: URL) {
        guard let sheet = window?.attachedSheet else { return }
        Self.writePNG(of: sheet.contentView, to: url)
        // The frame view carries the sheet's own background, which the content view alone does not draw.
        Self.writePNG(of: sheet.contentView?.superview, to: url.deletingPathExtension().appendingPathExtension("window.png"))
    }
}
#endif
