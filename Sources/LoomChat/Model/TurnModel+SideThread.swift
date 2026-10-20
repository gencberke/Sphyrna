import Foundation

extension TurnModel {
    /// A side chat's own part of its fork's transcript (V22 part 3): the entries from the one with this id on. A fork's file
    /// begins with a copy of the parent's records (and the CLI's repair records for what the parent left open), and the side
    /// chat's thread starts at its first question, whose record uuid the card keeps (`side_first_uuid`).
    ///
    /// The model of a transcript read so far is a tail of the file (the lens reads backwards, page by page), so the copy is
    /// not always in it:
    /// - the first question is in it: everything before is dropped and nothing older is wanted (`hasOlder` is false);
    /// - it is not, and older records exist: the read lies inside the side chat's own part, and it is kept whole;
    /// - it is not, and nothing older exists: the file has no such record (no question was sent yet, or it is not written yet),
    ///   and the whole read is the parent's copy, so nothing is kept.
    ///
    /// Turns that no kept entry belongs to go with the entries; the others are kept as they are.
    public func sideThread(startingAt firstID: String?, hasOlder: Bool) -> (model: TurnModel, hasOlder: Bool) {
        guard let firstID, let first = index[firstID] else {
            if firstID != nil, hasOlder { return (self, true) }
            return (kept(from: entries.count), false)
        }
        return (kept(from: first), false)
    }

    private func kept(from position: Int) -> TurnModel {
        guard position > 0 else { return self }
        var model = self
        let dropped = entries[..<position]
        model.entries.removeSubrange(..<position)
        let remaining = Set(model.entries.map(\.turnID))
        model.turns.removeAll { !remaining.contains($0.id) }
        model.unknownRecordCount = max(0, unknownRecordCount - dropped.filter {
            if case let .unknown(raw) = $0.body { raw.reason == .unknownType } else { false }
        }.count)
        model.index = Dictionary(model.entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, later in later })
        return model
    }
}
