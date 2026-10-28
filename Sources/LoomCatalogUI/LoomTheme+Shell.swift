import AppKit
import LoomCore
import SwiftUI

extension LoomTheme.Header {
    /// The session header's v4 Stop / actions group.
    static let sessionGroupHeight = LoomTheme.InkHeight.sm
    static let sessionGroupRadius = LoomTheme.InkRadius.row
}

extension LoomTheme.TabStrip {
    /// A session tab on its 36 pt row.
    static let sessionTabHeight = LoomTheme.InkHeight.sm
    static let sessionTabRadius = LoomTheme.InkRadius.row
}

/// The values of the window's shell in Ink (DESIGN §3 Shape and rhythm, §6 Project colour, Iconography, Controls and Terminal
/// framing): the project's mark, the control family and Sphyrna's focus ring. The header's, the tab row's and the pane's own
/// numbers are `Header`, `TabStrip`, `Layout` and `Space` in `LoomTheme.swift`.
extension LoomTheme {
    /// The project's mark: its initial, bold, on a soft square of its tone (24 % in Ink, 15 % in Paper), the initial in the
    /// tone (its Increase Contrast tone under Increase Contrast). No tone: a neutral square with the initial in secondary.
    enum ProjectMarkStyle {
        /// 16 in the sidebar's project head, 14 in tabs, chips and lists, 12 on an activity card, 26 on the project page.
        enum Size: CaseIterable, Sendable {
            case head, chip, card, page

            var side: CGFloat {
                switch self {
                case .head: 16
                case .chip: 14
                case .card: 12
                case .page: 26
                }
            }

            var radius: CGFloat {
                switch self {
                case .head: 5
                case .chip: 4
                case .card: 3.5
                case .page: 8
                }
            }

            var font: Font {
                switch self {
                case .head: .system(size: 9.5, weight: .bold)
                case .chip: .system(size: 8.5, weight: .bold)
                case .card: .system(size: 7.5, weight: .bold)
                case .page: .system(size: 12.5, weight: .bold)
                }
            }
        }

        static let washDarkOpacity = 0.24
        static let washLightOpacity = 0.15

        /// The first letter of a name, in capitals; "?" for a name with none.
        static func initial(of name: String) -> String {
            guard let first = name.trimmingCharacters(in: .whitespacesAndNewlines).first else { return "?" }
            return String(first).uppercased()
        }

        /// The tone's soft square, as data: the tone's own value in each appearance at the wash.
        static func square(_ tone: ProjectTone) -> AdaptiveTone {
            AdaptiveTone(dark: Tone(rgb: ProjectColor.baseRGB(tone), opacity: washDarkOpacity),
                         light: Tone(rgb: ProjectColor.lightBaseRGB(tone), opacity: washLightOpacity))
        }

        /// The initial's colour: the tone, and its Increase Contrast tone under Increase Contrast.
        static func initialStyle(_ tone: ProjectTone) -> ContrastStyle { ProjectColor.stripe(tone) }

        /// The neutral square.
        static let neutralSquare = Surface.selectedTone
    }

    /// The control family (DESIGN §0.3, §0.4): four heights, one radius, one hover and one focus ring for every control. The heights
    /// are xs 24 (chips, inline buttons), sm 28 (toolbar and icon buttons), default 32 (pages and sheets) and lg 36 (a sheet's or an
    /// empty state's main action); the radius is 8.
    enum Control {
        /// A button's size: its height, its inside padding and its type (13 medium, 12 medium at 24 high).
        enum Size: CaseIterable, Sendable {
            case small, regular, page, large

            var height: CGFloat {
                switch self {
                case .small: InkHeight.xs
                case .regular: InkHeight.sm
                case .page: InkHeight.standard
                case .large: InkHeight.lg
                }
            }

            var radius: CGFloat { InkRadius.row }

            var font: Font {
                switch self {
                case .small: InkType.smallButton.font
                case .regular: InkType.button.font
                case .page, .large: InkType.pageButton.font
                }
            }

            var paddingH: CGFloat {
                switch self {
                case .small: 8
                case .regular: 10
                case .page: 14
                case .large: 16
                }
            }
        }

