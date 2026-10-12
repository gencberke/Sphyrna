import Foundation

/// The fixed palette a project's colour comes from (D-48), in the order new projects take it.
/// Only the names live here; the colours are `LoomTheme`'s.
public enum ProjectTone: String, CaseIterable, Sendable {
    case rose, orchid, aqua, mint, sage, lemon

    /// What the catalog stores for a project the user set to None.
    public static let noneValue = "none"

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The least-used tone, ties in palette order: the first six projects get six different tones.
    public static func leastUsed(counts: [ProjectTone: Int]) -> ProjectTone {
        var best = allCases[0]
        for tone in allCases where counts[tone, default: 0] < counts[best, default: 0] { best = tone }
        return best
    }
}
