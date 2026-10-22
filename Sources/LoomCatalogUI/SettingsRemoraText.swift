import Foundation
import LoomChat
import LoomRemora

/// The words and the rules of Settings → Remora (DESIGN §20 Settings; the reference's `settings/body.html`), as plain values so
/// tests pin them.
enum RemoraSettingsText {
    static let switchTitle = "Remora"
    static let switchDetail = "Answers questions about your sessions on Home and from ⌘K, and drafts a new session's brief. It only reads."

    static let modelTitle = "Model"
    static let modelDetail = "Haiku 5.5 answers faster and uses much less of your plan."
    static let effortTitle = "Effort"

    static let briefTitle = "Morning brief"
    static let briefDetail = "One brief on the first Home of the day, when a session moved since the last one."
    static let languageTitle = "Brief language"
    /// The first item of the language list: no language is stored (`RemoraPreferences.language == nil`).
    static let sameLanguage = "Same as my last question"

    static let readsLabel = "What it reads"
    static let projectsTitle = "Projects it reads"
    static let projectsDetail = "An excluded project is never sent, never noted and never named."
    static let noProjects = "No projects yet."

    static let memoryLabel = "Memory"
    static let workingTitle = "Working memory"
    static let show = "Show…"
    static let clear = "Clear…"
    static let noteTitle = "Memory note"
    static let choose = "Choose…"
    static let open = "Open"
    static let proposalsTitle = "Propose things to remember"
    static let proposalsDetail = "A line under the brief asks before anything is saved."

    static let useLabel = "Use"
    static let todayTitle = "Today"
    static let thresholdTitle = "Wait while the 5-hour limit is under"
    static let thresholdDetail = "The morning brief waits; questions still run, with a warning line."

    /// The last line of the tab: what leaves the Mac while Remora is on, and what Off means.
    static let leavesTheMac = "Remora reads Claude's transcript files on this Mac only while it answers, and sends short excerpts to Claude through your Claude Code login. Claude Code's telemetry and update checks are off for Remora's calls. Its memory stays on this Mac."
    static let whenOff = "Off: Home starts with its band and Needs you, ⌘K has no Ask row, and the new-session page has no brief row. The memory stays until you clear it."

    static func lastLine(isOn: Bool) -> String { isOn ? leavesTheMac : whenOff }

    // MARK: The question before Clear

    static let clearTitle = "Clear Remora's working memory?"
    static let clearBody = "Remora forgets its journal, its project notes and the day's brief, and writes the notes again from your sessions. Remora.md is kept. This can't be undone."
    static let clearConfirm = "Clear Working Memory"
}

/// What the switch turns off. Off dims every row after the switch's own and answers nothing in them (DESIGN §20 Settings); the
/// switch stays, so Remora can be turned on again.
enum RemoraSettingsRule {
    static func dimsTheRest(isOn: Bool) -> Bool { !isOn }
}

// MARK: Model, effort, language

/// The lists behind the three popups. A stored value this build does not list is added to its list, so the popup never shows a
/// value that is not in its menu.
enum RemoraChoices {
    struct Option: Equatable, Hashable {
        let value: String
        let title: String
    }

    static let models = [Option(value: "sonnet", title: "Sonnet 5.5"), Option(value: "haiku", title: "Haiku 5.5")]

    static func efforts() -> [Option] {
        ChatEffort.ordered.map { Option(value: $0, title: ComposerBarText.effortLabel($0)) }
    }

    /// Common languages by their English names, in this order; `zh-Hans` is the form `RemoraPreferences` keeps.
    static let languages = [
        Option(value: "en", title: "English"), Option(value: "tr", title: "Turkish"), Option(value: "de", title: "German"),
        Option(value: "fr", title: "French"), Option(value: "es", title: "Spanish"), Option(value: "it", title: "Italian"),
        Option(value: "pt", title: "Portuguese"), Option(value: "nl", title: "Dutch"), Option(value: "ja", title: "Japanese"),
        Option(value: "ko", title: "Korean"), Option(value: "zh-Hans", title: "Chinese (Simplified)"),
    ]

    /// The model list, with the stored model when it is none of the two.
    static func models(including current: String) -> [Option] {
        models.contains { $0.value == current } ? models : models + [Option(value: current, title: current)]
    }

