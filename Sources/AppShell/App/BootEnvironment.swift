import Foundation
import SharedCore

@MainActor
public enum BootContext {
    public struct Snapshot: Sendable {
        public let database: SqliteDatabase
        public let projectStore: ProjectStore
        public let config: BootstrapConfig
        public let sparkleConfig: SparkleConfig?

        public init(
            database: SqliteDatabase, projectStore: ProjectStore,
            config: BootstrapConfig, sparkleConfig: SparkleConfig?
        ) {
            self.database = database
            self.projectStore = projectStore
            self.config = config
            self.sparkleConfig = sparkleConfig
        }
    }

    private static var _current: Snapshot?

    public static func install(_ snapshot: Snapshot) {
        _current = snapshot
    }

    public static var current: Snapshot? { _current }
}
