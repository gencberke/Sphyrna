import AppKit
import LoomCore
import SwiftUI

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

    /// The control family (DESIGN §6 Controls): one height, radius, hover and focus ring for every control. A button is 26 high
    /// with radius 6 in 12.5 medium; a page's main action 30 with radius 8 in 13; a small button 22 with radius 5 in 11.5.
    enum Control {
        enum Size: CaseIterable, Sendable {
            case regular, page, small

            var height: CGFloat {
                switch self {
                case .regular: InkHeight.control
                case .page: InkHeight.field
                case .small: InkHeight.chip
                }
            }

            var radius: CGFloat {
                switch self {
                case .regular: InkRadius.control
                case .page: InkRadius.row
                case .small: 5
                }
            }

            var font: Font {
                switch self {
                case .regular: InkType.button.font
                case .page: InkType.pageButton.font
                case .small: .system(size: 11.5, weight: .medium)
                }
            }

            var paddingH: CGFloat {
                switch self {
                case .regular: 10
                case .page: 14
                case .small: 8
                }
            }
        }

        /// The glyph of an icon button: 16 pt, in secondary until hovered.
        static let iconGlyph = Font.system(size: 16)
        static let iconSize = Layout.chromeButton
        static let iconRadius = InkRadius.control

        /// The filled accent button under the pointer: the accent a step toward white in Ink and toward black in Paper
        /// (`color-mix(accent 86 %, #fff)` in the reference).
        static let primaryHoverPair = Adaptive(
            dark: Accent.basePair.dark.mixed(with: whiteRGB, share: 0.14),
            light: Accent.basePair.light.mixed(with: RGB(red: 0, green: 0, blue: 0), share: 0.14))
        static let primaryHover = primaryHoverPair.color
    }

    /// The window's divider and the colours the app target needs from the shell.
    enum Shell {
        /// The canvas's hairline, as a dynamic colour for AppKit.
        static var dividerColor: NSColor { Surface.hairlineTone.nsColor }
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
        standard: LoomTheme.Tone(rgb: LoomTheme.whiteRGB, opacity: strongHairlineOpacity),
        increased: LoomTheme.Tone(rgb: LoomTheme.whiteRGB, opacity: hairlineIncreasedOpacity),
        lightStandard: LoomTheme.Tone(rgb: LoomTheme.inkRGB, opacity: strongHairlineLightOpacity),
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
    /// The canvas's hairline, white 7.5 % in Ink and the ink 8.5 % in Paper.
    public static var dividerColor: NSColor { LoomTheme.Shell.dividerColor }
}

// MARK: Focus ring

/// Sphyrna's focus ring on a control: the accent, 2 pt wide and 2 pt outside it (2.5 wide under Increase Contrast), drawn
/// only while `visible` (focused and keyboard navigation on, `ChromeButtonStyle.showsFocusRing`).
private struct ControlFocusRing: ViewModifier {
    let visible: Bool
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let width = LoomTheme.Line.focusRing(for: contrast)
        let reach = LoomTheme.Line.focusRingOffset + width
        content.overlay {
            RoundedRectangle(cornerRadius: radius + reach)
                .strokeBorder(visible ? LoomTheme.Surface.focusRing : .clear, lineWidth: width)
                .padding(-reach)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// The focus ring of the control family around a control of this corner radius.
    func controlFocusRing(visible: Bool, radius: CGFloat) -> some View {
        modifier(ControlFocusRing(visible: visible, radius: radius))
    }
}
