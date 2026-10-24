import Foundation

/// The inspector's three widths (W1-b): each tab draws at its class's width, and a drag on the inspector's edge changes only the
/// shown class's. The defaults are the widths D-78 fixed, so nothing moves for a user who never drags.
enum InspectorWidthClass: String, CaseIterable, Sendable {
    /// Overview and the Agents list.
    case narrow
    /// The Side tab.
    case side
    /// Changes, and a subagent's transcript in the Agents tab.
    case review

    init(tab: InspectorTab, showsTranscript: Bool) {
        switch tab {
        case .overview: self = .narrow
        case .agents: self = showsTranscript ? .review : .narrow
        case .side: self = .side
        case .changes: self = .review
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .narrow: LoomTheme.Rhythm.inspectorWidth
        case .side: LoomTheme.Rhythm.inspectorWidthSide
        case .review: LoomTheme.Rhythm.inspectorWidthReview
        }
    }

    /// No drag makes the class narrower than this. The widest is the pane's business (`InspectorLayout`).
    var minimumWidth: CGFloat {
        switch self {
        case .narrow: LoomTheme.Inspector.minimumWidthNarrow
        case .side: LoomTheme.Inspector.minimumWidthSide
        case .review: LoomTheme.Inspector.minimumWidthReview
        }
    }
}

/// The remembered width of each class (`UIPreferences.inspectorWidths`). A width is kept at or above its class's minimum and
/// whole; it has no maximum here, because the window decides what fits: a width wider than the pane allows is clamped when shown,
/// and the stored one stays. A missing or unreadable entry reads as the class's default.
public struct InspectorWidths: Codable, Equatable, Sendable {
    private var narrow: Double
    private var side: Double
    private var review: Double

    public init() {
        narrow = Double(InspectorWidthClass.narrow.defaultWidth)
        side = Double(InspectorWidthClass.side.defaultWidth)
        review = Double(InspectorWidthClass.review.defaultWidth)
    }

    subscript(widthClass: InspectorWidthClass) -> CGFloat {
        get {
            switch widthClass {
            case .narrow: CGFloat(narrow)
            case .side: CGFloat(side)
            case .review: CGFloat(review)
            }
        }
        set {
            let width = Double(Self.normalized(newValue, for: widthClass))
            switch widthClass {
            case .narrow: narrow = width
            case .side: side = width
            case .review: review = width
            }
        }
    }

    static func normalized(_ width: CGFloat, for widthClass: InspectorWidthClass) -> CGFloat {
        guard width.isFinite else { return widthClass.defaultWidth }
        return max(width.rounded(), widthClass.minimumWidth)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: InspectorWidthClass.self)
        self.init()
        for widthClass in InspectorWidthClass.allCases {
            if let width = (try? container.decodeIfPresent(Double.self, forKey: widthClass)) ?? nil {
                self[widthClass] = CGFloat(width)
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: InspectorWidthClass.self)
        for widthClass in InspectorWidthClass.allCases {
            try container.encode(Double(self[widthClass]), forKey: widthClass)
        }
    }
}

extension InspectorWidthClass: CodingKey {}
