import XCTest

@testable import AppShell
@testable import SharedCore

@MainActor
final class OnboardingStateModelTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    func testPresetSelectionUpdatesProjectDefaults() {
        let model = OnboardingStateModel()
        let classes = OnboardingStateModel.projectPresets[1]

        model.projectName = ""
        model.selectProjectPreset(classes)

        XCTAssertEqual(model.selectedPresetID, classes.id)
        XCTAssertEqual(model.projectName, "Classes")
        XCTAssertEqual(model.projectTemplateName, "Lecture Notes")
        XCTAssertEqual(model.projectColor, classes.color)
    }

    func testCommitFirstProjectPersistsSelectedPresetAndDoesNotDuplicate() async throws {
        let tempDir = try makeTempDir()
        let db = try await SqliteDatabase.open(at: tempDir.appendingPathComponent("onboarding.sqlite"))
        // Full schema so the projects table carries the v30 overrides_json column.
        try await AppSchema.bootstrap(database: db)
        let store = ProjectStore(database: db)
        let model = OnboardingStateModel(projectStore: store)
        let personal = OnboardingStateModel.projectPresets[2]

        model.projectName = ""
        model.selectProjectPreset(personal)

        let firstCommit = await model.commitFirstProject()
        let secondCommit = await model.commitFirstProject()
        XCTAssertTrue(firstCommit)
        XCTAssertTrue(secondCommit)

        let projects = try await store.list()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.name, "Personal")
        XCTAssertEqual(projects.first?.indicatorColor, personal.color)
        try await db.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCommitFirstProjectReportsMissingStoreInsteadOfAdvancingBlindly() async {
        let model = OnboardingStateModel()

        let didCommit = await model.commitFirstProject()

        XCTAssertFalse(didCommit)
        XCTAssertEqual(model.projectCreationError, "Project storage is not ready yet.")
    }
}

@MainActor
final class AppStateModelPersistenceTests: XCTestCase {
    func testMarkOnboardingCompletePersistsAcrossModels() {
        AppStateModel.clearPersistedOnboardingCompleteForTesting()
        let model = AppStateModel()

        model.markOnboardingComplete()

        XCTAssertTrue(AppStateModel.persistedOnboardingComplete())
        XCTAssertEqual(
            AppStateModel(onboardingComplete: AppStateModel.persistedOnboardingComplete()).activeScene, .main)
        AppStateModel.clearPersistedOnboardingCompleteForTesting()
    }
}
