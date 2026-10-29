import AppKit
import Foundation
import LoomCore
import SwiftUI

/// A native question can only be answered when every original key can be represented without loss.
fileprivate struct ManagedQuestions {
    struct Option {
        let label: String
        let detail: String?
        let preview: String?
    }
    struct Question {
        let text: String
        let header: String?
        let multiple: Bool
        let options: [Option]
    }
    // Native input is already capped at 16 KiB; these caps keep its rendered controls bounded as well.
    private static let maximumQuestions = 8
    private static let maximumOptions = 16
    let items: [Question]

    init?(_ input: JSONValue) {
        guard let raw = input.object?["questions"]?.array, !raw.isEmpty, raw.count <= Self.maximumQuestions else { return nil }
        var questions: [Question] = []
        var keys: Set<String> = []
        for value in raw {
            guard let object = value.object, let text = object["question"]?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, keys.insert(text).inserted else { return nil }
            let header: String?
            if let rawHeader = object["header"], rawHeader != .null {
                guard let value = rawHeader.string else { return nil }
                header = value
            } else { header = nil }
            let multiple: Bool
            if let rawMultiple = object["multiSelect"], rawMultiple != .null {
                guard let value = rawMultiple.bool else { return nil }
                multiple = value
            } else { multiple = false }
            guard let options = object["options"]?.array, options.count <= Self.maximumOptions else { return nil }
            var parsed: [Option] = []
            var labels: Set<String> = []
            for option in options {
                guard let object = option.object, let label = object["label"]?.string,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, labels.insert(label).inserted else { return nil }
                guard object["description"] == nil || object["description"] == .null || object["description"]?.string != nil,
                      object["preview"] == nil || object["preview"] == .null || object["preview"]?.string != nil else { return nil }
                parsed.append(Option(label: label, detail: object["description"]?.string, preview: object["preview"]?.string))
            }
            questions.append(Question(text: text, header: header, multiple: multiple, options: parsed))
        }
        items = questions
    }
}

struct ManagedAnswer {
    var selected: Set<Int> = []
    var other = ""
    var tooLong = false

    mutating func editOther(_ value: String) {
        tooLong = value.utf8.count > ManagedTaskPermissionOccurrence.maximumInputBytes
        if !tooLong {
            other = value
            if !value.isEmpty { selected = [] }
        }
    }

    fileprivate func value(for question: ManagedQuestions.Question) -> String? {
        guard !tooLong else { return nil }
        let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        let chosen = question.options.indices.filter { selected.contains($0) }.map { question.options[$0].label }
        return chosen.isEmpty ? nil : chosen.joined(separator: ", ")
    }
}