        /// The default action is neutral (DESIGN §0.1, Q1): Ink `#EDEDED` with `#171717` text, Paper `#171717` with `#FAFAFA` text.
        /// Its fill is at 90 % under the pointer and 80 % pressed.
        static let defaultFillPair = Adaptive(dark: RGB(hex: 0xEDEDED), light: RGB(hex: 0x171717))
        static let defaultTextPair = Adaptive(dark: RGB(hex: 0x171717), light: RGB(hex: 0xFAFAFA))
        static let defaultHoverOpacity = 0.9
        static let defaultPressedOpacity = 0.8
        static let linkUnderlineBottom: CGFloat = 3

        /// The destructive button (DESIGN §0.4): the failure red, at 60 % in Ink and solid in Paper, with white text. Under the
        /// pointer it is 74 % in Ink and 90 % in Paper, which keeps the white text at 4.5:1 or more.
        static let destructiveFill = AdaptiveTone(
            dark: Tone(rgb: Status.failurePair.dark, opacity: 0.60),
            light: Tone(rgb: Status.failurePair.light, opacity: 1))
        /// The destructive button's label: white on the failure red in both appearances.
        static let destructiveText = whiteRGB.color
        static let destructiveHover = AdaptiveTone(
            dark: Tone(rgb: Status.failurePair.dark, opacity: 0.74),
            light: Tone(rgb: Status.failurePair.light, opacity: 0.90))

        /// Sphyrna's focus ring (DESIGN §0.1): a 1 pt edge in the accent and a 3 pt halo of the accent at 45 % outside the
        /// control's edge (75 % under Increase Contrast), drawn on keyboard focus only.
        static let focusEdge: CGFloat = 1
        static let focusHalo: CGFloat = 3
        static let focusHaloOpacity = 0.45
        static let focusHaloIncreasedOpacity = 0.75

        /// The shared controls' sizes (DESIGN §0.4): a switch 32 × 18; a field and a segmented control 32 high; a badge 18 high;
        /// a key cap of radius 4.
        static let switchSize = CGSize(width: 32, height: 18)
        static let switchInset: CGFloat = 2
        static let switchThumb: CGFloat = 14
        static let switchLabelGap: CGFloat = 6
        static var switchOffFill: Color { Surface.muted }
        static var switchOnFill: Color { Accent.base }
        static let switchThumbFill = Color.white
        static let segmentedHeight: CGFloat = InkHeight.standard
        static let segmentRadius: CGFloat = 6
        static let segmentGroupRadius: CGFloat = InkRadius.row
        static let segmentInset: CGFloat = 2
        static let segmentGap: CGFloat = 2
        static let segmentPaddingH: CGFloat = 10
        static let segmentFont = InkType.button
        static let fieldHeight: CGFloat = InkHeight.standard
        static let fieldRadius: CGFloat = InkRadius.row
        static let fieldPaddingH: CGFloat = 12
        static let badgeHeight: CGFloat = 18
        static let badgePaddingH: CGFloat = 4
        static let keyCapRadius: CGFloat = InkRadius.key
        static let keyCapPaddingH: CGFloat = 4
        static let keyCapMinSide: CGFloat = 18

        /// The glyph of an icon button: 16 pt, in secondary until hovered.
        static let iconGlyph = Font.system(size: 16)
        /// An icon button is 28 × 28 with radius 8 (`Layout.chromeButton`, `InkRadius.row`).
        static let iconSize = Layout.chromeButton
        static let iconRadius = InkRadius.row
    }

    /// The window's divider and the colours the app target needs from the shell.
    enum Shell {
        /// The canvas's hairline, as a dynamic colour for AppKit.
        static var dividerColor: NSColor { Surface.hairlineTone.nsColor }
        /// The divider under Increase Contrast: 30 % in Ink and 45 % in Paper (DESIGN §3).
        static var dividerIncreasedColor: NSColor { Surface.hairlineIncreasedTone.nsColor }
    }
}

extension LoomTheme.RGB {
    /// This colour with `share` of `other` mixed in (0 keeps this colour).
    func mixed(with other: LoomTheme.RGB, share: Double) -> LoomTheme.RGB {
        LoomTheme.RGB(red: red * (1 - share) + other.red * share, green: green * (1 - share) + other.green * share,
                      blue: blue * (1 - share) + other.blue * share)
    }
}

