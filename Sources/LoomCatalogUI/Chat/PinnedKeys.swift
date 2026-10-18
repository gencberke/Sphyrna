import Foundation
import LoomChat

/// What a key does while a pinned card has the keyboard (CHAT-SPEC → Requests → Keys).
///
/// - ← and → move between the card's buttons, Space presses the focused one, digits 1–9 pick a question's options, and Tab
///   (with or without ⇧) gives the keyboard back to the composer.
/// - **Return never approves and Esc never denies**: neither key maps to anything here, so no key sequence reaches an
///   answer except Space on a button the user moved to, and a digit on a question's option (which only picks; Submit is a
///   button).
enum PinnedKey: Equatable {
    case left
    case right
    case space
    case digit(Int)
    case tab
    case returnKey
    case escape
    case other
}

enum PinnedKeyAction: Equatable {
    /// Moves the focus ring to the previous (-1) or next (+1) button.
    case moveFocus(Int)
    /// Presses the focused button.
    case pressFocused
    /// Picks the option with this 1-based number.
    case pickOption(Int)
    /// The keyboard goes back to the composer.
    case returnToComposer
}

enum PinnedKeys {
    static func action(for key: PinnedKey, kind: ChatPendingRequest.Kind?) -> PinnedKeyAction? {
        switch key {
        case .left: .moveFocus(-1)
        case .right: .moveFocus(1)
        case .space: .pressFocused
        case let .digit(number): kind == .question && (1...9).contains(number) ? .pickOption(number) : nil
        case .tab: .returnToComposer
        case .returnKey, .escape, .other: nil
        }
    }
}
