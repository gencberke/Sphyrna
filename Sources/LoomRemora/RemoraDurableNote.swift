import Foundation

/// `Remora.md`: the note that holds what the user told Remora to remember (design/DESIGN.md §20; LOMBOT §3.6). The caller
/// gives the path (the app's default and Settings' Choose… are L3's); the file may be in a vault the user edits in any editor,
/// so every operation reads it fresh, changes only its own line, and replaces the file atomically.
///
/// Remora writes only under `## Remembered`: `remember` adds a dated line, `undo` takes exactly that line out. Everything
/// else in the file, whoever wrote it, stays byte for byte. A missing file is created with Remora's headings (`template`).
/// The file may not pass 8,000 bytes: a save that would is refused with a reason, never cut.
public actor RemoraDurableNote {
    public static let maxBytes = 8_000
    public static let maxFactCharacters = 500
    public static let rememberedHeading = "## Remembered"

    /// The file a missing path starts with.
    public static let template = """
    # Remora

    Sphyrna's Home assistant. Remora writes only under its own headings, and only when you ask it to remember something.

    ## Who I am
    - I read Sphyrna's Claude sessions and my own notes, and answer. I never start, stop or change a session.
    - I mark what I remember with its date, and what I read now as current.

    ## How you want answers

    ## Remembered

    """

    /// Why a save did not happen. `reason` is a line the UI can show.
    public enum Refusal: Error, Equatable, CustomStringConvertible, Sendable {
        case tooLarge(limit: Int, wouldBe: Int)
        case factTooLong(limit: Int)
        case emptyFact
        /// The file is not UTF-8 text; it is left alone.
        case unreadable
        case writeFailed(String)

        public var reason: String {
            switch self {
            case let .tooLarge(limit, wouldBe): "Remora.md would be \(wouldBe) bytes; it can hold \(limit). Remove something from it first."
            case let .factTooLong(limit): "That is longer than \(limit) characters. Shorten it."
            case .emptyFact: "There is nothing to remember."
            case .unreadable: "Remora.md is not a text file Remora can read."
            case let .writeFailed(operation): "Remora.md could not be saved (\(operation))."
            }
        }

        public var description: String { reason }
    }

    public let url: URL
    private let clock: @Sendable () -> Date
    private let calendar: Calendar
    private var undoable: [RemoraUndoToken: String] = [:]

    public init(url: URL, timeZone: TimeZone = .current, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.clock = clock
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    // MARK: Read

    /// The file's text; empty when it is missing or unreadable.
    public func text() -> String { RemoraFiles.readText(url) ?? "" }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Whether `fact` is already a remembered line (the same words, any date or project).
    public func alreadyRemembers(_ fact: String) -> Bool {
        let wanted = RemoraText.flatten(fact).lowercased()
        guard !wanted.isEmpty, let text = RemoraFiles.readText(url) else { return false }
        let lines = text.components(separatedBy: "\n")
        guard let range = Self.rememberedRange(in: lines) else { return false }
        return lines[range].contains { $0.lowercased().hasSuffix(" \u{00B7} " + wanted) }
    }

    // MARK: Write

    /// Creates the file with Remora's headings when it is missing.
    public func ensureExists() throws {
        guard !exists else { return }
        try save(Self.template, existing: nil)
    }

    /// Appends `- 2026-10-21 · <project> · <fact>` (no project: `- 2026-10-21 · <fact>`) under `## Remembered` and returns
    /// the token that takes exactly that line out again.
    @discardableResult
    public func remember(_ fact: String, project: String? = nil) throws -> RemoraUndoToken {
        let cleaned = RemoraText.flatten(RemoraSecretMask.mask(fact))
        guard !cleaned.isEmpty else { throw Refusal.emptyFact }
        guard cleaned.count <= Self.maxFactCharacters else { throw Refusal.factTooLong(limit: Self.maxFactCharacters) }
        let (current, existing) = try load()
        let day = RemoraDay(clock(), calendar: calendar)
        var line = "- \(day.string) \u{00B7} "
        if let project = project.map({ RemoraText.flatten($0).replacingOccurrences(of: " \u{00B7} ", with: " - ") }), !project.isEmpty {
            line += project + " \u{00B7} "
        }
        line += cleaned

        var lines = current.components(separatedBy: "\n")
        if let range = Self.rememberedRange(in: lines) {
            var at = range.upperBound
            while at > range.lowerBound, lines[at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { at -= 1 }
            lines.insert(line, at: at)
        } else {
            if lines.last != "" { lines.append("") }
            lines.append(contentsOf: ["", Self.rememberedHeading, line, ""])
        }
        try save(lines.joined(separator: "\n"), existing: existing)
        let token = RemoraUndoToken()
        undoable[token] = line
        return token
    }

    /// Takes the remembered line out (the last identical one under `## Remembered`). False when the token is spent or the
    /// line is no longer there (the user changed or removed it).
    @discardableResult
    public func undo(_ token: RemoraUndoToken) throws -> Bool {
        guard let line = undoable[token], exists else { return false }
        let (current, existing) = try load()
        var lines = current.components(separatedBy: "\n")
        guard let range = Self.rememberedRange(in: lines), let index = lines[range].lastIndex(of: line) else { return false }
        lines.remove(at: index)
        try save(lines.joined(separator: "\n"), existing: existing)
        undoable[token] = nil
        return true
    }

    // MARK: File

    private func load() throws -> (text: String, mode: mode_t?) {
        guard exists else { return (Self.template, nil) }
        guard let data = RemoraFiles.read(url), let text = String(data: data, encoding: .utf8) else { throw Refusal.unreadable }
        var info = stat()
        return (text, stat(url.resolvingSymlinksInPath().path, &info) == 0 ? info.st_mode & 0o7777 : nil)
    }

    private func save(_ text: String, existing mode: mode_t?) throws {
        let bytes = text.utf8.count
        guard bytes <= Self.maxBytes else { throw Refusal.tooLarge(limit: Self.maxBytes, wouldBe: bytes) }
        do {
            try RemoraFiles.ensureParent(of: url)
            try RemoraFiles.writeAtomically(Data(text.utf8), to: url, mode: mode ?? 0o600)
        } catch let failure as RemoraFiles.Failure {
            throw Refusal.writeFailed(failure.operation)
        }
    }

    /// The line indices under the `## Remembered` heading, up to the next heading of level 1 or 2 (or the end).
    static func rememberedRange(in lines: [String]) -> Range<Int>? {
        guard let heading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == rememberedHeading }) else { return nil }
        var end = lines.count
        for index in (heading + 1)..<max(heading + 1, lines.count) where lines[index].hasPrefix("# ") || lines[index].hasPrefix("## ") {
            end = index
            break
        }
        return (heading + 1)..<end
    }
}
