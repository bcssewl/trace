import SharedCore
import SwiftUI

/// Renders a cross-meeting Q&A answer as Markdown (headings / bullets / inline
/// bold via the meeting-summary style) where each `[N]` citation is an
/// interactive chip: **hover** shows a preview card of the cited source,
/// **click** jumps to that meeting at its timestamp.
///
/// Inline-interactive citations + wrapping rich text aren't expressible with a
/// single SwiftUI `Text`, so each block is laid out as a `FlowLayout` of tokens —
/// per-word `Text` (carrying the word's inline-Markdown styling) interleaved with
/// citation chips.
@MainActor
struct CitedAnswerView: View {
    @Environment(\.brutalistPalette) private var palette
    let answer: QASearchPipeline.CitedAnswer
    let onOpen: (RetrievedPassage) -> Void
    private let passagesById: [Int: RetrievedPassage]

    init(answer: QASearchPipeline.CitedAnswer, onOpen: @escaping (RetrievedPassage) -> Void) {
        self.answer = answer
        self.onOpen = onOpen
        self.passagesById = Dictionary(
            answer.citations.map { ($0.id, $0.passage) }, uniquingKeysWith: { first, _ in first }
        )
    }

    private static let citationRegex = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(BrutalistMarkdownParser.parse(answer.answer).enumerated()), id: \.offset) { _, block in
                BrutalistMarkdownBlockView(block: block) { text in
                    tokenFlow(text)
                }
            }
        }
    }

    // MARK: Blocks

    private func tokenFlow(_ text: String) -> some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(Array(tokenize(text).enumerated()), id: \.offset) { _, token in
                tokenView(token)
            }
        }
    }

    @ViewBuilder
    private func tokenView(_ token: Token) -> some View {
        switch token {
        case .word(let attributed):
            Text(attributed)
                .font(BrutalistTypography.body)
                .foregroundStyle(palette.fg.color)
        case .citation(let id):
            if let passage = passagesById[id] {
                CitationChip(id: id, passage: passage) { onOpen(passage) }
            } else {
                Text("[\(id)]")
                    .font(BrutalistTypography.body)
                    .foregroundStyle(palette.primary.color)
            }
        }
    }

    // MARK: Tokenizing

    private enum Token {
        case word(AttributedString)
        case citation(Int)
    }

    /// Split a block into word tokens (with inline-Markdown styling preserved) and
    /// citation tokens for any `[N]` that maps to a real source.
    private func tokenize(_ text: String) -> [Token] {
        let regex = Self.citationRegex
        let ns = text as NSString
        var tokens: [Token] = []
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let pre = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !pre.isEmpty { tokens += Self.words(Self.inlineMarkdown(pre)).map(Token.word) }
            let id = Int(ns.substring(with: match.range(at: 1))) ?? -1
            if passagesById[id] != nil {
                tokens.append(.citation(id))
            } else {
                tokens += Self.words(Self.inlineMarkdown(ns.substring(with: match.range))).map(Token.word)
            }
            cursor = match.range.location + match.range.length
        }
        let tail = ns.substring(from: cursor)
        if !tail.isEmpty { tokens += Self.words(Self.inlineMarkdown(tail)).map(Token.word) }
        return tokens
    }

    private static func inlineMarkdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }

    /// Split an attributed string into whitespace-separated words, preserving each
    /// word's inline attributes (bold / italic).
    private static func words(_ attributed: AttributedString) -> [AttributedString] {
        var result: [AttributedString] = []
        let characters = attributed.characters
        var wordStart: AttributedString.Index?
        var index = characters.startIndex
        while index < characters.endIndex {
            if characters[index].isWhitespace {
                if let start = wordStart {
                    result.append(AttributedString(attributed[start..<index]))
                    wordStart = nil
                }
            } else if wordStart == nil {
                wordStart = index
            }
            index = characters.index(after: index)
        }
        if let start = wordStart {
            result.append(AttributedString(attributed[start..<characters.endIndex]))
        }
        return result
    }
}

/// An inline citation marker.
///
/// Hover → source preview card; click → open.
@MainActor
private struct CitationChip: View {
    @Environment(\.brutalistPalette) private var palette
    let id: Int
    let passage: RetrievedPassage
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Text("[\(id)]")
            .font(BrutalistTypography.body)
            .foregroundStyle(palette.primary.color)
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }
            .onHover { hovering = $0 }
            .popover(isPresented: $hovering, arrowEdge: .bottom) {
                CitationCard(passage: passage)
                    .environment(\.brutalistPalette, palette)
            }
            .help(Self.help(for: passage))
    }

    private static func help(for passage: RetrievedPassage) -> String {
        switch passage.openTarget {
        case .meeting: return "Click to open this meeting"
        case .file: return "Click to open the playbook file"
        case nil: return "Source"
        }
    }
}

/// The hover preview: where the cited claim came from, plus an open affordance.
@MainActor
private struct CitationCard: View {
    @Environment(\.brutalistPalette) private var palette
    let passage: RetrievedPassage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(passage.kindLabel)
                .font(BrutalistTypography.mono10)
                .foregroundStyle(palette.primary.color)
            if let title = passage.title, !title.isEmpty {
                Text(title)
                    .font(BrutalistTypography.labelEmphasis)
                    .foregroundStyle(palette.fg.color)
            }
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(BrutalistTypography.mono10)
                    .foregroundStyle(palette.fgMuted.color)
            }
            Text(passage.text)
                .font(BrutalistTypography.uiLabel)
                .foregroundStyle(palette.fg.color)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(palette.bgTertiary.color)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let speaker = passage.speaker, !speaker.isEmpty { parts.append(speaker) }
        if let ts = passage.tsSeconds { parts.append("@ \(TranscriptChunker.timeLabel(ts))") }
        if passage.kind == .playbook, let crumb = passage.breadcrumb, !crumb.isEmpty { parts.append(crumb) }
        return parts.joined(separator: " · ")
    }
}

/// Minimal wrapping flow layout — lays children left-to-right, wrapping to the
/// next line at the container width.
///
/// Used to interleave wrapping word tokens with
/// interactive citation chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x)
        }
        let width = maxWidth.isFinite ? maxWidth : widest
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
