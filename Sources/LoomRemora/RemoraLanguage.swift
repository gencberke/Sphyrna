import Foundation
import NaturalLanguage

/// The language of the user's last question, for a brief whose language is not set (design/DESIGN.md §20: "the language of
/// your last question unless set"). The question comes from the journal's newest question line, which survives a relaunch with
/// no file of its own. NaturalLanguage is used only here, and this runs only when a brief does.
enum RemoraLanguage {
    /// A guess below this confidence is no guess.
    static let minimumConfidence = 0.6
    /// A question with fewer letters than this says too little to tell.
    static let minimumLetters = 8

    /// A BCP-47 code (`tr`, `en`, `zh-Hans`) when `text` is reliably one language; nil otherwise.
    static func detect(_ text: String) -> String? {
        guard text.filter(\.isLetter).count >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined,
              recognizer.languageHypotheses(withMaximum: 1)[language, default: 0] >= minimumConfidence else { return nil }
        return language.rawValue
    }

    /// The language of the newest question line in the journal; nil when there is none or its language is not clear.
    static func ofLastQuestion(in memory: RemoraMemory) async -> String? {
        for day in await memory.journalDays().reversed() {
            let entries = await memory.journal(on: day)
            if let question = entries.last(where: { $0.kind == .question && !($0.question ?? "").isEmpty })?.question {
                return detect(question)
            }
        }
        return nil
    }
}
