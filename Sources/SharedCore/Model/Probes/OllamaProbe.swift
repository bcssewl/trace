import Foundation

public struct OllamaModel: Sendable, Hashable, Codable {
    public let name: String
    public let sizeBytes: Int64?
    public let digest: String?

    public init(name: String, sizeBytes: Int64?, digest: String?) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.digest = digest
    }
}

public struct OllamaProbeResult: Sendable, Hashable {
    public let reachable: Bool
    public let baseURL: URL
    public let models: [OllamaModel]

    public init(reachable: Bool, baseURL: URL, models: [OllamaModel]) {
        self.reachable = reachable
        self.baseURL = baseURL
        self.models = models
    }
}

public struct OllamaProbe: Sendable {
    public let session: URLSession
    public let baseURL: URL
    public let timeout: TimeInterval

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "http://localhost:11434")!,
        timeout: TimeInterval = 1.2
    ) {
        self.session = session
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public func probe() async -> OllamaProbeResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return OllamaProbeResult(reachable: false, baseURL: baseURL, models: [])
            }
            let models = parseModels(data)
            return OllamaProbeResult(reachable: true, baseURL: baseURL, models: models)
        } catch {
            return OllamaProbeResult(reachable: false, baseURL: baseURL, models: [])
        }
    }

    private func parseModels(_ data: Data) -> [OllamaModel] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr = json["models"] as? [[String: Any]]
        else {
            return []
        }
        return arr.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            let size = (row["size"] as? Int64) ?? (row["size"] as? Int).map(Int64.init)
            let digest = row["digest"] as? String
            return OllamaModel(name: name, sizeBytes: size, digest: digest)
        }
    }
}
