import AppKit
import Foundation

/// Reads of one accessibility element for the Settings tests (`SidebarAccessibilityTests.axTree` reads the same selectors). The tree
/// elements are `AnyObject`s that answer these selectors; `accessibilityValue()` and the like are ambiguous on `AnyObject`.
@MainActor
enum InkAX {
    /// A string-valued selector (`accessibilityLabel`, `accessibilityValue`, `accessibilityIdentifier` …); numbers read as their text.
    static func text(_ element: AnyObject, _ selector: String) -> String? {
        guard element.responds(to: NSSelectorFromString(selector)) else { return nil }
        let result = element.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
        return (result as? String) ?? (result as? NSNumber).map { "\($0)" }
    }

    static func identifier(_ element: AnyObject) -> String { text(element, "accessibilityIdentifier") ?? "" }
    static func label(_ element: AnyObject) -> String { text(element, "accessibilityLabel") ?? "" }
    static func value(_ element: AnyObject) -> String? { text(element, "accessibilityValue") }

    static func frame(_ element: AnyObject) -> NSRect {
        element.accessibilityFrame()
    }

    /// The names of the native menus under `view` (role `AXMenuButton`): a menu's own label reads as its title or its label,
    /// either of them possibly an attributed string; "" for a menu with neither.
    static func menuButtonLabels(in view: NSView) -> [String] {
        accessibilityElements(in: view).compactMap { element in
            let role: Any? = element.accessibilityRole?()
            guard (role as? NSAccessibility.Role) == .menuButton else { return nil }
            let names = ["accessibilityTitle", "accessibilityLabel"].compactMap { selector -> String? in
                guard element.responds(to: NSSelectorFromString(selector)) else { return nil }
                let name = element.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
                return (name as? String) ?? (name as? NSAttributedString)?.string
            }
            return names.first { !$0.isEmpty } ?? ""
        }
    }

    /// Whether the element holds the accessibility focus (SwiftUI's focus follows it).
    static func isFocused(_ element: AnyObject) -> Bool {
        (element.accessibilityAttributeValue?(NSAccessibility.Attribute(rawValue: "AXFocused")) as? Bool) ?? false
    }
}
