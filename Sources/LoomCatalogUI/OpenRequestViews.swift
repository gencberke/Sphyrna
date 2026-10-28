import SwiftUI
import LoomCore

/// The requests of an agent to open a session (D-40), above the requesting session's terminal or history view, below the
/// provider's own requests. Several requests are one card with a counter, oldest first (FB6-24); an answered one folds to a
/// line for 4 s. Nothing here answers by itself: no button is the default action, so Return stays with the terminal.
struct OpenRequestBoxes: View {
    let model: CatalogModel
    let requests: [OpenSessionRequest]
    @State private var folds: [OpenRequestFold] = []

    var body: some View {
        VStack(alignment: .leading, spacing: LoomTheme.OpenRequest.foldGap) {
            ForEach(folds) { fold in OpenRequestFoldLine(model: model, fold: fold) }
            if let request = requests.first {
                OpenRequestBox(model: model, request: request, position: 1, of: requests.count)
            }
        }
        .onChange(of: requests) { previous, current in
            foldAnswered(in: previous, remaining: current)
        }
    }

    /// A request that left the list was answered: starting but gone is an opened session, waiting but gone was denied.
    @MainActor private func foldAnswered(in previous: [OpenSessionRequest], remaining current: [OpenSessionRequest]) {
        let left = Set(current.map(\.id))
        for request in previous where !left.contains(request.id) {
            guard let outcome = request.answeredFold else { continue }
            let fold = OpenRequestFold(id: request.id, outcome: outcome, title: request.title,
                                       requesterID: request.requesterID)
            folds.append(fold)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(LoomTheme.OpenRequest.foldLinger))
                folds.removeAll { $0.id == fold.id }
            }
        }
    }
}

/// One request as the session it will become: the attention dot and the request, the requester and the counter in mono, the
/// title, the harness, model, effort, mode and project, the message's first three lines, then Deny and Open Session.
struct OpenRequestBox: View {
    let model: CatalogModel
    let request: OpenSessionRequest
    var position = 1
    var of = 1
    @State private var showsFullMessage = false
    @Environment(\.indicatorsAnimate) private var indicatorsAnimate

    var body: some View {
        let content = OpenRequestBoxContent(request, position: position, count: of)
        let shape = RoundedRectangle(cornerRadius: LoomTheme.OpenRequest.radius)
        VStack(alignment: .leading, spacing: LoomTheme.OpenRequest.sectionSpacing) {
            header(content)
            session(content)
            message(content)
            if let failure = content.failure {
                Text(failure).font(LoomTheme.OpenRequest.notice).foregroundStyle(LoomTheme.Status.failure)
                    .textSelection(.enabled)
            }
            buttons(content)
        }
        .padding(LoomTheme.OpenRequest.padding)
        .background(shape.fill(LoomTheme.OpenRequest.cardFill))
        .overlay(shape.strokeBorder(LoomTheme.OpenRequest.edge, lineWidth: LoomTheme.Line.hairline))
        .depth(LoomTheme.Elevation.card)
        .fadesIn()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Request to open a session: \(request.title)")
    }

