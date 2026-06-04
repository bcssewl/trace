import Foundation

/// Tolerant JSON extraction for LLM replies.
///
/// Routed models (Ollama, some cloud
/// providers) often wrap their JSON in code fences or prose; this parses the full
/// text first, then falls back to the outermost `{…}` span. One home for the
/// pattern that was otherwise copy-pasted per call site.
public enum JSONExtraction {

    /// Parse `text` into a JSON object dictionary, tolerating surrounding
    /// fences/prose. `nil` if neither the full text nor its outermost `{…}` span
    /// is a JSON object.
    public static func objectDictionary(from text: String) -> [String: Any]? {
        for candidate in candidates(in: text) {
            if let data = candidate.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                return object
            }
        }
        return nil
    }

    /// Decode `T` from `text`, tolerating surrounding fences/prose. `nil` if
    /// neither the full text nor its outermost `{…}` span decodes.
    public static func decode<T: Decodable>(
        _ type: T.Type, from text: String, decoder: JSONDecoder = JSONDecoder()
    ) -> T? {
        for candidate in candidates(in: text) {
            if let data = candidate.data(using: .utf8),
                let value = try? decoder.decode(T.self, from: data)
            {
                return value
            }
        }
        return nil
    }

    /// Candidate substrings to try, in order: the whole text, then the outermost
    /// `{…}` span (when present).
    private static func candidates(in text: String) -> [Substring] {
        var out: [Substring] = [text[...]]
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            out.append(text[open...close])
        }
        return out
    }
}
