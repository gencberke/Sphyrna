import AppKit
import Observation
import SwiftUI
import Testing
@testable import LoomCatalogUI
import LoomTestSupport
@testable import LoomCatalogUITestRigs

@MainActor @Observable private final class ControlTestState {
    var on = false
    var selection = "One"
    var enabled = true
    var stepperValue = 2
}

private struct ControlTestHarness: View {
    let state: ControlTestState

    var body: some View {
        VStack {
            InkSwitch(title: "Notifications", isOn: Binding(get: { state.on }, set: { state.on = $0 }))
            InkSegmented(values: ["One", "Two"], title: { $0 }, selection: state.selection,
                         enabled: state.enabled, onSelect: { state.selection = $0 })
                .accessibilityLabel("Choice")
            InkStepper(title: "Threshold", value: state.stepperValue, range: 1...3, valueText: "\(state.stepperValue)",
                       onChange: { state.stepperValue = $0 })
                .accessibilityIdentifier("test-stepper")
        }
        .padding(8)
    }
}

/// Ink v4's control family (DESIGN §0.1, §0.3, §0.4): six button roles at four heights, the neutral default action, the focus ring,
/// and the sizes of the shared controls. The values are data, so the rules are checked without a window.
struct ControlFamilyTests {
    typealias RGB = LoomTheme.RGB
    private static let white = RGB(red: 1, green: 1, blue: 1)

    @Test func thereAreSixButtonRolesNamedAsDesignSays() {
        #expect(ControlButtonStyle.Kind.allCases.map { "\($0)" } == ["default", "secondary", "outline", "ghost", "link", "destructive"])
    }

    /// Four heights (24, 28, 32, 36) and one radius (8) for every button.
    @Test func thereAreFourHeightsAndOneRadiusForEveryButton() {
        #expect(LoomTheme.Control.Size.allCases.map(\.height) == [24, 28, 32, 36])
        #expect(LoomTheme.Control.Size.allCases.allSatisfy { $0.radius == 8 })
    }

    /// The default action is neutral (Q1): Ink's `#EDEDED` with `#171717` text, Paper's `#171717` with `#FAFAFA`; hover at 90 %.
    @Test func theDefaultActionIsNeutralAndItsTextHoldsSevenToOne() {
        #expect(LoomTheme.Control.defaultFillPair == LoomTheme.Adaptive(dark: RGB(hex: 0xEDEDED), light: RGB(hex: 0x171717)))
        #expect(LoomTheme.Control.defaultTextPair == LoomTheme.Adaptive(dark: RGB(hex: 0x171717), light: RGB(hex: 0xFAFAFA)))
        #expect(LoomTheme.Control.defaultHoverOpacity == 0.9)
        for appearance in LoomTheme.Appearance.allCases {
            let contrast = LoomTheme.Control.defaultTextPair[appearance].contrast(with: LoomTheme.Control.defaultFillPair[appearance])
            #expect(contrast >= 7, "\(appearance): \(contrast)")
        }
    }

    /// Destructive is the failure red (60 % in Ink, solid in Paper) with white text; its text holds 4.5:1 at rest and under the pointer.
    @Test func theDestructiveTextHoldsFourAndAHalfOnItsFillInBothAppearances() {
        for appearance in LoomTheme.Appearance.allCases {
            let canvas = LoomTheme.Surface.greys(appearance, tone: .neutral).canvas
            for tone in [LoomTheme.Control.destructiveFill[appearance], LoomTheme.Control.destructiveHover[appearance]] {
                let fill = tone.rgb.composited(over: canvas, opacity: tone.opacity)
                #expect(Self.white.contrast(with: fill) >= 4.5, "\(appearance): \(Self.white.contrast(with: fill))")
            }
        }
        #expect(LoomTheme.Control.destructiveFill.dark.opacity == 0.60 && LoomTheme.Control.destructiveFill.light.opacity == 1)
    }

    /// The focus ring (DESIGN §0.1): a 1 pt accent edge and a 3 pt halo of the accent at 45 % outside the control.
    @Test func theFocusRingIsAnAccentEdgeAndAThreePointHalo() {
        #expect(LoomTheme.Control.focusEdge == 1 && LoomTheme.Control.focusHalo == 3)
        #expect(LoomTheme.Control.focusHaloOpacity == 0.45)
        #expect(LoomTheme.Control.focusHaloIncreasedOpacity > LoomTheme.Control.focusHaloOpacity)
    }

