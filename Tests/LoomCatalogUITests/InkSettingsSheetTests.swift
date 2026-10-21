import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCore
@testable import LoomCatalogUI

/// I4b: the sheet family's rules as plain values (keys, widths, focus order), Delete's and Full Access's words, the stepper's ends and
/// the source guard over the family's files.
@MainActor
struct InkSettingsSheetTests {
    // MARK: Keys

    @Test func escapeCancelsAndReturnDoesNothingWithoutAFilledButton() {
        #expect(SheetKeys.reaction(to: .escape, hasFilledButton: false) == .cancel)
        #expect(SheetKeys.reaction(to: .escape, hasFilledButton: true) == .cancel)
        #expect(SheetKeys.reaction(to: .return, hasFilledButton: false) == .swallow)
        #expect(SheetKeys.reaction(to: .return, hasFilledButton: true) == .confirm)
    }

    @Test func otherKeysAreNotTheSheetsAndTabStaysInsideIt() {
        for key in [KeyEquivalent("a"), .space, .delete, .upArrow, KeyEquivalent("w")] {
            #expect(SheetKeys.reaction(to: key, hasFilledButton: true) == .ignore, "\(key)")
        }
        #expect(SheetKeys.reaction(to: .tab, hasFilledButton: false) == .moveFocus(forward: true))
        #expect(SheetKeys.reaction(to: .tab, shift: true, hasFilledButton: false) == .moveFocus(forward: false))
    }

    @Test func theFocusStartsOnCancelAndTabWrapsAroundTheButtons() {
        let stops = ["leading", SheetFocusOrder.cancel, "action"]
        #expect(SheetFocusOrder.next(from: nil, in: stops, forward: true) == "leading")
        #expect(SheetFocusOrder.cancel == "cancel")
        #expect(SheetFocusOrder.next(from: "cancel", in: stops, forward: true) == "action")
        #expect(SheetFocusOrder.next(from: "action", in: stops, forward: true) == "leading")
        #expect(SheetFocusOrder.next(from: "leading", in: stops, forward: false) == "action")
        #expect(SheetFocusOrder.next(from: "x", in: [], forward: true) == nil)
    }

    // MARK: Width

    @Test func aSheetIs420WideOr480WhenItListsFiles() {
        #expect(SheetLayout.width(listsFiles: false) == 420)
        #expect(SheetLayout.width(listsFiles: true) == 480)
    }

    // MARK: Full Access asks only when it changes the default

    @Test func fullAccessAsksOnlyWhenItChangesTheDefault() {
        let full = ClaudePermissionMode.fullAccess.rawValue
        #expect(FullAccessRule.asks(choosing: full, current: nil))
        #expect(FullAccessRule.asks(choosing: full, current: ClaudePermissionMode.ask.rawValue))
        #expect(!FullAccessRule.asks(choosing: full, current: full), "picking it again asks nothing")
        #expect(!FullAccessRule.asks(choosing: ClaudePermissionMode.auto.rawValue, current: nil))
        #expect(!FullAccessRule.asks(choosing: "last-used", current: full))
        #expect(SettingsSheetText.fullAccessTitle == "Start new sessions in Full access?")
        #expect(SettingsSheetText.fullAccessConfirm == "Use Full Access")
    }

    // MARK: Delete's words

    private func row(_ title: String, files: Int?, bytes: Int64?) -> DeleteSheetText.Row {
        DeleteSheetText.Row(title: title, fileCount: files, byteCount: bytes)
    }

    @Test func deleteNamesTheCheckedSessionsAndTotalsWhatGoes() {
        let text = DeleteSheetText.make(
            rows: [row("Try the old sidebar spacing", files: 162, bytes: 14_000_000), row("Rename the usage chip", files: 41, bytes: 3_200_000)],
            folder: "~/.claude")
        #expect(text.title == "Delete 2 sessions?")
        #expect(text.names == "Try the old sidebar spacing, Rename the usage chip")
        #expect(text.lead == "Loom removes them from Loom, and deletes Claude's local files for them. This can't be undone.")
        #expect(text.removed == ["The transcripts and the subagent transcripts", "File snapshots and session folders"])
        #expect(text.kept == ["Your prompts in Claude's shared prompt history", "Project files and worktrees",
                              "Anything already sent to Anthropic"])
        #expect(text.totals == "203 files · \(DeleteSheetText.size(17_200_000)) · in ~/.claude")
    }

    @Test func deleteSaysOneSessionInTheSingular() {
        let text = DeleteSheetText.make(rows: [row("Only one", files: 1, bytes: 2_048)], folder: "~/.claude")
        #expect(text.title == "Delete 1 session?")
        #expect(text.lead == "Loom removes it from Loom, and deletes Claude's local files for it. This can't be undone.")
        #expect(text.totals == "1 file · \(DeleteSheetText.size(2_048)) · in ~/.claude")
    }

    @Test func deleteIsHonestWhenAnythingCouldNotBeCounted() {
        let some = DeleteSheetText.make(rows: [row("a", files: 10, bytes: 1_000), row("b", files: nil, bytes: nil)], folder: nil)
        #expect(some.totals == "At least 10 files · \(DeleteSheetText.size(1_000))")
        let none = DeleteSheetText.make(rows: [row("a", files: nil, bytes: nil)], folder: "~/.claude")
        #expect(none.totals == nil)
        let sizeOnly = DeleteSheetText.make(rows: [row("a", files: nil, bytes: 5_000)], folder: nil)
        #expect(sizeOnly.totals == "At least \(DeleteSheetText.size(5_000))")
    }

    // MARK: The stepper's ends

    @Test func theStepperStopsAtItsEnds() {
        let range = 7...365
        #expect(!StepperRule.canStep(7, by: -1, in: range))
        #expect(StepperRule.canStep(7, by: 1, in: range))
        #expect(!StepperRule.canStep(365, by: 1, in: range))
        #expect(StepperRule.canStep(365, by: -1, in: range))
        #expect(StepperRule.stepped(7, by: -1, in: range) == 7)
        #expect(StepperRule.stepped(365, by: 1, in: range) == 365)
        #expect(StepperRule.stepped(30, by: 1, in: range) == 31)
        #expect(StepperRule.stepped(30, by: -1, in: range) == 29)
        #expect(StepperRule.stepped(1, by: 1, in: range) == 7, "outside the range it is held inside")
        #expect(StepperRule.stepped(900, by: -1, in: range) == 365)
    }

    // MARK: The family takes its keys through its own key handling

    @Test func theSheetFamilyBindsNoDefaultCancelExitOrSubmitKey() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LoomCatalogUI", isDirectory: true)
        let names = ["SheetFamily.swift", "SettingsSheets.swift", "LoomTheme+Sheets.swift"]
        for name in names {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            #expect(code.contains { $0.contains("onKeyPress") } || name != "SheetFamily.swift", "the family reads its keys itself")
            for banned in [".defaultAction", "defaultAction", "cancelAction", "onExitCommand", "onSubmit", ".keyboardShortcut(.return",
                           ".keyboardShortcut(.defaultAction", ".keyboardShortcut(.cancelAction", ".keyboardShortcut(.escape"] {
                #expect(!code.contains { $0.contains(banned) }, "\(name) uses \(banned)")
            }
        }
    }
}
