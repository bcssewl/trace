import Foundation

/// A unit of work in the file batch pipeline.
///
/// Spans drag-drop intake, watched-folder
/// detection, iPhone Voice-Memo iCloud sync, and one-shot mic-driven voice memos.
///
/// The job carries the source URL plus optional project/template/engine overrides.
/// The repository is the source of truth for status; `FileBatchJob` is value-typed
/// and may be re-derived by the queue, controller, and storage layers.
public struct FileBatchJob: Sendable, Codable, Hashable, Identifiable {

    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        case audio
        case video
        /// Captured live through the mic-only voice-memo path. The `sourceURL`
        /// points at the freshly-written audio file in the project's audio dir.
        case voiceMemo
    }

    public enum Origin: String, Sendable, Codable, Hashable, CaseIterable {
        case dragDrop
        case watchedFolder
        case voiceMemosSync
        case voiceMemoCapture
    }

    public let id: UUID
    public let sourceURL: URL
    public let kind: Kind
    public let origin: Origin
    public let priority: Int
    public let projectID: String?
    public let templateID: String?
    public let asrTaskOverride: ASRTaskClass?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        kind: Kind,
        origin: Origin,
        priority: Int = 0,
        projectID: String? = nil,
        templateID: String? = nil,
        asrTaskOverride: ASRTaskClass? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.kind = kind
        self.origin = origin
        self.priority = priority
        self.projectID = projectID
        self.templateID = templateID
        self.asrTaskOverride = asrTaskOverride
    }

    /// File extensions recognized as direct audio input by the batch pipeline.
    public static let audioExtensions: Set<String> = [
        "wav", "m4a", "mp3", "aac", "caf", "flac", "aiff", "aif",
    ]

    /// File extensions recognized as video.
    ///
    /// Audio is extracted via AVFoundation
    /// before ASR.
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// Constructs a job if `url` has a supported audio or video extension.
    ///
    /// Returns `nil` for unsupported extensions so caller can silently filter
    /// dropped files (text, images, archives, etc.).
    public static func makeIfSupported(
        url: URL,
        origin: Origin,
        priority: Int = 0,
        projectID: String? = nil,
        templateID: String? = nil,
        asrTaskOverride: ASRTaskClass? = nil
    ) -> FileBatchJob? {
        let ext = url.pathExtension.lowercased()
        let kind: Kind
        if audioExtensions.contains(ext) {
            kind = .audio
        } else if videoExtensions.contains(ext) {
            kind = .video
        } else {
            return nil
        }
        return FileBatchJob(
            sourceURL: url,
            kind: kind,
            origin: origin,
            priority: priority,
            projectID: projectID,
            templateID: templateID,
            asrTaskOverride: asrTaskOverride
        )
    }

    /// Picks the ASR task class for this job, honoring an explicit override.
    ///
    /// Falls back to per-locale heuristics from the user's current locale.
    public func resolvedASRTask(locale: Locale = .current) -> ASRTaskClass {
        if let asrTaskOverride { return asrTaskOverride }
        if kind == .voiceMemo { return .voiceMemo }
        let lang = locale.language.languageCode?.identifier ?? "en"
        switch lang {
        case "en":
            return .fileBatchEnglish
        case "zh", "ja", "ko":
            return .fileBatchCJK
        default:
            return .fileBatchMulti
        }
    }
}
