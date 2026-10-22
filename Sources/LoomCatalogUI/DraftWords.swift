import Foundation

/// What the new-session page says, as plain values a test can pin (DESIGN §8): the folder line, the keys line, the branch
/// strip's segments and the rules of the name popover, and Send's tooltip. The views only draw these.
enum DraftWords {
    // MARK: Folder line

    /// "~/path · branch", in two pieces so the view can draw the middle dot with its own gap.
    struct Folder: Equatable {
        let path: String
        /// The branch, or nil when there is nothing to say (no project, not a Git folder, not read yet).
        let branch: String?

        var line: String { branch.map { path + " \u{00B7} " + $0 } ?? path }
    }

    /// The project's folder in `~` form and its branch. No clean or dirty state: nothing runs before the first send. A draft
    /// with no project shows the home folder.
    static func folder(projectPath: String?, branch: GitBranch?) -> Folder {
        guard let projectPath else { return Folder(path: "~", branch: nil) }
        let path = (projectPath as NSString).abbreviatingWithTildeInPath
        switch branch {
        case .named(let name)?: return Folder(path: path, branch: name)
        case .detached?: return Folder(path: path, branch: GitBranch.detached.label)
        case .unavailable?, nil: return Folder(path: path, branch: nil)
        }
    }

    // MARK: Keys line

    /// The keys under the composer, each a key and its words ("\u{21B5} start"); the view splits them at the first space.
    static let keys = ["\u{21B5} start", "\u{2318}\u{21B5} start in the background", "\u{21E7}\u{21B5} new line"]

    // MARK: Send

    static let sendHelpReady = "Start a Claude Code session"
    static let sendHelpNotReady = "Nothing to start yet"

    static func sendHelp(enabled: Bool) -> String { enabled ? sendHelpReady : sendHelpNotReady }

    // MARK: Branch strip

    /// One segment of the strip.
    struct Segment: Equatable {
        let kind: BranchKind
        /// The words: "Stay on main", "New branch", "New worktree".
        let title: String
        /// The name a chosen new choice shows after its words (nil on the others).
        let name: String?
        /// Only "Stay on" carries the branch glyph.
        let showsGlyph: Bool
        let isEnabled: Bool
        let isChosen: Bool
        /// The tooltip: where the session's files will be, or why the segment is off.
        let help: String
        /// Why the name is not usable, shown on the chosen segment and in the popover.
        let reason: String?

        /// What VoiceOver says: the words, then the name.
        var accessibilityLabel: String { name.map { title + ", " + $0 } ?? title }
    }

    static let invalidName = "That is not a valid branch name."
    static let noGitFolder = "This folder is not a Git repository, so there is nothing to branch from."
    static let noProject = "Pick a project to choose where the session starts."
    static let createsAtStart = "Sphyrna creates it when the session starts, never before."

    /// The reason a typed or suggested name cannot be used, or nil for a usable one.
    static func nameReason(_ name: String) -> String? {
        NewSessionBranchNames.isPlausible(name) ? nil : invalidName
    }

    /// "Stay on main"; a folder that is not a Git folder says so, and a branch still being read keeps the generic words.
    static func stayTitle(branch: GitBranch?, hasProject: Bool) -> String {
        switch branch {
        case .named(let name)?: "Stay on " + name
        case .detached?: "Stay on " + GitBranch.detached.label
        case .unavailable? where hasProject: "Not a Git folder"
        case .unavailable?, nil: "Stay on this branch"
        }
    }

    /// The three segments. With no project all are off. A folder with no Git branch has nothing to branch from, so the two new
    /// choices are off with the reason in their tooltip; the notes "(in this folder)" and "(its own folder)" are tooltips too.
    /// `name` is the draft's branch name (typed, or made from its first words): a chosen new choice shows it.
    static func segments(hasProject: Bool, branch: GitBranch?, chosen: BranchKind, name: String) -> [Segment] {
        let canBranch = hasProject && (branch.map { $0 != .unavailable } ?? false)
        let reason = nameReason(name)
        func newChoice(_ kind: BranchKind, _ title: String, folder: String) -> Segment {
            let on = chosen == kind
            let help = !hasProject ? noProject : (canBranch ? "\(title), \(folder)" : noGitFolder)
            return Segment(kind: kind, title: title, name: on ? name : nil, showsGlyph: false, isEnabled: canBranch,
                           isChosen: on, help: help, reason: on ? reason : nil)
        }
        return [
            Segment(kind: .stay, title: stayTitle(branch: branch, hasProject: hasProject), name: nil, showsGlyph: true,
                    isEnabled: hasProject, isChosen: chosen == .stay,
                    help: hasProject ? "Start on the branch the folder is on, in the project's folder" : noProject, reason: nil),
            newChoice(.newBranch, "New branch", folder: "in this folder"),
            newChoice(.newWorktree, "New worktree", folder: "in its own folder"),
        ]
    }

    /// A click on a segment: the strip's choice after it, and the segment whose name popover is open. Either new choice asks for
    /// its name, and a click on the chosen one opens the popover again; "Stay on" closes it.
    static func afterClick(_ kind: BranchKind) -> (chosen: BranchKind, popover: BranchKind?) {
        kind == .stay ? (.stay, nil) : (kind, kind)
    }
}
