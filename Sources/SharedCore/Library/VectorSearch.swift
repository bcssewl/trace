import Accelerate
import Foundation

/// In-memory dense retrieval over the `kb_chunks`/`kb_embeddings` cache.
///
/// Storage: vectors are packed into contiguous half-precision (IEEE-754 16-bit)
/// blocks grouped by dimension — half the steady-state memory of the previous
/// `[Float]`-per-chunk layout (≈110 MB instead of ≈220 MB at 100k × 768-dim
/// chunks). Scoring converts one block at a time back to Float32 (vImage) and
/// runs a single matrix·vector multiply per block (vDSP), keeping query latency
/// in the low tens of milliseconds at 100k chunks. Scores are identical to the
/// old per-chunk `vDSP_dotpr` scan modulo fp16 rounding of the stored vectors.
///
/// `refresh()` is incremental: a cheap id→version probe finds new / changed /
/// deleted chunks and only those are (re)loaded from SQLite; unchanged chunks
/// are never re-read. A fingerprint change (different embedding model) still
/// triggers a full reload.
public actor VectorSearch {
    public struct Hit: Sendable, Hashable {
        public let chunk: KbChunk
        public let score: Float
        public init(chunk: KbChunk, score: Float) {
            self.chunk = chunk
            self.score = score
        }
    }

    private let cache: KbCache
    private let config: EmbeddingConfig

    /// One contiguous half-precision block of vectors sharing a dimension.
    ///
    /// `chunks[row] == nil` marks a tombstone (chunk deleted or superseded);
    /// its vector slot is dead weight until `compactIfNeeded()` rebuilds.
    private struct Pack {
        let dim: Int
        var chunks: [KbChunk?]
        /// `chunks.count * dim` IEEE-754 binary16 bit patterns (UInt16 so this
        /// builds on every architecture; converted via vImage, not Swift Float16).
        var vectors: [UInt16]
        var liveCount: Int
    }

    private struct Slot {
        var pack: Int
        var row: Int
        var version: Int64
    }

    private var packs: [Pack] = []
    private var slots: [String: Slot] = [:]
    private var loadedFingerprint: String?
    private var hasLoaded = false

    public init(cache: KbCache, config: EmbeddingConfig) {
        self.cache = cache
        self.config = config
    }

    public func refresh() async throws {
        guard hasLoaded, loadedFingerprint == config.fingerprint else {
            try await fullReload()
            return
        }
        let current = try await cache.chunkVersions(config: config)
        var toLoad: [String] = []
        for (id, version) in current {
            if let slot = slots[id] {
                if slot.version != version { toLoad.append(id) }
            } else {
                toLoad.append(id)
            }
        }
        var removed: [String] = []
        for id in slots.keys where current[id] == nil { removed.append(id) }
        guard !toLoad.isEmpty || !removed.isEmpty else { return }

        for id in removed { tombstone(id) }
        // Changed chunks are tombstoned then re-appended with the fresh vector.
        for id in toLoad where slots[id] != nil { tombstone(id) }
        for (chunk, embedding) in try await cache.loadChunks(ids: toLoad, config: config) {
            append(chunk: chunk, embedding: embedding, version: current[chunk.id] ?? 0)
        }
        compactIfNeeded()
    }

    public func topK(
        query: [Float],
        k: Int,
        sourceFilePrefix: String? = nil,
        where filter: (@Sendable (KbChunk) -> Bool)? = nil
    ) async throws -> [Hit] {
        guard k > 0, !query.isEmpty else { return [] }
        if !hasLoaded || loadedFingerprint != config.fingerprint {
            try await refresh()
        }
        let normalizedQuery: [Float]
        switch config.normalization {
        case .unitL2: normalizedQuery = EmbeddingClient.unitL2(query)
        case .none: normalizedQuery = query
        }
        var scored: [Hit] = []
        for pack in packs where pack.dim == normalizedQuery.count && pack.liveCount > 0 {
            scored.reserveCapacity(scored.count + pack.liveCount)
            let scores = Self.blockScores(pack: pack, query: normalizedQuery)
            for (row, chunk) in pack.chunks.enumerated() {
                guard let chunk else { continue }
                if let prefix = sourceFilePrefix, !chunk.sourceFile.hasPrefix(prefix) { continue }
                if let filter, !filter(chunk) { continue }
                scored.append(Hit(chunk: chunk, score: scores[row]))
            }
        }
        scored.sort { $0.score > $1.score }
        if scored.count > k {
            scored.removeLast(scored.count - k)
        }
        return scored
    }

    public func indexedChunkCount() -> Int {
        packs.reduce(0) { $0 + $1.liveCount }
    }

    // MARK: - Index maintenance

    private func fullReload() async throws {
        packs = []
        slots = [:]
        let versions = try await cache.chunkVersions(config: config)
        for (chunk, embedding) in try await cache.loadValid(config: config) {
            append(chunk: chunk, embedding: embedding, version: versions[chunk.id] ?? 0)
        }
        loadedFingerprint = config.fingerprint
        hasLoaded = true
    }

    private func append(chunk: KbChunk, embedding: KbEmbedding, version: Int64) {
        let dim = embedding.vector.count
        guard dim > 0 else { return }
        let packIndex: Int
        if let existing = packs.firstIndex(where: { $0.dim == dim }) {
            packIndex = existing
        } else {
            packs.append(Pack(dim: dim, chunks: [], vectors: [], liveCount: 0))
            packIndex = packs.count - 1
        }
        let row = packs[packIndex].chunks.count
        packs[packIndex].chunks.append(chunk)
        packs[packIndex].vectors.append(contentsOf: Self.toHalf(embedding.vector))
        packs[packIndex].liveCount += 1
        slots[chunk.id] = Slot(pack: packIndex, row: row, version: version)
    }

    private func tombstone(_ id: String) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        packs[slot.pack].chunks[slot.row] = nil
        packs[slot.pack].liveCount -= 1
    }

    /// Rebuild any pack whose tombstones exceed a quarter of its rows, so churn
    /// (meeting re-indexing) can't grow dead vector slots without bound.
    private func compactIfNeeded() {
        for index in packs.indices {
            let total = packs[index].chunks.count
            let dead = total - packs[index].liveCount
            guard total >= 64, dead * 4 >= total else { continue }
            compact(packIndex: index)
        }
    }

    private func compact(packIndex: Int) {
        let old = packs[packIndex]
        var newChunks: [KbChunk?] = []
        newChunks.reserveCapacity(old.liveCount)
        var newVectors: [UInt16] = []
        newVectors.reserveCapacity(old.liveCount * old.dim)
        for (row, chunk) in old.chunks.enumerated() {
            guard let chunk else { continue }
            let newRow = newChunks.count
            newChunks.append(chunk)
            newVectors.append(contentsOf: old.vectors[(row * old.dim)..<((row + 1) * old.dim)])
            slots[chunk.id]?.row = newRow
        }
        packs[packIndex] = Pack(
            dim: old.dim, chunks: newChunks, vectors: newVectors, liveCount: newChunks.count)
    }

    // MARK: - Scoring

    /// Rows scanned per scratch block: 2048 × 768 dims × 4 B ≈ 6 MB transient.
    private static let blockRows = 2048

    /// Dot product of `query` against every row of `pack` (tombstoned rows
    /// produce garbage scores that the caller skips via the nil chunk).
    private static func blockScores(pack: Pack, query: [Float]) -> [Float] {
        let dim = pack.dim
        let rows = pack.chunks.count
        var out = [Float](repeating: 0, count: rows)
        guard rows > 0 else { return out }
        var scratch = [Float](repeating: 0, count: min(rows, blockRows) * dim)
        pack.vectors.withUnsafeBufferPointer { half in
            query.withUnsafeBufferPointer { q in
                out.withUnsafeMutableBufferPointer { outBuf in
                    scratch.withUnsafeMutableBufferPointer { scratchBuf in
                        var row = 0
                        while row < rows {
                            let count = min(blockRows, rows - row)
                            halfToFloat(
                                src: half.baseAddress! + row * dim,
                                dst: scratchBuf.baseAddress!,
                                count: count * dim
                            )
                            // scores[row..<row+count] = scratch(count×dim) · query(dim×1)
                            vDSP_mmul(
                                scratchBuf.baseAddress!, 1,
                                q.baseAddress!, 1,
                                outBuf.baseAddress! + row, 1,
                                vDSP_Length(count), 1, vDSP_Length(dim)
                            )
                            row += count
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Half-precision conversion (vImage; works on every architecture)

    static func toHalf(_ floats: [Float]) -> [UInt16] {
        guard !floats.isEmpty else { return [] }
        var out = [UInt16](repeating: 0, count: floats.count)
        floats.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                    height: 1, width: vImagePixelCount(floats.count),
                    rowBytes: floats.count * MemoryLayout<Float>.stride)
                var dstBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(dst.baseAddress!),
                    height: 1, width: vImagePixelCount(floats.count),
                    rowBytes: floats.count * MemoryLayout<UInt16>.stride)
                vImageConvert_PlanarFtoPlanar16F(&srcBuf, &dstBuf, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    private static func halfToFloat(src: UnsafePointer<UInt16>, dst: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var srcBuf = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: src),
            height: 1, width: vImagePixelCount(count),
            rowBytes: count * MemoryLayout<UInt16>.stride)
        var dstBuf = vImage_Buffer(
            data: UnsafeMutableRawPointer(dst),
            height: 1, width: vImagePixelCount(count),
            rowBytes: count * MemoryLayout<Float>.stride)
        vImageConvert_Planar16FtoPlanarF(&srcBuf, &dstBuf, vImage_Flags(kvImageNoFlags))
    }
}
