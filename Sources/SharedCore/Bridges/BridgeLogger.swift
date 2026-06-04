import os

public enum BridgeLogger {
    public static let subsystem = "app.trace.bridges"
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")
    public static let calendar = Logger(subsystem: subsystem, category: "calendar")
    public static let accessibility = Logger(subsystem: subsystem, category: "accessibility")
    public static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    public static let workspace = Logger(subsystem: subsystem, category: "workspace")
    public static let activity = Logger(subsystem: subsystem, category: "activity")
    public static let sparkle = Logger(subsystem: subsystem, category: "sparkle")
}
