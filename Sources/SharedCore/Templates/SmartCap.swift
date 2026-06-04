import Foundation

public enum SmartCap {
    public static let defaultCapChars = 60_000

    public static func trim(transcript: String, cap: Int = defaultCapChars) -> String {
        guard transcript.count > cap else { return transcript }
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count < 4 {
            return capByCharThirds(transcript: transcript, cap: cap)
        }
        return capByLineThirds(lines: lines.map(String.init), cap: cap)
    }

    private static func capByCharThirds(transcript: String, cap: Int) -> String {
        let third = cap / 3
        let head = String(transcript.prefix(third))
        let tail = String(transcript.suffix(third))
        let middle = "\n[... transcript trimmed: \(transcript.count - 2 * third) characters omitted ...]\n"
        return head + middle + tail
    }

    private static func capByLineThirds(lines: [String], cap: Int) -> String {
        let total = lines.count
        let halfBudget = max(1, (cap - 64) / 2)
        let head = takeLinesByChar(from: lines, fromStart: true, budget: halfBudget)
        let tail = takeLinesByChar(from: lines, fromStart: false, budget: halfBudget)
        let kept = head.count + tail.count
        let omitted = max(0, total - kept)
        let middle = "\n[... \(omitted) utterances omitted ...]\n"
        return head.joined(separator: "\n") + middle + tail.joined(separator: "\n")
    }

    private static func takeLinesByChar(from lines: [String], fromStart: Bool, budget: Int) -> [String] {
        var picked: [String] = []
        var spent = 0
        let iter = fromStart ? Array(lines) : Array(lines.reversed())
        for line in iter {
            let cost = line.count + 1
            if spent + cost > budget { break }
            spent += cost
            picked.append(line)
        }
        return fromStart ? picked : picked.reversed()
    }
}
