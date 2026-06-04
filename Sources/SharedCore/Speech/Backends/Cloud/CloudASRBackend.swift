@preconcurrency import AVFoundation
import Foundation

public enum CloudASRProvider: String, Sendable, Codable, Hashable, CaseIterable {
    case openai
    case groq
    case deepgram
    case assemblyAI
    case revAI
    case speechmatics
    case soniox
    case elevenlabs
    case fireworks
    case volcengine

    /// Human-facing label for pickers and status rows (BAS-21).
    public var displayName: String {
        switch self {
        case .openai: return "OpenAI Whisper"
        case .groq: return "Groq Whisper Large v3"
        case .deepgram: return "Deepgram Nova-3"
        case .assemblyAI: return "AssemblyAI Universal"
        case .revAI: return "Rev.ai"
        case .speechmatics: return "Speechmatics"
        case .soniox: return "Soniox"
        case .elevenlabs: return "ElevenLabs Scribe"
        case .fireworks: return "Fireworks AI"
        case .volcengine: return "Volcengine Doubao"
        }
    }

    /// `true` when this provider exposes a real-time streaming socket the app
    /// implements (BAS-7).
    ///
    /// Today only Deepgram; the rest run as one-shot batch
    /// uploads (`CloudASRBackend.transcribe`).
    public var supportsStreaming: Bool {
        self == .deepgram
    }
}

public struct CloudASREndpoints: Sendable, Hashable {
    public let provider: CloudASRProvider
    public let baseURL: URL
    public let path: String
    public let keychainAccount: String

    public init(provider: CloudASRProvider, baseURL: URL, path: String, keychainAccount: String) {
        self.provider = provider
        self.baseURL = baseURL
        self.path = path
        self.keychainAccount = keychainAccount
    }

    public static let openai = CloudASREndpoints(
        provider: .openai, baseURL: URL(string: "https://api.openai.com/v1")!, path: "audio/transcriptions",
        keychainAccount: "openai")
    public static let groq = CloudASREndpoints(
        provider: .groq, baseURL: URL(string: "https://api.groq.com/openai/v1")!, path: "audio/transcriptions",
        keychainAccount: "groq")
    public static let deepgram = CloudASREndpoints(
        provider: .deepgram, baseURL: URL(string: "https://api.deepgram.com/v1")!, path: "listen",
        keychainAccount: "deepgram")
    public static let assemblyAI = CloudASREndpoints(
        provider: .assemblyAI, baseURL: URL(string: "https://api.assemblyai.com/v2")!, path: "transcript",
        keychainAccount: "assemblyai")
    public static let revAI = CloudASREndpoints(
        provider: .revAI, baseURL: URL(string: "https://api.rev.ai/speechtotext/v1")!, path: "jobs",
        keychainAccount: "revai")
    public static let speechmatics = CloudASREndpoints(
        provider: .speechmatics, baseURL: URL(string: "https://asr.api.speechmatics.com/v2")!, path: "jobs",
        keychainAccount: "speechmatics")
    public static let soniox = CloudASREndpoints(
        provider: .soniox, baseURL: URL(string: "https://api.soniox.com")!, path: "transcribe",
        keychainAccount: "soniox")
    public static let elevenlabs = CloudASREndpoints(
        provider: .elevenlabs, baseURL: URL(string: "https://api.elevenlabs.io/v1")!, path: "speech-to-text",
        keychainAccount: "elevenlabs")
    public static let fireworks = CloudASREndpoints(
        provider: .fireworks, baseURL: URL(string: "https://audio-prod.us-virginia-1.direct.fireworks.ai/v1")!,
        path: "audio/transcriptions", keychainAccount: "fireworks")
    public static let volcengine = CloudASREndpoints(
        provider: .volcengine, baseURL: URL(string: "https://openspeech.bytedance.com/api/v3")!, path: "auc/submit",
        keychainAccount: "volcengine")
}

