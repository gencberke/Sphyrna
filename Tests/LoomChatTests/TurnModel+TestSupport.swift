@testable import LoomChat

extension TurnModel {
    /// Every message that has not been read (nor cancelled) yet, from the whole model. The app reads the driver's unread rows
    /// instead (`ChatComposerState.unreadMessageIDs`); tests check delivery states with this.
    var pendingUserMessageIDs: [String] {
        entries.compactMap { entry in
            if case let .user(prompt) = entry.body, prompt.delivery == .pending || prompt.delivery == .queued { entry.id } else { nil }
        }
    }
}
