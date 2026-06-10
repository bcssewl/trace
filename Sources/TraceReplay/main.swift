import Foundation
import SharedCore

// Dev-only replay harness with two modes:
//
// 1. Audio replay: feed a recorded audio file through the REAL Parakeet backend
//    (the same engine meetings use) and print the transcript — so meeting
//    transcription can be tested and diffed without sitting through a live
//    meeting.
//
//      Usage:  swift run TraceReplay <audio-file> [--locale es_ES]
//
// 2. Coach bench: replay scripted meeting scenarios through the REAL
//    CoachListener against the REAL routed cloud model, with a virtual clock,
//    and report behaviour versus expectations (see CoachBench.swift).
//
//      Usage:  swift run TraceReplay coach-bench <scenarios-dir> [--only <name>]
//
// Uses top-level `await` (SwiftPM's implicit async main). No MainActor work here,
// so the async entry is safe — and a Task{}+semaphore bridge actually deadlocks
// in a plain executable target (the Task never gets scheduled).

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let args = CommandLine.arguments
guard args.count >= 2 else {
    err("usage: trace-replay <audio-file> [--locale en_US]")
    err("       trace-replay coach-bench <scenarios-dir> [--only <name>]")
    exit(2)
}
if args[1] == "coach-bench" {
    exit(await CoachBench.run(arguments: Array(args.dropFirst(2))))
}
let url = URL(fileURLWithPath: args[1])
var localeID = "en_US"
if let i = args.firstIndex(of: "--locale"), i + 1 < args.count { localeID = args[i + 1] }
var engineName = "parakeet"
if let i = args.firstIndex(of: "--engine"), i + 1 < args.count { engineName = args[i + 1].lowercased() }

do {
    err("[stage] harness started; engine=\(engineName) locale=\(localeID); reading \(url.lastPathComponent)…")
    let reader = FileAudioReader()
    let audio = try await reader.read(url: url)
    let seconds = Double(audio.durationMs) / 1000.0
    err("[stage] read \(audio.samples.count) samples (\(String(format: "%.1f", seconds))s)")

    let backend: any TranscriptionBackend
    switch engineName {
    case "whisperkit", "whisper":
        backend = WhisperKitBackend()
    case "qwen3", "qwen":
        backend = Qwen3Backend(variant: .f32)
    default:
        backend = ParakeetBackend(version: .v3)
    }
    let t0 = Date()
    try await backend.prepare(
        onStatus: { status in err("[prepare] \(status)") },
        onProgress: { _ in }
    )
    err("[prepare] loaded in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

    // Transcribe in fixed 30s windows: a multi-minute recording fed whole into the
    // TDT decoder is pathologically slow. Decoder state carries across windows.
    let sampleRate = 16_000
    let windowSamples = sampleRate * 30
    let total = audio.samples.count
    let windowCount = Int((Double(total) / Double(windowSamples)).rounded(.up))
    var pieces: [String] = []
    let t1 = Date()
    var offset = 0
    var windowIndex = 0
    while offset < total {
        let end = min(offset + windowSamples, total)
        let chunk = Array(audio.samples[offset..<end])
        let piece = try await backend.transcribe(
            chunk, locale: Locale(identifier: localeID), previousContext: nil
        )
        if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pieces.append(piece) }
        windowIndex += 1
        err(
            "[\(windowIndex)/\(windowCount)] \(Int(Double(offset) / Double(sampleRate)))s → +\(piece.split(separator: " ").count)w"
        )
        offset = end
    }
    let text = pieces.joined(separator: " ")
    let elapsed = Date().timeIntervalSince(t1)

    print(text)
    let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    err("")
    err(
        "--- engine=\(backend.displayName) | \(words) words | "
            + "transcribe \(String(format: "%.1f", elapsed))s for \(String(format: "%.1f", seconds))s audio "
            + "(\(String(format: "%.2f", elapsed / max(seconds, 0.001)))x realtime) ---")
} catch {
    err("ERROR: \(error)")
    exit(1)
}
