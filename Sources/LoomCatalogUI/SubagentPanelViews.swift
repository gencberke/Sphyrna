import LoomCore
import SwiftUI

// The pieces around the subagent panel's transcript (FB4-5): the header row that replaces the session's
// while the panel is open, and the notice for an approval that waits in the session's terminal.

/// The header of an open subagent panel: the provider mark, then the crumb "session › agent type · description"
/// (which gives way first), the subagent's state pill, a hairline and the Session control, laid out by
/// `HeaderFlow` like the session's own row. The project chip and Stop are not shown.
struct SubagentHeaderRow: View {
    let model: CatalogModel
    let row: SessionRowModel
    let agentID: String

    /// The subagent as its session's live state lists it; nil for the instant it dropped out.
    private var record: SubagentRecord? { row.live?.subagents.first { $0.id == agentID } }

    var body: some View {
        HStack(spacing: LoomTheme.Space.detailSpacing) {
            ProviderIcon(provider: row.record.session.provider, size: LoomTheme.Layout.providerIconHeader)
            HeaderFlow {
                crumb.headerSlot(.title)
                if let record {
                    let content = SubagentPillContent(record: record, now: model.now)
                    if let style = StatePillStyle(content.indicator, label: content.label) {
                        StatePill(indicator: content.indicator, style: style).headerSlot(.status)
                    }
                }
                HeaderRule().headerSlot(.rule)
                SessionBackControl { model.closeSubagent() }.headerSlot(.group)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var crumb: some View {
        HStack(spacing: LoomTheme.Header.crumbGap) {
            Text(model.title(of: row)).foregroundStyle(LoomTheme.Text.secondaryStyle)
                .fontWeight(.medium).lineLimit(1).truncationMode(.tail)
            Text(verbatim: "›").foregroundStyle(LoomTheme.Text.tertiary).accessibilityHidden(true)
            Image(systemName: "person.crop.circle").font(LoomTheme.Header.crumbGlyph)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).accessibilityHidden(true)
            Text(Self.agentTitle(record)).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// "agent type · description", or the id while the record has not got either yet.
    static func agentTitle(_ record: SubagentRecord?) -> String {
        guard let record else { return "Subagent" }
        let type = record.agentType.isEmpty ? "Subagent" : record.agentType
        return record.description.map { "\(type) · \($0)" } ?? type
    }
}

/// How the subagent's state pill reads: the chase and "Running 4m", or "Finished 7m" without a mark.
/// Claude reports neither success nor failure for a subagent, so there is no failed state to show.
struct SubagentPillContent: Equatable {
    let indicator: SessionIndicator
    let label: String

    init(record: SubagentRecord, now: Date) {
        if let ended = record.endedAt {
            indicator = .idle
            label = "Finished \(SubagentTreeContent.duration(from: record.startedAt, to: ended))"
        } else {
            indicator = .working
            let elapsed = RelativeTime.string(from: record.startedAt, to: now)
            label = elapsed == "now" ? "Running" : "Running \(elapsed)"
        }
    }
}

/// "‹ Session  esc": back to the terminal. Esc does the same.
struct SessionBackControl: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: LoomTheme.Header.backGap) {
                Image(systemName: "chevron.left").accessibilityHidden(true)
                Text("Session").font(LoomTheme.Typography.small)
                Text("esc").font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .padding(.horizontal, LoomTheme.Header.keyCapPadding)
                    .overlay(RoundedRectangle(cornerRadius: LoomTheme.Radius.barSlim)
                        .strokeBorder(LoomTheme.Surface.hairlineStyle, lineWidth: LoomTheme.Line.hairline))
                    .accessibilityHidden(true)
            }
            .padding(.leading, LoomTheme.Header.backLeading).padding(.trailing, LoomTheme.Header.backTrailing)
        }
        .buttonStyle(HeaderSegmentStyle()).focusEffectDisabled()
        .keyboardShortcut(.cancelAction)
        .frame(height: LoomTheme.Header.groupHeight)
        .background(LoomTheme.Header.group)
        .clipShape(RoundedRectangle(cornerRadius: LoomTheme.Radius.control))
        .fixedSize()
        .help("Back to the session (Esc)")
        .accessibilityLabel("Back to the session")
    }
}

/// The subagent's own permission prompt is answered in the session's terminal, which the panel replaces:
/// this says so, with a way to show it. Opacity only, like the other notices above a terminal.
struct SubagentApprovalNotice: View {
    let model: CatalogModel

    var body: some View {
        HStack(spacing: LoomTheme.Space.detailSpacing) {
            Image(systemName: "exclamationmark.circle.fill").accessibilityHidden(true)
            Text("Waiting for approval: answer it in the session's terminal")
            Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            Button("Show Session") { model.closeSubagent() }
        }
        .font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Status.attention)
        .padding(.horizontal, LoomTheme.Space.detailInset).padding(.bottom, LoomTheme.Space.bannerBottom)
        .fadesIn()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagent-approval-notice")
    }
}
