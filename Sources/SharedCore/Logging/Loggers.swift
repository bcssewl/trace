import Foundation
import os

/// Centralized `os.Logger` registry.
///
/// Each subsystem gets its own category so
/// `log show` and Console.app can filter cleanly.
public enum Loggers {
    public static let subsystem = "app.trace"

    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let speech = Logger(subsystem: subsystem, category: "speech")
    public static let model = Logger(subsystem: subsystem, category: "model")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let coach = Logger(subsystem: subsystem, category: "coach")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let bridges = Logger(subsystem: subsystem, category: "bridges")
    public static let dictation = Logger(subsystem: subsystem, category: "dictation")
    public static let meeting = Logger(subsystem: subsystem, category: "meeting")
    public static let files = Logger(subsystem: subsystem, category: "files")
    public static let templates = Logger(subsystem: subsystem, category: "templates")
    public static let project = Logger(subsystem: subsystem, category: "project")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let bootstrap = Logger(subsystem: subsystem, category: "bootstrap")
}
