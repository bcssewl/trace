import Foundation
import SharedCore

@MainActor
public final class AppEnvironment {
    public let paths: DatabasePaths
    public let palette: BrutalistPalette.Pair
    public let state: AppStateModel
    public let database: SqliteDatabase?
    public let projectStore: ProjectStore?
    /// Owns the on-device speech-model download for the whole app lifetime, so
    /// an approved download survives the user leaving the onboarding wizard and
    /// the dictation runtime can wait on the same instance.
    public let asrInstall: AsrModelInstallCoordinator

    public init(
        paths: DatabasePaths = DatabasePaths(),
        palette: BrutalistPalette.Pair? = nil,
        state: AppStateModel? = nil
    ) {
        self.paths = paths
        let boot = BootContext.current
        self.database = boot?.database
        self.projectStore = boot?.projectStore
        if let palette {
            self.palette = palette
        } else if let loaded = try? BrutalistPalette.loadFromBundle() {
            self.palette = loaded
        } else {
            self.palette = BrutalistPalette.Pair(dark: .dark, light: .light)
        }
        self.state = state ?? AppStateModel(onboardingComplete: AppStateModel.persistedOnboardingComplete())
        self.asrInstall = AsrModelInstallCoordinator()
    }
}
