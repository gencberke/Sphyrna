import AppKit
import LoomChat
import LoomCore
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport

/// What both halves of `ChatInkStreamTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ChatInkStreamShared {
    typealias Chat = LoomTheme.Chat
}

/// `ChatInkStreamTests`'s fixtures, for both halves of the suite.
@MainActor protocol ChatInkStreamFixtures {}

extension ChatInkStreamFixtures {
    typealias Chat = ChatInkStreamShared.Chat

    func measured(_ row: ChatRow, width: CGFloat = 900, context: ChatRowContext = ChatRowContext()) -> CGFloat {
        ChatRowMeasurer(context: context).height(of: row, width: width)
    }
}
