import Foundation

public struct Utterance: Sendable, Codable, Hashable {
    public enum Speaker: Sendable, Codable, Hashable {
        case you
        case other(id: String)

        public init(rawValue: String) {
            if rawValue == "you" { self = .you } else { self = .other(id: rawValue) }
        }

        public var rawValue: String {
            switch self {
            case .you: return "you"
            case .other(let id): return id
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(rawValue: try container.decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public let t: Double
    public let speaker: Speaker
    public let text: String
    public let conf: Double
    public let asr: String?
    public let diar: String?
    public let cleaned: String?

    public init(
        t: Double,
        speaker: Speaker,
        text: String,
        conf: Double,
        asr: String? = nil,
        diar: String? = nil,
        cleaned: String? = nil
    ) {
        self.t = t
        self.speaker = speaker
        self.text = text
        self.conf = conf
        self.asr = asr
        self.diar = diar
        self.cleaned = cleaned
    }
}
