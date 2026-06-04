import Foundation

public struct SSEEvent: Sendable, Hashable {
    public let event: String?
    public let data: String
    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

public enum StreamingSSE {
    public static func parse(_ rawBytes: Data) -> [SSEEvent] {
        guard let text = String(data: rawBytes, encoding: .utf8) else { return [] }
        return parse(text)
    }

    public static func parse(_ rawText: String) -> [SSEEvent] {
        var events: [SSEEvent] = []
        let blocks = rawText.components(separatedBy: "\n\n")
        for block in blocks where !block.isEmpty {
            var event: String?
            var dataChunks: [String] = []
            for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix(":") { continue }
                if let colon = line.firstIndex(of: ":") {
                    let field = String(line[..<colon])
                    var value = String(line[line.index(after: colon)...])
                    if value.hasPrefix(" ") { value.removeFirst() }
                    switch field {
                    case "event": event = value
                    case "data": dataChunks.append(value)
                    default: break
                    }
                }
            }
            if !dataChunks.isEmpty {
                events.append(SSEEvent(event: event, data: dataChunks.joined(separator: "\n")))
            }
        }
        return events
    }

    /// The JSON payload of an SSE `data:` line (handles both `data:` and
    /// `data: ` spellings), or `nil` for a non-data line.
    ///
    /// Lets line-oriented
    /// providers whose event type is carried inside the data JSON (Anthropic,
    /// Codex Responses) share one extraction instead of open-coding it.
    public static func dataPayload(from line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        return String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
    }

    public static func parseLines(_ chunk: String, into buffer: inout String) -> [SSEEvent] {
        buffer += chunk
        var emitted: [SSEEvent] = []
        while let range = buffer.range(of: "\n\n") {
            let block = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            let parsed = parse(block + "\n\n")
            emitted.append(contentsOf: parsed)
        }
        return emitted
    }
}
