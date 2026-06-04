import AppKit
import CryptoKit
import Foundation
import PDFKit
import os

public actor KnowledgeBaseIndexer {

    public struct Report: Sendable {
        public var indexed: Int = 0
        public var embedded: Int = 0
        public var cacheHits: Int = 0
        public var skippedFiles: Int = 0
        public var chunks: [KbChunk] = []
    }

    private let cache: KbCache
    private let embedder: EmbeddingClient
    private let config: EmbeddingConfig
    private let log = Loggers.library

    public init(cache: KbCache, embedder: EmbeddingClient, config: EmbeddingConfig) {
        self.cache = cache
        self.embedder = embedder
        self.config = config
    }

    /// Index a single playbook folder.
    ///
    /// Convenience over ``index(folders:)`` for the
    /// single-root case (and the existing tests).
    @discardableResult
    public func index(folder: URL) async throws -> Report {
        try await index(folders: [folder])
    }

    /// Index one or more playbook folders into the **shared** playbook corpus in a
    /// single pass, with one unioned prune at the end.
    ///
    /// Indexing folders separately
    /// would make each folder's prune wipe the others (the prune keeps only the
    /// files it was just handed), so the whole live set must be presented together.
    /// Relative `source_file`s are folder-root-relative; the prune is scoped to
    /// playbook rows, so meeting chunks are never touched (see ``KbCache/pruneObsolete``).
    /// Embedding happens before the prune, so an embedder failure throws without
    /// destroying the existing corpus.
    @discardableResult
    public func index(folders: [URL]) async throws -> Report {
        var report = Report()
        var keep: [(file: String, sha: String)] = []
        var pendingChunks: [KbChunk] = []
        var pendingTexts: [String] = []

        for folder in folders {
            let files = try enumerateDocFiles(in: folder)
            for file in files {
                let rel = relativePath(file: file, root: folder)
                let bytes: Data
                do {
                    bytes = try Data(contentsOf: file)
                } catch {
                    log.error(
                        "could not read \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    report.skippedFiles += 1
                    // Transient read failure (iCloud/Dropbox sync lock, permission
                    // blip): preserve the file's already-indexed chunks rather than
                    // letting the unioned prune drop them — keep them by their
                    // existing sha. A genuinely-removed file isn't enumerated at all,
                    // so it still prunes correctly.
                    for sha in (try? await cache.shasForFile(rel)) ?? [] {
                        keep.append((file: rel, sha: sha))
                    }
                    continue
                }
                let sha = KbCache.sha256Hex(of: bytes)
                keep.append((file: rel, sha: sha))

                let text = await extractText(from: file, bytes: bytes)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    log.info("no extractable text in \(rel, privacy: .public) — skipping")
                    report.skippedFiles += 1
                    continue
                }
                let raw = MarkdownChunker.chunk(markdown: text, sourceFile: rel)
                for r in raw {
                    let chunk = KbChunk(
                        sourceFile: rel, breadcrumb: r.breadcrumb,
                        text: r.text, sourceSha256: sha
                    )
                    report.chunks.append(chunk)
                    report.indexed += 1
                    let needs = try await cache.shouldEmbed(chunk: chunk, config: config)
                    if needs {
                        pendingChunks.append(chunk)
                        pendingTexts.append(chunk.text)
                    } else {
                        report.cacheHits += 1
                    }
                }
            }
        }

        if !pendingTexts.isEmpty {
            let vectors = try await embedder.embedForIndex(texts: pendingTexts)
            precondition(
                vectors.count == pendingChunks.count,
                "embedder returned \(vectors.count) vectors for \(pendingChunks.count) chunks"
            )
            for (chunk, vec) in zip(pendingChunks, vectors) {
                let emb = KbEmbedding(
                    chunkId: chunk.id, vector: vec,
                    configFingerprint: config.fingerprint
                )
                try await cache.upsert(chunk: chunk, embedding: emb, config: config)
                report.embedded += 1
            }
        }

        // Single unioned prune over the whole presented set. An empty `keep`
        // (no folders, or all empty) clears the playbook corpus — meetings survive.
        try await cache.pruneObsolete(keeping: keep)
        log.info(
            "indexed \(report.indexed) chunks (\(report.embedded) new, \(report.cacheHits) cached) across \(folders.count) folder(s)"
        )
        return report
    }

    /// Doc extensions the playbook indexer reads.
    ///
    /// Markdown / plain-text are read
    /// directly; PDF via PDFKit; Word / RTF via AppKit's document importer.
    /// (PowerPoint isn't supported yet — tracked separately.)
    private static let supportedExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "pdf", "docx", "doc", "rtf",
    ]

    private func enumerateDocFiles(in folder: URL) throws -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        guard
            let it = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        for case let url as URL in it {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext), !name.hasPrefix("_"), !name.hasPrefix(".") else {
                continue
            }
            let v = try url.resourceValues(forKeys: [.isRegularFileKey])
            if v.isRegularFile == true { results.append(url) }
        }
        return results.sorted { $0.path < $1.path }
    }

    /// Extract plain text from a doc by type.
    ///
    /// Markdown / plain-text decode the raw
    /// bytes; PDF uses PDFKit; Word / RTF use AppKit's document importer (on the
    /// main thread, since document reading isn't guaranteed safe off-main).
    private func extractText(from file: URL, bytes: Data) async -> String {
        switch file.pathExtension.lowercased() {
        case "pdf":
            return PDFDocument(url: file)?.string ?? ""
        case "docx", "doc", "rtf":
            return await Self.attributedText(from: file)
        default:
            return String(data: bytes, encoding: .utf8) ?? ""
        }
    }

    @MainActor
    private static func attributedText(from file: URL) -> String {
        (try? NSAttributedString(url: file, options: [:], documentAttributes: nil))?.string ?? ""
    }

    private func relativePath(file: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return filePath
    }
}