    /// The shared controls (DESIGN §0.4): a switch is 32 × 18, a field and the segmented control are 32 high, a badge 18 high, and a
    /// key cap is radius 4.
    @Test func theSharedControlsHaveDesignsSizes() {
        #expect(LoomTheme.Control.switchSize == CGSize(width: 32, height: 18))
        #expect(LoomTheme.Control.segmentedHeight == 32 && LoomTheme.Control.segmentRadius == 6)
        #expect(LoomTheme.Control.fieldHeight == 32 && LoomTheme.Control.fieldRadius == 8)
        #expect(LoomTheme.Control.badgeHeight == 18)
        #expect(LoomTheme.Control.keyCapRadius == 4)
    }

    /// Measure the actual controls, not just the tokens: both settings switches and the segmented choices use these views.
    @MainActor @Test func theRenderedSwitchAndSegmentsUseV4Sizes() {
        func fittingSize<V: View>(_ view: V) -> CGSize {
            let host = NSHostingView(rootView: view)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        for isOn in [false, true] {
            let size = fittingSize(Toggle("Notifications", isOn: .constant(isOn)).labelsHidden().toggleStyle(InkSwitchStyle()))
            #expect(size == CGSize(width: 32, height: 24), "switch on=\(isOn): its track is 32 × 18 inside a 24 pt hit area: \(size)")
        }
        let labelled = fittingSize(InkSwitch(title: "Allow edits", isOn: .constant(false), showsLabel: true))
        #expect(labelled.width > 32 && labelled.height == 24, "the Side switch keeps its visible label")
        for choice in ["One", "Two"] {
            let size = fittingSize(InkSegmented(values: ["One", "Two"], title: { $0 }, selection: choice, onSelect: { _ in }))
            #expect(size.height == 32, "selection \(choice): \(size)")
        }
    }

    /// A main action raises the button row from the 32 pt Cancel to 36 pt, for both save and destructive questions.
    @MainActor @Test func sheetMainActionsAreTallerThanCancel() {
        func height(_ actions: [SheetAction]) -> CGFloat {
            let host = NSHostingView(rootView: InkSheet(title: "Question", cancel: {}, actions: actions) { EmptyView() })
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let cancelOnly = height([])
        for tint: SheetAction.Tint in [.filled, .failure, .accent, .tone(LoomTheme.Control.defaultFillPair)] {
            let withAction = height([SheetAction(id: "main", title: "Continue", tint: tint, perform: {})])
            #expect(abs(withAction - cancelOnly - 4) < 0.5, "\(tint): \(withAction - cancelOnly)")
        }
    }

    /// The remaining shared controls keep their measured size in each of their supported states.
    @MainActor @Test func fieldBadgeAndKeyChipMeasureAsTheV4Family() {
        func size<V: View>(_ view: V) -> CGSize {
            let host = NSHostingView(rootView: view)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        for focused in [false, true] {
            for hasError in [false, true] {
                let field = InkField(focused: focused, hasError: hasError) {
                    TextField("Title", text: .constant("Hello"))
                }.frame(width: 200)
                #expect(size(field).height == 32)
            }
        }
        for kind: InkBadge.Kind in [.neutral, .outline, .status(fill: .red, text: .white)] {
            #expect(size(InkBadge(text: "3", kind: kind)).height == 18)
        }
        #expect(size(KeyChip(text: "⌘K")).height == 18)
        #expect(LoomTheme.InkType.caption.size == 11 && !LoomTheme.InkType.caption.mono)
        #expect(LoomTheme.InkType.meta.size == 11 && LoomTheme.InkType.meta.mono)
    }

    @MainActor @Test func theSettingsStepperUsesThePageControlGeometry() {
        let host = NSHostingView(rootView: InkStepper(title: "Retention", value: 30, range: 7...365,
                                                      valueText: "30 days", onChange: { _ in }))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == 32, "the rendered stepper is \(host.fittingSize.height) pt high")
        #expect(LoomTheme.Settings.stepperButton == 32 && LoomTheme.Settings.stepperRadius == 8)
    }

    @MainActor @Test func decorativeKeyChipsDoNotAddAccessibilityElements() async throws {
        enableAccessibilityTree()
        let host = NSHostingController(rootView: VStack {
            Button {} label: { HStack { Text("Open"); KeyChip(text: "⌘O") } }
                .accessibilityLabel("Open").accessibilityIdentifier("open-action")
            KeyChip(text: "⌘K").accessibilityIdentifier("decorative-key")
            KeyChip(text: "⇥", isDecorative: false).accessibilityIdentifier("spoken-key")
        }.padding(8))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120))
        host.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let elements = accessibilityElements(in: host.view)
        let buttons = elements.filter { InkAX.identifier($0) == "open-action" && $0.accessibilityRole?() == .button }
        #expect(buttons.count == 1 && buttons.first.map(InkAX.label) == "Open")
        #expect(!elements.contains { InkAX.identifier($0) == "decorative-key" }, "a decorative key cap is not a second accessibility item")
        #expect(elements.contains { InkAX.identifier($0) == "spoken-key" }, "a standalone key hint remains readable")
    }

