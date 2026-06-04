import Foundation

public struct SessionLayout: Sendable, Hashable {
    public let root: URL
    public let projectFolderName: String
    public let sessionId: String

    public init(root: URL, projectFolderName: String, sessionId: String) {
        self.root = root
        self.projectFolderName = projectFolderName
        self.sessionId = sessionId
    }

    public static func defaultSessionId(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.timeZone = TimeZone.current
        return "session_\(formatter.string(from: date))"
    }

    public var projectDirectory: URL {
        root.appendingPathComponent(projectFolderName, isDirectory: true)
    }

    public var sessionDirectory: URL {
        projectDirectory.appendingPathComponent(sessionId, isDirectory: true)
    }

    public var audioDirectory: URL {
        sessionDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    public var attachmentsDirectory: URL {
        sessionDirectory.appendingPathComponent("attachments", isDirectory: true)
    }

    public var imagesDirectory: URL {
        sessionDirectory.appendingPathComponent("images", isDirectory: true)
    }

    public var sessionJsonURL: URL {
        sessionDirectory.appendingPathComponent("session.json", isDirectory: false)
    }

    public var transcriptLiveURL: URL {
        sessionDirectory.appendingPathComponent("transcript.live.jsonl", isDirectory: false)
    }

    public var transcriptFinalURL: URL {
        sessionDirectory.appendingPathComponent("transcript.final.jsonl", isDirectory: false)
    }

    public var notesURL: URL {
        sessionDirectory.appendingPathComponent("notes.md", isDirectory: false)
    }

    public var notesMetaURL: URL {
        sessionDirectory.appendingPathComponent("notes.meta.json", isDirectory: false)
    }

    /// Per-session speaker rename map (`rawSpeakerID` → display name), written at
    /// finalize.
    ///
    /// Durable seam so the library indexer can show real speaker names
    /// in citations instead of "Speaker N" (BAS-11 persists it → BAS-28 consumes).
    public var speakerNamesURL: URL {
        sessionDirectory.appendingPathComponent(MeetingSpeakerNames.filename, isDirectory: false)
    }

    /// Per-`remote_N` mean voiceprints from the finalize diarization pass, persisted
    /// so a post-finalize speaker rename can re-run cross-meeting enrollment off the
    /// saved meeting without the live audio (BAS-43).
    ///
    /// Written only when speaker
    /// memory is enabled and the offline pass produced embeddings.
    public var speakerVoiceprintsURL: URL {
        sessionDirectory.appendingPathComponent(MeetingVoiceprints.filename, isDirectory: false)
    }

    public var micAudioURL: URL {
        audioDirectory.appendingPathComponent("mic.caf", isDirectory: false)
    }

    public var systemAudioURL: URL {
        audioDirectory.appendingPathComponent("sys.caf", isDirectory: false)
    }

    public var finalAudioURL: URL {
        audioDirectory.appendingPathComponent("final.m4a", isDirectory: false)
    }

    public func createDirectories() throws {
        let fm = FileManager.default
        for dir in [sessionDirectory, audioDirectory, attachmentsDirectory, imagesDirectory] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}
