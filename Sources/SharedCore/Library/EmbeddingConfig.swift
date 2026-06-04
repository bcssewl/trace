import Foundation

public struct EmbeddingConfig: Sendable, Hashable, Codable {
    public enum Normalization: String, Sendable, Hashable, Codable {
        case unitL2
        case none

        public var tag: String {
            switch self {
            case .unitL2: return "n1"
            case .none: return "n0"
            }
        }
    }

    public let provider: String
    public let baseURL: URL?
    public let model: String
    public let normalization: Normalization

    public init(provider: String, baseURL: URL?, model: String, normalization: Normalization) {
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.normalization = normalization
    }

    public var fingerprint: String {
        let providerToken = provider.lowercased()
        let baseToken = baseURL?.absoluteString.lowercased() ?? ""
        let modelToken = model.lowercased()
        return "\(providerToken)|\(baseToken)|\(modelToken)|\(normalization.tag)"
    }
}
