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
    /// User-visible failure/notice queue, rendered as banners in the main
    /// window. The coordinator posts here wherever it previously swallowed an
    /// error into the log — the enforcement point of the no-silent-failure rule.
    public let notices = AppNoticeCenter()

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
        // Honour a deferred engine take-over: if onboarding's practice step had
        // to fall back to Apple Speech while Parakeet was still downloading, it
        // promised Parakeet would take over once the download lands. The flip
        // below is what keeps that promise — and an explicit engine choice in
        // Settings clears the flag, so it can never override the user.
        self.asrInstall.onParakeetReady = { [state = self.state] in
            guard state.parakeetTakeoverPending else { return }
            state.parakeetTakeoverPending = false
            state.dictationASREngine = .parakeet
            Loggers.bootstrap.info("Parakeet finished downloading — taking over dictation as promised at onboarding")
        }
    }
}
