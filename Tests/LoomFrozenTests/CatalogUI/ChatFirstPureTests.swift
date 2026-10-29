import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
@testable import LoomCatalogUITestRigs

// V19 pieces that need no process: the one reason wording, the one banner, the face-aware keys, the sidebar's New session
// row.

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ChatFirstPureTests {
    // MARK: The banner

    @Test func thePolicySignalAndWireDriftAreOneBannerWithTheRestBehindAPlus() {
        func items(policy: Bool = false, drift: Int = 0, records: Int = 0, canContinue: Bool = true) -> [ChatBannerItem] {
            ChatBanners.items(policySignal: policy, policyDismissed: false, canContinueInTerminal: canContinue,
                              wireDrift: drift, wireDriftDismissed: false, unknownRecords: records, recordsDismissed: false)
        }
        #expect(items().isEmpty)
        let both = items(policy: true, drift: 2, records: 1)
        // The blocker comes first, then the notices; the view shows the first and "+2" for the others.
        #expect(both.map(\.kind) == [.policy, .wireDrift, .unknownRecords])
        #expect(both[0].actionTitle == "Switch to Terminal")
        #expect(both[1].actionTitle == nil)
        // Without the way to move the session the policy banner only informs.
        let stuck = ChatBanners.items(policySignal: true, policyDismissed: false, canContinueInTerminal: false, owner: .terminal,
                                      wireDrift: 0, wireDriftDismissed: false, unknownRecords: 0, recordsDismissed: false)
        #expect(stuck[0].actionTitle == nil && stuck[0].message.contains("The terminal still runs this session."))
        // M5: a Chat-owned session never says the terminal runs it.
        let chatOwned = items(policy: true, canContinue: false)
        #expect(chatOwned[0].actionTitle == nil && !chatOwned[0].message.contains("terminal still runs"))
        // A dismissed one stays gone.
        let dismissed = ChatBanners.items(policySignal: true, policyDismissed: true, canContinueInTerminal: true,
                                          wireDrift: 1, wireDriftDismissed: false, unknownRecords: 0, recordsDismissed: false)
        #expect(dismissed.map(\.kind) == [.wireDrift])
    }

    @Test func policyBannerExplainsWhyTerminalHandoverIsBlocked() {
        let preferences = UIPreferencesStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("banner-\(UUID()).json"))
        let model = CatalogModel(catalog: nil, events: SessionEventHub(), preferences: preferences)
        let record = CatalogSession(
            session: ManagedSession(provider: .claude, providerConversationID: "fixture", workingDirectory: "/tmp"),
            title: nil, createdAt: Date(), lastUsedAt: Date(), lifecycle: .idle, pinned: false)
        let row = SessionRowModel(record: record, live: nil)
        let connections = HarnessConnections(choices: [.claude: false])
        model.harnessConnections = connections
        for missing in [false, true] {
            if missing {
                connections.setOn(.claude, true)
                model.harnessAvailability = [.claude: HarnessAvailability(id: .claude, state: .notFound)]
            }
            let reason = model.continueUnavailableReason(in: .terminal, row: row) ?? "missing reason"
            let items = ChatBanners.items(policySignal: true, policyDismissed: false,
                                          canContinueInTerminal: model.canContinue(in: .terminal, row: row),
                                          continueUnavailableReason: reason, wireDrift: 0, wireDriftDismissed: false, unknownRecords: 0, recordsDismissed: false)
            #expect(items.first?.actionTitle == nil)
            #expect(items.first?.message.contains(reason) == true)
            #expect(items.first?.lineLimit == nil, "the explanation can wrap without being cut off")
        }
    }

    // MARK: Face-aware keys

    @Test func onlyAPrintableKeyTypedInTheStreamGoesToTheComposer() {
        #expect(ChatTableView.printable("a") == "a")
        #expect(ChatTableView.printable("é") == "é")
        #expect(ChatTableView.printable("?") == "?")
        #expect(ChatTableView.printable(" ") == nil, "Space scrolls")
        #expect(ChatTableView.printable("\r") == nil)
        #expect(ChatTableView.printable("\u{1B}") == nil)
        #expect(ChatTableView.printable("\u{F700}") == nil, "an arrow key carries a private-use character")
        #expect(ChatTableView.printable("") == nil)
    }

    /// M7: Option and Shift make characters on other layouts (`@`, `[`, `{`, `|`); the stream gives the event itself to the
    /// composer (so the input method sees it), and ⌘ or ⌃ stay shortcuts.
    @Test func anOptionCharacterTypedInTheStreamReachesTheComposerAsTheEvent() throws {
        let table = ChatTableView()
        let controller = ChatStreamController(context: ChatRowContext())
        table.controller = controller
        var taken: [String] = []
        controller.onTypeToFocus = { taken.append($0.characters ?? "") }
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                          context: nil, characters: characters, charactersIgnoringModifiers: "q",
                                          isARepeat: false, keyCode: 12))
        }
        for characters in ["@", "[", "{", "|", "a"] { table.keyDown(with: try key(characters, [.option])) }
        #expect(taken == ["@", "[", "{", "|", "a"])
        table.keyDown(with: try key("a", [.command]))
        table.keyDown(with: try key("\u{F700}", []))
        #expect(taken.count == 5, "a shortcut or an arrow key is not typing")
    }
}
