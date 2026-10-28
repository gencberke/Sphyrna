import Foundation
import LoomCore
import SwiftUI

// The header's model segment (fix round 3 F, D-69): the model and the context fill of a Claude session on every
// face that has no composer bar. The live chat keeps its bar and gets no second copy (DESIGN §6 Header).

/// What the segment says: the model's short name in the composer bar's wording and, once the usage index holds a reading,
/// a small ring. Before the first reply the model is the one the session was launched with, if one was picked; never a
/// guessed model, and never a share without a window.
struct HeaderModelContent: Equatable {
    /// "Opus 5.5"; nil when the reading names no model and none was picked.
    let name: String?
    /// The latest reading, nil before the first reply.
    let usage: ContextUsage?
    /// The tooltip: the composer's context line and the model id, or what the launch picked.
    let help: String
    let accessibilityLabel: String

    /// Nil when there is nothing to show: no reading and no model picked at launch. `catalog` names an alias (`CatalogModel.modelCatalog`).
    @MainActor init?(usage: ContextUsage?, launchModel: String?, catalog: ModelCatalog) {
        let reported = usage.map(\.model).flatMap { $0.isEmpty ? nil : $0 }
        let launched = Self.launchTitle(launchModel, catalog: catalog)
        let title = reported.map(ComposerBarText.prettyModel) ?? launched
        guard usage != nil || title != nil else { return nil }
        name = title
        self.usage = usage
        if let usage {
            help = [ComposerBarText.contextLine(usage), reported].compactMap { $0 }.joined(separator: "\n")
            accessibilityLabel = [title.map { "Model \($0)" }, ContextRingText.spoken(usage)].compactMap { $0 }
                .joined(separator: ", ")
        } else if let title {
            help = "Model \u{00B7} \(title) (chosen at launch)"
            accessibilityLabel = "Model \(title), chosen at launch"
        } else {
            return nil
        }
    }

    /// The name of the model a session was launched with: nothing for "no choice" and for Default (the CLI then picks one
    /// the session has not reported yet), the composer's wording for an id, the alias's title for an alias.
    @MainActor static func launchTitle(_ chosen: String?, catalog: ModelCatalog) -> String? {
        guard let chosen, !chosen.isEmpty, chosen != "default" else { return nil }
        return chosen.hasPrefix("claude-") ? ComposerBarText.prettyModel(chosen) : catalog.claudeTitle(of: chosen)
    }
}

/// The launch choices of the sessions the header and the inspector have shown: the catalog's `sessions` row is the one
/// source (the UI keeps no copy of its own), read once per run of a shown session. Only the selected session is read, so
/// a change redraws only the views that show it. The model is held apart from the effort and the mode, so the header's
/// segment (which reads the model) does not redraw for the Overview's other two.
@MainActor @Observable
final class SessionLaunchModels {
    private(set) var chosen: [UUID: String] = [:]
    /// The effort and the permission mode a session was launched with (the CLI's words), for the Overview before the run
    /// reports its own.
    private(set) var launched: [UUID: ClaudeLaunchChoices] = [:]
    /// The Claude Code version the runtime's toolchain probe read; nil until a start resolved it.
    private(set) var claudeVersion: String?

    func model(of id: UUID) -> String? { chosen[id] }
    func effort(of id: UUID) -> String? { launched[id]?.effort }
    func permissionMode(of id: UUID) -> String? { launched[id]?.permissionMode }

    func load(_ id: UUID, from catalog: SessionCatalog?) async {
        guard let catalog, let choices = try? await catalog.launchChoices(sessionID: id) else { return }
        if chosen[id] != choices.model { chosen[id] = choices.model }
        let own = ClaudeLaunchChoices(permissionMode: choices.permissionMode, effort: choices.effort)
        if launched[id] != own { launched[id] = own }
    }

    func loadClaudeVersion(from intents: (any ConversationIntents)?) async {
        let version = await intents?.toolchainVersion(provider: .claude)
        if claudeVersion != version { claudeVersion = version }
    }
}

extension CatalogModel {
    /// Whether the header carries the model segment for a session: one whose context use Loom reads, on a face without the
    /// composer bar. A live Chat run, and a stopped session the Chat face owns, have the bar (its model chip and ring).
    func headerShowsModelSegment(_ row: SessionRowModel) -> Bool {
        capabilities(of: row.record.session.provider).readsContext && runEndpoint(of: row) != .pipe && !showsStoppedLiveChat(row)
    }

