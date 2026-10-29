import AppKit
import Foundation
import SwiftUI
import Testing
import LoomCore
@testable import LoomCatalogUI
@testable import LoomCatalogUITestRigs

/// D-69 point 11 (O-12): the failure mark under "Differentiate without color" and the app icon on the first-run Home.
/// Both are drawn off screen with `ImageRenderer`; nothing opens a window.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct IdentityMarksTests {
    private static let scale: CGFloat = 4

    /// The area the view paints, in points squared: the sum of the alpha over the render.
    private func ink<Content: View>(_ content: Content) throws -> (area: Double, rect: CGRect) {
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.scale
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        var area = 0.0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let alpha = Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                guard alpha > 0.02 else { continue }
                area += alpha
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let rect = maxX < 0 ? CGRect.zero
            : CGRect(x: CGFloat(minX) / Self.scale, y: CGFloat(minY) / Self.scale,
                     width: CGFloat(maxX - minX + 1) / Self.scale, height: CGFloat(maxY - minY + 1) / Self.scale)
        return (area / Double(Self.scale * Self.scale), rect)
    }

    private func indicator(_ state: SessionIndicator, differentiate: Bool) -> some View {
        IndicatorView(indicator: state)
            .transformEnvironment(\.self) { $0._accessibilityDifferentiateWithoutColor = differentiate }
    }

    @Test func theDecisionNamesFailureStatesOnlyAndOnlyUnderTheSetting() {
        for state in [SessionIndicator.failed(nil), .failed("rate limit"), .stopUnverified("x"), .problem("x")] {
            #expect(IndicatorView.drawsDiamond(state, differentiateWithoutColor: true))
            #expect(!IndicatorView.drawsDiamond(state, differentiateWithoutColor: false))
        }
        for state in [SessionIndicator.waitingForApproval, .waitingForInput, .unviewedCompletion, .working,
                      .identityUnclear, .unknown, .idle, .ready, .stale, .ended] {
            #expect(!IndicatorView.drawsDiamond(state, differentiateWithoutColor: true), "\(state) keeps its mark")
        }
    }

    /// A 7 pt diamond covers about two thirds of the 7 pt dot's area (24.5 against 38.5 pt squared) and reaches the middle of its
    /// edges, not their corners.
    @Test func failureIsADiamondOnlyWhileDifferentiateWithoutColorIsOn() throws {
        let dot = try ink(indicator(.failed(nil), differentiate: false))
        let diamond = try ink(indicator(.failed(nil), differentiate: true))
        #expect(abs(dot.area - Double.pi * 3.5 * 3.5) < 3, "the dot covers \(dot.area) pt squared")
        #expect(abs(diamond.area - 24.5) < 3, "the diamond covers \(diamond.area) pt squared")
        #expect(abs(diamond.rect.width - LoomTheme.Layout.failureDiamond) < 0.6
                && abs(diamond.rect.height - LoomTheme.Layout.failureDiamond) < 0.6, "\(diamond.rect)")
        // The other failure states follow, and attention keeps its dot under the setting.
        #expect(abs(try ink(indicator(.problem("x"), differentiate: true)).area - 24.5) < 3)
        #expect(abs(try ink(indicator(.stopUnverified("x"), differentiate: true)).area - 24.5) < 3)
        let attention = try ink(indicator(.waitingForApproval, differentiate: true))
        #expect(abs(attention.area - dot.area) < 1, "attention is a dot under the setting")
        let unviewed = try ink(indicator(.unviewedCompletion, differentiate: true))
        #expect(abs(unviewed.area - dot.area) < 1)
    }

    /// Ink's status marks (DESIGN §4): the attention, unviewed and failure dots are 7 pt; State unknown and Identity
    /// unclear are hollow rings, 8 pt across.
    @Test func theDotsAreSevenPointsAndTheRingsEight() throws {
        for state in [SessionIndicator.waitingForApproval, .waitingForInput, .unviewedCompletion, .failed(nil)] {
            let dot = try ink(indicator(state, differentiate: false))
            #expect(abs(dot.rect.width - 7) < 0.6 && abs(dot.rect.height - 7) < 0.6, "\(state): \(dot.rect)")
        }
        for state in [SessionIndicator.unknown, .identityUnclear] {
            let ring = try ink(indicator(state, differentiate: false))
            #expect(abs(ring.rect.width - 8) < 0.6 && abs(ring.rect.height - 8) < 0.6, "\(state): \(ring.rect)")
            // Hollow: the ring's ink is its stroke, far less than a disc of that size.
            #expect(ring.area < Double.pi * 16 * 0.75, "\(state) covers \(ring.area) pt squared")
        }
        #expect(LoomTheme.StatusMark.dot == 7 && LoomTheme.StatusMark.ring == 8)
    }

    /// The project row's dot follows the card's rule: failure is a diamond under the setting, attention and an
    /// unviewed finish stay dots, and the card and the row agree for every indicator.
    @Test func theProjectRowsFailureDotIsADiamondUnderTheSameRule() throws {
        func mark(_ attention: ProjectAttention, _ differentiate: Bool) -> some View {
            ProjectAttentionMark(attention: attention, differentiateWithoutColor: differentiate)
        }
        let dot = try ink(mark(.failure, false))
        let diamond = try ink(mark(.failure, true))
        #expect(abs(dot.area - Double.pi * 12.25) < 3, "the dot covers \(dot.area) pt squared (7 pt)")
        #expect(abs(diamond.area - 24.5) < 3, "the diamond covers \(diamond.area) pt squared")
        #expect(abs(try ink(mark(.attention, true)).area - dot.area) < 1)
        #expect(abs(try ink(mark(.unviewed, true)).area - dot.area) < 1)
        // One rule for both views.
        let states: [SessionIndicator] = [.failed(nil), .stopUnverified("x"), .problem("x"), .waitingForApproval,
                                          .waitingForInput, .unviewedCompletion, .identityUnclear, .working, .idle]
        for state in states {
            for setting in [true, false] {
                #expect(IndicatorView.drawsDiamond(state, differentiateWithoutColor: setting)
                        == ProjectAttention.drawsDiamond(ProjectAttention(state), differentiateWithoutColor: setting),
                        "\(state) with the setting \(setting)")
            }
        }
        #expect(!ProjectAttention.drawsDiamond(nil, differentiateWithoutColor: true))
    }

    @Test func onlyTheFirstRunCarriesTheMarkAndConnectYourAgentsTakesItsPlace() {
        #expect(HomeEmptyCatalog.showsMark(connectCards: false))
        #expect(!HomeEmptyCatalog.showsMark(connectCards: true))
    }
}
