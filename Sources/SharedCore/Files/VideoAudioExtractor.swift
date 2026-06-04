@preconcurrency import AVFoundation
import Foundation

/// Extracts the audio track from a video container into a temporary `.m4a`
/// file.
///
/// The temporary URL is owned by the caller — typically the
/// `FileBatchController`, which deletes it once the source job reaches a
/// terminal state.
public protocol VideoAudioExtracting: Sendable {
    /// Returns a temporary audio URL containing the extracted audio. The file
    /// lives in `FileManager.default.temporaryDirectory` so eviction by macOS
    /// is acceptable.
    func extractAudio(from videoURL: URL) async throws -> URL
}

public struct AVFoundationVideoAudioExtractor: VideoAudioExtracting {

    public init() {}

    public func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-files", isDirectory: true)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
        let outputURL =
            tempDir
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension("m4a")

        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetAppleM4A
            )
        else {
            throw TraceError.audioCaptureFailed(
                reason: "AVAssetExportSession init failed for \(videoURL.lastPathComponent)"
            )
        }

        do {
            try await session.export(to: outputURL, as: .m4a)
        } catch {
            throw TraceError.audioCaptureFailed(
                reason: "AVAssetExportSession failed: \(error.localizedDescription)"
            )
        }
        return outputURL
    }
}
