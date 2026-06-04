import Foundation

public enum CitationEnforcer {

    public struct Validation: Sendable, Hashable {
        public let isValid: Bool
        public let citedIndices: Set<Int>
        public let invalidIndices: Set<Int>
        public let outOfRangeIndices: Set<Int>
        public let unsupportedClaims: [String]

        public var hasViolations: Bool { !isValid }

        /// A clean, no-violations validation — for answers with no claims to check
        /// (e.g. the "nothing matched" empty answer).
        public static let empty = Validation(
            isValid: true, citedIndices: [], invalidIndices: [],
            outOfRangeIndices: [], unsupportedClaims: []
        )
    }

    public static func validate(
        answer: String,
        contextChunkCount n: Int,
        minimumCitations: Int = 1
    ) -> Validation {
        let pattern = #"\[(\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Validation(
                isValid: false, citedIndices: [], invalidIndices: [],
                outOfRangeIndices: [], unsupportedClaims: ["regex compile failed"]
            )
        }
        let range = NSRange(answer.startIndex..., in: answer)
        let matches = regex.matches(in: answer, options: [], range: range)
        var cited: Set<Int> = []
        var oor: Set<Int> = []
        for match in matches {
            guard match.numberOfRanges >= 2, let r = Range(match.range(at: 1), in: answer) else {
                continue
            }
            guard let idx = Int(answer[r]) else { continue }
            if idx >= 1 && idx <= n {
                cited.insert(idx)
            } else {
                oor.insert(idx)
            }
        }
        var problems: [String] = []
        if cited.count < minimumCitations {
            problems.append("answer cites \(cited.count) chunks; need at least \(minimumCitations)")
        }
        if !oor.isEmpty {
            problems.append("answer cites out-of-range indices: \(oor.sorted())")
        }
        let unsupported = detectUnsupportedSentences(answer)
        problems.append(contentsOf: unsupported)
        let valid = problems.isEmpty
        return Validation(
            isValid: valid, citedIndices: cited, invalidIndices: [],
            outOfRangeIndices: oor, unsupportedClaims: problems
        )
    }

    private static func detectUnsupportedSentences(_ answer: String) -> [String] {
        let sentences = answer.split(whereSeparator: { ".!?".contains($0) })
        var problems: [String] = []
        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 30 else { continue }
            if !trimmed.contains("[") {
                problems.append("uncited claim: \(trimmed.prefix(60))…")
            }
        }
        return problems
    }
}
