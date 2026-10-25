import Foundation
import LoomCore
import SwiftUI

/// The main model each listed session runs on, for the sidebar's cards (RESCUE C3). Two sources, both read off the main actor:
/// the catalog's stored model (`sessions.model`: the launch choice or the last live change, an alias or a release id) and the
/// usage index's latest main-thread message. Only the cards' model labels read this, so a change redraws those labels and no
/// card body.
@MainActor @Observable
final class SidebarCardModels {
    private(set) var stored: [UUID: String] = [:]
    private(set) var reported: [UUID: String] = [:]

    /// The model a card names: the stored model when it is a release id, else what the latest main-thread message ran on, else
    /// the launch alias. `default` says nothing about the model, so it names none.
    static func source(stored: String?, reported: String?) -> String? {
        let stored = stored.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
        if let stored, stored.hasPrefix("claude-") { return stored }
        if let reported, !reported.isEmpty { return reported }
        return stored
    }

    /// The full name a card shows ("Opus 5.5"): a Claude release id spelled out, a Claude alias by what the probe said it
    /// resolves to. Any other harness's name is neither, so it shows as it is (as in the header's `launchTitle`).
    static func fullName(of source: String) -> String {
        ModelCatalog.prettyClaudeID(source) ?? ModelCatalog.shared.claudeTitle(of: source)
    }

    func name(of id: UUID) -> String? {
        Self.source(stored: stored[id], reported: reported[id]).map(Self.fullName(of:))
    }

    /// Replaces both maps, each only when it changed, so a read that finds the same models redraws nothing.
    func publish(stored: [UUID: String], reported: [UUID: String]) {
        if self.stored != stored { self.stored = stored }
        if self.reported != reported { self.reported = reported }
    }
}

extension CatalogModel {
    /// Reads the models of the sessions the sidebar holds again, in the background; a newer read replaces one still running.
    func refreshCardModels() {
        let records = rowModels.values.map(\.record)
        let catalog = catalog
        let usage = usage
        let conversations: [(UUID, String)] = records.compactMap { record in
            guard capabilities(of: record.session.provider).readsContext,
                  let conversation = record.session.providerConversationID else { return nil }
            return (record.session.id, conversation)
        }
        cardModelTask?.cancel()
        guard !records.isEmpty else {
            cardModels.publish(stored: [:], reported: [:])
            return
        }
        cardModelTask = Task { [weak self] in
            let stored = (try? await catalog?.launchModels(sessionIDs: records.map(\.session.id))) ?? [:]
            let latest = await usage?.latestMainModels(sessions: conversations.map(\.1)) ?? [:]
            guard !Task.isCancelled, let self else { return }
            var reported: [UUID: String] = [:]
            for (id, conversation) in conversations { reported[id] = latest[conversation] }
            self.cardModels.publish(stored: stored, reported: reported)
        }
    }
}

/// A card's model, after the harness's mark: its own view, the only part of a card that reads the models, so a new reading
/// redraws this label and not the card.
struct CardModelLabel: View {
    let row: SessionRowModel
    let model: CatalogModel
    /// From the mark to the name: the title's column on the top line, the meta gap on the bottom row.
    var spacing: CGFloat = LoomTheme.Sidebar.metaSpacing

    var body: some View {
        let provider = row.record.session.provider
        HStack(spacing: spacing) {
            HarnessMark(provider: provider)
            if let name = model.cardModels.name(of: row.id) {
                Text(name).font(LoomTheme.Sidebar.metaFont).lineLimit(1)
            }
        }
        .help(ProviderName.title(provider))
    }
}