    @MainActor @Test func sharedControlStatesUseTheV4PaletteAndKeyboardFocusRule() {
        #expect(LoomTheme.Control.switchOffFill == LoomTheme.Surface.muted)
        #expect(LoomTheme.Control.switchOnFill == LoomTheme.Accent.base)
        #expect(LoomTheme.Control.switchThumbFill == .white)
        #expect(LoomTheme.Control.switchThumb == 14 && LoomTheme.Control.switchInset == 2)
        #expect(LoomTheme.Control.segmentGroupRadius == 8 && LoomTheme.Control.segmentRadius == 6)
        #expect(LoomTheme.Control.fieldPaddingH == 12)
        #expect(!ChromeButtonStyle.showsFocusRing(focused: true, keyboardNavigation: false))
        #expect(ChromeButtonStyle.showsFocusRing(focused: true, keyboardNavigation: true))
        #expect(!ChromeButtonStyle.showsFocusRing(focused: false, keyboardNavigation: true))
        let label = LoomTheme.InkType.label
        #expect(label.size == 11 && label.weight == .semibold && !label.mono && label.capitals && label.tracking == 0.05)
    }

    /// Exercise the drawn states: the track, selected segment, badge and field edge must actually use their design colours.
    @MainActor @Test(.renderProbe) func sharedControlsDrawTheirStateColours() throws {
        func render<V: View>(_ view: V) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        func rgba(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> [CGFloat] {
            let color = try #require(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        }
        func close(_ a: [CGFloat], _ b: [CGFloat]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) < 0.03 } }
        func swatch(_ color: Color) throws -> [CGFloat] {
            try rgba(render(Rectangle().fill(color).frame(width: 8, height: 8)), 4, 4)
        }

        let muted = try swatch(LoomTheme.Surface.muted)
        let accent = try swatch(LoomTheme.Accent.base)
        let selected = try swatch(LoomTheme.Surface.segmentOn)
        for on in [false, true] {
            let image = try render(InkSwitch(title: "Notifications", isOn: .constant(on)))
            #expect(close(try rgba(image, on ? 5 : 26, 12), on ? accent : muted), "switch on=\(on)")
            #expect(try rgba(image, 16, 0)[3] < 0.01, "the 18 pt track sits within a 24 pt hit area")
        }
        for selection in ["One", "Two"] {
            let image = try render(InkSegmented(values: ["One", "Two"], title: { $0 }, selection: selection, onSelect: { _ in }))
            #expect(close(try rgba(image, 10, 5), selection == "One" ? selected : muted), "first segment, \(selection)")
            #expect(close(try rgba(image, image.pixelsWide - 10, 5), selection == "Two" ? selected : muted), "second segment, \(selection)")
        }
        RenderProbeExclusive.holdHover("segment:Two")
        let hovered = try render(InkSegmented(values: ["One", "Two"], title: { $0 }, selection: "One", onSelect: { _ in }))
        let hoverFill = try rgba(render(Rectangle().fill(LoomTheme.Surface.muted)
            .overlay(Rectangle().fill(LoomTheme.Surface.hover)).frame(width: 8, height: 8)), 4, 4)
        #expect(close(try rgba(hovered, hovered.pixelsWide - 10, 5), hoverFill), "unchosen hover uses the shared hover fill")
        let badge = try render(InkBadge(text: ""))
        #expect(close(try rgba(badge, badge.pixelsWide / 2, 9), muted))
        let statusBadge = try render(InkBadge(text: "", kind: .status(fill: .red, text: .white)))
        #expect(close(try rgba(statusBadge, statusBadge.pixelsWide / 2, 9), try swatch(.red)))
        let outlineBadge = try render(InkBadge(text: "", kind: .outline))
        #expect(try rgba(outlineBadge, outlineBadge.pixelsWide / 2, 9)[3] < 0.01)
        let failure = try swatch(LoomTheme.Status.failure)
        let field = try render(InkField(focused: false, hasError: true) { Color.clear }.frame(width: 100))
        #expect(close(try rgba(field, 0, 16), failure), "error edge")

        func alphaTotal(_ image: NSBitmapImageRep) throws -> CGFloat {
            try (0..<image.pixelsHigh).reduce(CGFloat.zero) { sum, y in
                try sum + (0..<image.pixelsWide).reduce(CGFloat.zero) { subtotal, x in
                    try subtotal + rgba(image, x, y)[3]
                }
            }
        }
        RenderProbeExclusive.holdHover(nil)
        let link = Button("Details") {}.buttonStyle(ControlButtonStyle(kind: .link, size: .small, key: "test-link"))
        let resting = try render(link)
        RenderProbeExclusive.holdHover("test-link")
        let lit = try render(link)
        #expect(try alphaTotal(lit) > alphaTotal(resting) + 5, "a hovered link gains its underline")
    }

