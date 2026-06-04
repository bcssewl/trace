import Foundation

/// Oldest-first pruning of retained audio recordings to keep them under a cache
/// budget (BAS-44).
///
/// The default capture path deletes `sys.caf` after refinement
/// (BAS-41), but the opt-in "Keep call recordings" path retains the large raw
/// captures (~230 MB/hour); this caps their total size. Notes / transcripts
/// (markdown + DB) are never touched — only the matching audio files.
public struct AudioArchivePruner: Sendable {
    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let sizeBytes: Int64
        public let modified: Date
        public init(url: URL, sizeBytes: Int64, modified: Date) {
            self.url = url
            self.sizeBytes = sizeBytes
            self.modified = modified
        }
    }

    public struct Result: Sendable, Equatable {
        public let deleted: [URL]
        public let freedBytes: Int64
        public let totalBytesBefore: Int64
        public let budgetBytes: Int64
    }

    /// File extensions treated as prunable recordings (lowercased, no dot).
    public let extensions: Set<String>

    public init(extensions: Set<String> = ["caf"]) {
        self.extensions = extensions
    }

    /// Pure: the entries to delete (oldest first) to bring the total to ≤ budget.
    public static func selectForDeletion(_ entries: [Entry], budgetBytes: Int64) -> [Entry] {
        let total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard total > budgetBytes else { return [] }
        var running = total
        var deleted: [Entry] = []
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            if running <= budgetBytes { break }
            deleted.append(entry)
            running -= entry.sizeBytes
        }
        return deleted
    }

    /// Scans `roots` recursively for matching files and deletes oldest-first until
    /// the total fits `budgetBytes`.
    ///
    /// Returns what was removed (the caller logs it —
    /// pruning is never silent). A delete failure is skipped, not fatal.
    @discardableResult
    public func prune(roots: [URL], budgetBytes: Int64, fileManager: FileManager = .default) -> Result {
        let entries = scan(roots: roots, fileManager: fileManager)
        let total = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var freed: Int64 = 0
        var deletedURLs: [URL] = []
        for entry in Self.selectForDeletion(entries, budgetBytes: budgetBytes) {
            do {
                try fileManager.removeItem(at: entry.url)
                freed += entry.sizeBytes
                deletedURLs.append(entry.url)
            } catch {
                Loggers.storage.error(
                    "Cache prune: failed to delete \(entry.url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return Result(deleted: deletedURLs, freedBytes: freed, totalBytesBefore: total, budgetBytes: budgetBytes)
    }

    func scan(roots: [URL], fileManager: FileManager) -> [Entry] {
        var entries: [Entry] = []
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        for root in roots {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in enumerator {
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                    continue
                }
                entries.append(
                    Entry(
                        url: url,
                        sizeBytes: Int64(values.fileSize ?? 0),
                        modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                    ))
            }
        }
        return entries
    }
}
