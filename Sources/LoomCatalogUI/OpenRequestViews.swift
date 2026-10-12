import SwiftUI
import LoomCore

/// The boxes of an agent's requests to open a session (D-40), above the requesting session's terminal
/// or history view, below the provider's own requests. Nothing here answers by itself: no button is
/// the default action, so Return stays with the terminal.
struct OpenRequestBoxes: View {
    let model: CatalogModel
    let requests: [OpenSessionRequest]

    var body: some View {
        ForEach(requests) { OpenRequestBox(model: model, request: $0) }
    }
}

struct OpenRequestBox: View {
    let model: CatalogModel
    let request: OpenSessionRequest
    @State private var showsFullMessage = false

    var body: some View {
        let content = OpenRequestBoxContent(request)
        VStack(alignment: .leading, spacing: LoomTheme.Space.requestLineSpacing * 2) {
            HStack(alignment: .top, spacing: LoomTheme.Space.requestSpacing) {
                Image(systemName: content.needsDecision ? "plus.square.on.square" : "info.circle")
                    .foregroundStyle(content.needsDecision ? LoomTheme.Status.attention : LoomTheme.Text.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: LoomTheme.Space.requestLineSpacing) {
                    Text(content.heading).font(LoomTheme.Typography.smallMedium)
                        .foregroundStyle(LoomTheme.Text.primary).textSelection(.enabled)
                    ForEach(content.lines, id: \.label) { line in
                        HStack(alignment: .firstTextBaseline, spacing: LoomTheme.Space.requestLineSpacing * 2) {
                            Text(line.label).font(LoomTheme.Typography.caption)
                                .foregroundStyle(LoomTheme.Text.secondaryStyle)
                                .frame(width: LoomTheme.Layout.requestLabelWidth, alignment: .leading)
                            Text(line.value).font(LoomTheme.Typography.small)
                                .foregroundStyle(LoomTheme.Text.primary).textSelection(.enabled)
                        }
                    }
                    if !content.preview.isEmpty { message(content) }
                    if let status = content.status {
                        Text(status).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                    if let failure = content.failure {
                        Text(failure).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Status.failure)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: LoomTheme.Space.detailMinSpacer)
            }
            HStack(spacing: LoomTheme.Space.requestLineSpacing * 2) {
                Spacer(minLength: 0)
                ForEach(content.actions, id: \.self) { action in button(for: action, content: content) }
            }
        }
        .padding(LoomTheme.Space.requestPadding)
        .background(RoundedRectangle(cornerRadius: LoomTheme.Radius.callout).fill(background(content)))
        .fadesIn()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.needsDecision ? "Request to open a session: \(request.title)" : content.heading)
    }

    private func background(_ content: OpenRequestBoxContent) -> Color {
        content.needsDecision ? LoomTheme.Status.attention.opacity(LoomTheme.Status.tintOpacity) : LoomTheme.Surface.control
    }

    /// The first lines of the message; the rest in a bounded scroll area on request.
    @ViewBuilder private func message(_ content: OpenRequestBoxContent) -> some View {
        if showsFullMessage {
            ScrollView {
                Text(content.message).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: LoomTheme.Layout.requestMessageMaxHeight)
            .accessibilityLabel("Message")
        } else {
            Text(content.preview).font(LoomTheme.Typography.small).foregroundStyle(LoomTheme.Text.primary)
                .lineLimit(OpenRequestBoxContent.previewLineLimit).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Message: \(content.preview)")
        }
        if content.hasMore {
            Button(showsFullMessage ? "Show less" : "Show full message") { showsFullMessage.toggle() }
                .buttonStyle(.plain).font(LoomTheme.Typography.caption).foregroundStyle(LoomTheme.Accent.base)
        }
    }

    @ViewBuilder private func button(for action: OpenRequestBoxContent.Action, content: OpenRequestBoxContent) -> some View {
        switch action {
        case .deny:
            Button("Deny") { model.denyOpenRequest(request.id) }.disabled(content.actionsDisabled)
        case .openSession:
            // Neither button is the default action: Return belongs to the terminal below.
            Button("Open Session") { model.approveOpenRequest(request.id) }
                .buttonStyle(AccentButtonStyle(kind: .filled)).disabled(content.actionsDisabled)
        case .showSession:
            Button("Show Session") { model.showExistingSession(of: request) }
        case .dismiss:
            Button("Dismiss") { model.dismissOpenRequest(request.id) }
        }
    }
}