public actor CloudASRBackend: TranscriptionBackend {
    public nonisolated let displayName: String
    private let endpoint: CloudASREndpoints
    private let session: URLSession
    private let keychain: KeychainSecrets

    public init(
        endpoint: CloudASREndpoints, session: URLSession = .shared, keychain: KeychainSecrets = KeychainSecrets()
    ) {
        self.endpoint = endpoint
        self.session = session
        self.keychain = keychain
        self.displayName = "Cloud ASR (\(endpoint.provider.rawValue))"
    }

    /// Convenience: build a backend straight from a provider, using its canonical
    /// endpoint (BAS-21).
    public init(
        provider: CloudASRProvider, session: URLSession = .shared, keychain: KeychainSecrets = KeychainSecrets()
    ) {
        self.init(endpoint: CloudASRBackend.endpoints(for: provider), session: session, keychain: keychain)
    }

    /// Canonical endpoint configuration for a provider — the single mapping the
    /// resolver factory uses to turn an ASR route's engine identifier into a real
    /// cloud backend (BAS-21).
    public static func endpoints(for provider: CloudASRProvider) -> CloudASREndpoints {
        switch provider {
        case .openai: return .openai
        case .groq: return .groq
        case .deepgram: return .deepgram
        case .assemblyAI: return .assemblyAI
        case .revAI: return .revAI
        case .speechmatics: return .speechmatics
        case .soniox: return .soniox
        case .elevenlabs: return .elevenlabs
        case .fireworks: return .fireworks
        case .volcengine: return .volcengine
        }
    }

    public func checkStatus() async -> BackendStatus {
        guard let token = try? keychain.load(account: endpoint.keychainAccount), !token.isEmpty else {
            return .unavailable(reason: "missing api key for \(endpoint.provider.rawValue)")
        }
        return .ready
    }

    public func prepare(
        onStatus: @escaping @Sendable (BackendStatus) -> Void,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let status = await checkStatus()
        onStatus(status)
        onProgress(status == .ready ? 1 : 0)
    }

    public func transcribe(_ samples: [Float], locale: Locale, previousContext: String?) async throws -> String {
        // Cloud APIs take an explicit language code; auto-detect falls back to system.
        let locale = locale.concreteOrCurrent
        switch endpoint.provider {
        case .openai, .groq, .fireworks:
            return try await transcribeOpenAICompatible(
                samples: samples, locale: locale, previousContext: previousContext
            )
        case .deepgram:
            return try await transcribeDeepgram(samples: samples, locale: locale)
        case .elevenlabs:
            return try await transcribeElevenLabs(samples: samples, locale: locale)
        case .soniox:
            return try await transcribeSoniox(samples: samples, locale: locale)
        case .assemblyAI:
            return try await transcribeAssemblyAI(samples: samples, locale: locale)
        case .revAI:
            return try await transcribeRev(samples: samples, locale: locale)
        case .speechmatics:
            return try await transcribeSpeechmatics(samples: samples, locale: locale)
        case .volcengine:
            return try await transcribeVolcengine(samples: samples, locale: locale)
        }
    }

    private func transcribeElevenLabs(samples: [Float], locale: Locale) async throws -> String {
        let key = try requireApiKey()
        let wavData = encodeWav(samples: samples, sampleRate: 16_000)
        let boundary = "trace-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(endpoint.path))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        appendField(&body, boundary: boundary, name: "model_id", value: "scribe_v1")
        appendField(&body, boundary: boundary, name: "language_code", value: String(locale.identifier.prefix(2)))
        appendFile(
            &body, boundary: boundary, name: "file", filename: "audio.wav", contentType: "audio/wav", data: wavData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let data = try await execute(request, engine: "cloud:elevenlabs")
        let root = try jsonObject(data, engine: "cloud:elevenlabs")
        if let text = root["text"] as? String { return text }
        throw TraceError.asrInferenceFailed(engine: "cloud:elevenlabs", reason: "missing text in response")
    }

    private func transcribeSoniox(samples: [Float], locale: Locale) async throws -> String {
        let key = try requireApiKey()
        let wavData = encodeWav(samples: samples, sampleRate: 16_000)
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("v1/transcribe"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "audio": wavData.base64EncodedString(),
            "audio_format": "wav",
            "model": "stt-async-preview",
            "language_hints": [String(locale.identifier.prefix(2))],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await execute(request, engine: "cloud:soniox")
        let root = try jsonObject(data, engine: "cloud:soniox")
        if let text = root["text"] as? String { return text }
        if let tokens = root["tokens"] as? [[String: Any]] {
            return tokens.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        throw TraceError.asrInferenceFailed(engine: "cloud:soniox", reason: "no text in response")
    }

    private func transcribeAssemblyAI(samples: [Float], locale: Locale) async throws -> String {
        let key = try requireApiKey()
        let wavData = encodeWav(samples: samples, sampleRate: 16_000)
        var uploadReq = URLRequest(url: endpoint.baseURL.appendingPathComponent("upload"))
        uploadReq.httpMethod = "POST"
        uploadReq.setValue(key, forHTTPHeaderField: "authorization")
        uploadReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadReq.httpBody = wavData
        let uploadData = try await execute(uploadReq, engine: "cloud:assemblyai:upload")
        let uploadRoot = try jsonObject(uploadData, engine: "cloud:assemblyai:upload")
        guard let uploadURL = uploadRoot["upload_url"] as? String else {
            throw TraceError.asrInferenceFailed(engine: "cloud:assemblyai", reason: "no upload_url in response")
        }
        var jobReq = URLRequest(url: endpoint.baseURL.appendingPathComponent("transcript"))
        jobReq.httpMethod = "POST"
        jobReq.setValue(key, forHTTPHeaderField: "authorization")
        jobReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let jobBody: [String: Any] = [
            "audio_url": uploadURL,
            "language_code": String(locale.identifier.prefix(2)),
            "speech_model": "universal",
        ]
        jobReq.httpBody = try JSONSerialization.data(withJSONObject: jobBody)
        let jobData = try await execute(jobReq, engine: "cloud:assemblyai:submit")
        let jobRoot = try jsonObject(jobData, engine: "cloud:assemblyai:submit")
        guard let jobId = jobRoot["id"] as? String else {
            throw TraceError.asrInferenceFailed(engine: "cloud:assemblyai", reason: "no job id")
        }
        return try await pollJSON(
            url: endpoint.baseURL.appendingPathComponent("transcript/\(jobId)"),
            authHeader: ("authorization", key),
            engine: "cloud:assemblyai",
            terminalKey: "status",
            successValue: "completed",
            failureValues: ["error"],
            resultKey: "text",
            errorKey: "error"
        )
    }

    private func transcribeRev(samples: [Float], locale: Locale) async throws -> String {
        let key = try requireApiKey()
        let wavData = encodeWav(samples: samples, sampleRate: 16_000)
        let boundary = "trace-\(UUID().uuidString)"
        var submitReq = URLRequest(url: endpoint.baseURL.appendingPathComponent("jobs"))
        submitReq.httpMethod = "POST"
        submitReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        submitReq.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        let opts: [String: Any] = ["language": String(locale.identifier.prefix(2)), "skip_diarization": false]
        let optsData = try JSONSerialization.data(withJSONObject: opts)
        appendField(&body, boundary: boundary, name: "options", value: String(data: optsData, encoding: .utf8) ?? "{}")
        appendFile(
            &body, boundary: boundary, name: "media", filename: "audio.wav", contentType: "audio/wav", data: wavData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        submitReq.httpBody = body
        let submitData = try await execute(submitReq, engine: "cloud:revai:submit")
        let submitRoot = try jsonObject(submitData, engine: "cloud:revai:submit")
        guard let jobId = submitRoot["id"] as? String else {
            throw TraceError.asrInferenceFailed(engine: "cloud:revai", reason: "no job id")
        }
        _ = try await pollJSON(
            url: endpoint.baseURL.appendingPathComponent("jobs/\(jobId)"),
            authHeader: ("Authorization", "Bearer \(key)"),
            engine: "cloud:revai:poll",
            terminalKey: "status",
            successValue: "transcribed",
            failureValues: ["failed"],
            resultKey: nil,
            errorKey: "failure_detail"
        )
        var transcriptReq = URLRequest(url: endpoint.baseURL.appendingPathComponent("jobs/\(jobId)/transcript"))
        transcriptReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        transcriptReq.setValue("text/plain", forHTTPHeaderField: "Accept")
        let transcriptData = try await execute(transcriptReq, engine: "cloud:revai:fetch")
        return String(data: transcriptData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func transcribeSpeechmatics(samples: [Float], locale: Locale) async throws -> String {
        let key = try requireApiKey()
        let wavData = encodeWav(samples: samples, sampleRate: 16_000)
        let boundary = "trace-\(UUID().uuidString)"
        var submitReq = URLRequest(url: endpoint.baseURL.appendingPathComponent("jobs"))
        submitReq.httpMethod = "POST"
        submitReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        submitReq.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        let config: [String: Any] = [
            "type": "transcription",
            "transcription_config": [
                "language": String(locale.identifier.prefix(2)),
                "operating_point": "enhanced",
            ],
        ]
        let configData = try JSONSerialization.data(withJSONObject: config)
        appendField(&body, boundary: boundary, name: "config", value: String(data: configData, encoding: .utf8) ?? "{}")
        appendFile(
            &body, boundary: boundary, name: "data_file", filename: "audio.wav", contentType: "audio/wav", data: wavData
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        submitReq.httpBody = body
        let submitData = try await execute(submitReq, engine: "cloud:speechmatics:submit")
        let submitRoot = try jsonObject(submitData, engine: "cloud:speechmatics:submit")
        guard let jobId = submitRoot["id"] as? String else {
            throw TraceError.asrInferenceFailed(engine: "cloud:speechmatics", reason: "no job id")
        }
        _ = try await pollJSON(
            url: endpoint.baseURL.appendingPathComponent("jobs/\(jobId)"),
            authHeader: ("Authorization", "Bearer \(key)"),
            engine: "cloud:speechmatics:poll",
            terminalKey: "job.status",
            successValue: "done",
            failureValues: ["rejected"],
            resultKey: nil,
            errorKey: nil
        )
        var transcriptReq = URLRequest(
            url: endpoint.baseURL.appendingPathComponent("jobs/\(jobId)/transcript?format=txt"))
        transcriptReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let transcriptData = try await execute(transcriptReq, engine: "cloud:speechmatics:fetch")
        return String(data: transcriptData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func transcribeVolcengine(samples: [Float], locale: Locale) async throws -> String {
        let key = try requireApiKey()
        let wavData = encodeWav(samples: samples, sampleRate: 16_000)
        var submitReq = URLRequest(url: endpoint.baseURL.appendingPathComponent("auc/submit"))
        submitReq.httpMethod = "POST"
        submitReq.setValue("Bearer; \(key)", forHTTPHeaderField: "Authorization")
        submitReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submitReq.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        let payload: [String: Any] = [
            "user": ["uid": "trace"],
            "audio": [
                "format": "wav",
                "data": wavData.base64EncodedString(),
                "rate": 16_000,
                "channel": 1,
            ],
            "request": [
                "model_name": "bigmodel",
                "language": String(locale.identifier.prefix(2)),
                "result_type": "full",
            ],
        ]
        submitReq.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let submitData = try await execute(submitReq, engine: "cloud:volcengine:submit")
        let submitRoot = try jsonObject(submitData, engine: "cloud:volcengine:submit")
        guard let taskId = submitRoot["task_id"] as? String ?? (submitRoot["id"] as? String) else {
            throw TraceError.asrInferenceFailed(engine: "cloud:volcengine", reason: "no task_id")
        }
        let pollURL = endpoint.baseURL.appendingPathComponent("auc/query")
        return try await pollVolcengine(taskId: taskId, key: key, pollURL: pollURL)
    }

    private func pollVolcengine(taskId: String, key: String, pollURL: URL) async throws -> String {
        let deadline = Date().addingTimeInterval(180)
        var attempt = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(min(8, 1 + attempt)) * 1_000_000_000)
            attempt += 1
            var req = URLRequest(url: pollURL)
            req.httpMethod = "POST"
            req.setValue("Bearer; \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["task_id": taskId])
            let data = try await execute(req, engine: "cloud:volcengine:poll")
            let root = try jsonObject(data, engine: "cloud:volcengine:poll")
            let status = (root["status"] as? String) ?? ((root["task_status"] as? String) ?? "")
            if status == "Success" || status == "success" {
                if let result = root["result"] as? [String: Any], let text = result["text"] as? String { return text }
                if let text = root["text"] as? String { return text }
                throw TraceError.asrInferenceFailed(engine: "cloud:volcengine", reason: "result missing text")
            }
            if status == "Failed" || status == "failed" {
                throw TraceError.asrInferenceFailed(engine: "cloud:volcengine", reason: "task failed: \(status)")
            }
        }
        throw TraceError.asrInferenceFailed(engine: "cloud:volcengine", reason: "poll timeout after 180s")
    }

    private func pollJSON(
        url: URL,
        authHeader: (String, String),
        engine: String,
        terminalKey: String,
        successValue: String,
        failureValues: [String],
        resultKey: String?,
        errorKey: String?
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(300)
        var attempt = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(min(10, 1 + attempt)) * 1_000_000_000)
            attempt += 1
            var req = URLRequest(url: url)
            req.setValue(authHeader.1, forHTTPHeaderField: authHeader.0)
            let data = try await execute(req, engine: engine)
            let root = try jsonObject(data, engine: engine)
            let status = nestedString(root, keyPath: terminalKey) ?? ""
            if status == successValue {
                if let resultKey, let value = root[resultKey] as? String { return value }
                return ""
            }
            if failureValues.contains(status) {
                let reason = errorKey.flatMap { root[$0] as? String } ?? "terminal status: \(status)"
                throw TraceError.asrInferenceFailed(engine: engine, reason: reason)
            }
        }
        throw TraceError.asrInferenceFailed(engine: engine, reason: "poll timeout")
    }

    private func nestedString(_ root: [String: Any], keyPath: String) -> String? {
        var current: Any = root
        for part in keyPath.split(separator: ".") {
            guard let dict = current as? [String: Any], let next = dict[String(part)] else { return nil }
            current = next
        }
        return current as? String
    }

    private func execute(_ request: URLRequest, engine: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TraceError.asrInferenceFailed(
                engine: engine,
                reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(msg.prefix(200))"
            )
        }
        return data
    }

    private func jsonObject(_ data: Data, engine: String) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TraceError.asrInferenceFailed(engine: engine, reason: "response was not a JSON object")
        }
        return root
    }

    private func requireApiKey() throws -> String {
        guard let key = try keychain.load(account: endpoint.keychainAccount), !key.isEmpty else {
            throw TraceError.asrInferenceFailed(
                engine: "cloud:\(endpoint.provider.rawValue)",
                reason: "missing API key in Keychain (account: \(endpoint.keychainAccount))"
            )
        }
        return key
    }

    private func transcribeOpenAICompatible(
        samples: [Float], locale: Locale, previousContext: String?
    ) async throws -> String {
        guard let key = try keychain.load(account: endpoint.keychainAccount), !key.isEmpty else {
            throw TraceError.asrInferenceFailed(
                engine: "cloud:\(endpoint.provider.rawValue)",
                reason: "missing API key in Keychain (account: \(endpoint.keychainAccount))"
            )
        }
        let wavData = encodeWav(samples: samples, sampleRate: 16_000)
        let boundary = "trace-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(endpoint.path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        let modelName = defaultModelName()
        appendField(&body, boundary: boundary, name: "model", value: modelName)
        appendField(&body, boundary: boundary, name: "response_format", value: "text")
        if let previousContext { appendField(&body, boundary: boundary, name: "prompt", value: previousContext) }
        appendField(&body, boundary: boundary, name: "language", value: String(locale.identifier.prefix(2)))
        appendFile(
            &body, boundary: boundary, name: "file", filename: "audio.wav", contentType: "audio/wav", data: wavData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TraceError.asrInferenceFailed(
                engine: "cloud:\(endpoint.provider.rawValue)",
                reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(msg.prefix(200))"
            )
        }
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeDeepgram(samples: [Float], locale: Locale) async throws -> String {
        guard let key = try keychain.load(account: endpoint.keychainAccount), !key.isEmpty else {
            throw TraceError.asrInferenceFailed(
                engine: "cloud:deepgram",
                reason: "missing API key in Keychain"
            )
        }
        let wavData = encodeWav(samples: samples, sampleRate: 16_000)
        var components = URLComponents(
            url: endpoint.baseURL.appendingPathComponent(endpoint.path), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: String(locale.identifier.prefix(2))),
            URLQueryItem(name: "smart_format", value: "true"),
        ]
        guard let url = components?.url else {
            throw TraceError.asrInferenceFailed(engine: "cloud:deepgram", reason: "URL build failed")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "<binary>"
            throw TraceError.asrInferenceFailed(
                engine: "cloud:deepgram",
                reason: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(msg.prefix(200))"
            )
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let results = root["results"] as? [String: Any],
            let channels = results["channels"] as? [[String: Any]],
            let alternatives = channels.first?["alternatives"] as? [[String: Any]],
            let transcript = alternatives.first?["transcript"] as? String
        else {
            throw TraceError.asrInferenceFailed(engine: "cloud:deepgram", reason: "unable to parse response JSON")
        }
        return transcript
    }

    private func defaultModelName() -> String {
        switch endpoint.provider {
        case .openai: return "whisper-1"
        case .groq: return "whisper-large-v3-turbo"
        case .fireworks: return "whisper-v3-turbo"
        default: return "whisper-1"
        }
    }

    private func appendField(_ body: inout Data, boundary: String, name: String, value: String) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func appendFile(
        _ body: inout Data, boundary: String, name: String, filename: String, contentType: String, data: Data
    ) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    private func encodeWav(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let pcmBytes = samples.count * 2
        let totalSize = 36 + pcmBytes
        let header: [UInt8] = [
            0x52, 0x49, 0x46, 0x46,
            UInt8(totalSize & 0xff), UInt8((totalSize >> 8) & 0xff),
            UInt8((totalSize >> 16) & 0xff), UInt8((totalSize >> 24) & 0xff),
            0x57, 0x41, 0x56, 0x45,
            0x66, 0x6d, 0x74, 0x20,
            16, 0, 0, 0,
            1, 0,
            1, 0,
            UInt8(sampleRate & 0xff), UInt8((sampleRate >> 8) & 0xff),
            UInt8((sampleRate >> 16) & 0xff), UInt8((sampleRate >> 24) & 0xff),
            UInt8((sampleRate * 2) & 0xff), UInt8(((sampleRate * 2) >> 8) & 0xff),
            UInt8(((sampleRate * 2) >> 16) & 0xff), UInt8(((sampleRate * 2) >> 24) & 0xff),
            2, 0,
            16, 0,
            0x64, 0x61, 0x74, 0x61,
            UInt8(pcmBytes & 0xff), UInt8((pcmBytes >> 8) & 0xff),
            UInt8((pcmBytes >> 16) & 0xff), UInt8((pcmBytes >> 24) & 0xff),
        ]
        data.append(contentsOf: header)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let i16 = Int16(clamped * 32_767.0)
            withUnsafeBytes(of: i16.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public func transcribeStream(_ buffer: AVAudioPCMBuffer) async throws -> ASRDelta? {
        nil
    }

    public func clearModelCache() async {}
}
