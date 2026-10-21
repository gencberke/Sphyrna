import LoomCore

/// The live-session issue that rides the top banner stack (DESIGN §19 Banners): a failure box with no ×, present exactly while
/// the issue is (for example the hook watchdog's "Loom is not receiving events from Claude…"). Without it the person sees only
/// the "Problem" label on the card; the text otherwise shows only on the record, which a live session does not have. The stack
/// (`Banners`) draws it on the terminal and chat routes, so unrelated state changes neither redraw nor re-fade it.
enum SessionIssueNotice {
    /// The text to show for a live state, nil when it has no issue.
    nonisolated static func message(for live: SessionViewState?) -> String? {
        guard let issue = live?.issue, !issue.isEmpty else { return nil }
        return issue
    }
}
