import SwiftUI

/// The agent's words and its Result in the Agents tab as Markdown (FB6-18): the Chat's blocks (`ChatContent.blocks`, cached by
/// text) at the tab's type scale. Links open only for http, https and mailto, as in Chat. The blocks are parsed once per text,
/// and the list of lines is lazy, so only the rows in view build a view.
struct SubagentMarkdownView: View {
    let id: String
    let text: String
    @State private var context = ChatRowContext()

    var body: some View {
        ChatMarkdownView(blocks: ChatContent.blocks(id: id, text: text, isStreaming: false, in: context), flags: [], rowID: id,
                         context: context)
            .environment(\.chatMarkdownScale, ChatMarkdownScale(
                reading: LoomTheme.Agents.markdownReading, lineSpacing: LoomTheme.Agents.markdownLineSpacing,
                heading1: LoomTheme.Agents.markdownHeading, heading2: LoomTheme.Agents.markdownHeading,
                heading3: LoomTheme.Agents.markdownHeading))
    }
}