    @MainActor @Test func theSharedFocusHaloAppearsOnlyWhenVisible() throws {
        func pixel(visible: Bool) throws -> NSColor {
            let view = Rectangle().fill(Color.black).frame(width: 20, height: 20)
                .controlFocusRing(visible: visible, radius: 4).padding(4)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            return try #require(image.colorAt(x: 2, y: 14)?.usingColorSpace(.sRGB))
        }
        let hidden = try pixel(visible: false)
        let normal = try pixel(visible: true)
        #expect(hidden.alphaComponent < 0.01)
        #expect(normal.alphaComponent > 0.3)
        #expect(LoomTheme.Control.focusHaloIncreasedOpacity > LoomTheme.Control.focusHaloOpacity)
    }

    /// A hidden halo must not enlarge any shared control's accessibility frame.
    @MainActor @Test func anUnfocusedSharedControlKeepsItsAccessibilityFrame() async throws {
        enableAccessibilityTree()
        let size = NSSize(width: 120, height: 28)
        func frame<V: View>(_ view: V) async throws -> CGRect {
            let root = view.accessibilityElement(children: .contain).accessibilityIdentifier("test-control-frame")
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(!window.isVisible)
            let element = try #require(accessibilityElements(in: host).first { InkAX.identifier($0) == "test-control-frame" })
            return element.accessibilityFrame()
        }
        let button = Button("Action") {}.buttonStyle(.plain).frame(width: size.width, height: size.height)
        let reference = try await frame(button)
        let hidden = try await frame(button.controlFocusRing(visible: false, radius: LoomTheme.Control.iconRadius))
        print("CONTROL-FOCUS-OFFSCREEN reference=\(reference) hidden=\(hidden)")
        #expect(abs(hidden.width - reference.width) < 0.5 && abs(hidden.height - reference.height) < 0.5)
    }

    /// The custom drawing keeps a native toggle's value and action, and each segment remains an actionable named choice.
    @MainActor @Test func sharedControlsExposeAccessibleActionsAndRespectDisabledState() async throws {
        enableAccessibilityTree()
        let state = ControlTestState()
        let host = NSHostingController(rootView: ControlTestHarness(state: state))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 140), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(120))
            host.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        try await settle()
        func elements() -> [AnyObject] { accessibilityElements(in: host.view) }
        let toggle = try #require(elements().first { $0.accessibilityRole?() == .checkBox && InkAX.label($0) == "Notifications" })
        #expect(InkAX.value(toggle) == "0")
        #expect(toggle.accessibilityPerformPress?() == true)
        try await settle()
        #expect(state.on && InkAX.value(toggle) == "1")
        let two = try #require(elements().first { $0.accessibilityRole?() == .button && InkAX.label($0) == "Two" })
        #expect(two.accessibilityPerformPress?() == true)
        try await settle()
        #expect(state.selection == "Two")
        state.enabled = false
        try await settle()
        let disabled = try #require(elements().first { $0.accessibilityRole?() == .button && InkAX.label($0) == "One" })
        #expect(disabled.isAccessibilityEnabled?() == false)
        let stepper = try #require(elements().first { InkAX.identifier($0) == "test-stepper" })
        // SwiftUI exposes a textual adjustable value as AXValueDescription, not numeric AXValue.
        #expect(InkAX.text(stepper, "accessibilityValueDescription") == "2")
        #expect(stepper.accessibilityPerformIncrement?() == true)
        try await settle()
        #expect(state.stepperValue == 3 && InkAX.text(stepper, "accessibilityValueDescription") == "3")
        #expect(stepper.accessibilityPerformIncrement?() == true)
        #expect(state.stepperValue == 3, "the upper bound cannot be stepped past")
        #expect(stepper.accessibilityPerformDecrement?() == true)
        try await settle()
        #expect(state.stepperValue == 2 && InkAX.text(stepper, "accessibilityValueDescription") == "2")
    }
}
