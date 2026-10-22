import Foundation
import LoomCore
import LoomRemora

/// ⌘K's door to Remora (DESIGN §20 "⌘K"; SPEC §10.5): when what is typed reads as a question, Ask Remora heads the palette with its
/// scope, ⇥ and ↵. The rules here are plain values; the palette's state (`PaletteState`) keeps the scope and the question asked, and
/// the one call is in `PaletteRemoraCalls` (`RemoraReachTests` counts it). Nothing is called while typing.

// MARK: Reads as a question

/// Whether the palette's text reads as a question: no model, only the text. It does when it ends in a question mark (`?`, `？`, `؟`)
/// or a Japanese, Chinese or Korean question ending; when it holds a Chinese, Japanese or Korean question word; when a Turkish
/// question particle (mi, mı, mu, mü and their forms) follows its first word; or when it has at least three words and starts with an
/// interrogative of a language Remora writes in (English, German, French, Spanish, Italian, Portuguese, Dutch, Turkish), compared
/// without case or accents. A search term ("login flow", "token rotation") does not, nor does a lone word.
enum PaletteRemoraQuestion {
    static let marks: Set<Character> = ["?", "？", "؟"]
    /// A Japanese か, a Chinese 吗 or 呢, a Korean 까 at the end.
    static let endings: Set<Character> = ["か", "吗", "呢", "까"]
    static let questionWords = ["什么", "为什么", "怎么", "哪个", "なぜ", "どうして", "どこ", "いつ", "무엇", "어떻게", "언제", "어디"]
    static let minimumWords = 3

    /// First words (or first two), folded: lowercase, accents off.
    static let interrogatives: Set<String> = [
        // English
        "what", "which", "who", "whom", "whose", "why", "how", "when", "where", "is", "are", "was", "were", "did", "does", "has",
        "have", "had", "can", "could", "should", "would", "will",
        // German
        "wer", "wie", "wo", "warum", "wann", "welche", "welcher", "welches", "wieso", "weshalb", "woher", "wohin", "ist", "sind",
        "gibt", "kann", "hat",
        // French
        "que", "quoi", "qui", "quel", "quelle", "quels", "quelles", "pourquoi", "comment", "quand", "ou", "combien", "est-ce",
        // Spanish
        "quien", "quienes", "cual", "cuales", "como", "cuando", "donde", "cuanto", "cuantos", "por que",
        // Italian
        "cosa", "chi", "quale", "quali", "perche", "come", "dove", "quanti", "che cosa",
        // Portuguese
        "quem", "qual", "quais", "onde", "o que",
        // Dutch
        "wat", "wie", "welke", "welk", "waarom", "hoe", "wanneer", "waar", "hoeveel", "zijn", "heeft",
        // Turkish
        "ne", "neden", "nasıl", "nasil", "hangi", "kim", "nerede", "kac", "niye", "nicin", "ne zaman",
    ]
    /// Turkish question particles, a word of their own after the first.
    static let particles: Set<String> = ["mi", "mı", "mu", "misin", "mısın", "musun", "midir", "mıdır", "mudur", "miyim", "mıyım"]

    static func readsAsQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, trimmed.count > 1 else { return false }
        if marks.contains(last) || endings.contains(last) { return true }
        if questionWords.contains(where: { trimmed.contains($0) }) { return true }
        let words = trimmed.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }.filter { !$0.isEmpty }
        if words.count >= 2, words.dropFirst().contains(where: particles.contains) { return true }
        guard words.count >= minimumWords else { return false }
        return interrogatives.contains(words[0]) || interrogatives.contains(words[0] + " " + words[1])
    }

    /// Lowercase, accents off (the Turkish dotless ı stays itself), the punctuation around a word off.
    static func fold(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-")))
    }
}

// MARK: The scope

/// One scope ⇥ can land on.
enum PaletteRemoraScopeChoice: Equatable {
    case allProjects
    case project(UUID, name: String)
    case session(UUID)

    var scope: RemoraScope {
        switch self {
        case .allProjects: .allProjects
        case .project(let id, _): .project(id)
        case .session(let id): .session(id)
        }
    }

    /// "All projects", the project's name, "This session".
    var label: String {
        switch self {
        case .allProjects: "All projects"
        case .project(_, let name): name
        case .session: "This session"
        }
    }

    /// The evidence's word for it.
    var kind: String {
        switch self {
        case .allProjects: "all"
        case .project: "project"
        case .session: "session"
        }
    }
}

