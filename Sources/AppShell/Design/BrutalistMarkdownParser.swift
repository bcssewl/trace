import SwiftUI

/// The block model + parser shared by `BrutalistMarkdownView` (meeting summaries,
/// coach cards) and `CitedAnswerView` (cross-meeting Q&A).
///
/// Both render the same
/// lightweight Markdown — `#`…`####` headings, `*`/`-` bullets, everything else a
/// paragraph — and differ only in how inline content is laid out (a plain `Text`
/// vs. a `FlowLayout` of word + citation-chip tokens). Extracting the split here
/// (BAS-32) keeps the two renderers from drifting apart.
enum BrutalistMarkdownBlock: Hashable {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case paragraph(text: String)
}

enum BrutalistMarkdownParser {

    /// Split `markdown` into blocks: blank lines are dropped, each remaining line
    /// is trimmed, then classified as a heading (longest `#` run wins), a bullet
    /// (`* `/`- ` prefix), or a paragraph.
    static func parse(_ markdown: String) -> [BrutalistMarkdownBlock] {
        var blocks: [BrutalistMarkdownBlock] = []
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let heading = headingLevel(line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                blocks.append(.bullet(text: String(line.dropFirst(2))))
            } else {
                blocks.append(.paragraph(text: line))
            }
        }
        return blocks
    }

    /// Returns the heading level (1–4) and trimmed text when `line` opens with
    /// `#`…`####` followed by a space.
    ///
    /// Longest prefix wins, so `### x` is level 3.
    static func headingLevel(_ line: String) -> (level: Int, text: String)? {
        for level in [4, 3, 2, 1] {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return (level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }
}

/// Renders one parsed block with the brutalist styling shared by both Markdown
/// views.
///
/// Heading rendering is self-contained; bullets and paragraphs delegate
/// their inline content to the caller's `inline` builder — a plain styled `Text`
/// for `BrutalistMarkdownView`, or the citation-aware token flow for
/// `CitedAnswerView`.
@MainActor
struct BrutalistMarkdownBlockView<Inline: View>: View {
    @Environment(\.brutalistPalette) private var palette
    let block: BrutalistMarkdownBlock
    @ViewBuilder let inline: (String) -> Inline

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text.uppercased())
                .font(.system(size: level <= 2 ? 14 : 12, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(palette.fg.color)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(BrutalistTypography.body)
                    .foregroundStyle(palette.primary.color)
                inline(text)
            }
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            inline(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
