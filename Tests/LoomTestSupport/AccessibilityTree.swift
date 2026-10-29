import AppKit
import Foundation
import SwiftUI
import Testing

/// One node of the accessibility tree as an assistive technology would read it.
public struct AXNode {
    public let role: String
    public let subrole: String?
    public let label: String?
    public let value: String?
    public let title: String?
    public let roleDescription: String?
    public let help: String?
    public let traits: Int
    public let children: [AXNode]

    /// UIAccessibilityTraitHeader, the bit SwiftUI sets for `.isHeader`.
    public var isHeader: Bool { traits & 0x10000 != 0 }

    public func flattened() -> [AXNode] { [self] + children.flatMap { $0.flattened() } }
    public var description: String { "\(role)\(subrole.map { "/\($0)" } ?? "") label=\(label ?? "-") value=\(value ?? "-") title=\(title ?? "-") rd=\(roleDescription ?? "-") help=\(help ?? "-")" }
}

@MainActor
public func axTree(of object: Any, depth: Int = 0) -> AXNode {
    let element = object as AnyObject
    func string(_ selector: String) -> String? {
        guard element.responds(to: NSSelectorFromString(selector)) else { return nil }
        let result = element.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
        return (result as? String) ?? (result as? NSNumber).map { "\($0)" }
    }
    let children: [Any] = depth > 40 ? [] : ((element.accessibilityChildren?() as? [Any]) ?? [])
    return AXNode(role: string("accessibilityRole") ?? "?", subrole: string("accessibilitySubrole"),
                  label: string("accessibilityLabel"), value: string("accessibilityValue"),
                  title: string("accessibilityTitle"),
                  roleDescription: string("accessibilityRoleDescription"), help: string("accessibilityHelp"),
                  traits: (element.accessibilityAttributeValue?(NSAccessibility.Attribute(rawValue: "AXTraits")) as? Int) ?? 0,
                  children: children.map { axTree(of: $0, depth: depth + 1) })
}

/// What a hosted SwiftUI view exposes to VoiceOver. AppKit builds the SwiftUI tree only for an
/// accessibility client, so the test process asks for it (no system setting is touched).
@MainActor
public func enableAccessibilityTree() {
    for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
        _ = NSApplication.shared.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                                         with: true as NSNumber, with: attribute)
    }
}

@MainActor
public func accessibilityElements(in object: Any) -> [AnyObject] {
    let element = object as AnyObject
    let children = (element.accessibilityChildren?() as? [Any]) ?? []
    return [element] + children.flatMap(accessibilityElements(in:))
}