/// Where the palette was opened from, as the scope needs it.
struct PaletteRemoraPlace: Equatable {
    var project: (id: UUID, name: String)?
    var session: UUID?
    /// The session runs in Chat: the quick question (§15) asks Claude with the whole session in view, so Remora does not offer it.
    var sessionRunsInChat = false

    static func == (left: Self, right: Self) -> Bool {
        left.project?.id == right.project?.id && left.project?.name == right.project?.name && left.session == right.session
            && left.sessionRunsInChat == right.sessionRunsInChat
    }
}

enum PaletteRemoraScope {
    /// All projects first; ⇥ narrows to this project, then this session. This session only for an ended or terminal session; an
    /// excluded project is never offered, nor is a session in it (Remora never reads it).
    static func choices(_ place: PaletteRemoraPlace, excluded: Set<UUID>) -> [PaletteRemoraScopeChoice] {
        var choices: [PaletteRemoraScopeChoice] = [.allProjects]
        let projectExcluded = place.project.map { excluded.contains($0.id) } ?? false
        if let project = place.project, !projectExcluded { choices.append(.project(project.id, name: project.name)) }
        if let session = place.session, !place.sessionRunsInChat, !projectExcluded { choices.append(.session(session)) }
        return choices
    }

    /// ⇥: the next choice, back to the first after the last.
    static func next(after index: Int, count: Int) -> Int { count > 0 ? (index + 1) % count : 0 }
}

// MARK: Keys

/// What a key does while Ask Remora is offered or its answer shows. `passThrough` leaves the key to the palette as it was.
enum PaletteRemoraKeys {
    enum Key: Equatable { case tab, `return`, commandReturn, escape, arrow }

    enum Stage: Equatable {
        /// The list: whether Ask Remora is offered, is the selected row, and whether Remora is busy with another call.
        case typing(offered: Bool, askSelected: Bool, busy: Bool)
        /// The answer: whether its call still runs and whether it names a session.
        case answer(inFlight: Bool, hasChip: Bool)
    }

    enum Action: Equatable {
        case passThrough
        case nothing
        case cycleScope
        case ask
        case openFirstChip
        case openOnHome
        case stopAndClose
        case close
    }

    static func resolve(_ key: Key, _ stage: Stage) -> Action {
        switch stage {
        case .typing(let offered, let askSelected, let busy):
            switch key {
            case .tab: return offered ? .cycleScope : .passThrough
            case .return: return askSelected ? (busy ? .nothing : .ask) : .passThrough
            case .commandReturn: return askSelected ? .nothing : .passThrough
            case .escape, .arrow: return .passThrough
            }
        case .answer(let inFlight, let hasChip):
            switch key {
            case .tab, .arrow: return .nothing
            case .return: return hasChip ? .openFirstChip : .nothing
            case .commandReturn: return inFlight ? .nothing : .openOnHome
            case .escape: return inFlight ? .stopAndClose : .close
            }
        }
    }
}

// MARK: Texts

enum PaletteRemoraText {
    static let header = "Remora"
    static let ask = "Ask Remora"
    static let busy = "Remora is answering something else"
    static let openChip = "open the session"
    static let openOnHome = "open on Home"
}

// MARK: The call

/// The palette's one call into the model's Remora API (`RemoraReachTests` counts it): ↵ on Ask Remora.
@MainActor
enum PaletteRemoraCalls {
    @discardableResult
    static func ask(_ model: CatalogModel, _ question: String, scope: RemoraScope) -> Bool {
        model.askRemora(question, scope: scope, door: .palette)
    }
}

// MARK: Where the palette opened

extension CatalogModel {
    /// Remora is on and has its host: the palette may offer Ask Remora.
    var paletteOffersRemora: Bool { remora.preferences.isOn && hasRemora }

    /// The project and the session the palette was opened over, for the scope.
    var paletteRemoraPlace: PaletteRemoraPlace {
        switch destination {
        case .session(let id)?:
            guard !isDeleting(id) else { return PaletteRemoraPlace() }
            let row = rowModels[id]
            guard let record = row?.record ?? liveRecords[id], !record.isSideChat else { return PaletteRemoraPlace() }
            let project = record.projectID.map { ($0, projectName(for: record) ?? "This project") }
            let runsInChat = row.map { isRunning($0) && owningFace(of: $0) == .chat } ?? false
            return PaletteRemoraPlace(project: project, session: id, sessionRunsInChat: runsInChat)
        case .projectPage(let id)?, .draft(projectID: let id?)?:
            let name = projects.first { $0.id == id }?.name ?? "This project"
            return PaletteRemoraPlace(project: (id, name))
        default:
            return PaletteRemoraPlace()
        }
    }
}
