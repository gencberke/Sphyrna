import Foundation
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI

/// The new-session page in Ink (DESIGN §8): what it says and the values it draws with, as plain values. The start path and the
/// stored drafts are `NewSessionTests`; the question's wrapping is `UIFixRoundViewTests`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DraftPageTests {
    // MARK: Words

    @Test func theKeysLineSaysWhatEachKeyDoes() {
        #expect(DraftWords.keys == ["\u{21B5} start", "\u{2318}\u{21B5} start in the background", "\u{21E7}\u{21B5} new line"])
        // The line draws each as a key and its words.
        let split = DraftWords.keys.map(ComposerHints.split)
        #expect(split.map(\.key) == ["\u{21B5}", "\u{2318}\u{21B5}", "\u{21E7}\u{21B5}"])
        #expect(split.map(\.words) == ["start", "start in the background", "new line"])
    }

    @Test func theFolderLineIsThePathAndTheBranchAndNeverAState() {
        let home = NSHomeDirectory()
        let folder = DraftWords.folder(projectPath: home + "/Documents/loom", branch: .named("swarm/1"))
        #expect(folder == DraftWords.Folder(path: "~/Documents/loom", branch: "swarm/1"))
        #expect(folder.line == "~/Documents/loom \u{00B7} swarm/1")
        #expect(DraftWords.folder(projectPath: "/opt/work", branch: .named("main")).line == "/opt/work \u{00B7} main")
        #expect(DraftWords.folder(projectPath: "/opt/work", branch: .detached).line == "/opt/work \u{00B7} Detached HEAD")
        // Not a Git folder, or not read yet: the path alone.
        #expect(DraftWords.folder(projectPath: "/opt/work", branch: .unavailable).line == "/opt/work")
        #expect(DraftWords.folder(projectPath: "/opt/work", branch: nil).line == "/opt/work")
        // No project: the home folder.
        #expect(DraftWords.folder(projectPath: nil, branch: nil).line == "~")
        #expect(DraftWords.folder(projectPath: nil, branch: .named("main")).line == "~")
        for line in [folder.line, DraftWords.folder(projectPath: "/opt/work", branch: nil).line] {
            #expect(!line.lowercased().contains("clean") && !line.lowercased().contains("dirty"))
        }
    }

    @Test func theSendTooltipNamesTheSessionItStarts() {
        #expect(DraftWords.sendHelp(enabled: true) == "Start a Claude Code session")
        #expect(DraftWords.sendHelp(enabled: false) == "Nothing to start yet")
    }

    // MARK: The strip

    @Test func theStripHasThreeSegmentsAndStaysOnTheBranch() {
        let segments = DraftWords.segments(hasProject: true, branch: .named("swarm/1"), chosen: .stay, name: "loom/fix")
        #expect(segments.map(\.title) == ["Stay on swarm/1", "New branch", "New worktree"])
        #expect(segments.map(\.kind) == [.stay, .newBranch, .newWorktree])
        #expect(segments.map(\.isChosen) == [true, false, false])
        #expect(segments.map(\.isEnabled) == [true, true, true])
        #expect(segments.map(\.showsGlyph) == [true, false, false])
        // Only a chosen new choice shows a name.
        #expect(segments.map(\.name) == [nil, nil, nil])
        // The notes "(in this folder)" and "(its own folder)" are tooltips.
        #expect(segments[1].help == "New branch, in this folder" && segments[2].help == "New worktree, in its own folder")
        #expect(DraftWords.segments(hasProject: true, branch: .detached, chosen: .stay, name: "x")[0].title == "Stay on Detached HEAD")
        #expect(DraftWords.segments(hasProject: true, branch: nil, chosen: .stay, name: "x")[0].title == "Stay on this branch")
    }

    @Test func theStripIsOffWithNoProjectAndTheNewChoicesAreOffWithoutGit() {
        let none = DraftWords.segments(hasProject: false, branch: nil, chosen: .stay, name: "x")
        #expect(none.map(\.isEnabled) == [false, false, false])
        #expect(none.allSatisfy { $0.help == DraftWords.noProject })
        // A project whose folder is not a Git repository: it can stay, it cannot branch, and the tooltip says why.
        let plain = DraftWords.segments(hasProject: true, branch: .unavailable, chosen: .stay, name: "x")
        #expect(plain.map(\.isEnabled) == [true, false, false])
        #expect(plain[0].title == "Not a Git folder")
        #expect(plain[1].help == DraftWords.noGitFolder && plain[2].help == DraftWords.noGitFolder)
        // The branch is still being read: nothing to branch from yet.
        #expect(DraftWords.segments(hasProject: true, branch: nil, chosen: .stay, name: "x").map(\.isEnabled) == [true, false, false])
    }

    @Test func aChosenNewChoiceShowsItsNameAndAnInvalidNameSaysWhy() {
        let branch = DraftWords.segments(hasProject: true, branch: .named("main"), chosen: .newBranch, name: "feat/a")
        #expect(branch.map(\.isChosen) == [false, true, false])
        #expect(branch[1].name == "feat/a" && branch[1].reason == nil && branch[1].accessibilityLabel == "New branch, feat/a")
        #expect(branch[0].name == nil && branch[2].name == nil)
        let worktree = DraftWords.segments(hasProject: true, branch: .named("main"), chosen: .newWorktree, name: "a b")
        #expect(worktree[2].isChosen && worktree[2].name == "a b")
        #expect(worktree[2].reason == "That is not a valid branch name.")
        #expect(worktree[1].reason == nil, "only the chosen segment carries the reason")
        #expect(DraftWords.nameReason("feat/ok") == nil && DraftWords.nameReason("") == DraftWords.invalidName)
    }

    @Test func aClickOnANewChoiceOpensItsNamePopoverAgainAndStayClosesIt() {
        #expect(DraftWords.afterClick(.newBranch) == (.newBranch, .newBranch))
        #expect(DraftWords.afterClick(.newWorktree) == (.newWorktree, .newWorktree))
        #expect(DraftWords.afterClick(.stay) == (.stay, nil))
        // The same click twice opens it both times: the chosen segment is the way back to the name.
        #expect(DraftWords.afterClick(.newBranch) == DraftWords.afterClick(.newBranch))
    }

    // MARK: Values

    @Test func theRhythmIsTheMapsAndTheComposerIsCentredInTheColumn() {
        typealias L = NewSessionLayout
        #expect(L.column == 720 && L.sideInset == 40 && L.bottomLift == 70)
        #expect(L.composerWidth == 680 && L.composerWidth < L.column)
        #expect([L.folderTop, L.composerTop, L.keysTop, L.stripTop, L.presetsTop] == [16, 30, 14, 26, 14])
        #expect(L.presetGap == 8)
        // The composer's own insets stay the live composer's (FixRoundLookTests ties the three).
        #expect(L.textInset == LoomTheme.Composer.textInsetH && L.textTop == LoomTheme.Composer.textTop)
    }

    @Test func theQuestionIsDisplayTypeUnderlinedInTheProjectsTone() {
        typealias D = LoomTheme.Draft
        #expect(D.question == LoomTheme.InkType.display)
        #expect(D.question.size == 46 && D.question.weight == .ultraLight && D.question.tracking == -0.03)
        #expect(D.underlineThickness == 2 && D.underlineGap == 4 && D.underlineOpacity == 0.85 && D.chevronBox == 20)
        for tone in ProjectTone.allCases {
            let style = D.underline(tone)
            #expect(style.standard.opacity == 0.85 && style.lightStandard.opacity == 0.85 && style.increased.opacity == 0.85, "\(tone)")
            #expect(style.standard.rgb == LoomTheme.ProjectColor.baseRGB(tone), "\(tone)")
            #expect(style.lightStandard.rgb == LoomTheme.ProjectColor.lightBaseRGB(tone), "\(tone)")
        }
        // A project with no tone gets the neutral underline.
        #expect(D.underline(nil) == LoomTheme.Text.tertiaryStyle)
    }

    @Test func theStripIsASegmentedControlAndThePresetsAreSmallChips() {
        typealias D = LoomTheme.Draft
        // The group is 26 high with radius 7 and 2 inside; a segment is 22 high with radius 5.
        #expect(LoomTheme.InkHeight.control == 26 && LoomTheme.InkRadius.group == 7 && LoomTheme.InkRadius.groupInner == 5)
        #expect(LoomTheme.InkHeight.control - 2 * D.segmentPadding == LoomTheme.InkHeight.chip)
        #expect(D.segmentGap == 2 && D.segmentPaddingH == 10)
        // A preset chip is 26 high with radius 6, 12 secondary words, the canvas at 72 %.
        #expect(LoomTheme.InkRadius.control == 6 && D.chipText == LoomTheme.InkType.small && D.chipFillOpacity == 0.72)
        #expect(D.keys == LoomTheme.InkType.meta && D.keysGap == 18)
        #expect(D.folder.size == 12 && D.folder.mono)
        // The optical values are not on the 4 pt grid's list; the grid ones are.
        #expect(D.chevronDrop == 3 && D.questionWordGap == 11)
    }

    @Test func theSourceNoteIsQuietAndOnlyWhenTheDefaultsDecide() {
        let own = NewSessionDefaults.resolve(
            modePick: .value("plan"), modelPick: .value("opus"), effortPick: .inherit,
            lastUsed: nil, settings: NewSessionSettings(), askAllowed: true)
        #expect(DraftSourceNote.words(resolved: own, projectName: "loom") == nil)
        let settings = NewSessionDefaults.resolve(
            modePick: .inherit, modelPick: .inherit, effortPick: .inherit,
            lastUsed: nil, settings: NewSessionSettings(permissionMode: nil, model: "opus"), askAllowed: true)
        #expect(DraftSourceNote.words(resolved: settings, projectName: "loom") == "Mode and model from Settings")
        let remembered = NewSessionDefaults.resolve(
            modePick: .inherit, modelPick: .inherit, effortPick: .inherit,
            lastUsed: ClaudeLaunchChoices(permissionMode: nil, model: "sonnet", effort: nil), settings: NewSessionSettings(),
            askAllowed: true)
        #expect(DraftSourceNote.words(resolved: remembered, projectName: "loom") == "Mode and model as last used in loom")
        #expect(DraftSourceNote.words(resolved: remembered, projectName: nil) == "Mode and model as last used")
    }
}
