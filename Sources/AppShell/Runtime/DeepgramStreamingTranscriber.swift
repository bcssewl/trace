@preconcurrency import AVFoundation
import Foundation
import SharedCore

/// BAS-7 — a second live `StreamingTranscriber` (the first being Apple's), this
/// one cloud-backed via Deepgram's realtime WebSocket.
///
/// It streams the mic to
/// Deepgram as `linear16` and surfaces interim partials through its OWN
/// transcriber, exactly like `AppleSpeechStreamingTranscriber` does locally.
///
/// The de-chunking (interim-replaces / final-commits) is the pure, unit-tested
/// `DeepgramTranscriptAccumulator`; this type only owns the socket lifecycle.
/// `start()` returns `false` when there's no Deepgram key, so `BatchedASR`
/// cleanly falls back to the one-shot batch path (`CloudASRBackend`).
public final class DeepgramStreamingTranscriber: StreamingTranscriber, @unchecked Sendable {
    private let keychain: KeychainSecrets
    private let session: URLSession
    /// How long `finish()` waits after asking Deepgram to close the stream, so a
    /// trailing final result can arrive before we read the accumulated transcript.
    private static let finalFlushGraceNanos: UInt64 = 700_000_000

    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var accumulator = DeepgramTranscriptAccumulator()
    private var onPartial: (@Sendable (String) -> Void)?
    private var closed = false

    public init(keychain: KeychainSecrets = KeychainSecrets(), session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    public func start(onPartial: @escaping @Sendable (String) -> Void) async -> Bool {
        guard let key = try? keychain.load(account: "deepgram"), !key.isEmpty else {
            Loggers.dictation.warning("Deepgram streaming unavailable: no API key; falling back to batch ASR")
            return false
        }
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "model", value: "nova-3"),
        ]
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        lock.withLock {
            self.onPartial = onPartial
            self.accumulator = DeepgramTranscriptAccumulator()
            self.closed = false
            self.socket = task
        }
        task.resume()
        receiveNext(task)
        Loggers.dictation.info("Deepgram streaming session started")
        return true
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        let data = ASRAudioConvert.mono16kInt16LEData(buffer)
        guard !data.isEmpty else { return }
        let task = lock.withLock { socket }
        task?.send(.data(data)) { error in
            if let error {
                Loggers.dictation.error("Deepgram send error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    public func finish() async -> String {
        let task = lock.withLock { socket }
        // Ask Deepgram to flush remaining audio and emit the final result.
        task?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
        // Brief grace so the closing final frame can arrive before we read the
        // accumulated transcript. Never blocks indefinitely.
        try? await Task.sleep(nanoseconds: Self.finalFlushGraceNanos)
        return lock.withLock {
            closed = true
            task?.cancel(with: .normalClosure, reason: nil)
            socket = nil
            onPartial = nil
            return accumulator.cumulative
        }
    }

    /// One-shot receive that re-arms itself until the socket closes.
    ///
    /// Each result
    /// frame is folded into the accumulator and any advance is pushed to the live
    /// handler off-main.
    private func receiveNext(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            guard case .success(let message) = result else {
                return  // failure → socket closed/cancelled; stop the loop
            }
            let frame: String?
            switch message {
            case .string(let text): frame = text
            case .data(let data): frame = String(data: data, encoding: .utf8)
            @unknown default: frame = nil
            }
            if let frame {
                let advanced = self.lock.withLock { self.accumulator.ingest(jsonFrame: frame) }
                if let advanced {
                    let handler = self.lock.withLock { self.onPartial }
                    handler?(advanced)
                }
            }
            let keepGoing = self.lock.withLock { !self.closed && self.socket != nil }
            if keepGoing { self.receiveNext(task) }
        }
    }
}
