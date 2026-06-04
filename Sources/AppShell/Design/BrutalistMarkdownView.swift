import SwiftUI

/// Lightweight Markdown renderer for AI-generated notes — block-level headings,
/// bullets, and paragraphs (which SwiftUI's `Text` can't lay out on its own),
/// with inline bold/italic/code via `AttributedString`.
///
/// Styled to the brutalist
/// palette; no third-party dependency. Good enough for meeting summaries and
/// coach cards, which emit simple structured Markdown.
///
/// Block parsing + styling are shared with `CitedAnswerView` via
/// `BrutalistMarkdownParser` / `BrutalistMarkdownBlockView`; this view supplies a
/// plain-`Text` inline builder (the Q&A view supplies a citation-aware one).
@MainActor
struct BrutalistMarkdownView: View {
    @Environment(\.brutalistPalette) private var palette
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(BrutalistMarkdownParser.parse(markdown).enumerated()), id: \.offset) { _, block in
                BrutalistMarkdownBlockView(block: block) { text in
                    inline(text)
                        .font(BrutalistTypography.body)
                        .foregroundStyle(palette.fg.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Inline-only Markdown (bold / italic / code / links).
    ///
    /// Falls back to plain
    /// text if parsing fails.
    private func inline(_ string: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(string)
    }
}
