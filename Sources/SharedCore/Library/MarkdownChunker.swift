import Foundation

public enum MarkdownChunker {

    public struct Output: Sendable, Hashable {
        public let text: String
        public let breadcrumb: String
        public let sourceFile: String
    }

    public static let defaultTargetMin = 80
    public static let defaultTargetMax = 500
    public static let defaultOverlap = 100

    public static func chunk(
        markdown raw: String,
        sourceFile: String,
        targetMin: Int = defaultTargetMin,
        targetMax: Int = defaultTargetMax,
        overlapWords: Int = defaultOverlap
    ) -> [Output] {
        let stripped = stripFrontmatter(raw)
        let sections = parseSections(stripped)

        if sections.allSatisfy({ $0.breadcrumb.isEmpty }) {
            if sections.isEmpty {
                return []
            }
            return fixedWindow(
                text: stripped, breadcrumb: "", sourceFile: sourceFile,
                targetMax: targetMax, overlapWords: overlapWords
            )
        }

        let merged = mergeSmallSections(sections, targetMin: targetMin)
        var outputs: [Output] = []
        for section in merged {
            let words = section.body.split(whereSeparator: \.isWhitespace)
            if words.count <= targetMax {
                outputs.append(
                    Output(
                        text: section.body, breadcrumb: section.breadcrumb, sourceFile: sourceFile
                    ))
            } else {
                outputs.append(
                    contentsOf: fixedWindow(
                        text: section.body, breadcrumb: section.breadcrumb, sourceFile: sourceFile,
                        targetMax: targetMax, overlapWords: overlapWords
                    ))
            }
        }
        return outputs
    }

    internal static func stripFrontmatter(_ raw: String) -> String {
        guard raw.hasPrefix("---") else { return raw }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return raw }
        var close: Int? = nil
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            close = i
            break
        }
        guard let c = close else { return raw }
        return lines[(c + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Section: Sendable {
        var breadcrumb: String
        var body: String
    }

    private static func parseSections(_ raw: String) -> [Section] {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        var headerStack: [String?] = Array(repeating: nil, count: 6)
        var current = Section(breadcrumb: "", body: "")
        var output: [Section] = []

        func flush() {
            let trimmed = current.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                var s = current
                s.body = trimmed
                output.append(s)
            }
        }
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if let (level, title) = parseHeader(trimmedLine) {
                flush()
                headerStack[level - 1] = title
                for deeper in level..<6 { headerStack[deeper] = nil }
                let crumb = headerStack.compactMap { $0 }.joined(separator: " > ")
                current = Section(breadcrumb: crumb, body: "")
            } else if !line.isEmpty || !current.body.isEmpty {
                if !current.body.isEmpty { current.body += "\n" }
                current.body += String(line)
            }
        }
        flush()
        return output
    }

    private static func parseHeader(_ line: String) -> (level: Int, title: String)? {
        var level = 0
        for ch in line {
            guard ch == "#" else { break }
            level += 1
        }
        guard level >= 1 && level <= 6, line.count > level else { return nil }
        let afterHashes = line.index(line.startIndex, offsetBy: level)
        guard line[afterHashes] == " " else { return nil }
        let title = String(line[line.index(after: afterHashes)...])
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (level, title)
    }

    private static func mergeSmallSections(_ sections: [Section], targetMin: Int) -> [Section] {
        guard sections.count > 1 else { return sections }
        var merged: [Section] = []
        var pending: Section? = nil
        for section in sections {
            if var p = pending {
                p.body += "\n\n" + section.body
                pending = p
                if p.body.split(whereSeparator: \.isWhitespace).count >= targetMin {
                    merged.append(p)
                    pending = nil
                }
                continue
            }
            let wc = section.body.split(whereSeparator: \.isWhitespace).count
            if wc < targetMin {
                pending = section
            } else {
                merged.append(section)
            }
        }
        if let trailing = pending {
            if var last = merged.popLast() {
                last.body += "\n\n" + trailing.body
                merged.append(last)
            } else {
                merged.append(trailing)
            }
        }
        return merged
    }

    private static func fixedWindow(
        text: String, breadcrumb: String, sourceFile: String,
        targetMax: Int, overlapWords: Int
    ) -> [Output] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > targetMax else {
            return [Output(text: text, breadcrumb: breadcrumb, sourceFile: sourceFile)]
        }
        var outputs: [Output] = []
        let stride = max(targetMax - overlapWords, 1)
        var start = 0
        while start < words.count {
            let end = min(start + targetMax, words.count)
            outputs.append(
                Output(
                    text: words[start..<end].joined(separator: " "),
                    breadcrumb: breadcrumb, sourceFile: sourceFile
                ))
            if end == words.count { break }
            start += stride
        }
        return outputs
    }
}
