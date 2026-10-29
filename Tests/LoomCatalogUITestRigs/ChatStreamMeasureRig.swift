import AppKit
import Foundation
import Testing
import LoomChat
import LoomCore
import SwiftUI
@testable import LoomCatalogUI
import LoomTestSupport

/// Shared by `ChatStreamMeasureTests` and the tests of other tiers that reuse its fixtures (DEVELOPMENT §3.1).
enum ChatStreamMeasureRig {
    @MainActor static func streamingRow(id: String, text: String, flags: Set<String> = [], fold: ChatTreePosition? = nil) -> ChatRow {
        var row = baseRow()
        guard case var .prose(entry, _) = row.kind, case var .assistantText(body) = entry.body else { return row }
        entry.id = id
        body.text = text
        body.isStreaming = true
        entry.body = .assistantText(body)
        row = ChatRow(id: id, kind: .prose(entry, settled: false), flags: flags)
        row.foldGuide = fold
        return row
    }

    /// The row laid out whole, unceiled: what the composition has to match.
    @MainActor static func wholeHeight(_ row: ChatRow, width: CGFloat, context: ChatRowContext,
                                       host: NSHostingController<ChatRowView>) -> CGFloat {
        host.rootView = ChatRowView(row: row, context: context, measuring: true)
        return host.sizeThatFits(in: CGSize(width: width, height: 100_000)).height
    }

    @MainActor static func baseRow() -> ChatRow {
        ChatFixture.rows(ChatFixture.turn(1, answer: "base")).first { if case .prose = $0.kind { true } else { false } }!
    }
}