    /// What the segment and the inspector's Model fact say for a session, from the one source: the usage index's reading,
    /// else the launch choice. Reads only this session's entries.
    func modelContent(of record: CatalogSession) -> HeaderModelContent? {
        guard capabilities(of: record.session.provider).readsContext else { return nil }
        let reading = record.session.providerConversationID.flatMap { usage?.contexts[$0] }
        return HeaderModelContent(usage: reading, launchModel: launchModels.model(of: record.session.id), catalog: modelCatalog)
    }
}

/// Reads a shown session's launch model again whenever its run changes.
private struct LoadsLaunchModel: ViewModifier {
    let model: CatalogModel
    let row: SessionRowModel

    private struct Key: Equatable {
        let id: UUID
        let run: UUID?
    }

    func body(content: Content) -> some View {
        content.task(id: Key(id: row.id, run: row.live?.runID)) {
            await model.launchModels.load(row.id, from: model.catalog)
        }
    }
}

extension View {
    func loadsLaunchModel(_ model: CatalogModel, row: SessionRowModel) -> some View {
        modifier(LoadsLaunchModel(model: model, row: row))
    }
}

/// Counts how often the header row and its model segment evaluate their `body`, for the sessions a test watches (none in
/// every normal run: one emptiness check per evaluation). A reading redraws the segment and never the row.
@MainActor
enum HeaderRenderProbe {
    static var watched: Set<UUID> = []
    private(set) static var rowBodies = 0
    private(set) static var segmentBodies = 0

    static func row(_ id: UUID) {
        guard !watched.isEmpty, watched.contains(id) else { return }
        rowBodies += 1
    }

    static func segment(_ id: UUID) {
        guard !watched.isEmpty, watched.contains(id) else { return }
        segmentBodies += 1
    }

    static func watch(_ ids: Set<UUID>) {
        watched = ids
        rowBodies = 0
        segmentBodies = 0
    }
}

/// The segment: a small ring (a token count while the window is not known), then the model's name. Its own view, so a
/// reading redraws this and not the row. It takes the room the chip's branch would otherwise want only after the title
/// has given way: narrower than its full form it draws nothing (`HeaderFlowPlan`).
struct HeaderModelSegment: View {
    let model: CatalogModel
    let row: SessionRowModel

    var body: some View {
        let _ = HeaderRenderProbe.segment(row.id)
        let content = model.modelContent(of: row.record)
        ViewThatFits(in: .horizontal) {
            if let content { segment(content) }
            Color.clear.frame(width: 0, height: 0)
        }
        .loadsLaunchModel(model, row: row)
    }

    private func segment(_ content: HeaderModelContent) -> some View {
        HStack(spacing: LoomTheme.Header.modelGap) {
            ProviderIcon(provider: row.record.session.provider, size: LoomTheme.Layout.harnessMarkRow)
            if let usage = content.usage { HeaderContextMark(usage: usage) }
            if let name = content.name {
                Text(name).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.secondary).lineLimit(1)
            }
        }
        .fixedSize()
        .frame(height: LoomTheme.Header.chipHeight)
        .help(content.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabel)
        .accessibilityIdentifier("header-model")
    }
}

/// The composer ring's picture without its button: the arc where the window is known (red from the composer's threshold),
/// a short count where it is not.
struct HeaderContextMark: View {
    let usage: ContextUsage

    var body: some View {
        if usage.window == nil {
            Text(UsageFormat.tokens(usage.tokens)).font(LoomTheme.Typography.statusLabel).monospacedDigit()
                .foregroundStyle(LoomTheme.Text.secondary)
        } else {
            let fraction = usage.fraction
            ZStack {
                Circle().stroke(LoomTheme.ContextRing.track, lineWidth: LoomTheme.ContextRing.lineWidth)
                if let fraction, fraction > 0 {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(fraction >= LoomTheme.Composer.ringRed ? LoomTheme.Status.failure : LoomTheme.ContextRing.arc,
                                style: StrokeStyle(lineWidth: LoomTheme.ContextRing.lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
            .padding(LoomTheme.ContextRing.lineWidth / 2)
            .frame(width: LoomTheme.ContextRing.diameter, height: LoomTheme.ContextRing.diameter)
        }
    }
}
