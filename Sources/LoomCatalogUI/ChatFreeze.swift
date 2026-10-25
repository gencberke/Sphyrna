import Foundation

/// D-100: the Chat face is frozen. Sphyrna is terminal-first; the Chat code stays in the tree, unreachable in the product.
///
/// The one switch. While `isFrozen` is true:
/// - the app builds no Chat host (`AppDelegate`), so every Claude start, resume and approved opening runs in the terminal
///   (`FacePolicy` without a structured host), and every host-gated surface (the live chat, Quick Question, the Side tab,
///   Rewind, pinned request cards, Changes' Send) is off;
/// - a stopped Claude session never shows a chat and the inspector has no Side tab (`SessionFaces.readOnlyChatEnabled` is false
///   by default);
/// - a stored or missing "Sessions run in" preference reads as Terminal (`UIPreferences`), and Settings hides the switch;
/// - the menus leave out Show Chat, Show Terminal and Ask a Quick Question.
///
/// Un-freezing is setting this to false. Tests that install their own Chat host (`installChatSessions`) and pick the Chat
/// face (`setNewSessionFace(.chat)`, `readOnlyChatEnabled = true`) still exercise the frozen code.
public enum ChatFreeze {
    public static let isFrozen = true

    /// The face a stored preference reads as: Terminal while frozen.
    public static func readFace(_ stored: SessionFace?) -> SessionFace {
        isFrozen ? .terminal : stored ?? .chat
    }
}
