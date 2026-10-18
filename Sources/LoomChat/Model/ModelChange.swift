import Foundation

/// What changed in a `TurnModel`, as values the receiver applies to its own copy. A source that hands over the whole model on
/// every change makes both sides copy it (the receiver still holds the buffers the source is about to write to); a change
/// carries only what a change touched, so the receiver's cost is the size of the change.
///
/// - `.growth`: entries were added at the end, entries that were there changed in place, turns were added or changed. The
///   receiver checks that its model is the one the change was made on (`entriesBefore`, `turnsBefore`, `sequence`).
/// - `.replaced` and `.older`: the whole model (the first read, a file that was replaced, a snapshot) or the model with older
///   turns put in front. Rare, and the receiver rebuilds from them.
///
/// The change carries what the stream's rows need: the entries, the turns, the `activity` and the unknown-record count. The
/// rest of a source's `TurnModel` (the init, the context usage, the tasks) is not copied.
public struct ModelChange: Sendable {
    public enum Kind: Sendable, Equatable {
        case growth
        case replaced
        case older
    }

    public var kind: Kind
    /// Counts the changes a source makes, 1 for its first. A change that is not the next one after the last the receiver
    /// took (it missed one, or got them out of order) is not applied; the receiver asks the source for a snapshot.
    public var sequence: Int
    /// Older turns exist before the first entry of the model.
    public var hasOlder: Bool

    /// `.replaced`, `.older`: the whole model.
    public var model: TurnModel?

    /// `.growth`: what the source's `ModelDelta` named.
    public var delta: ModelDelta
    /// `.growth`: the counts the model had before the change.
    public var entriesBefore: Int
    public var turnsBefore: Int
    /// `.growth`: entries from position `entriesBefore` on, in order.
    public var appended: [ChatEntry]
    /// `.growth`: entries before that which changed (the delta's `updated`), as they are now.
    public var updated: [ChatEntry]
    /// `.growth`: turns that are new or may have changed, with their positions. The newest two turns always; a turn changes
    /// only at the end of the model, or through an entry that is in `updated`.
    public var turns: [TurnAt]
    public var activity: String?
    /// `.growth`: `activity` differs from what it was (a status such as "compacting"): a change although no entry moved.
    public var activityChanged: Bool
    public var unknownRecordCount: Int

    public struct TurnAt: Sendable {
        public var position: Int
        public var turn: ChatTurn

        public init(position: Int, turn: ChatTurn) {
            self.position = position
            self.turn = turn
        }
    }

    /// A growth that changed nothing. It still carries the source's current `sequence`: a receiver that is behind that number
    /// missed a change (one that was in flight when a feed stopped) and asks for a snapshot.
    public var isEmpty: Bool { kind == .growth && delta.isEmpty && appended.isEmpty && updated.isEmpty && !activityChanged }

    public init(kind: Kind, sequence: Int, hasOlder: Bool, model: TurnModel? = nil, delta: ModelDelta = ModelDelta(),
                entriesBefore: Int = 0, turnsBefore: Int = 0, appended: [ChatEntry] = [], updated: [ChatEntry] = [],
                turns: [TurnAt] = [], activity: String? = nil, activityChanged: Bool = false, unknownRecordCount: Int = 0) {
        self.kind = kind
        self.sequence = sequence
        self.hasOlder = hasOlder
        self.model = model
        self.delta = delta
        self.entriesBefore = entriesBefore
        self.turnsBefore = turnsBefore
        self.appended = appended
        self.updated = updated
        self.turns = turns
        self.activity = activity
        self.activityChanged = activityChanged
        self.unknownRecordCount = unknownRecordCount
    }
}

/// Where a view's `TurnModel` changes come from: a transcript being followed (`TranscriptGrowthFeed`), later the chat driver.
/// Changes arrive in order and carry consecutive sequence numbers from 1; the first is a snapshot (`.replaced`).
public protocol ModelChangeSource: Sendable {
    var changes: AsyncStream<ModelChange> { get }
}

extension TurnModel {
    /// The change from a model that had `entriesBefore` entries and `turnsBefore` turns to this one, by `delta`: the work of a
    /// source after it applied something, in proportion to the delta.
    public func growth(sequence: Int, entriesBefore: Int, turnsBefore: Int, delta: ModelDelta, hasOlder: Bool,
                       activityChanged: Bool = false) -> ModelChange {
        let appended = entriesBefore < entries.count ? Array(entries[entriesBefore...]) : []
        var updated: [ChatEntry] = []
        // The newest two turns, and every turn from the one that was newest before the change: a change that adds turns ends it.
        var positions = Set<Int>(max(0, turns.count - 2)..<turns.count)
        positions.formUnion(max(0, min(turnsBefore, turns.count) - 1)..<turns.count)
        for id in delta.updated {
            guard let position = index[id], position < entriesBefore else { continue }
            updated.append(entries[position])
            if let turn = turns.lastIndex(where: { $0.id == entries[position].turnID }) { positions.insert(turn) }
        }
        return ModelChange(kind: .growth, sequence: sequence, hasOlder: hasOlder, delta: delta, entriesBefore: entriesBefore,
                           turnsBefore: turnsBefore, appended: appended, updated: updated,
                           turns: positions.sorted().map { ModelChange.TurnAt(position: $0, turn: turns[$0]) },
                           activity: activity, activityChanged: activityChanged, unknownRecordCount: unknownRecordCount)
    }

    /// Whether this model holds what the stream's rows come from as `other` does: the entries (and where they are found), the
    /// turns, the activity and the unknown-record count. What a receiver that applied a source's changes must satisfy.
    public func rowInputsEqual(_ other: TurnModel) -> Bool {
        entries == other.entries && turns == other.turns && activity == other.activity
            && unknownRecordCount == other.unknownRecordCount && entries.allSatisfy { index[$0.id] == other.index[$0.id] }
    }

    /// The whole model as a change.
    public func snapshot(sequence: Int, kind: ModelChange.Kind = .replaced, hasOlder: Bool) -> ModelChange {
        ModelChange(kind: kind, sequence: sequence, hasOlder: hasOlder, model: self, activity: activity, unknownRecordCount: unknownRecordCount)
    }

    /// Takes a change made on a model like this one. False, with nothing changed, when this is not the model the change was
    /// made on (the counts differ, or an entry it names is not here).
    @discardableResult
    public mutating func apply(_ change: ModelChange) -> Bool {
        switch change.kind {
        case .replaced, .older:
            guard let whole = change.model else { return false }
            self = whole
            return true
        case .growth:
            guard entries.count == change.entriesBefore, turns.count == change.turnsBefore,
                  change.updated.allSatisfy({ index[$0.id] != nil }),
                  change.turns.allSatisfy({ $0.position < change.turnsBefore + change.turns.count }) else { return false }
            for entry in change.updated { entries[index[entry.id]!] = entry }
            for entry in change.appended {
                index[entry.id] = entries.count
                entries.append(entry)
            }
            for item in change.turns {
                if item.position < turns.count { turns[item.position] = item.turn } else { turns.append(item.turn) }
            }
            activity = change.activity
            unknownRecordCount = change.unknownRecordCount
            return true
        }
    }
}
