import Foundation
import LoomCore
import Observation

/// The keyboard cursor belongs to one open picker, not to the persisted draft.
@MainActor @Observable final class ModelPickerController {
    enum Section: Hashable { case recent, harness(HarnessID) }
    enum Outcome: Equatable { case ignored, moved, choose(ModelPickerChoice), dismiss }

    var query = ""
    var cursor: ModelPickerRow?
    var activeSection: Section?
    var jumpTarget: Section?
    var jumpSerial = 0

    func prepare(selected: ModelPickerChoice, rows: [ModelPickerRow]) {
        query = ""
        cursor = rows.first { $0.choice == selected } ?? rows.first
        activeSection = cursor?.section
        jumpTarget = nil
    }

    func search(_ text: String, rows: [ModelPickerRow]) {
        guard query != text else { return }
        query = text
        cursor = rows.first
        activeSection = cursor?.section
    }

    func jump(_ section: Section, rows: [ModelPickerRow]) {
        activeSection = section
        cursor = rows.first { $0.section == section }
        jumpTarget = section
        jumpSerial += 1
    }

    func handle(_ key: InkKey, rows: [ModelPickerRow]) -> Outcome {
        switch key {
        case .up, .down:
            guard !rows.isEmpty, let cursor else { return .ignored }
            let delta = key == .down ? 1 : -1
            let index = ComposerPopoverKeys.cursor(from: rows.firstIndex(of: cursor), delta: delta, count: rows.count)
            self.cursor = index.map { rows[$0] }
            return .moved
        case .return:
            guard let cursor, rows.contains(cursor) else { return .ignored }
            return .choose(cursor.choice)
        case .escape: return .dismiss
        case .left, .right, .space: return .ignored
        }
    }
}

@MainActor @Observable final class EffortPickerController {
    enum Choice: Hashable { case `default`, level(String) }
    enum Outcome: Equatable { case ignored, moved, choose(Choice), dismiss }
    var cursor: Choice?
    var owner: EffortPickerOwner?

    func prepare(owner: EffortPickerOwner, options: EffortPickerOptions) {
        self.owner = owner
        cursor = options.current.map(Choice.level) ?? .default
    }

    func handle(_ key: InkKey, options: EffortPickerOptions) -> Outcome {
        switch key {
        case .up, .down:
            let choices: [Choice] = [.default] + options.levels.map(Choice.level)
            let delta = key == .down ? 1 : -1
            let index = ComposerPopoverKeys.cursor(from: cursor.flatMap(choices.firstIndex(of:)),
                                                   delta: delta, count: choices.count)
            cursor = index.map { choices[$0] }
            return index == nil ? .ignored : .moved
        case .return:
            guard let cursor else { return .ignored }
            if case let .level(level) = cursor, !options.levels.contains(level) { return .ignored }
            return .choose(cursor)
        case .escape: return .dismiss
        case .left, .right, .space: return .ignored
        }
    }
}