extension LoomTheme.Surface {
    /// The edge of controls, fields and chips: the strong hairline; the raised hairline (30 %, ink 45 % in Paper) under Increase Contrast.
    static let strongEdgeStyle = LoomTheme.ContrastStyle(
        standard: strongHairlineTone.dark,
        increased: LoomTheme.Tone(rgb: LoomTheme.whiteRGB, opacity: hairlineIncreasedOpacity),
        lightStandard: strongHairlineTone.light,
        lightIncreased: LoomTheme.Tone(rgb: LoomTheme.inkRGB, opacity: hairlineIncreasedLightOpacity))
}

extension LoomTheme.ProjectColor {
    /// A 1 pt edge of the tone at `opacity`; under Increase Contrast the tone's Increase Contrast value at `increasedOpacity`.
    static func edge(_ tone: ProjectTone, opacity: Double, increasedOpacity: Double) -> LoomTheme.ContrastStyle {
        LoomTheme.ContrastStyle(
            standard: LoomTheme.Tone(rgb: baseRGB(tone), opacity: opacity),
            increased: LoomTheme.Tone(rgb: increasedRGB(tone), opacity: increasedOpacity),
            lightStandard: LoomTheme.Tone(rgb: lightBaseRGB(tone), opacity: opacity),
            lightIncreased: LoomTheme.Tone(rgb: lightIncreasedRGB(tone), opacity: increasedOpacity))
    }

    /// The header chip's edge (DESIGN §6 Project colour): 32 %, 75 % under Increase Contrast.
    static func chipEdge(_ tone: ProjectTone) -> LoomTheme.ContrastStyle {
        edge(tone, opacity: chipEdgeOpacity, increasedOpacity: chipEdgeIncreasedOpacity)
    }

    /// The open tab's edge: 42 %, 75 % under Increase Contrast.
    static func tabEdge(_ tone: ProjectTone) -> LoomTheme.ContrastStyle {
        edge(tone, opacity: tabStrokeOpen, increasedOpacity: tabStrokeOpenIncreased)
    }
}

/// What the app target reads from the shell: the colour of the split view's divider (DESIGN §2 item 2).
public enum ShellChrome {
    /// The canvas's hairline, white 7 % in Ink and #E5E5E5 in Paper; 30 % and 45 % under Increase Contrast.
    public static var dividerColor: NSColor {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? LoomTheme.Shell.dividerIncreasedColor : LoomTheme.Shell.dividerColor
    }
}

/// The main window's split view: the sidebar beside the main pane, divided by the canvas's 1 pt hairline (DESIGN §2 item
/// 2). A split view controller's own split view is vertical; one set in its place starts horizontal (the panes would
/// stack), so this one is made vertical and thin here.
public final class CanvasSplitView: NSSplitView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isVertical = true
        dividerStyle = .thin
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override var dividerColor: NSColor { ShellChrome.dividerColor }

    /// The divider is an opaque line (FB6-1): the canvas under the canvas's hairline, so the clear window never shows through
    /// the 1 pt gap between the panes — neither pane paints under it.
    public override func drawDivider(in rect: NSRect) {
        LoomTheme.Surface.canvasNS.setFill()
        rect.fill()
        dividerColor.setFill()
        rect.fill()
    }

    /// Appearance and Increase Contrast change what the divider resolves to, and AppKit keeps the divider's drawing: redraw it.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: Focus ring

/// Sphyrna's focus ring on a control (DESIGN §0.1): the accent's 1 pt edge and a 3 pt halo of the accent outside it, drawn only
/// while `visible` (focused and keyboard navigation on, `ChromeButtonStyle.showsFocusRing`).
private struct ControlFocusRing: ViewModifier {
    let visible: Bool
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let halo = LoomTheme.Control.focusHalo
        let haloOpacity = contrast == .increased
            ? LoomTheme.Control.focusHaloIncreasedOpacity : LoomTheme.Control.focusHaloOpacity
        content.overlay {
            if visible {
                ZStack {
                    // A stroke centred half the halo's width outside the edge covers the band from the edge out to the halo's width.
                    RoundedRectangle(cornerRadius: radius + halo / 2)
                        .stroke(LoomTheme.Surface.focusRing.opacity(haloOpacity), lineWidth: halo)
                        .padding(-halo / 2)
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(LoomTheme.Surface.focusRing, lineWidth: LoomTheme.Control.focusEdge)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    /// The focus ring of the control family around a control of this corner radius.
    func controlFocusRing(visible: Bool, radius: CGFloat) -> some View {
        modifier(ControlFocusRing(visible: visible, radius: radius))
    }
}
