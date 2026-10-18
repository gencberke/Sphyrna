import Foundation

/// The effort levels of the CLI, lowest first, and what a model that offers fewer of them does with a level it lacks.
public enum ChatEffort {
    public static let ordered = ["low", "medium", "high", "xhigh", "max"]

    /// `level` as a model that offers `levels` takes it: itself when offered, else the highest offered level below it, else
    /// the lowest offered one. Nil when the model offers none (it takes no `--effort` at all).
    public static func clamped(_ level: String, to levels: [String]) -> String? {
        let offered = levels.filter(ordered.contains).sorted { ordered.firstIndex(of: $0)! < ordered.firstIndex(of: $1)! }
        guard !offered.isEmpty else { return nil }
        if offered.contains(level) { return level }
        guard let rank = ordered.firstIndex(of: level) else { return offered.first }
        return offered.last { ordered.firstIndex(of: $0)! < rank } ?? offered.first
    }
}
