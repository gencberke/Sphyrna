import Foundation
import LoomChat
import LoomCore

/// The pinned cards of a live Chat session, as development evidence and the app's own calls reach them (V18). Every
/// action is what a click on the card does: it goes through the card's model, which answers only on this call.
extension CatalogModel {
    /// The cards of the session whose driver lives (made with its live stream).
    func pinnedCards(for sessionID: UUID) -> PinnedCardsModel? {
        guard let driver = chatSessions?.existingDriver(for: sessionID) else { return nil }
        let feed: LiveChatFeed? = chatAttachments.existingAttachment(for: driver)
        return feed?.cards
    }

    /// Counts and kinds of the cards, never their text (evidence).
    public func pinnedCardsSummary(_ sessionID: UUID) -> [String: Any] {
        guard let cards = pinnedCards(for: sessionID) else { return ["cards": false] }
        var summary = cards.summary
        summary["cards"] = true
        return summary
    }

    /// One card action, as a click or a key on the card does it: `allow-once`, `allow-session`, `deny[:note]`,
    /// `deny-stop[:note]`, `approve-plan:<mode>`, `keep-planning[:feedback]`, `pick:<n>`, `next`, `back`, `submit`,
    /// `step:<+1|-1>`, `note:<text>`, `resume`, `open-held`, `expire-folded`. Returns false when there is no such card or action.
    @discardableResult
    public func pinnedCardAction(_ sessionID: UUID, _ command: String) async -> Bool {
        guard let cards = pinnedCards(for: sessionID) else { return false }
        let parts = command.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "resume": await cards.resume()
        case "open-held": cards.openHeld()
        case "expire-folded": cards.expireFolded()
        case "step": cards.step(Int(argument) ?? 1)
        case "note":
            // As typing it into the composer does: the composer holds the text and the cards read it.
            if let composer = composer(of: sessionID) {
                composer.setText("")
                composer.typeForEvidence(argument)
            } else {
                cards.note.set(argument)
                cards.noteEdited()
            }
        default:
            guard let request = cards.current else { return false }
            switch parts[0] {
            case "allow-once": await cards.allowOnce(request)
            case "allow-session": await cards.allowForSession(request)
            case "deny", "deny-stop", "keep-planning":
                if !argument.isEmpty { cards.note.set(argument) }
                switch parts[0] {
                case "deny": await cards.deny(request)
                case "deny-stop": await cards.denyAndStop(request)
                default: await cards.keepPlanning(request)
                }
            case "approve-plan":
                cards.setPlanMode(argument.isEmpty ? "default" : argument, for: request)
                await cards.approvePlan(request)
            case "pick": cards.pick(option: (Int(argument) ?? 1) - 1, in: request)
            case "next": cards.next(in: request)
            case "back": cards.back(in: request)
            case "submit": await cards.submit(request)
            default: return false
            }
        }
        return true
    }
}