    static func efforts(including current: String) -> [Option] {
        let all = efforts()
        return all.contains { $0.value == current } ? all : all + [Option(value: current, title: current)]
    }

    /// The language list: "Same as my last question" first (the tag is "", which stands for no language), then the languages.
    static func languages(including current: String?) -> [Option] {
        var list = [Option(value: "", title: RemoraSettingsText.sameLanguage)] + languages
        if let current, !list.contains(where: { $0.value == current }) { list.append(Option(value: current, title: current)) }
        return list
    }

    static func title(of value: String, in options: [Option]) -> String { options.first { $0.value == value }?.title ?? value }

    /// A popup's tag for a stored language, and the stored language for a tag.
    static func tag(forLanguage language: String?) -> String { language ?? "" }
    static func language(forTag tag: String) -> String? { tag.isEmpty ? nil : tag }
}

// MARK: Lines

/// The two mono lines of the tab.
enum RemoraSettingsLine {
    /// "6 questions · 1 brief · 81K tokens of your plan"; the day before anything was asked says so.
    static func today(_ day: RemoraUsage.Day?) -> String {
        guard let day, day.calls > 0 else { return "Nothing asked yet today" }
        var parts: [String] = []
        if day.questions > 0 { parts.append(plural(day.questions, "question")) }
        if day.briefs > 0 { parts.append(plural(day.briefs, "brief")) }
        parts.append("\(UsageFormat.tokens(Int64(day.tokens.total))) tokens of your plan")
        return parts.joined(separator: " · ")
    }

    /// "14 days · 4 project notes · updated today 09:12"; nothing kept says so (the host gives no time for an empty memory).
    static func workingMemory(days: Int, notes: Int, updated: Date? = nil, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard days > 0 || notes > 0 || updated != nil else { return "Nothing kept yet" }
        var parts = [plural(days, "day"), plural(notes, "project note")]
        if let updated { parts.append("updated " + RemoraJournal.when(updated, now: now, calendar: calendar)) }
        return parts.joined(separator: " · ")
    }

    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    /// The threshold as the stepper reads it ("10%").
    static func threshold(_ percent: Int) -> String { "\(percent)%" }
}

/// The threshold between the preference (a share, 0...1) and the stepper (whole percent).
enum RemoraThreshold {
    static func percent(of share: Double) -> Int {
        min(max(Int((share * 100).rounded()), LoomTheme.RemoraTab.thresholdRange.lowerBound),
            LoomTheme.RemoraTab.thresholdRange.upperBound)
    }

    static func share(ofPercent percent: Int) -> Double { Double(percent) / 100 }
}

// MARK: The memory note

/// Where Choose… leads: a folder chosen in the panel means `Remora.md` inside it; a file is used as it is.
enum RemoraNoteChoice {
    static func url(forChosen url: URL, isDirectory: Bool) -> URL {
        isDirectory ? url.appendingPathComponent(RemoraPreferences.defaultNoteName) : url
    }

    /// The Obsidian vault a note sits in: the nearest folder above it that holds a `.obsidian` folder, or nil outside every vault
    /// (the default `Remora.md` in Remora's folder is outside). Obsidian answers a path outside its vaults with an error.
    static func vault(containing note: URL, fileManager: FileManager = .default) -> URL? {
        var folder = note.standardizedFileURL.deletingLastPathComponent()
        while folder.pathComponents.count > 1 {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: folder.appendingPathComponent(".obsidian").path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return folder
            }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// Where Open sends a note inside a vault (DESIGN §20); nil sends it to the app that opens the file.
    static func obsidianURL(forNote note: URL, fileManager: FileManager = .default) -> URL? {
        guard vault(containing: note, fileManager: fileManager) != nil else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?")
        return note.path.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: "obsidian://open?path=" + $0) }
    }
}

/// The two native panels the memory note's buttons open: Choose… (a file panel) and Open (the user's editor). They sit behind this
/// value so a test replaces them; no test runs a panel or the workspace.
struct RemoraNoteActions {
    /// Shows the file panel; the chosen note file, or nil when the panel was cancelled.
    var choose: @MainActor () -> URL?
    /// Opens the note: in Obsidian when it sits in a vault and Obsidian is installed, else in the app that opens the file.
    var open: @MainActor (URL) -> Void
}
