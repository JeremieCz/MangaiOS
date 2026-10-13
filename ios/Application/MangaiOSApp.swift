import SwiftData
import SwiftUI

@main
@MainActor
struct MangaiOSApp: App {
    private struct Dependencies {
        let container: ModelContainer
        let repository: SwiftDataLibraryRepository
        let importer: LocalImportService
        let root: URL
        let recoveryWarning: String?
    }
    private let storage: Result<Dependencies, Error>

    init() {
        storage = Result {
            let container = try StorageFactory.makeContainer()
            let root = try LocalImportService.defaultRoot()
            let repository = try SwiftDataLibraryRepository(container: container)
            let warning = try LibraryBackupService(root: root).recover(repository: repository)
            return Dependencies(container: container, repository: repository,
                                importer: LocalImportService(root: root), root: root, recoveryWarning: warning)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch storage {
            case .success(let dependencies):
                LibraryPlaceholderView(repository: dependencies.repository, importer: dependencies.importer,
                                       root: dependencies.root, initialError: dependencies.recoveryWarning)
                    .modelContainer(dependencies.container)
            case .failure:
                VStack {
                    ContentUnavailableView(
                        "Stockage indisponible",
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(
                            "Impossible d’ouvrir ou de réconcilier les données locales. "
                            + "Les copies de sécurité sont conservées. Relancez l’application "
                            + "après avoir vérifié l’espace disponible."
                        )
                    )
                    BackupRecoveryFilesView().padding()
                }
            }
        }
    }
}