/// One request's local draft; it is discarded with the occurrence and never becomes a composer or a task input.
struct ManagedAgentRequestCard: View {
    let occurrence: ManagedTaskPermissionOccurrence
    let available: Bool
    let message: String?
    let decide: (ManagedTaskUserDecision) -> Void
    @State private var answers: [Int: ManagedAnswer] = [:]
    private typealias M = LoomTheme.ManagedAgents

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: M.cardRadius)
        VStack(alignment: .leading, spacing: M.cardGap) {
            VStack(alignment: .leading, spacing: M.lineGap) {
                Text(verbatim: occurrence.request.toolName).font(M.heading).foregroundStyle(LoomTheme.Text.primary)
                Text(verbatim: occurrence.request.summary).font(M.body).foregroundStyle(LoomTheme.Text.primary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let note = occurrence.request.note, !note.isEmpty {
                    Text(verbatim: note).font(M.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            switch occurrence.request.kind {
            case .approval:
                HStack(spacing: M.rowGap) {
                    Button("Deny") { decide(.deny) }
                        .buttonStyle(ControlButtonStyle(kind: .ghost, size: .regular))
                        .accessibilityLabel("Deny, \(occurrence.request.toolName)")
                        .accessibilityIdentifier("managed-deny:\(occurrence.id.uuidString)")
                    Button("Allow Once") { decide(.allow) }
                        .buttonStyle(ControlButtonStyle(kind: .outline, size: .regular))
                        .accessibilityLabel("Allow Once, \(occurrence.request.toolName)")
                        .accessibilityIdentifier("managed-allow:\(occurrence.id.uuidString)")
                }
                .disabled(!available)
            case .question:
                if occurrence.request.toolName == "AskUserQuestion", let questions = ManagedQuestions(occurrence.originalInput) {
                    questionForm(questions)
                } else {
                    Text("This question cannot be answered here. Take Over to review it.")
                        .font(M.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .plan:
                if let plan = occurrence.originalInput.object?["plan"]?.string, !plan.isEmpty {
                    Text(verbatim: plan).font(M.body).foregroundStyle(LoomTheme.Text.primary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else {
                    Text("The plan text is unavailable here.").font(M.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                }
                Text("Approve this plan after Take Over, or keep planning here.")
                    .font(M.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Keep Planning") { decide(.deny) }
                    .buttonStyle(ControlButtonStyle(kind: .outline, size: .regular))
                    .disabled(!available)
                    .accessibilityIdentifier("managed-keep-planning:\(occurrence.id.uuidString)")
            }
            if let message {
                Text(verbatim: message).font(M.detail).foregroundStyle(LoomTheme.Status.attentionLight)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("managed-request-message:\(occurrence.id.uuidString)")
            }
        }
        .padding(M.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(M.cardFill))
        .overlay(shape.strokeBorder(M.cardEdge, lineWidth: LoomTheme.Line.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("managed-request:\(occurrence.id.uuidString)")
        .onChange(of: occurrence) { _, _ in answers = [:] }
    }

    private func questionForm(_ questions: ManagedQuestions) -> some View {
        VStack(alignment: .leading, spacing: M.cardGap) {
            ForEach(Array(questions.items.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: M.rowGap) {
                    if let header = question.header, !header.isEmpty {
                        Text(verbatim: header).font(M.metadata).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                    Text(verbatim: question.text).font(M.heading).foregroundStyle(LoomTheme.Text.primary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if question.multiple {
                        Text("Select one or more").font(M.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                    }
                    ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                        optionRow(option, question: question, index: index, optionIndex: optionIndex)
                    }
                    ManagedOtherAnswerField(answer: Binding(
                        get: { answers[index] ?? ManagedAnswer() },
                        set: { answers[index] = $0 }),
                        question: question.text, identifier: "managed-other:\(occurrence.id.uuidString):\(index)",
                        available: available)
                        .padding(.horizontal, M.fieldInset).frame(maxWidth: .infinity, minHeight: M.fieldHeight)
                        .background(RoundedRectangle(cornerRadius: M.fieldRadius).fill(M.fieldFill))
                        .overlay(RoundedRectangle(cornerRadius: M.fieldRadius).strokeBorder(M.fieldEdge, lineWidth: LoomTheme.Line.hairline))
                        .accessibilityLabel("Other answer for \(question.text)")
                        .accessibilityIdentifier("managed-other:\(occurrence.id.uuidString):\(index)")
                    if answers[index]?.tooLong == true {
                        Text("This answer is too long and was not added. Try a shorter answer.")
                            .font(M.detail).foregroundStyle(LoomTheme.Status.attentionLight)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button("Submit Answers") {
                if let answer = answerObject(for: questions) { decide(.answer(answer)) }
            }
            .buttonStyle(ControlButtonStyle(kind: .outline, size: .regular))
            .disabled(!available || answerObject(for: questions) == nil)
            .accessibilityIdentifier("managed-submit:\(occurrence.id.uuidString)")
            if allAnswered(questions), answerObject(for: questions) == nil {
                Text("The combined answers are too long. Shorten them before submitting.")
                    .font(M.detail).foregroundStyle(LoomTheme.Status.attentionLight)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func optionRow(_ option: ManagedQuestions.Option, question: ManagedQuestions.Question, index: Int,
                           optionIndex: Int) -> some View {
        let selected = answers[index]?.selected.contains(optionIndex) == true
        return Button {
            var answer = answers[index] ?? ManagedAnswer()
            answer.other = ""
            answer.tooLong = false
            if question.multiple {
                if !answer.selected.insert(optionIndex).inserted { answer.selected.remove(optionIndex) }
            } else { answer.selected = [optionIndex] }
            answers[index] = answer
        } label: {
            HStack(alignment: .top, spacing: M.rowGap) {
                choiceMark(selected, multiple: question.multiple)
                VStack(alignment: .leading, spacing: M.lineGap) {
                    Text(verbatim: option.label).font(M.body).foregroundStyle(LoomTheme.Text.primary)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(verbatim: detail).font(M.detail).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let preview = option.preview, !preview.isEmpty {
                        Text(verbatim: preview).font(M.metadata).foregroundStyle(LoomTheme.Text.secondaryStyle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(M.optionInset).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected, radius: M.optionRadius))
        .disabled(!available)
        .accessibilityLabel("\(option.label), \(question.text)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("managed-option:\(occurrence.id.uuidString):\(index):\(optionIndex)")
    }

    @ViewBuilder private func choiceMark(_ selected: Bool, multiple: Bool) -> some View {
        if multiple { choice(RoundedRectangle(cornerRadius: M.choiceRadius), selected: selected) }
        else { choice(Circle(), selected: selected) }
    }

    private func choice<S: InsettableShape>(_ shape: S, selected: Bool) -> some View {
        shape.fill(selected ? M.selectedFill : Color.clear)
            .overlay(shape.strokeBorder(M.fieldEdge, lineWidth: LoomTheme.Line.hairline))
            .overlay { if selected { InkIcon(.check, size: LoomTheme.Icon.tiny).foregroundStyle(M.selectedMark) } }
            .frame(width: M.choiceMark, height: M.choiceMark).accessibilityHidden(true)
    }

    private func answerObject(for questions: ManagedQuestions) -> JSONValue? {
        var result: [String: JSONValue] = [:]
        for (index, question) in questions.items.enumerated() {
            guard let value = answers[index]?.value(for: question) else { return nil }
            result[question.text] = .string(value)
        }
        let answer = JSONValue.object(result)
        guard let encoded = try? JSONEncoder().encode(answer), encoded.count <= ManagedTaskPermissionOccurrence.maximumInputBytes else {
            return nil
        }
        return answer
    }

    private func allAnswered(_ questions: ManagedQuestions) -> Bool {
        questions.items.enumerated().allSatisfy { index, question in answers[index]?.value(for: question) != nil }
    }
}

/// Keeps the displayed editor and its bounded answer in agreement after a rejected paste or edit.
private struct ManagedOtherAnswerField: NSViewRepresentable {
    @Binding var answer: ManagedAnswer
    let question: String
    let identifier: String
    let available: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: LoomTheme.ManagedAgents.fieldFontSize)
        field.textColor = LoomTheme.Text.primaryPair.nsColor
        field.placeholderString = "Other answer"
        field.usesSingleLineMode = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.isEnabled = available
        field.setAccessibilityLabel("Other answer for \(question)")
        field.setAccessibilityIdentifier(identifier)
        guard coordinator.synced != answer.other else { return }
        if let editor = field.currentEditor() as? NSTextView {
            guard !editor.hasMarkedText() else { return }
            if editor.string != answer.other { editor.string = answer.other }
        } else if field.stringValue != answer.other {
            field.stringValue = answer.other
        }
        coordinator.synced = answer.other
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ManagedOtherAnswerField
        var synced = ""

        init(_ parent: ManagedOtherAnswerField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            var next = parent.answer
            next.editOther(editor.string)
            if next.tooLong {
                editor.string = next.other
                editor.setSelectedRange(NSRange(location: (next.other as NSString).length, length: 0))
            }
            synced = next.other
            parent.answer = next
        }
    }
}
