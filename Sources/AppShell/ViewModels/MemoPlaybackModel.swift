@preconcurrency import AVFoundation
import Foundation
import Observation
import SharedCore

/// Drives in-app playback for a single voice-memo / file row at a time.
///
/// Only one clip plays at once — starting a new one stops the previous. The
/// view binds the play/pause button and scrubber to `playingID` / `currentTime`
/// / `duration`. A lightweight ticker republishes `currentTime` while playing so
/// the scrubber tracks the audio without a per-frame timer.
@MainActor
@Observable
public final class MemoPlaybackModel: NSObject, AVAudioPlayerDelegate {
    /// The id of the row currently loaded into the player (playing OR paused),
    /// or nil when nothing is loaded.
    public private(set) var playingID: String?
    public var isPlaying: Bool = false
    public var currentTime: Double = 0
    public private(set) var duration: Double = 0
    /// Set when the audio file couldn't be opened — surfaced by the view rather
    /// than failing silently.
    public private(set) var failedID: String?

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    public override init() { super.init() }

    /// Play the row if idle/paused-elsewhere, or pause/resume if it's the active
    /// one. The single entry point behind the row's play/pause button.
    public func toggle(_ record: FileRecord) {
        if playingID == record.id {
            if isPlaying { pause() } else { resume() }
        } else {
            start(path: record.sourcePath, id: record.id)
        }
    }

    private func start(path: String, id: String) {
        stop()
        let url = URL(fileURLWithPath: path)
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            failedID = id
            return
        }
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        playingID = id
        failedID = nil
        duration = player.duration
        currentTime = 0
        player.play()
        isPlaying = true
        startTicker()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    public func resume() {
        guard player != nil else { return }
        player?.play()
        isPlaying = true
        startTicker()
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        playingID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    /// Scrub to a position (seconds) on the active clip.
    public func seek(to time: Double) {
        guard let player else { return }
        let clamped = min(max(0, time), player.duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            // Ignore a finish callback for a clip we've already replaced — otherwise
            // a clip the user just started gets torn down by the previous one's
            // end-of-playback notification.
            guard let self, self.player === player else { return }
            self.stop()
        }
    }
}
