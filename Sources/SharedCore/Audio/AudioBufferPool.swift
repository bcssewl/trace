@preconcurrency import AVFoundation
import Foundation
import os

/// Small reuse pool of pre-allocated `AVAudioPCMBuffer`s for the system-tap IO
/// callback.
///
/// Why: the IO proc used to allocate a fresh `AVAudioPCMBuffer` per callback
/// (hundreds to ~1.3k allocations/sec depending on the HAL chunk size). With a
/// pool, the steady-state path is a lock-protected array pop — no heap
/// allocation on the IO queue once the consumer recycles buffers back.
///
/// Ownership contract (this is what keeps reuse safe):
/// - `acquire` hands out a buffer the pool no longer references.
/// - The consumer must call `recycle` only with buffers it received from this
///   capture's stream, and only AFTER it has finished reading them (i.e. it
///   has copied any samples it needs). Recycling early aliases live audio.
/// - If nothing recycles (e.g. a consumer that never returns buffers), every
///   `acquire` misses and the caller falls back to fresh allocation — exactly
///   the previous behaviour, never corruption.
///
/// `rebuild` is called whenever the capture (re)builds its pipeline so pooled
/// buffers always match the current tap format; buffers from a previous format
/// are rejected on recycle.
public final class AudioBufferPool: @unchecked Sendable {

    public struct Stats: Sendable, Equatable {
        public var hits: Int = 0
        public var misses: Int = 0
        public var recycled: Int = 0
        public var rejected: Int = 0
    }

    private struct State {
        var available: [AVAudioPCMBuffer] = []
        var format: AVAudioFormat?
        var capacityFrames: AVAudioFrameCount = 0
        var stats = Stats()
    }

    /// Upper bound on buffers kept for reuse; recycles beyond this are dropped
    /// (the buffer just deallocates as before).
    public let maxPooledBuffers: Int

    private let lock: OSAllocatedUnfairLock<State>

    public init(maxPooledBuffers: Int = 16) {
        self.maxPooledBuffers = max(1, maxPooledBuffers)
        self.lock = OSAllocatedUnfairLock(initialState: State())
    }

    /// (Re)configure for a stream format: drops everything pooled and
    /// pre-allocates `preallocate` buffers of `capacityFrames` so the first
    /// seconds of capture don't allocate either.
    public func rebuild(format: AVAudioFormat, capacityFrames: AVAudioFrameCount, preallocate: Int) {
        var allocated: [AVAudioPCMBuffer] = []
        for _ in 0..<min(max(0, preallocate), maxPooledBuffers) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacityFrames) else { break }
            allocated.append(buffer)
        }
        let fresh = allocated
        lock.withLock { state in
            state.available = fresh
            state.format = format
            state.capacityFrames = capacityFrames
        }
    }

    /// Drop all pooled buffers (capture stopped).
    public func drain() {
        lock.withLock { state in
            state.available.removeAll()
            state.format = nil
            state.capacityFrames = 0
        }
    }

    /// A reusable buffer for `frameCount` frames of `format`, or `nil` when
    /// the pool is empty / misconfigured — the caller then allocates fresh.
    /// The returned buffer's `frameLength` is NOT set; the caller sets it.
    public func acquire(frameCount: AVAudioFrameCount, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        lock.withLock { state in
            guard let poolFormat = state.format,
                state.capacityFrames >= frameCount,
                Self.formatsMatch(poolFormat, format),
                let buffer = state.available.popLast()
            else {
                state.stats.misses += 1
                return nil
            }
            state.stats.hits += 1
            return buffer
        }
    }

    /// Return a buffer for reuse once the consumer has finished reading it.
    /// Rejected (and simply released) when the format no longer matches, the
    /// pool is full, or the same instance is already pooled (double recycle).
    public func recycle(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { state in
            guard let poolFormat = state.format,
                Self.formatsMatch(poolFormat, buffer.format),
                buffer.frameCapacity >= state.capacityFrames,
                state.available.count < maxPooledBuffers,
                !state.available.contains(where: { $0 === buffer })
            else {
                state.stats.rejected += 1
                return
            }
            state.stats.recycled += 1
            state.available.append(buffer)
        }
    }

    public var stats: Stats {
        lock.withLock { $0.stats }
    }

    /// Number of buffers currently available for reuse.
    public var availableCount: Int {
        lock.withLock { $0.available.count }
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }
}
