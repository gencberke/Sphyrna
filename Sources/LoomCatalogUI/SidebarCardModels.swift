import Foundation
import LoomCore
import SwiftUI

/// The known main model for each listed session, for the sidebar's cards. Two sources, both read off the main actor:
/// the catalog's stored model (`sessions.model`: the launch choice or the last live change, an alias or a release id) and the
/// usage index's latest main-thread message. The model and accessibility leaves read this, so a change redraws those leaves
/// and no card body.
@MainActor @Observable
final class SidebarCardModels {
    enum Provenance: String {
        case stored = "stored model"
        case reported = "reported model"
    }

    struct Presentation: Equatable {
        let name: String
        let provenance: Provenance
    }

    private(set) var stored: [UUID: String] = [:]
    private(set) var reported: [UUID: String] = [:]

    /// The model a card names: the stored model when it is a release id, else what the latest main-thread message ran on, else
    /// the launch alias. `default` says nothing about the model, so it names none.
    static func selection(stored: String?, reported: String?) -> (value: String, provenance: Provenance)? {
        let stored = stored.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
        let reported = reported.flatMap { $0.isEmpty || $0 == "default" ? nil : $0 }
        if let stored, stored.hasPrefix("claude-") { return (stored, .stored) }
        if let reported { return (reported, .reported) }
        return stored.map { ($0, .stored) }
    }

    /// Only a Claude release ID names a version. An alias remains an alias: the current catalogue's resolved release is
    /// not proof of what an earlier session ran. Other harnesses' IDs are kept as recorded.
    static func fullName(of source: String, provider: ManagedSession.Provider) -> String {
        guard let kind = HarnessTranscriptKind(provider: provider), case .claude = kind else { return source }
        return ModelCatalog.prettyClaudeID(source) ?? ModelCatalog.claudeTitle(of: source)
    }

    func presentation(of id: UUID, provider: ManagedSession.Provider) -> Presentation? {
        Self.selection(stored: stored[id], reported: reported[id]).map {
            Presentation(name: Self.fullName(of: $0.value, provider: provider), provenance: $0.provenance)
        }
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
            // latestMainModels is the Claude index, not a cross-harness index.
            // Native IDs from other formats can coincide with Claude's IDs.
            guard let kind = HarnessTranscriptKind(provider: record.session.provider), case .claude = kind,
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

/// A card's model, after the harness's mark: a leaf view, so a new reading redraws the label and not the card body.
struct CardModelLabel: View {
    let row: SessionRowModel
    let model: CatalogModel
    var markSize: CGFloat = LoomTheme.Sidebar.cardMarkSide
    var body: some View {
        let provider = row.record.session.provider
        let presentation = model.cardModels.presentation(of: row.id, provider: provider)
        HStack(spacing: LoomTheme.Sidebar.cardMarkGap) {
            HarnessMark(provider: provider, size: markSize)
            if let presentation {
                Text(presentation.name).font(LoomTheme.Sidebar.metaFont).lineLimit(1).truncationMode(.tail)
            }
        }
        .help(presentation.map { "\(ProviderName.title(provider)) · \($0.name) · \($0.provenance.rawValue)" }
              ?? ProviderName.title(provider))
    }
}
