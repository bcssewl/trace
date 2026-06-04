import Foundation

public enum RegexDetector {
    public enum Marker: String, Sendable, Codable, Hashable, CaseIterable {
        case question
        case claim
        case currency
        case commitment
        case objection
    }

    private static let questionPatterns: [NSRegularExpression] = compile([
        "(?i)\\b(what|how|why|when|where|who|which|can|could|would|should|do|does|did|is|are|was|were)\\b.{0,80}\\?",
        "\\?$",
    ])

    private static let claimPatterns: [NSRegularExpression] = compile([
        "(?i)\\b(we|our|the)\\s+(only|best|fastest|cheapest|most|largest)\\b",
        "(?i)\\b(always|never|all|every|none)\\b",
    ])

    private static let currencyPatterns: [NSRegularExpression] = compile([
        "\\$\\s?\\d[\\d,]*(?:\\.\\d+)?(?:[kKmMbB])?",
        "\\b\\d+(?:\\.\\d+)?\\s?(?:dollars|usd|EUR|GBP)\\b",
    ])

    private static let commitmentPatterns: [NSRegularExpression] = compile([
        "(?i)\\bi (will|'ll|am going to|am gonna|commit to)\\b",
        "(?i)\\bwe (will|'ll|are going to|committed to|agreed to)\\b",
    ])

    private static let objectionPatterns: [NSRegularExpression] = compile([
        "(?i)\\b(too expensive|not sure|concerned about|worried about|don't think|problem with)\\b",
        "(?i)\\bbut\\s+(it|that|the)\\b",
    ])

    public static func detect(_ text: String) -> Set<Marker> {
        var hits: Set<Marker> = []
        if anyMatch(questionPatterns, in: text) { hits.insert(.question) }
        if anyMatch(claimPatterns, in: text) { hits.insert(.claim) }
        if anyMatch(currencyPatterns, in: text) { hits.insert(.currency) }
        if anyMatch(commitmentPatterns, in: text) { hits.insert(.commitment) }
        if anyMatch(objectionPatterns, in: text) { hits.insert(.objection) }
        return hits
    }

    private static func anyMatch(_ regexes: [NSRegularExpression], in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regexes.contains { $0.firstMatch(in: text, options: [], range: range) != nil }
    }

    private static func compile(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }
}
