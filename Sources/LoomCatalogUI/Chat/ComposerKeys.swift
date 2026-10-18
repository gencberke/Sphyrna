import AppKit

/// The composer's key rules (CHAT-SPEC → Composer → Keys and Menus), as one pure function: a key code, the modifiers and
/// the state the composer is in go in, what the composer does comes out. The text view only asks and obeys, so every
/// rule is tested without a window.
///
/// Every key is matched by its key code, never by the character it types: the characters depend on the keyboard layout
/// (on a Turkish Q keyboard `/` needs ⇧ and `@` needs ⌥), the key codes do not. Menus open from the characters that are
/// inserted (`ComposerTrigger`), so they open on any layout; the shortcuts below are letters, which sit on the same
/// keys on a Turkish Q keyboard.
enum ComposerKeys {
    // Key codes (Carbon `kVK_*`; positions, the same on every layout).
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let upArrow: UInt16 = 126
    static let downArrow: UInt16 = 125
    static let letterV: UInt16 = 9
    static let letterA: UInt16 = 0
    static let letterM: UInt16 = 46
    static let letterK: UInt16 = 40

    /// The modifiers that count; caps lock, the numeric-pad and function flags do not.
    static let relevantModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]

    enum Mode: Equatable {
        /// The session's own composer.
        case live
        /// The new-session draft's composer: ↵ starts the session, ⌘↵ starts it and opens a fresh draft.
        case draft
    }

    /// What the composer is doing when a key arrives.
    struct State: Equatable {
        var mode = Mode.live
        /// A turn runs (Claude works).
        var working = false
        /// A request (card) waits for the user: Esc then does nothing.
        var cardWaiting = false
        /// A card is on screen (not held by the typing guard) and takes the composer's text with its answer: ↵ then neither
        /// answers it nor sends the text, and Tab moves to it.
        var cardShown = false
        var menuOpen = false
        /// A queued message is being edited (Esc cancels the edit).
        var editingQueued = false
        /// An input method composes text (`hasMarkedText`): no key sends then.
        var hasMarkedText = false
        var isRepeat = false
        /// Nothing typed and nothing attached.
        var isEmpty = true
        /// The caret has no selection, and sits on the first / last line of the text.
        var caretOnFirstLine = true
        var caretOnLastLine = true
        var hasSelection = false
        /// The text is a recall that was not edited since (so ↑ and ↓ keep walking the history).
        var holdsUneditedRecall = false
        /// A recall is under way (↓ walks forward only then).
        var recalling = false
        /// There are earlier messages to recall.
        var hasHistory = false

        init() {}
    }

    /// What a key press means for the composer.
    enum Action: Hashable {
        /// ↵: send now (idle: send; working: `next`). In the draft: start the session.
        case send
        /// ⌘↵: send; while Claude works, after this turn. In the draft: start and open a fresh draft.
        case sendSecondary
        case newline
        case interrupt
        case closeMenu
        case cancelEdit
        case menuMove(Int)
        case menuInsert
        /// Tab with a card shown: the keyboard goes to the card.
        case focusCard
        case recallOlder
        case recallNewer
        case pastePlain
        case openMenu(MenuRequest)
        /// The key is taken and does nothing (Esc while a card waits, a held ↵).
        case ignore
        /// The text view handles the key as it would.
        case passThrough
    }

    enum MenuRequest: Hashable {
        case attach
        case mention
        case commands
    }

    /// The meaning of a key down.
    static func resolve(keyCode: UInt16, modifiers rawModifiers: NSEvent.ModifierFlags, state: State) -> Action {
        let modifiers = rawModifiers.intersection(relevantModifiers)
        switch keyCode {
        case returnKey, keypadEnter:
            // An input method that composes owns Return: it commits the composition.
            guard !state.hasMarkedText else { return .passThrough }
            switch modifiers {
            case []:
                if state.isRepeat { return .ignore }
                if state.menuOpen { return .menuInsert }
                // With a card shown ↵ does nothing: it never answers the card and never sends the card's text.
                return state.cardShown ? .ignore : .send
            case [.command]:
                return state.isRepeat || state.cardShown ? .ignore : .sendSecondary
            case [.shift], [.option]:
                return .newline
            default:
                return .passThrough
            }
        case tab:
            guard modifiers.isEmpty, !state.hasMarkedText else { return .passThrough }
            if state.menuOpen { return .menuInsert }
            return state.cardShown && state.mode == .live ? .focusCard : .passThrough
        case escape:
            guard !state.hasMarkedText else { return .passThrough }
            guard modifiers.isEmpty else { return .passThrough }
            if state.menuOpen { return .closeMenu }
            if state.editingQueued { return .cancelEdit }
            // The draft has nothing to interrupt, and an idle composer has none either: Esc does nothing there (and the text
            // view must not open its completion popup).
            if state.mode == .draft { return .ignore }
            // Esc interrupts only when Claude works and no card waits; with a card waiting it does nothing, and it never
            // denies anything.
            if state.cardWaiting { return .ignore }
            return state.working ? .interrupt : .ignore
        case upArrow:
            guard modifiers.isEmpty, !state.hasMarkedText else { return .passThrough }
            if state.menuOpen { return .menuMove(-1) }
            return state.hasHistory && !state.hasSelection && state.caretOnFirstLine
                && (state.isEmpty || state.holdsUneditedRecall) ? .recallOlder : .passThrough
        case downArrow:
            guard modifiers.isEmpty, !state.hasMarkedText else { return .passThrough }
            if state.menuOpen { return .menuMove(1) }
            return state.recalling && state.holdsUneditedRecall && !state.hasSelection && state.caretOnLastLine
                ? .recallNewer : .passThrough
        case letterV where modifiers == [.command, .shift]:
            return .pastePlain
        case letterA where modifiers == [.command, .shift]:
            return state.mode == .live ? .openMenu(.attach) : .passThrough
        case letterM where modifiers == [.command, .shift]:
            return state.mode == .live ? .openMenu(.mention) : .passThrough
        case letterK where modifiers == [.command, .shift]:
            return state.mode == .live ? .openMenu(.commands) : .passThrough
        default:
            return .passThrough
        }
    }

    // MARK: Shortcut labels

    /// The shortcut each item of the + menu shows (they are matched by key code in `resolve`).
    static let attachShortcut = "\u{21E7}\u{2318}A"
    static let mentionShortcut = "\u{21E7}\u{2318}M"
    static let commandsShortcut = "\u{21E7}\u{2318}K"
}
