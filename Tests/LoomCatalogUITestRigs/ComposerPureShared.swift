import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LoomCatalogUI
@testable import LoomChat
@testable import LoomCore
import LoomTestSupport

/// What both halves of `ComposerPureTests` use (the split by tier copied it; DEVELOPMENT §3.1).
enum ComposerPureShared {
    nonisolated static let qLayouts = ["com.apple.keylayout.Turkish-QWERTY", "com.apple.keylayout.Turkish-QWERTY-PC"]

    nonisolated static let fLayouts = ["com.apple.keylayout.Turkish", "com.apple.keylayout.Turkish-Standard"]

    @MainActor
    static func layout(_ id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// The character a key makes with these Carbon modifiers (`shift` 2, `option` 8), dead keys off.
    @MainActor
    static func character(_ layout: Data, key: UInt16, modifiers: UInt32) -> String {
        layout.withUnsafeBytes { raw -> String in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return "" }
            var dead: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(base, key, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &characters)
            return status == noErr ? String(utf16CodeUnits: characters, count: length) : ""
        }
    }

    /// The chords that type `target` on a layout: (key code, Carbon modifiers).
    @MainActor
    static func chords(typing target: String, _ layout: Data) -> [(UInt16, UInt32)] {
        var found: [(UInt16, UInt32)] = []
        for key in UInt16(0)...UInt16(50) {
            for modifiers: UInt32 in [0, 2, 8, 10] where character(layout, key: key, modifiers: modifiers) == target {
                found.append((key, modifiers))
            }
        }
        return found
    }
}

/// `ComposerBarTextTests`'s fixtures, for both halves of the suite.
protocol ComposerBarTextFixtures {}

extension ComposerBarTextFixtures {
    func state(_ adjust: (inout ChatComposerState) -> Void = { _ in }) -> ChatComposerState {
        var state = ChatComposerState.idle(sessionID: UUID())
        adjust(&state)
        return state
    }
}

/// `ComposerPasteTests`'s fixtures, for both halves of the suite.
protocol ComposerPasteFixtures {}

extension ComposerPasteFixtures {
    func png(width: Int, height: Int, alpha: Bool = false) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                   samplesPerPixel: alpha ? 4 : 3, hasAlpha: alpha, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