    private func header(_ content: OpenRequestBoxContent) -> some View {
        HStack(spacing: LoomTheme.OpenRequest.headerGap) {
            Circle().fill(LoomTheme.Status.attention)
                .frame(width: LoomTheme.OpenRequest.dot, height: LoomTheme.OpenRequest.dot)
                .accessibilityHidden(true)
            Text(content.heading).font(LoomTheme.OpenRequest.heading)
                .foregroundStyle(LoomTheme.Text.primary)
            Spacer(minLength: LoomTheme.OpenRequest.headerGap)
            Text(content.requester).font(LoomTheme.OpenRequest.requester)
                .foregroundStyle(LoomTheme.Text.tertiaryStyle).lineLimit(1)
            if let counter = content.counter {
                Text(counter).font(LoomTheme.OpenRequest.counter)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The session it will be: the title, then the harness, the choices and the project in the sidebar card's order.
    private func session(_ content: OpenRequestBoxContent) -> some View {
        VStack(alignment: .leading, spacing: LoomTheme.OpenRequest.lineSpacing) {
            Text(content.title).font(LoomTheme.OpenRequest.title)
                .foregroundStyle(LoomTheme.Text.primary).lineLimit(2).textSelection(.enabled)
            HStack(spacing: LoomTheme.OpenRequest.metaGap) {
                if let provider = content.provider { HarnessMark(provider: provider) }
                Text([content.harnessName, content.model, content.effort, content.mode].joined(separator: " \u{00B7} "))
                    .font(LoomTheme.OpenRequest.meta).foregroundStyle(LoomTheme.Text.tertiaryStyle)
                Text("\u{00B7}").font(LoomTheme.OpenRequest.meta).foregroundStyle(LoomTheme.Text.faint)
                ProjectMarkView(name: content.projectName,
                                tone: model.projectTone(forProject: request.projectID), size: .card)
                Text(content.projectName).font(LoomTheme.OpenRequest.meta)
                    .foregroundStyle(LoomTheme.Text.tertiaryStyle)
            }
            .lineLimit(1)
        }
    }

    /// The first lines of the message on a raised 1 inset; the rest in a bounded scroll area on request.
    @ViewBuilder private func message(_ content: OpenRequestBoxContent) -> some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.OpenRequest.messageRadius)
        Group {
            if showsFullMessage {
                ScrollView {
                    Text(content.message).font(LoomTheme.OpenRequest.body)
                        .foregroundStyle(LoomTheme.Text.primary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: LoomTheme.OpenRequest.messageMaxHeight)
                .accessibilityLabel("Message")
            } else {
                Text(content.preview).font(LoomTheme.OpenRequest.body)
                    .foregroundStyle(LoomTheme.Text.primary)
                    .lineLimit(OpenRequestBoxContent.previewLineLimit).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Message: \(content.preview)")
            }
        }
        .padding(.vertical, LoomTheme.OpenRequest.messagePaddingV)
        .padding(.horizontal, LoomTheme.OpenRequest.messagePaddingH)
        .background(shape.fill(LoomTheme.OpenRequest.messageFill))
        if content.hasMore {
            HStack {
                Button(showsFullMessage ? "Show less" : "Show full message") { showsFullMessage.toggle() }
                    .buttonStyle(ControlButtonStyle(kind: .link))
                Spacer(minLength: 0)
            }
        }
    }

    private func buttons(_ content: OpenRequestBoxContent) -> some View {
        HStack(spacing: LoomTheme.OpenRequest.buttonSpacing) {
            Spacer(minLength: 0)
            ForEach(content.actions, id: \.self) { action in
                switch action {
                case .deny:
                    Button("Deny") { model.denyOpenRequest(request.id) }
                        .buttonStyle(ControlButtonStyle(kind: .secondary))
                        .disabled(content.actionsDisabled)
                case .openSession:
                    if content.showsSpinner {
                        BrailleSpinner(animating: indicatorsAnimate)
                            .frame(width: LoomTheme.OpenRequest.spinnerWidth,
                                   height: LoomTheme.Control.Size.regular.height)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Opening…")
                    } else {
                        // Neither button is the default action: Return belongs to the terminal below.
                        Button("Open Session") { model.approveOpenRequest(request.id) }
                            .buttonStyle(ControlButtonStyle(kind: .default))
                            .disabled(content.actionsDisabled)
                    }
                case .dismiss:
                    Button("Dismiss") { model.dismissOpenRequest(request.id) }
                        .buttonStyle(ControlButtonStyle(kind: .ghost))
                }
            }
        }
    }
}

/// An answered request, folded to one line for four seconds: "Opened: <title>" with Go to Session when the new session is
/// already in the lists, or "Denied: <title>".
struct OpenRequestFoldLine: View {
    let model: CatalogModel
    let fold: OpenRequestFold

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LoomTheme.OpenRequest.foldRadius)
        HStack(spacing: LoomTheme.OpenRequest.headerGap) {
            Circle().fill(fold.outcome == .opened ? LoomTheme.OpenRequest.openedMark : LoomTheme.OpenRequest.deniedMark)
                .frame(width: LoomTheme.OpenRequest.dot, height: LoomTheme.OpenRequest.dot)
                .accessibilityHidden(true)
            Text(fold.text).font(LoomTheme.OpenRequest.fold)
                .foregroundStyle(LoomTheme.Text.secondaryStyle).lineLimit(1)
            Spacer(minLength: 0)
            if fold.showsGoToSession,
               let sessionID = model.openedSession(openedBy: fold.requesterID, title: fold.title) {
                Button("Go to Session") { model.select(sessionID) }
                    .buttonStyle(ControlButtonStyle(kind: .ghost))
            }
        }
        .padding(.horizontal, LoomTheme.OpenRequest.foldPaddingH)
        .frame(height: LoomTheme.OpenRequest.foldHeight)
        .background(shape.fill(LoomTheme.OpenRequest.foldFill))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fold.text)
    }
}
