import Foundation

/// Pure-Sendable helpers turning raw inbox events into `FileBatchJob`s.
///
/// All
/// AppKit and UI plumbing is left to higher layers; the inbox itself works
/// purely off URLs so it can be exercised by unit tests without spinning up
/// `NSItemProvider`.
public enum FileInbox {

    /// Filters and constructs jobs from a dragged URL set.
    ///
    /// Unsupported URLs
    /// (text files, archives) are silently dropped. Direct-children duplicates
    /// (same path, same priority) are de-duplicated by path.
    public static func jobsFromDrop(
        urls: [URL],
        projectID: String? = nil,
        templateID: String? = nil,
        asrTaskOverride: ASRTaskClass? = nil,
        priority: Int = 0
    ) -> [FileBatchJob] {
        var seen: Set<String> = []
        var out: [FileBatchJob] = []
        for url in urls {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            guard
                let job = FileBatchJob.makeIfSupported(
                    url: url,
                    origin: .dragDrop,
                    priority: priority,
                    projectID: projectID,
                    templateID: templateID,
                    asrTaskOverride: asrTaskOverride
                )
            else { continue }
            out.append(job)
        }
        return out
    }

    /// Default iCloud Drive path Apple's Voice Memos app syncs to on macOS.
    public static func defaultVoiceMemosFolder(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent("Voice Memos", isDirectory: true)
    }

    /// Builds the initial set of jobs to import from a Voice Memos folder.
    ///
    /// If `importExisting` is false, returns empty so first-watch does not
    /// retroactively pull old recordings.
    public static func voiceMemosBacklogJobs(
        currentlyInFolder urls: [URL],
        importExisting: Bool,
        projectID: String? = nil,
        templateID: String? = nil
    ) -> [FileBatchJob] {
        guard importExisting else { return [] }
        return urls.compactMap { url in
            FileBatchJob.makeIfSupported(
                url: url,
                origin: .voiceMemosSync,
                priority: 0,
                projectID: projectID,
                templateID: templateID
            )
        }
    }
}

/// Stateful snapshot of a watched folder's contents.
///
/// Each `diff` call returns
/// jobs for newly-present supported files. The owner (typically a
/// `WatchedFolderSession`) drives `diff` whenever a `DispatchSource` change
/// event fires.
public struct WatchedFolderSnapshot: Sendable {
    private var known: Set<String>
    private let origin: FileBatchJob.Origin
    private let projectID: String?
    private let templateID: String?

    public init(
        existing: Set<URL> = [],
        origin: FileBatchJob.Origin = .watchedFolder,
        projectID: String? = nil,
        templateID: String? = nil
    ) {
        self.known = Set(existing.map(\.standardizedFileURL.path))
        self.origin = origin
        self.projectID = projectID
        self.templateID = templateID
    }

    public var knownPaths: Set<String> { known }

    public mutating func diff(currentFiles: Set<URL>) -> [FileBatchJob] {
        let current = Set(currentFiles.map(\.standardizedFileURL.path))
        let added = current.subtracting(known)
        known = current
        let sortedAdded = added.sorted()
        return sortedAdded.compactMap { path in
            FileBatchJob.makeIfSupported(
                url: URL(fileURLWithPath: path),
                origin: origin,
                priority: 0,
                projectID: projectID,
                templateID: templateID
            )
        }
    }
}

/// Resolved, scoped access to a watched folder root.
///
/// Constructed from a
/// `SecurityScopedBookmark` so the app retains read access across launches
/// without prompting the user again.
public struct WatchedFolderConfig: Sendable, Codable, Hashable {
    public let bookmarkData: Data?
    public let displayPath: String
    public let importExistingOnFirstScan: Bool
    public let projectID: String?
    public let templateID: String?

    public init(
        bookmarkData: Data? = nil,
        displayPath: String,
        importExistingOnFirstScan: Bool = false,
        projectID: String? = nil,
        templateID: String? = nil
    ) {
        self.bookmarkData = bookmarkData
        self.displayPath = displayPath
        self.importExistingOnFirstScan = importExistingOnFirstScan
        self.projectID = projectID
        self.templateID = templateID
    }

    /// A copy with a different project assignment — the config's fields are
    /// immutable, so editing one (e.g. re-assigning the folder's project) goes
    /// through here instead of hand-copying every field at the call site.
    public func with(projectID: String?) -> WatchedFolderConfig {
        WatchedFolderConfig(
            bookmarkData: bookmarkData,
            displayPath: displayPath,
            importExistingOnFirstScan: importExistingOnFirstScan,
            projectID: projectID,
            templateID: templateID
        )
    }

    /// Resolves to a `ResolvedFolder`.
    ///
    /// Caller must keep the returned handle
    /// alive while reading directory contents. The handle releases its
    /// security scope on deinit.
    public func resolve() throws -> ResolvedFolder {
        if let data = bookmarkData {
            return try SecurityScopedBookmark(
                bookmarkData: data, originalPath: displayPath
            ).resolve()
        }
        return ResolvedFolder(
            url: URL(fileURLWithPath: displayPath),
            isStale: false
        )
    }
}

/// Enumerates supported files immediately under a folder URL.
///
/// Does not recurse;
/// Voice Memos and watched folders are flat by design. The result is a Set so
/// callers can diff against the prior snapshot trivially.
public enum WatchedFolderScan {
    public static func currentSupportedFiles(in folder: URL) -> Set<URL> {
        let supportedExts = FileBatchJob.audioExtensions.union(FileBatchJob.videoExtensions)
        let fm = FileManager.default
        guard
            let contents = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        else { return [] }
        var out: Set<URL> = []
        for url in contents {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            guard supportedExts.contains(url.pathExtension.lowercased()) else { continue }
            out.insert(url.standardizedFileURL)
        }
        return out
    }
}
